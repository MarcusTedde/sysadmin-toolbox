<#
.SYNOPSIS
    Copies server-level DHCP options from the source server to the partner server.

.DESCRIPTION
    DHCP failover replicates scope-level settings automatically, but server-level
    options (set at the IPv4 level, not on individual scopes) do NOT replicate.
    This script reads all server-level options from the source and applies them
    to the partner.

    Think of it like copying the "house rules" that apply to every room.
    Failover copies the room-specific settings, but the building-wide defaults
    need to be set manually on the new server. This script does that for you.

    What it copies:
      - All server-level IPv4 option values (DNS servers, domain name, etc.)
      - Vendor class definitions (needed before vendor-class options can be set)
      - Vendor-class specific option definitions
      - Vendor-class specific server-level option values

    What it does NOT copy (requires manual action):
      - DNS dynamic update credentials (see notes below)
      - DHCP policies at the server level
      - MAC address filters (allow/deny lists)

.PARAMETER SourceServer
    The FQDN or hostname of the original (old) DHCP server.

.PARAMETER PartnerServer
    The FQDN or hostname of the new DHCP server (failover partner).

.PARAMETER WhatIf
    Shows what would be changed without making any changes.

.EXAMPLE
    .\Copy-DHCPServerOptions.ps1 -SourceServer "OLD-DC.domain.local" -PartnerServer "NEW-DC.domain.local"

.EXAMPLE
    .\Copy-DHCPServerOptions.ps1 -SourceServer "OLD-DC" -PartnerServer "NEW-DC" -WhatIf

.NOTES
    Author  : Marcus Tedde
    Version : 1.1
    Requires: DHCP management tools (RSAT) installed on the machine running this script.
              Run as Administrator.

    DNS DYNAMIC UPDATE CREDENTIALS:
    This script cannot copy DNS dynamic update credentials because they are
    stored securely and cannot be read via PowerShell. You must configure
    these manually on the partner server:
      1. Open the DHCP console on the partner server
      2. Right-click IPv4 > Properties > DNS tab
      3. Click Advanced > Credentials
      4. Enter the same service account used on the source server
    If you skip this, the new server will not have permission to update
    existing DNS records on behalf of DHCP clients.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SourceServer,

    [Parameter(Mandatory)]
    [string]$PartnerServer
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK]   $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Write-SkipWarn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor White
}

# Counters
$script:copiedCount = 0
$script:skippedCount = 0
$script:failedCount = 0
$script:vendorCopiedCount = 0

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  COPY DHCP SERVER-LEVEL OPTIONS" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Source:  $SourceServer" -ForegroundColor White
Write-Host "  Target:  $PartnerServer" -ForegroundColor White
Write-Host ""

# ============================================================================
# PRE-FLIGHT CHECK
# ============================================================================
Write-Host "  Pre-flight checks..." -ForegroundColor White

# Check source
Write-Host "  Testing $SourceServer..." -NoNewline
if (-not (Test-Connection -ComputerName $SourceServer -Count 2 -Quiet)) {
    Write-Fail "Cannot reach $SourceServer."
    exit 1
}
try {
    Get-DhcpServerv4Scope -ComputerName $SourceServer -ErrorAction Stop | Out-Null
    Write-Success "Reachable, DHCP responding."
}
catch {
    # If the error is "no scopes", the server IS responding
    if ($_.Exception.Message -like "*no*scope*" -or $_.Exception.Message -like "*not found*") {
        Write-Success "Reachable, DHCP responding (no scopes, but service is up)."
    }
    else {
        Write-Fail "Cannot query DHCP on $SourceServer : $($_.Exception.Message)"
        exit 1
    }
}

# Check partner
Write-Host "  Testing $PartnerServer..." -NoNewline
if (-not (Test-Connection -ComputerName $PartnerServer -Count 2 -Quiet)) {
    Write-Fail "Cannot reach $PartnerServer."
    exit 1
}
try {
    Get-DhcpServerv4Scope -ComputerName $PartnerServer -ErrorAction Stop | Out-Null
    Write-Success "Reachable, DHCP responding."
}
catch {
    if ($_.Exception.Message -like "*no*scope*" -or $_.Exception.Message -like "*not found*") {
        Write-Success "Reachable, DHCP responding (no scopes, but service is up)."
    }
    else {
        Write-Fail "Cannot query DHCP on $PartnerServer : $($_.Exception.Message)"
        exit 1
    }
}

# ============================================================================
# RETRIEVE SOURCE SERVER-LEVEL OPTIONS
# ============================================================================
Write-Host ""
Write-Host "  --- RETRIEVING SERVER-LEVEL OPTIONS FROM SOURCE ---" -ForegroundColor Cyan
Write-Host ""

$sourceOpts = @()
try {
    $sourceOpts = @(Get-DhcpServerv4OptionValue -ComputerName $SourceServer -ErrorAction Stop)
}
catch {
    # Get-DhcpServerv4OptionValue throws when no server-level options exist.
    # This is expected and not an error.
}

if ($sourceOpts.Count -eq 0) {
    Write-Info "No standard server-level options found on $SourceServer."
}
else {
    Write-Info "Found $($sourceOpts.Count) server-level option(s) on $SourceServer :"
    Write-Host ""
    foreach ($opt in $sourceOpts) {
        Write-Host "    Option $($opt.OptionId) [$($opt.Name)]: $($opt.Value -join ', ')" -ForegroundColor White
    }
    Write-Host ""
}

# ============================================================================
# RETRIEVE PARTNER SERVER-LEVEL OPTIONS (for comparison)
# ============================================================================
$partnerOpts = @()
try {
    $partnerOpts = @(Get-DhcpServerv4OptionValue -ComputerName $PartnerServer -ErrorAction Stop)
}
catch {
    # No options on partner yet, which is expected for a new server.
}

# ============================================================================
# COPY STANDARD OPTIONS TO PARTNER
# ============================================================================
if ($sourceOpts.Count -gt 0) {
    Write-Host "  --- COPYING STANDARD OPTIONS TO PARTNER ---" -ForegroundColor Cyan
    Write-Host ""

    foreach ($opt in $sourceOpts) {
        $optId = $opt.OptionId
        $optName = $opt.Name
        $optValue = $opt.Value
        $sourceVal = $optValue -join ', '

        # Check if this option already exists on the partner with the same value
        $existingOpt = $partnerOpts | Where-Object { $_.OptionId -eq $optId }

        if ($existingOpt) {
            $partnerVal = $existingOpt.Value -join ', '
            if ($sourceVal -eq $partnerVal) {
                Write-Success "Option $optId [$optName]: Already matches ($sourceVal). Skipped."
                $script:skippedCount++
                continue
            }
            else {
                Write-Info "Option $optId [$optName]: Updating from '$partnerVal' to '$sourceVal'."
            }
        }
        else {
            Write-Info "Option $optId [$optName]: Setting to '$sourceVal'."
        }

        # Apply the option to the partner server
        try {
            if ($PSCmdlet.ShouldProcess("$PartnerServer Option $optId [$optName]", "Set value to '$sourceVal'")) {
                Set-DhcpServerv4OptionValue -ComputerName $PartnerServer -OptionId $optId -Value $optValue -ErrorAction Stop
                Write-Success "Option $optId [$optName]: Set successfully."
                $script:copiedCount++
            }
        }
        catch {
            Write-Fail "Option $optId [$optName]: Failed to set. $($_.Exception.Message)"
            $script:failedCount++
        }
    }
}

# ============================================================================
# CHECK FOR VENDOR-CLASS DEFINITIONS AND OPTIONS
# ============================================================================
Write-Host ""
Write-Host "  --- CHECKING VENDOR-CLASS DEFINITIONS AND OPTIONS ---" -ForegroundColor Cyan
Write-Host ""

# Vendor classes (e.g. "Cisco AP", "Microsoft Windows Options") are server-level
# definitions that do NOT replicate via failover. If the source server has custom
# vendor classes, we need to:
#   1. Create the vendor class definition on the partner
#   2. Create any custom option definitions for that vendor class
#   3. Then set the option values
# If we skip steps 1 and 2, step 3 fails with "option definition does not exist."

$sourceVendorClasses = @()
try {
    $sourceVendorClasses = @(Get-DhcpServerv4Class -ComputerName $SourceServer -Type Vendor -ErrorAction Stop)
}
catch {
    # No vendor classes or unable to query
}

$partnerVendorClasses = @()
try {
    $partnerVendorClasses = @(Get-DhcpServerv4Class -ComputerName $PartnerServer -Type Vendor -ErrorAction Stop)
}
catch {
    # No vendor classes on partner
}

if ($sourceVendorClasses.Count -eq 0) {
    Write-Success "No vendor classes defined on source. Nothing to check."
}
else {
    Write-Info "Found $($sourceVendorClasses.Count) vendor class(es) on source."

    $partnerVcNames = $partnerVendorClasses | ForEach-Object { $_.Name }

    foreach ($vc in $sourceVendorClasses) {
        Write-Host ""
        Write-Host "  Vendor class: $($vc.Name)" -ForegroundColor White

        # Step 1: Ensure the vendor class definition exists on the partner
        if ($vc.Name -in $partnerVcNames) {
            Write-Success "  Class definition exists on partner. Skipped."
        }
        else {
            Write-Info "  Class definition missing on partner. Creating..."
            try {
                if ($PSCmdlet.ShouldProcess("$PartnerServer Vendor Class '$($vc.Name)'", "Create vendor class definition")) {
                    Add-DhcpServerv4Class -ComputerName $PartnerServer -Name $vc.Name -Type Vendor -Data $vc.Data -Description $vc.Description -ErrorAction Stop
                    Write-Success "  Class definition '$($vc.Name)' created on partner."
                    $script:vendorCopiedCount++
                }
            }
            catch {
                Write-Fail "  Could not create class definition: $($_.Exception.Message)"
                $script:failedCount++
                Write-Host "    Skipping options for this vendor class." -ForegroundColor Yellow
                continue
            }
        }

        # Step 2: Ensure vendor-class option definitions exist on the partner
        $sourceVcOptDefs = @()
        try {
            $sourceVcOptDefs = @(Get-DhcpServerv4OptionDefinition -ComputerName $SourceServer -VendorClass $vc.Name -ErrorAction Stop)
        }
        catch {
            # No custom option definitions for this vendor class
        }

        if ($sourceVcOptDefs.Count -gt 0) {
            $partnerVcOptDefs = @()
            try {
                $partnerVcOptDefs = @(Get-DhcpServerv4OptionDefinition -ComputerName $PartnerServer -VendorClass $vc.Name -ErrorAction Stop)
            }
            catch {
                # No option definitions on partner for this class
            }

            $partnerOptDefIds = $partnerVcOptDefs | ForEach-Object { $_.OptionId }

            foreach ($optDef in $sourceVcOptDefs) {
                if ($optDef.OptionId -in $partnerOptDefIds) {
                    Write-Success "  Option definition $($optDef.OptionId) [$($optDef.Name)] exists on partner."
                }
                else {
                    try {
                        if ($PSCmdlet.ShouldProcess("$PartnerServer Option Definition $($optDef.OptionId) for '$($vc.Name)'", "Create option definition")) {
                            # Build parameters dynamically to handle optional switches
                            # like -MultiValued which must only be present when true.
                            $optDefParams = @{
                                ComputerName = $PartnerServer
                                OptionId     = $optDef.OptionId
                                Name         = $optDef.Name
                                Type         = $optDef.Type
                                VendorClass  = $vc.Name
                                ErrorAction  = "Stop"
                            }
                            if ($optDef.MultiValued) {
                                $optDefParams["MultiValued"] = $true
                            }
                            if ($optDef.Description) {
                                $optDefParams["Description"] = $optDef.Description
                            }
                            if ($optDef.DefaultValue) {
                                $optDefParams["DefaultValue"] = $optDef.DefaultValue
                            }
                            Add-DhcpServerv4OptionDefinition @optDefParams
                            Write-Success "  Option definition $($optDef.OptionId) [$($optDef.Name)] created on partner."
                            $script:vendorCopiedCount++
                        }
                    }
                    catch {
                        Write-Fail "  Could not create option definition $($optDef.OptionId): $($_.Exception.Message)"
                        $script:failedCount++
                    }
                }
            }
        }

        # Step 3: Copy vendor-class option values at server level
        $vcOpts = @()
        try {
            $vcOpts = @(Get-DhcpServerv4OptionValue -ComputerName $SourceServer -VendorClass $vc.Name -ErrorAction Stop)
        }
        catch {
            # No server-level option values for this vendor class
        }

        if ($vcOpts.Count -gt 0) {
            Write-Info "  $($vcOpts.Count) server-level option value(s) to copy."

            foreach ($opt in $vcOpts) {
                $optId = $opt.OptionId
                $optName = $opt.Name
                $optValue = $opt.Value
                $sourceVal = $optValue -join ', '

                try {
                    if ($PSCmdlet.ShouldProcess("$PartnerServer VendorClass '$($vc.Name)' Option $optId", "Set value to '$sourceVal'")) {
                        Set-DhcpServerv4OptionValue -ComputerName $PartnerServer -OptionId $optId -VendorClass $vc.Name -Value $optValue -ErrorAction Stop
                        Write-Success "  Option $optId [$optName]: Set successfully."
                        $script:vendorCopiedCount++
                    }
                }
                catch {
                    Write-Fail "  Option $optId [$optName]: Failed. $($_.Exception.Message)"
                    $script:failedCount++
                }
            }
        }
        else {
            Write-Info "  No server-level option values for this vendor class."
        }
    }
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Standard options copied:  $($script:copiedCount)" -ForegroundColor Green
Write-Host "  Standard options skipped: $($script:skippedCount) (already matched)" -ForegroundColor White
Write-Host "  Vendor class items copied: $($script:vendorCopiedCount)" -ForegroundColor Green
Write-Host "  Failed:                   $($script:failedCount)" -ForegroundColor $(if ($script:failedCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($script:failedCount -gt 0) {
    Write-Host "  Some items failed to copy. Review the errors above." -ForegroundColor Red
    Write-Host "  You may need to set them manually using:" -ForegroundColor Yellow
    Write-Host "    Set-DhcpServerv4OptionValue -ComputerName `"$PartnerServer`" -OptionId <ID> -Value <Value>" -ForegroundColor Cyan
}
elseif ($script:copiedCount -gt 0 -or $script:skippedCount -gt 0 -or $script:vendorCopiedCount -gt 0) {
    Write-Host "  All server-level options are now in sync." -ForegroundColor Green
}
else {
    Write-Host "  No server-level options to copy. Both servers are clean." -ForegroundColor Green
}

Write-Host ""
Write-Host "  MANUAL STEP REQUIRED: DNS Dynamic Update Credentials" -ForegroundColor Yellow
Write-Host "  ====================================================" -ForegroundColor Yellow
Write-Host "  DNS update credentials cannot be read or copied via PowerShell." -ForegroundColor Yellow
Write-Host "  If $SourceServer uses a service account for DNS dynamic updates," -ForegroundColor Yellow
Write-Host "  you must configure the same account on $PartnerServer :" -ForegroundColor Yellow
Write-Host ""
Write-Host "    1. Open DHCP console on $PartnerServer" -ForegroundColor White
Write-Host "    2. Right-click IPv4 > Properties" -ForegroundColor White
Write-Host "    3. Go to the DNS tab" -ForegroundColor White
Write-Host "    4. Click Advanced > Credentials" -ForegroundColor White
Write-Host "    5. Enter the same service account and password" -ForegroundColor White
Write-Host ""
Write-Host "  Without this, the new server cannot update existing DNS" -ForegroundColor Yellow
Write-Host "  A records for DHCP clients, causing stale DNS entries." -ForegroundColor Yellow
Write-Host ""
