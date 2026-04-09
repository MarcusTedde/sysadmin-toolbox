<#
.SYNOPSIS
    Verifies DHCP failover replication between source and partner servers.

.DESCRIPTION
    Run this script after Migrate-DHCPFailover.ps1 to confirm that all scopes,
    leases, reservations, and scope-level options have replicated correctly
    from the source server to the partner server.

    The script compares both servers side-by-side and produces a clear
    pass/fail report. Think of it like a stocktake after moving warehouses:
    you check every shelf in the new building against the inventory list
    from the old one.

    What it checks:
      - Both servers are reachable and DHCP service is running
      - Failover relationship is in a healthy state
      - Scope count and scope IDs match
      - Lease counts match (or are within acceptable drift)
      - Reservation counts and MAC/IP mappings match exactly
      - Scope-level option values match (DNS servers, gateways, etc.)
      - Exclusion ranges match
      - Server-level options are flagged (they don't replicate via failover)

.PARAMETER SourceServer
    The FQDN or hostname of the original (old) DHCP server.

.PARAMETER PartnerServer
    The FQDN or hostname of the new DHCP server (failover partner).

.PARAMETER FailoverName
    Name of the failover relationship to check. Defaults to "DHCP-Migration".

.PARAMETER ExportReport
    If specified, saves the verification report to a text file in the given directory.

.EXAMPLE
    .\Verify-DHCPReplication.ps1 -SourceServer "OLD-DC.domain.local" -PartnerServer "NEW-DC.domain.local"

.EXAMPLE
    .\Verify-DHCPReplication.ps1 -SourceServer "OLD-DC" -PartnerServer "NEW-DC" -ExportReport "C:\DHCPMigration"

.NOTES
    Author  : Marcus Tedde
    Version : 1.1
    Requires: DHCP management tools (RSAT) installed on the machine running this script.
              A failover relationship must already exist between the two servers.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceServer,

    [Parameter(Mandatory)]
    [string]$PartnerServer,

    [string]$FailoverName = "DHCP-Migration",

    [string]$ExportReport
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Check {
    param([string]$Message)
    Write-Host "  [CHECK] $Message" -ForegroundColor White
}

function Write-Pass {
    param([string]$Message)
    Write-Host "  [PASS]  $Message" -ForegroundColor Green
    $script:passCount++
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL]  $Message" -ForegroundColor Red
    $script:failCount++
}

function Write-SkipWarn {
    param([string]$Message)
    Write-Host "  [WARN]  $Message" -ForegroundColor Yellow
    $script:warnCount++
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO]  $Message" -ForegroundColor Gray
}

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "  --- $Message ---" -ForegroundColor Cyan
    Write-Host ""
}

function Add-Report {
    param([string]$Line)
    $script:reportLines += $Line
}

# Initialise counters and report buffer
$script:passCount = 0
$script:failCount = 0
$script:warnCount = 0
$script:reportLines = @()

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DHCP FAILOVER REPLICATION VERIFICATION" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Source Server:   $SourceServer" -ForegroundColor White
Write-Host "  Partner Server:  $PartnerServer" -ForegroundColor White
Write-Host "  Failover Name:   $FailoverName" -ForegroundColor White
Write-Host ""

Add-Report "DHCP Failover Replication Verification Report"
Add-Report "Generated: $(Get-Date)"
Add-Report "Source Server:  $SourceServer"
Add-Report "Partner Server: $PartnerServer"
Add-Report "Failover Name:  $FailoverName"
Add-Report ("=" * 60)

# ============================================================================
# 0. PRE-FLIGHT CONNECTIVITY CHECK
# ============================================================================
Write-Section "PRE-FLIGHT CONNECTIVITY CHECK"
Add-Report ""
Add-Report "PRE-FLIGHT CONNECTIVITY CHECK"
Add-Report ("-" * 40)

$canContinue = $true

# Check source server
Write-Host "  Testing $SourceServer..." -NoNewline
if (Test-Connection -ComputerName $SourceServer -Count 2 -Quiet) {
    try {
        $svcSource = Get-Service -ComputerName $SourceServer -Name "DHCPServer" -ErrorAction Stop
        if ($svcSource.Status -eq "Running") {
            Write-Pass "Reachable, DHCP service running."
            Add-Report "  PASS: $SourceServer reachable, DHCP running"
        }
        else {
            Write-SkipWarn "Reachable, but DHCP service is $($svcSource.Status)."
            Add-Report "  WARN: $SourceServer DHCP service $($svcSource.Status)"
        }
    }
    catch {
        Write-Fail "Reachable, but cannot query DHCP service: $($_.Exception.Message)"
        Add-Report "  FAIL: $SourceServer DHCP service query failed"
        $canContinue = $false
    }
}
else {
    Write-Fail "Cannot reach $SourceServer on the network."
    Add-Report "  FAIL: $SourceServer unreachable"
    $canContinue = $false
}

# Check partner server
Write-Host "  Testing $PartnerServer..." -NoNewline
if (Test-Connection -ComputerName $PartnerServer -Count 2 -Quiet) {
    try {
        $svcPartner = Get-Service -ComputerName $PartnerServer -Name "DHCPServer" -ErrorAction Stop
        if ($svcPartner.Status -eq "Running") {
            Write-Pass "Reachable, DHCP service running."
            Add-Report "  PASS: $PartnerServer reachable, DHCP running"
        }
        else {
            Write-SkipWarn "Reachable, but DHCP service is $($svcPartner.Status)."
            Add-Report "  WARN: $PartnerServer DHCP service $($svcPartner.Status)"
        }
    }
    catch {
        Write-Fail "Reachable, but cannot query DHCP service: $($_.Exception.Message)"
        Add-Report "  FAIL: $PartnerServer DHCP service query failed"
        $canContinue = $false
    }
}
else {
    Write-Fail "Cannot reach $PartnerServer on the network."
    Add-Report "  FAIL: $PartnerServer unreachable"
    $canContinue = $false
}

if (-not $canContinue) {
    Write-Host ""
    Write-Host "  Cannot continue verification. Fix connectivity issues above first." -ForegroundColor Red
    Add-Report "RESULT: ABORTED - connectivity failure"
    exit 1
}

# ============================================================================
# 1. CHECK FAILOVER RELATIONSHIP STATUS
# ============================================================================
Write-Section "FAILOVER RELATIONSHIP STATUS"
Add-Report ""
Add-Report "FAILOVER RELATIONSHIP STATUS"
Add-Report ("-" * 40)

try {
    $foStatus = Get-DhcpServerv4Failover -ComputerName $SourceServer -Name $FailoverName -ErrorAction Stop

    Write-Check "Failover state: $($foStatus.State)"
    Add-Report "  State: $($foStatus.State)"

    if ($foStatus.State -eq "Normal") {
        Write-Pass "Failover relationship is in Normal state."
        Add-Report "  PASS: Normal state"
    }
    elseif ($foStatus.State -eq "CommunicationInterrupted") {
        Write-Fail "Failover is in Communication Interrupted state. Servers cannot sync."
        Add-Report "  FAIL: Communication Interrupted"
    }
    else {
        Write-SkipWarn "Failover state is '$($foStatus.State)'. Expected 'Normal'."
        Add-Report "  WARN: Unexpected state: $($foStatus.State)"
    }

    Write-Check "Mode: $($foStatus.Mode)"
    Write-Check "Partner: $($foStatus.PartnerServer)"
    Write-Check "Max Client Lead Time: $($foStatus.MaxClientLeadTime)"
    Add-Report "  Mode: $($foStatus.Mode)"
    Add-Report "  Partner: $($foStatus.PartnerServer)"
    Add-Report "  MCLT: $($foStatus.MaxClientLeadTime)"
}
catch {
    Write-Fail "Could not retrieve failover relationship '$FailoverName': $($_.Exception.Message)"
    Write-Host "  Is the failover name correct? Run Get-DhcpServerv4Failover -ComputerName `"$SourceServer`" to list all." -ForegroundColor Yellow
    Add-Report "  FAIL: Could not retrieve failover relationship"
}

# ============================================================================
# 2. COMPARE SCOPE LISTS
# ============================================================================
Write-Section "SCOPE COMPARISON"
Add-Report ""
Add-Report "SCOPE COMPARISON"
Add-Report ("-" * 40)

try {
    $sourceScopes = @(Get-DhcpServerv4Scope -ComputerName $SourceServer -ErrorAction Stop)
    $partnerScopes = @(Get-DhcpServerv4Scope -ComputerName $PartnerServer -ErrorAction Stop)

    # Separate active and inactive scopes on the source.
    # Failover only replicates active scopes, so inactive scopes on the source
    # are expected to be absent from the partner. They should not count as failures.
    $sourceActiveScopes = @($sourceScopes | Where-Object { $_.State -eq "Active" })
    $sourceInactiveScopes = @($sourceScopes | Where-Object { $_.State -ne "Active" })

    $sourceActiveScopeIds = $sourceActiveScopes | ForEach-Object { $_.ScopeId.ToString() } | Sort-Object
    $partnerScopeIds = $partnerScopes | ForEach-Object { $_.ScopeId.ToString() } | Sort-Object

    # Report inactive scopes as informational (not failures)
    if ($sourceInactiveScopes.Count -gt 0) {
        Write-Info "$($sourceInactiveScopes.Count) inactive/disabled scope(s) on source (not included in failover):"
        foreach ($scope in $sourceInactiveScopes) {
            Write-Host "    $($scope.ScopeId)  [$($scope.Name)]  State: $($scope.State)" -ForegroundColor Gray
        }
        Add-Report "  INFO: $($sourceInactiveScopes.Count) inactive scope(s) on source (skipped, not part of failover)"
        Write-Host ""
    }

    # Check active scope count
    if ($sourceActiveScopes.Count -eq $partnerScopes.Count) {
        Write-Pass "Active scope count matches: $($sourceActiveScopes.Count) on source, $($partnerScopes.Count) on partner."
        Add-Report "  PASS: Active scope count matches ($($sourceActiveScopes.Count))"
    }
    else {
        Write-Fail "Active scope count mismatch: Source=$($sourceActiveScopes.Count) active  Partner=$($partnerScopes.Count)"
        Add-Report "  FAIL: Active scope count mismatch (Source=$($sourceActiveScopes.Count), Partner=$($partnerScopes.Count))"
    }

    # Check for active scopes on source but missing from partner
    $missingOnPartner = @()
    if ($sourceActiveScopeIds) {
        $missingOnPartner = @($sourceActiveScopeIds | Where-Object { $_ -notin $partnerScopeIds })
    }
    if ($missingOnPartner.Count -gt 0) {
        foreach ($missing in $missingOnPartner) {
            $scopeName = ($sourceActiveScopes | Where-Object { $_.ScopeId.ToString() -eq $missing }).Name
            Write-Fail "Scope $missing [$scopeName] is active on source but NOT on partner."
            Add-Report "  FAIL: Missing on partner: $missing [$scopeName]"
        }
    }

    # Check for unexpected scopes on partner that aren't on source
    $extraOnPartner = @()
    if ($partnerScopeIds) {
        $extraOnPartner = @($partnerScopeIds | Where-Object { $_ -notin $sourceActiveScopeIds })
    }
    if ($extraOnPartner.Count -gt 0) {
        foreach ($extra in $extraOnPartner) {
            $scopeName = ($partnerScopes | Where-Object { $_.ScopeId.ToString() -eq $extra }).Name
            Write-SkipWarn "Scope $extra [$scopeName] exists on partner but NOT active on source (unexpected)."
            Add-Report "  WARN: Extra on partner: $extra [$scopeName]"
        }
    }

    if ($missingOnPartner.Count -eq 0 -and $extraOnPartner.Count -eq 0) {
        Write-Pass "All active scope IDs match between source and partner."
        Add-Report "  PASS: All active scope IDs match"
    }
}
catch {
    Write-Fail "Could not retrieve scopes: $($_.Exception.Message)"
    Add-Report "  FAIL: Could not retrieve scopes"
    Write-Host "  Cannot continue verification without scope data. Aborting." -ForegroundColor Red
    exit 1
}

# ============================================================================
# 3. COMPARE LEASES, RESERVATIONS, OPTIONS, AND EXCLUSIONS PER SCOPE
# ============================================================================
Write-Section "PER-SCOPE DETAILED COMPARISON"
Add-Report ""
Add-Report "PER-SCOPE DETAILED COMPARISON"
Add-Report ("-" * 40)

# Only compare active scopes that exist on both servers
$commonScopeIds = @()
if ($sourceActiveScopeIds) {
    $commonScopeIds = @($sourceActiveScopeIds | Where-Object { $_ -in $partnerScopeIds })
}

foreach ($scopeIdStr in $commonScopeIds) {
    $scopeId = [System.Net.IPAddress]::Parse($scopeIdStr)
    $scopeName = ($sourceScopes | Where-Object { $_.ScopeId.ToString() -eq $scopeIdStr }).Name

    Write-Host ""
    Write-Host "  Scope: $scopeIdStr  [$scopeName]" -ForegroundColor White
    Add-Report ""
    Add-Report "  Scope: $scopeIdStr [$scopeName]"

    # --- Leases ---
    $sourceLeases = @(Get-DhcpServerv4Lease -ComputerName $SourceServer -ScopeId $scopeId -ErrorAction SilentlyContinue)
    $partnerLeases = @(Get-DhcpServerv4Lease -ComputerName $PartnerServer -ScopeId $scopeId -ErrorAction SilentlyContinue)

    $leaseDiff = [Math]::Abs($sourceLeases.Count - $partnerLeases.Count)
    if ($sourceLeases.Count -eq $partnerLeases.Count) {
        Write-Pass "  Leases: $($sourceLeases.Count) on both servers."
        Add-Report "    PASS: Leases match ($($sourceLeases.Count))"
    }
    elseif ($leaseDiff -le 2) {
        # Small differences (1-2) are normal due to timing between checks
        Write-SkipWarn "  Leases: Source=$($sourceLeases.Count)  Partner=$($partnerLeases.Count) (minor drift, likely timing)."
        Add-Report "    WARN: Lease drift (Source=$($sourceLeases.Count), Partner=$($partnerLeases.Count))"
    }
    else {
        Write-Fail "  Leases: Source=$($sourceLeases.Count)  Partner=$($partnerLeases.Count) (significant difference)."
        Add-Report "    FAIL: Lease mismatch (Source=$($sourceLeases.Count), Partner=$($partnerLeases.Count))"
    }

    # --- Reservations ---
    $sourceRes = @(Get-DhcpServerv4Reservation -ComputerName $SourceServer -ScopeId $scopeId -ErrorAction SilentlyContinue)
    $partnerRes = @(Get-DhcpServerv4Reservation -ComputerName $PartnerServer -ScopeId $scopeId -ErrorAction SilentlyContinue)

    if ($sourceRes.Count -eq $partnerRes.Count) {
        Write-Pass "  Reservations: $($sourceRes.Count) on both servers."
        Add-Report "    PASS: Reservation count match ($($sourceRes.Count))"
    }
    else {
        Write-Fail "  Reservations: Source=$($sourceRes.Count)  Partner=$($partnerRes.Count)"
        Add-Report "    FAIL: Reservation count mismatch (Source=$($sourceRes.Count), Partner=$($partnerRes.Count))"
    }

    # Check reservation details (IP + MAC mapping) if counts match
    if ($sourceRes.Count -gt 0 -and $sourceRes.Count -eq $partnerRes.Count) {
        $resMismatch = 0
        foreach ($res in $sourceRes) {
            $partnerMatch = $partnerRes | Where-Object {
                $_.IPAddress.ToString() -eq $res.IPAddress.ToString() -and
                $_.ClientId -eq $res.ClientId
            }
            if (-not $partnerMatch) {
                $resMismatch++
                if ($resMismatch -le 3) {
                    Write-Fail "  Reservation mismatch: $($res.IPAddress) / $($res.ClientId) [$($res.Name)] not found on partner."
                    Add-Report "    FAIL: Missing reservation: $($res.IPAddress) / $($res.ClientId) [$($res.Name)]"
                }
            }
        }
        if ($resMismatch -eq 0) {
            Write-Pass "  All reservation IP/MAC mappings match."
            Add-Report "    PASS: All reservation details match"
        }
        elseif ($resMismatch -gt 3) {
            Write-Fail "  $resMismatch total reservation mismatches (only first 3 shown)."
            Add-Report "    FAIL: $resMismatch reservation mismatches total"
        }
    }

    # --- Scope Options ---
    # Retrieve from each server independently so a failure on one doesn't
    # mask the state of the other. Get-DhcpServerv4OptionValue throws when
    # a scope has no options configured, so we catch that per-server.
    $sourceOpts = @()
    $partnerOpts = @()
    $sourceOptsOk = $true
    $partnerOptsOk = $true

    try {
        $sourceOpts = @(Get-DhcpServerv4OptionValue -ComputerName $SourceServer -ScopeId $scopeId -ErrorAction Stop)
    }
    catch {
        # No options configured on source for this scope (expected for some scopes)
        $sourceOptsOk = $true  # Not an error, just empty
    }

    try {
        $partnerOpts = @(Get-DhcpServerv4OptionValue -ComputerName $PartnerServer -ScopeId $scopeId -ErrorAction Stop)
    }
    catch {
        # No options configured on partner for this scope
        $partnerOptsOk = $true  # Not an error, just empty
    }

    if ($sourceOpts.Count -eq 0 -and $partnerOpts.Count -eq 0) {
        Write-Pass "  Scope options: None configured (same on both)."
        Add-Report "    PASS: No scope options configured"
    }
    elseif ($sourceOpts.Count -ne $partnerOpts.Count) {
        Write-Fail "  Scope options count: Source=$($sourceOpts.Count)  Partner=$($partnerOpts.Count)"
        Add-Report "    FAIL: Scope option count mismatch (Source=$($sourceOpts.Count), Partner=$($partnerOpts.Count))"
    }
    else {
        # Same count, compare each option value
        $optMismatch = 0
        foreach ($opt in $sourceOpts) {
            $partnerOpt = $partnerOpts | Where-Object { $_.OptionId -eq $opt.OptionId }
            if (-not $partnerOpt) {
                $optMismatch++
                Write-Fail "  Option $($opt.OptionId) [$($opt.Name)] missing on partner."
                Add-Report "    FAIL: Missing option $($opt.OptionId) [$($opt.Name)]"
            }
            elseif (($opt.Value -join ',') -ne ($partnerOpt.Value -join ',')) {
                $optMismatch++
                Write-Fail "  Option $($opt.OptionId) [$($opt.Name)] value differs: Source='$($opt.Value -join ',')' Partner='$($partnerOpt.Value -join ',')'"
                Add-Report "    FAIL: Option $($opt.OptionId) value mismatch"
            }
        }
        if ($optMismatch -eq 0) {
            Write-Pass "  Scope options: $($sourceOpts.Count) options match."
            Add-Report "    PASS: All $($sourceOpts.Count) scope options match"
        }
    }

    # --- Exclusion Ranges ---
    # Get-DhcpServerv4ExclusionRange returns nothing (not an error) when a scope
    # has no exclusion ranges. The @() wrapping gives us an empty array with Count=0.
    # We retrieve from each server independently for the same reason as scope options.
    $sourceExcl = @()
    $partnerExcl = @()

    try {
        $sourceExcl = @(Get-DhcpServerv4ExclusionRange -ComputerName $SourceServer -ScopeId $scopeId -ErrorAction Stop)
    }
    catch {
        Write-SkipWarn "  Could not retrieve exclusion ranges from source: $($_.Exception.Message)"
        Add-Report "    WARN: Could not retrieve source exclusion ranges"
    }

    try {
        $partnerExcl = @(Get-DhcpServerv4ExclusionRange -ComputerName $PartnerServer -ScopeId $scopeId -ErrorAction Stop)
    }
    catch {
        Write-SkipWarn "  Could not retrieve exclusion ranges from partner: $($_.Exception.Message)"
        Add-Report "    WARN: Could not retrieve partner exclusion ranges"
    }

    if ($sourceExcl.Count -eq $partnerExcl.Count) {
        if ($sourceExcl.Count -eq 0) {
            Write-Pass "  Exclusion ranges: None configured (same on both)."
            Add-Report "    PASS: No exclusion ranges"
        }
        else {
            Write-Pass "  Exclusion ranges: $($sourceExcl.Count) on both servers."
            Add-Report "    PASS: Exclusion ranges match ($($sourceExcl.Count))"
        }
    }
    else {
        Write-Fail "  Exclusion ranges: Source=$($sourceExcl.Count)  Partner=$($partnerExcl.Count)"
        Add-Report "    FAIL: Exclusion range count mismatch"
    }
}

# ============================================================================
# 4. CHECK SERVER-LEVEL OPTIONS (THESE DON'T REPLICATE)
# ============================================================================
Write-Section "SERVER-LEVEL OPTIONS (manual action required)"
Add-Report ""
Add-Report "SERVER-LEVEL OPTIONS"
Add-Report ("-" * 40)

# Retrieve server-level options independently from each server.
# Get-DhcpServerv4OptionValue without -ScopeId returns server-level options.
$sourceServerOpts = @()
$partnerServerOpts = @()

try {
    $sourceServerOpts = @(Get-DhcpServerv4OptionValue -ComputerName $SourceServer -ErrorAction Stop)
}
catch {
    # No server-level options, or unable to retrieve. Either way, empty array.
}

try {
    $partnerServerOpts = @(Get-DhcpServerv4OptionValue -ComputerName $PartnerServer -ErrorAction Stop)
}
catch {
    # No server-level options on partner, or unable to retrieve.
}

if ($sourceServerOpts.Count -eq 0) {
    Write-Pass "No server-level options on source. Nothing to check."
    Add-Report "  PASS: No server-level options on source"
}
else {
    Write-Host "  Server-level options do NOT replicate via failover." -ForegroundColor Yellow
    Write-Host "  These must be set manually on the partner server." -ForegroundColor Yellow
    Write-Host ""
    Add-Report "  NOTE: Server-level options do NOT replicate via failover."

    foreach ($opt in $sourceServerOpts) {
        $partnerMatch = $partnerServerOpts | Where-Object { $_.OptionId -eq $opt.OptionId }
        $sourceVal = $opt.Value -join ', '

        if ($partnerMatch) {
            $partnerVal = $partnerMatch.Value -join ', '
            if ($sourceVal -eq $partnerVal) {
                Write-Pass "  Option $($opt.OptionId) [$($opt.Name)]: matches ($sourceVal)"
                Add-Report "    PASS: Option $($opt.OptionId) [$($opt.Name)] matches"
            }
            else {
                Write-Fail "  Option $($opt.OptionId) [$($opt.Name)]: MISMATCH  Source='$sourceVal'  Partner='$partnerVal'"
                Add-Report "    FAIL: Option $($opt.OptionId) mismatch (Source='$sourceVal', Partner='$partnerVal')"
                Write-Host "    Fix: Set-DhcpServerv4OptionValue -ComputerName `"$PartnerServer`" -OptionId $($opt.OptionId) -Value $sourceVal" -ForegroundColor Cyan
            }
        }
        else {
            Write-Fail "  Option $($opt.OptionId) [$($opt.Name)]: MISSING on partner (Source='$sourceVal')"
            Add-Report "    FAIL: Option $($opt.OptionId) [$($opt.Name)] missing on partner"
            Write-Host "    Fix: Set-DhcpServerv4OptionValue -ComputerName `"$PartnerServer`" -OptionId $($opt.OptionId) -Value $sourceVal" -ForegroundColor Cyan
        }
    }
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  VERIFICATION SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Passed:   $($script:passCount)" -ForegroundColor Green
Write-Host "  Warnings: $($script:warnCount)" -ForegroundColor Yellow
Write-Host "  Failed:   $($script:failCount)" -ForegroundColor $(if ($script:failCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

Add-Report ""
Add-Report ("=" * 60)
Add-Report "SUMMARY: Passed=$($script:passCount)  Warnings=$($script:warnCount)  Failed=$($script:failCount)"

if ($script:failCount -eq 0 -and $script:warnCount -eq 0) {
    Write-Host "  RESULT: ALL CHECKS PASSED. Replication is fully verified." -ForegroundColor Green
    Add-Report "RESULT: ALL CHECKS PASSED"
}
elseif ($script:failCount -eq 0) {
    Write-Host "  RESULT: All critical checks passed. Warnings are informational only." -ForegroundColor Green
    Write-Host "  Lease count warnings (1-2 difference) are normal due to timing between checks." -ForegroundColor Yellow
    Add-Report "RESULT: PASSED with warnings"
}
else {
    Write-Host "  RESULT: $($script:failCount) check(s) FAILED. Review the failures above." -ForegroundColor Red
    Write-Host ""
    Write-Host "  To force a full replication sync, run:" -ForegroundColor Yellow
    Write-Host "    Invoke-DhcpServerv4FailoverReplication -ComputerName `"$SourceServer`" -Name `"$FailoverName`"" -ForegroundColor Cyan
    Write-Host "  Then wait a minute and run this verification script again." -ForegroundColor Yellow
    Add-Report "RESULT: FAILED - $($script:failCount) check(s) require attention"
}

# ============================================================================
# EXPORT REPORT (optional)
# ============================================================================
if ($ExportReport) {
    try {
        if (-not (Test-Path $ExportReport)) {
            New-Item -ItemType Directory -Path $ExportReport -Force | Out-Null
        }
        $reportFile = Join-Path $ExportReport "DHCPVerification_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').txt"
        $script:reportLines | Out-File -FilePath $reportFile -Encoding UTF8
        Write-Host ""
        Write-Host "  Report saved to: $reportFile" -ForegroundColor Green
    }
    catch {
        Write-Host "  Could not save report: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
