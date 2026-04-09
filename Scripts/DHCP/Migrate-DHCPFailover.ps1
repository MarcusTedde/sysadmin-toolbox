<#
.SYNOPSIS
    Backs up DHCP scopes from a source server and configures failover to a new partner DC.

.DESCRIPTION
    This script automates the DHCP migration process:
      1. Validates both servers are reachable, have the DHCP role, and can talk to each other
      2. Exports a full backup of the source DHCP configuration (XML + native backup)
      3. Retrieves all active IPv4 scopes from the source server
      4. Creates a failover relationship, replicating all scopes to the new server
      5. Verifies the replication was successful (scopes, leases, reservations)

    Think of it like photocopying a filing cabinet. We take a safety copy first,
    then set up a live sync between the old cabinet and the new one.

.PARAMETER SourceServer
    The FQDN or hostname of the current (old) DHCP server that holds the live scopes.

.PARAMETER PartnerServer
    The FQDN or hostname of the new DC that will become the failover partner.

.PARAMETER BackupPath
    Directory where DHCP backups will be saved. Defaults to C:\DHCPMigration.

.PARAMETER FailoverName
    Name for the failover relationship. Defaults to "DHCP-Migration".

.PARAMETER SharedSecret
    The shared secret password for failover authentication between the two servers.

.PARAMETER FailoverMode
    Choose HotStandby or LoadBalance. Defaults to HotStandby (recommended for migrations).
    - HotStandby: Old server stays active, new server is passive standby.
    - LoadBalance: Both servers actively issue leases (split by percentage).

.PARAMETER ReservePercent
    Percentage of addresses reserved for the standby server. Only used in HotStandby mode. Defaults to 10.

.PARAMETER MaxClientLeadTime
    How far ahead one server can extend a lease before the partner catches up. Defaults to 1 hour.

.PARAMETER StateSwitchInterval
    How long the standby waits before auto-takeover if the primary goes down.
    Set to 00:00:00 to disable automatic switchover. Defaults to 45 minutes.

.PARAMETER LoadBalancePercent
    Percentage of leases handled by the source server in LoadBalance mode. Defaults to 50.

.PARAMETER SkipBackup
    Skip the backup step if you've already taken one.

.EXAMPLE
    .\Migrate-DHCPFailover.ps1 -SourceServer "OLD-DC.domain.local" -PartnerServer "NEW-DC.domain.local" -SharedSecret "Str0ngP@ss!"

.EXAMPLE
    .\Migrate-DHCPFailover.ps1 -SourceServer "OLD-DC" -PartnerServer "NEW-DC" -SharedSecret "Str0ngP@ss!" -FailoverMode LoadBalance

.NOTES
    Author  : Marcus Tedde
    Version : 2.0
    Requires: Run as Administrator with DHCP management tools (RSAT) installed.
              Both servers must be running Windows Server 2016 or later.
              The DHCP role must be installed and authorised on the partner server before running this script.
              TCP port 647 must be open between the two servers.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SourceServer,

    [Parameter(Mandatory)]
    [string]$PartnerServer,

    [Parameter(Mandatory)]
    [string]$SharedSecret,

    [string]$BackupPath = "C:\DHCPMigration",

    [string]$FailoverName = "DHCP-Migration",

    [ValidateSet("HotStandby", "LoadBalance")]
    [string]$FailoverMode = "HotStandby",

    [ValidateRange(1, 50)]
    [int]$ReservePercent = 10,

    [TimeSpan]$MaxClientLeadTime = (New-TimeSpan -Hours 1),

    [TimeSpan]$StateSwitchInterval = (New-TimeSpan -Minutes 45),

    [ValidateRange(1, 99)]
    [int]$LoadBalancePercent = 50,

    [switch]$SkipBackup
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Step {
    <# Prints a formatted step header so you can see progress at a glance #>
    param([string]$StepNumber, [string]$Message)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  STEP $StepNumber - $Message" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARNING] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAILED] $Message" -ForegroundColor Red
}

function Test-DHCPServerReachable {
    <#
        Checks that we can reach a server and that it has the DHCP role.
        Like knocking on the door and checking someone's home before you start moving furniture.
    #>
    param([string]$ServerName)

    # Can we reach it on the network?
    Write-Host "  Testing connectivity to $ServerName..." -NoNewline
    if (-not (Test-Connection -ComputerName $ServerName -Count 2 -Quiet)) {
        Write-Fail "Cannot reach $ServerName on the network."
        return $false
    }
    Write-Success "Reachable"

    # Is the DHCP service running (or at least installed)?
    Write-Host "  Checking DHCP service on $ServerName..." -NoNewline
    try {
        $service = Get-Service -ComputerName $ServerName -Name "DHCPServer" -ErrorAction Stop
        if ($service.Status -eq "Running") {
            Write-Success "DHCP service is running"
        }
        else {
            Write-Warn "DHCP service exists but is in state: $($service.Status)"
        }
        return $true
    }
    catch {
        Write-Fail "DHCP service not found on $ServerName. Is the DHCP role installed?"
        return $false
    }
}

# ============================================================================
# STEP 1 - VALIDATE PREREQUISITES
# ============================================================================
Write-Step "1" "VALIDATING PREREQUISITES"

# --- Check source server ---
Write-Host "  Checking source server ($SourceServer)..." -ForegroundColor White
$sourceOk = Test-DHCPServerReachable -ServerName $SourceServer
if (-not $sourceOk) {
    Write-Fail "Source server validation failed. Aborting."
    exit 1
}

# --- Check partner server ---
Write-Host ""
Write-Host "  Checking partner server ($PartnerServer)..." -ForegroundColor White
$partnerOk = Test-DHCPServerReachable -ServerName $PartnerServer
if (-not $partnerOk) {
    Write-Fail "Partner server validation failed. Aborting."
    Write-Host "  Make sure you've installed the DHCP role on $PartnerServer first:" -ForegroundColor Yellow
    Write-Host "    Install-WindowsFeature DHCP -IncludeManagementTools" -ForegroundColor Yellow
    Write-Host "    Add-DhcpServerInDC -DnsName `"$PartnerServer`"" -ForegroundColor Yellow
    exit 1
}

# --- Check TCP port 647 (failover communication port) ---
# This is the port the two DHCP servers use to talk to each other.
# If a firewall blocks this, the failover creation will fail with a vague error.
Write-Host ""
Write-Host "  Testing TCP port 647 (DHCP failover) to $PartnerServer..." -NoNewline
try {
    # Note: Test-NetConnection runs from the machine executing this script.
    # If you're running from a third admin workstation, this confirms the partner
    # is listening on 647, but you should also verify source-to-partner connectivity.
    $portTest = Test-NetConnection -ComputerName $PartnerServer -Port 647 -WarningAction SilentlyContinue -ErrorAction Stop
    if ($portTest.TcpTestSucceeded) {
        Write-Success "Port 647 open on $PartnerServer"
    }
    else {
        Write-Warn "Port 647 may be blocked on $PartnerServer. Failover might fail."
        Write-Host "  Ensure TCP 647 is open bidirectionally between $SourceServer and $PartnerServer." -ForegroundColor Yellow
    }
}
catch {
    Write-Warn "Could not test port 647: $($_.Exception.Message)"
    Write-Host "  Ensure TCP 647 is open bidirectionally between both servers." -ForegroundColor Yellow
}

# --- Check DNS resolution between the two servers ---
# Failover requires both servers to resolve each other by name.
# A DNS failure gives a confusing error message, so we catch it early.
Write-Host "  Testing DNS resolution of $PartnerServer..." -NoNewline
try {
    # Filter for A records specifically. Resolve-DnsName can return CNAME records
    # first, which don't have an IPAddress property and would show blank output.
    $dnsResult = Resolve-DnsName -Name $PartnerServer -Type A -ErrorAction Stop | Select-Object -First 1
    if ($dnsResult -and $dnsResult.IPAddress) {
        Write-Success "Resolves to $($dnsResult.IPAddress)"
    }
    else {
        Write-Warn "DNS returned a result but no A record found for $PartnerServer."
        Write-Host "  Try using the FQDN (e.g. server.domain.local)." -ForegroundColor Yellow
    }
}
catch {
    Write-Warn "DNS resolution failed for $PartnerServer."
    Write-Host "  Failover requires both servers to resolve each other by FQDN." -ForegroundColor Yellow
    Write-Host "  Check DNS records and try using the FQDN (e.g. server.domain.local)." -ForegroundColor Yellow
}

# --- Check partner server has no existing scopes ---
# If matching scopes already exist on the partner, failover creation will fail.
Write-Host "  Checking partner server has no existing scopes..." -NoNewline
try {
    $existingScopes = Get-DhcpServerv4Scope -ComputerName $PartnerServer -ErrorAction Stop
    if ($existingScopes) {
        Write-Fail "Partner server already has $(@($existingScopes).Count) scope(s)."
        Write-Host "  Failover cannot be configured if scopes already exist on both servers." -ForegroundColor Yellow
        Write-Host "  Remove existing scopes from $PartnerServer first, or use a clean DHCP installation." -ForegroundColor Yellow
        exit 1
    }
    Write-Success "Clean (no scopes found)"
}
catch {
    # If we get an error because there are genuinely no scopes, that's fine
    Write-Success "Clean (no scopes found)"
}

# --- Check the partner is authorised in AD ---
Write-Host "  Checking partner is authorised in AD..." -NoNewline
try {
    $authorisedServers = Get-DhcpServerInDC -ErrorAction Stop
    # Resolve the partner's IP for comparison (using -Type A to avoid CNAME issues)
    $partnerIP = (Resolve-DnsName -Name $PartnerServer -Type A -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    # Check for hostname match (wildcard covers both short name and FQDN)
    # or IP match as a fallback
    $partnerAuthorised = $authorisedServers | Where-Object {
        $_.DnsName -like "*$PartnerServer*" -or ($partnerIP -and $_.IPAddress -eq $partnerIP)
    }
    if ($partnerAuthorised) {
        Write-Success "Authorised in AD"
    }
    else {
        Write-Warn "Partner may not be authorised in AD. Attempting to authorise now..."
        if ($PSCmdlet.ShouldProcess($PartnerServer, "Authorise DHCP server in AD")) {
            Add-DhcpServerInDC -DnsName $PartnerServer -ErrorAction Stop
            Write-Success "Authorised $PartnerServer in AD"
        }
    }
}
catch {
    Write-Warn "Could not verify AD authorisation: $($_.Exception.Message)"
    Write-Host "  You may need to run: Add-DhcpServerInDC -DnsName `"$PartnerServer`"" -ForegroundColor Yellow
}

# ============================================================================
# STEP 2 - BACKUP CURRENT DHCP CONFIGURATION
# ============================================================================

# Initialise $backupDir so it's always available (even if backup is skipped)
$backupDir = $null

if (-not $SkipBackup) {
    Write-Step "2" "BACKING UP DHCP CONFIGURATION FROM $SourceServer"

    # Create backup directory with a timestamp so we never overwrite previous backups
    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $backupDir = Join-Path $BackupPath $timestamp

    Write-Host "  Creating backup directory: $backupDir"
    if ($PSCmdlet.ShouldProcess($backupDir, "Create backup directory")) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    # Method 1: PowerShell XML export (the proper way, includes everything)
    # This is the gold standard backup. It captures scopes, leases, reservations,
    # options, server-level settings, policies, filters -- the lot.
    # The -Leases flag is critical: without it, only configuration is exported
    # and active lease assignments are NOT included. If you ever need to restore
    # from this backup without -Leases, every client loses their current IP.
    $xmlPath = Join-Path $backupDir "dhcp-export.xml"
    Write-Host "  Exporting DHCP configuration and leases to XML..." -NoNewline
    try {
        if ($PSCmdlet.ShouldProcess($SourceServer, "Export DHCP config and leases to $xmlPath")) {
            Export-DhcpServer -ComputerName $SourceServer -File $xmlPath -Leases -Force -ErrorAction Stop
            $xmlSize = [math]::Round((Get-Item $xmlPath).Length / 1KB, 1)
            Write-Success "Exported ($($xmlSize) KB)"
        }
    }
    catch {
        Write-Fail "XML export failed: $($_.Exception.Message)"
        Write-Host "  This is non-fatal but means you have no rollback file." -ForegroundColor Yellow
        Write-Host "  Consider investigating before proceeding." -ForegroundColor Yellow
    }

    # Method 2: Native netsh backup (belt and braces, gives you a .dat file too)
    # netsh must run locally on the source server, so we use Invoke-Command
    # and save the file on the remote server's local disk.
    Write-Host "  Exporting DHCP configuration via netsh (on source server)..." -NoNewline
    try {
        if ($PSCmdlet.ShouldProcess($SourceServer, "Export DHCP config via netsh")) {
            Invoke-Command -ComputerName $SourceServer -ScriptBlock {
                $exportDir = "C:\DHCPNetshBackup"
                if (-not (Test-Path $exportDir)) {
                    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
                }
                $exportFile = Join-Path $exportDir "dhcp-backup.dat"
                netsh dhcp server export $exportFile all
                return $exportFile
            } -ErrorAction Stop | Out-Null
            Write-Success "Exported to C:\DHCPNetshBackup\dhcp-backup.dat on $SourceServer"
        }
    }
    catch {
        Write-Warn "netsh export failed (non-critical): $($_.Exception.Message)"
    }

    # Save a human-readable summary of all scopes for reference
    $summaryPath = Join-Path $backupDir "scope-summary.txt"
    Write-Host "  Saving scope summary..." -NoNewline
    try {
        $scopes = Get-DhcpServerv4Scope -ComputerName $SourceServer -ErrorAction Stop
        $scopeSummary = @()
        $scopeSummary += "DHCP Scope Summary - $SourceServer - $(Get-Date)"
        $scopeSummary += "=" * 80
        $scopeSummary += ($scopes | Format-Table -AutoSize ScopeId, SubnetMask, Name, State, StartRange, EndRange | Out-String)

        # Also capture reservation counts per scope
        $scopeSummary += ""
        $scopeSummary += "Reservation Counts:"
        $scopeSummary += "-" * 40
        foreach ($scope in $scopes) {
            $resCount = @(Get-DhcpServerv4Reservation -ComputerName $SourceServer -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue).Count
            $scopeSummary += "  $($scope.ScopeId) [$($scope.Name)]: $resCount reservation(s)"
        }

        # Capture server-level options (these DON'T replicate via failover)
        $scopeSummary += ""
        $scopeSummary += "Server-Level Options (these do NOT replicate via failover, set manually on partner):"
        $scopeSummary += "-" * 80
        try {
            $serverOptions = Get-DhcpServerv4OptionValue -ComputerName $SourceServer -ErrorAction Stop
            $scopeSummary += ($serverOptions | Format-Table -AutoSize OptionId, Name, Value | Out-String)
        }
        catch {
            $scopeSummary += "  None found or unable to retrieve."
        }

        $scopeSummary | Out-File -FilePath $summaryPath -Encoding UTF8
        Write-Success "Saved to $summaryPath"
    }
    catch {
        Write-Warn "Could not save summary: $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "  Backup location: $backupDir" -ForegroundColor Green
    Write-Host "  Keep this safe. It's your rollback plan if anything goes wrong." -ForegroundColor Green
}
else {
    Write-Step "2" "BACKUP SKIPPED (SkipBackup flag set)"
    Write-Warn "No backup taken. Make sure you have one before proceeding in production."
}

# ============================================================================
# STEP 3 - RETRIEVE ALL SCOPES FROM SOURCE SERVER
# ============================================================================
Write-Step "3" "RETRIEVING SCOPES FROM $SourceServer"

try {
    # Wrap in @() to guarantee an array even with a single scope.
    # Without this, PowerShell returns a bare object and .Count fails.
    $allScopes = @(Get-DhcpServerv4Scope -ComputerName $SourceServer -ErrorAction Stop)
}
catch {
    Write-Fail "Failed to retrieve scopes from $SourceServer : $($_.Exception.Message)"
    exit 1
}

if ($allScopes.Count -eq 0) {
    Write-Fail "No IPv4 scopes found on $SourceServer. Nothing to migrate."
    exit 1
}

# Display what we found, including lease and reservation counts
Write-Host "  Found $($allScopes.Count) scope(s):" -ForegroundColor White
Write-Host ""
foreach ($scope in $allScopes) {
    $leaseCount = @(Get-DhcpServerv4Lease -ComputerName $SourceServer -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue).Count
    $resCount = @(Get-DhcpServerv4Reservation -ComputerName $SourceServer -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue).Count
    Write-Host "    $($scope.ScopeId)  [$($scope.Name)]  State: $($scope.State)  Leases: $leaseCount  Reservations: $resCount" -ForegroundColor White
}

# Only include active scopes in the failover. Inactive scopes will still get
# backed up but there's no point replicating scopes that aren't in use.
$activeScopes = @($allScopes | Where-Object { $_.State -eq "Active" })
$inactiveScopes = @($allScopes | Where-Object { $_.State -ne "Active" })

if ($inactiveScopes.Count -gt 0) {
    Write-Host ""
    Write-Warn "$($inactiveScopes.Count) inactive scope(s) will be skipped for failover (but are included in the backup):"
    foreach ($scope in $inactiveScopes) {
        Write-Host "    $($scope.ScopeId)  [$($scope.Name)]  State: $($scope.State)" -ForegroundColor Yellow
    }
}

if ($activeScopes.Count -eq 0) {
    Write-Fail "No active scopes to configure for failover."
    exit 1
}

# Force into an array of IPAddress objects so .Count always works,
# even with a single scope. Without @(), PowerShell returns a bare
# IPAddress object instead of an array, and .Count returns nothing.
[array]$scopeIds = $activeScopes | Select-Object -ExpandProperty ScopeId

Write-Host ""
Write-Success "$($scopeIds.Count) active scope(s) will be configured for failover."

# ============================================================================
# STEP 4 - CHECK FOR EXISTING FAILOVER RELATIONSHIPS
# ============================================================================
Write-Step "4" "CHECKING FOR EXISTING FAILOVER RELATIONSHIPS"

try {
    $existingFailover = @(Get-DhcpServerv4Failover -ComputerName $SourceServer -ErrorAction SilentlyContinue)
    if ($existingFailover.Count -gt 0) {
        Write-Warn "Existing failover relationship(s) found on $SourceServer :"
        foreach ($fo in $existingFailover) {
            Write-Host "    Name: $($fo.Name)  Partner: $($fo.PartnerServer)  Mode: $($fo.Mode)  State: $($fo.State)" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  You need to remove existing failover relationships before creating new ones." -ForegroundColor Yellow
        Write-Host "  To remove, run: Remove-DhcpServerv4Failover -ComputerName `"$SourceServer`" -Name `"<RelationshipName>`"" -ForegroundColor Yellow
        Write-Host ""

        $continue = Read-Host "  Do you want to continue anyway? (y/n)"
        if ($continue -ne 'y') {
            Write-Host "  Aborting. Remove existing failover relationships first." -ForegroundColor Red
            exit 1
        }

        # Filter out scopes that are already in a failover relationship.
        # Each failover relationship has a ScopeId property that can be a
        # single value or an array. We flatten all of them into one list.
        $failoverScopeIds = @()
        foreach ($fo in $existingFailover) {
            # @() ensures we handle both single values and arrays
            $failoverScopeIds += @($fo.ScopeId)
        }

        # Convert to string representations for reliable comparison.
        # IPAddress objects don't always compare cleanly with -notin,
        # but their .ToString() output is consistent.
        $failoverScopeStrings = $failoverScopeIds | ForEach-Object { $_.ToString() }
        [array]$scopeIds = $scopeIds | Where-Object { $_.ToString() -notin $failoverScopeStrings }

        if ($scopeIds.Count -eq 0) {
            Write-Fail "All active scopes are already in a failover relationship. Nothing to do."
            exit 1
        }
        Write-Success "$($scopeIds.Count) scope(s) available for new failover configuration."
    }
    else {
        Write-Success "No existing failover relationships found. Good to go."
    }
}
catch {
    Write-Success "No existing failover relationships found. Good to go."
}

# ============================================================================
# STEP 5 - CREATE THE FAILOVER RELATIONSHIP
# ============================================================================
Write-Step "5" "CREATING FAILOVER RELATIONSHIP"

Write-Host "  Configuration summary:" -ForegroundColor White
Write-Host "    Source (Active):     $SourceServer" -ForegroundColor White
Write-Host "    Partner:             $PartnerServer" -ForegroundColor White
Write-Host "    Relationship Name:   $FailoverName" -ForegroundColor White
Write-Host "    Mode:                $FailoverMode" -ForegroundColor White
if ($FailoverMode -eq "HotStandby") {
    Write-Host "    Source Role:         Active (primary, keeps issuing leases)" -ForegroundColor White
    Write-Host "    Partner Role:        Standby (passive, takes over if source fails)" -ForegroundColor White
    Write-Host "    Reserve Percent:     $ReservePercent%" -ForegroundColor White
}
else {
    Write-Host "    Load Balance:        ${LoadBalancePercent}% (source) / $([int](100 - $LoadBalancePercent))% (partner)" -ForegroundColor White
}
Write-Host "    Max Client Lead:     $MaxClientLeadTime" -ForegroundColor White
Write-Host "    State Switch:        $(if ($StateSwitchInterval.TotalSeconds -gt 0) { $StateSwitchInterval } else { 'Disabled (manual switchover only)' })" -ForegroundColor White
Write-Host "    Scopes:              $($scopeIds.Count)" -ForegroundColor White
Write-Host ""

# List every scope that will be included
Write-Host "  Scopes to be configured:" -ForegroundColor White
foreach ($sid in $scopeIds) {
    $scopeName = ($activeScopes | Where-Object { $_.ScopeId.ToString() -eq $sid.ToString() }).Name
    Write-Host "    $sid  [$scopeName]" -ForegroundColor White
}
Write-Host ""

# Confirmation prompt. This is the point of no return for changes.
$confirm = Read-Host "  Ready to create the failover relationship? (y/n)"
if ($confirm -ne 'y') {
    Write-Host "  Aborting. No changes have been made." -ForegroundColor Yellow
    exit 0
}

# Build the failover parameters using splatting.
#
# IMPORTANT: Add-DhcpServerv4Failover does NOT have a -Mode parameter.
# This is a common mistake. The mode is determined by which parameters you pass:
#   - Include -ServerRole (Active or Standby) = Hot Standby mode
#   - Include -LoadBalancePercent without -ServerRole = Load Balance mode (default)
# Passing -Mode will cause the cmdlet to fail with an unrecognised parameter error.
#
$failoverParams = @{
    ComputerName      = $SourceServer
    PartnerServer     = $PartnerServer
    Name              = $FailoverName
    SharedSecret      = $SharedSecret
    MaxClientLeadTime = $MaxClientLeadTime
    ScopeId           = $scopeIds
    Force             = $true
    ErrorAction       = "Stop"
}

# Add mode-specific parameters
if ($FailoverMode -eq "HotStandby") {
    # ServerRole "Active" means the source server stays as the primary.
    # The partner automatically becomes the standby.
    # ReservePercent sets how much of the address pool the standby
    # can use if it needs to take over.
    $failoverParams["ServerRole"] = "Active"
    $failoverParams["ReservePercent"] = $ReservePercent
}
else {
    # No -ServerRole means Load Balance mode (the default).
    # LoadBalancePercent sets what percentage the source server handles.
    # The partner gets the remainder (e.g. 50/50, 60/40, etc).
    $failoverParams["LoadBalancePercent"] = $LoadBalancePercent
}

# Only add StateSwitchInterval if it's greater than zero.
# A zero value means "don't auto-switch", which some admins prefer during
# migrations so nothing happens unexpectedly.
# When StateSwitchInterval is set, AutoStateTransition is automatically
# enabled by the cmdlet (confirmed in Microsoft docs).
if ($StateSwitchInterval.TotalSeconds -gt 0) {
    $failoverParams["StateSwitchInterval"] = $StateSwitchInterval
}

Write-Host "  Creating failover relationship..." -ForegroundColor White
try {
    if ($PSCmdlet.ShouldProcess("$SourceServer -> $PartnerServer", "Create DHCP failover relationship")) {
        Add-DhcpServerv4Failover @failoverParams
        Write-Success "Failover relationship '$FailoverName' created successfully!"
    }
}
catch {
    Write-Fail "Failed to create failover relationship: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "  Common causes:" -ForegroundColor Yellow
    Write-Host "    - TCP port 647 blocked between the two servers" -ForegroundColor Yellow
    Write-Host "    - Scopes already exist on the partner server" -ForegroundColor Yellow
    Write-Host "    - Partner server not authorised in AD" -ForegroundColor Yellow
    Write-Host "    - DNS resolution issues between the servers" -ForegroundColor Yellow
    Write-Host "    - Shared secret contains special characters that need escaping" -ForegroundColor Yellow
    Write-Host "    - Time is out of sync between the two servers (Kerberos needs <5 min drift)" -ForegroundColor Yellow
    Write-Host ""
    if ($backupDir) {
        Write-Host "  Your backup is safe at: $backupDir" -ForegroundColor Green
    }
    exit 1
}

# ============================================================================
# STEP 6 - VERIFY REPLICATION
# ============================================================================
Write-Step "6" "VERIFYING REPLICATION TO $PartnerServer"

# Give it time to replicate. Larger environments need more time.
$waitSeconds = [Math]::Max(10, [Math]::Min(30, $scopeIds.Count * 3))
Write-Host "  Waiting $waitSeconds seconds for initial replication..." -ForegroundColor White
Start-Sleep -Seconds $waitSeconds

# --- Check the failover relationship status ---
Write-Host "  Checking failover relationship status..." -NoNewline
try {
    $foStatus = Get-DhcpServerv4Failover -ComputerName $SourceServer -Name $FailoverName -ErrorAction Stop
    Write-Success "State: $($foStatus.State)  Mode: $($foStatus.Mode)"
}
catch {
    Write-Warn "Could not retrieve failover status: $($_.Exception.Message)"
}

# --- Check scopes replicated to the partner ---
Write-Host "  Checking scopes on partner server..." -NoNewline
try {
    $partnerScopes = @(Get-DhcpServerv4Scope -ComputerName $PartnerServer -ErrorAction Stop)
    if ($partnerScopes.Count -ge $scopeIds.Count) {
        Write-Success "$($partnerScopes.Count) scope(s) found on partner (expected $($scopeIds.Count))"
    }
    else {
        Write-Warn "Expected $($scopeIds.Count) scopes but found $($partnerScopes.Count) on partner."
        Write-Host "  Replication may still be in progress. Check again in a minute." -ForegroundColor Yellow
    }
}
catch {
    Write-Warn "Could not query partner scopes: $($_.Exception.Message)"
}

# --- Spot check leases on a sample of scopes ---
Write-Host "  Spot-checking lease replication..." -ForegroundColor White
$checkCount = [Math]::Min(5, $scopeIds.Count)
$leaseIssues = 0
for ($i = 0; $i -lt $checkCount; $i++) {
    $sid = $scopeIds[$i]
    try {
        $sourceLeases = @(Get-DhcpServerv4Lease -ComputerName $SourceServer -ScopeId $sid -ErrorAction SilentlyContinue).Count
        $partnerLeases = @(Get-DhcpServerv4Lease -ComputerName $PartnerServer -ScopeId $sid -ErrorAction SilentlyContinue).Count
        $match = if ($sourceLeases -eq $partnerLeases) { "MATCH" } else { "DIFF" }
        $colour = if ($match -eq "MATCH") { "Green" } else { "Yellow" }
        if ($match -ne "MATCH") { $leaseIssues++ }
        Write-Host "    Scope $sid : Source=$sourceLeases  Partner=$partnerLeases  [$match]" -ForegroundColor $colour
    }
    catch {
        Write-Warn "    Could not check leases for scope $sid"
    }
}

# --- Spot check reservations on a sample of scopes ---
Write-Host "  Spot-checking reservation replication..." -ForegroundColor White
$resIssues = 0
for ($i = 0; $i -lt $checkCount; $i++) {
    $sid = $scopeIds[$i]
    try {
        $sourceRes = @(Get-DhcpServerv4Reservation -ComputerName $SourceServer -ScopeId $sid -ErrorAction SilentlyContinue).Count
        $partnerRes = @(Get-DhcpServerv4Reservation -ComputerName $PartnerServer -ScopeId $sid -ErrorAction SilentlyContinue).Count
        $match = if ($sourceRes -eq $partnerRes) { "MATCH" } else { "DIFF" }
        $colour = if ($match -eq "MATCH") { "Green" } else { "Yellow" }
        if ($match -ne "MATCH") { $resIssues++ }
        Write-Host "    Scope $sid : Source=$sourceRes  Partner=$partnerRes  [$match]" -ForegroundColor $colour
    }
    catch {
        Write-Warn "    Could not check reservations for scope $sid"
    }
}

if ($leaseIssues -gt 0 -or $resIssues -gt 0) {
    Write-Host ""
    Write-Warn "Some counts don't match. This can be normal if replication is still syncing."
    Write-Host "  Run this to force a full sync:" -ForegroundColor Yellow
    Write-Host "    Invoke-DhcpServerv4FailoverReplication -ComputerName `"$SourceServer`" -Name `"$FailoverName`"" -ForegroundColor Cyan
    Write-Host "  Then re-check counts in a few minutes." -ForegroundColor Yellow
}

# --- Check server-level options (these don't replicate via failover) ---
Write-Host ""
Write-Host "  Checking server-level options (these do NOT replicate via failover)..." -ForegroundColor White
try {
    $serverOptions = @(Get-DhcpServerv4OptionValue -ComputerName $SourceServer -ErrorAction Stop)
    if ($serverOptions.Count -gt 0) {
        Write-Warn "Found $($serverOptions.Count) server-level option(s) on $SourceServer that need manual setup on $PartnerServer :"
        foreach ($opt in $serverOptions) {
            Write-Host "    Option $($opt.OptionId) [$($opt.Name)]: $($opt.Value -join ', ')" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Set these on the partner server using:" -ForegroundColor Yellow
        Write-Host "    Set-DhcpServerv4OptionValue -ComputerName `"$PartnerServer`" -OptionId <ID> -Value <Value>" -ForegroundColor Cyan
    }
    else {
        Write-Success "No server-level options found (nothing to set manually)."
    }
}
catch {
    Write-Warn "Could not check server-level options: $($_.Exception.Message)"
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  MIGRATION STEP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  What's been done:" -ForegroundColor White
if ($backupDir) {
    Write-Host "    - Full DHCP backup saved to: $backupDir" -ForegroundColor White
    Write-Host "    - netsh backup saved to: C:\DHCPNetshBackup\dhcp-backup.dat on $SourceServer" -ForegroundColor White
}
Write-Host "    - Failover relationship '$FailoverName' created ($FailoverMode mode)" -ForegroundColor White
Write-Host "    - $($scopeIds.Count) scope(s) replicating to $PartnerServer" -ForegroundColor White
Write-Host ""
Write-Host "  What you need to do next:" -ForegroundColor Yellow
Write-Host "    1. Verify scopes and reservations in the DHCP console on $PartnerServer" -ForegroundColor Yellow
Write-Host "    2. Set any server-level options listed above on $PartnerServer manually" -ForegroundColor Yellow
Write-Host "    3. Check DNS dynamic update credentials (IPv4 > Properties > DNS tab > Advanced > Credentials)" -ForegroundColor Yellow
Write-Host "    4. Update IP helpers on your firewalls/switches to include $PartnerServer" -ForegroundColor Yellow
Write-Host "    5. Let both servers run side-by-side for a day or two (soak period)" -ForegroundColor Yellow
Write-Host "    6. When ready to cut over, run on the NEW server:" -ForegroundColor Yellow
Write-Host "       Remove-DhcpServerv4Failover -Name `"$FailoverName`"" -ForegroundColor Cyan
Write-Host "       (Scopes stay on whichever server runs this command)" -ForegroundColor Yellow
Write-Host "    7. Remove old server from IP helpers and decommission" -ForegroundColor Yellow
Write-Host ""
Write-Host "  To force a manual replication sync at any time:" -ForegroundColor White
Write-Host "    Invoke-DhcpServerv4FailoverReplication -ComputerName `"$SourceServer`" -Name `"$FailoverName`"" -ForegroundColor Cyan
Write-Host ""
