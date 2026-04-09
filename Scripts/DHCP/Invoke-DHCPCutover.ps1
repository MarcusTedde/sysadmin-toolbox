<#
.SYNOPSIS
    Performs the DHCP cutover from the old server to the new server.

.DESCRIPTION
    This is the final step of a DHCP migration. It breaks the failover
    relationship (keeping scopes on the new server), stops and disables
    the DHCP service on the old server, and verifies the new server is
    the sole DHCP authority.

    Think of it like handing in the keys to the old office. We make sure
    everything is moved to the new building, lock the old door, and verify
    the new office is fully operational before walking away.

    IMPORTANT: This script must target the NEW server as the -NewServer
    parameter. Scopes are retained on whichever server the Remove command
    is run against. If you get the parameters backwards, the OLD server
    keeps the scopes and the NEW server loses them.

    The script enforces the correct cutover order:
      1. Verifies both servers are reachable and failover is active
      2. Shows a pre-cutover summary of scopes and leases
      3. Breaks the failover relationship (scopes stay on new server)
      4. Verifies scopes remain on the new server
      5. Stops and disables the DHCP service on the old server
      6. Verifies the old server is no longer serving DHCP
      7. Provides next steps (remove old IP helpers)

    DO NOT just stop the old DHCP service without breaking failover first.
    See the Migrate-DHCPFailover.ps1 summary for a full explanation of why.

.PARAMETER NewServer
    The FQDN or hostname of the NEW DHCP server that will keep the scopes.

.PARAMETER OldServer
    The FQDN or hostname of the OLD DHCP server being decommissioned.

.PARAMETER FailoverName
    Name of the failover relationship to break. Defaults to "DHCP-Migration".

.EXAMPLE
    .\Invoke-DHCPCutover.ps1 -NewServer "NEW-DC.domain.local" -OldServer "OLD-DC.domain.local"

.EXAMPLE
    .\Invoke-DHCPCutover.ps1 -NewServer "NEW-DC" -OldServer "OLD-DC" -WhatIf

.NOTES
    Author  : Marcus Tedde
    Version : 1.0
    Requires: Run as Administrator with DHCP management tools (RSAT) installed.
              Both servers must be reachable at the time of cutover.
              A failover relationship must exist between the two servers.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$NewServer,

    [Parameter(Mandatory)]
    [string]$OldServer,

    [string]$FailoverName = "DHCP-Migration"
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

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "  --- $Message ---" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Red
Write-Host "  DHCP CUTOVER - FINAL MIGRATION STEP" -ForegroundColor Red
Write-Host "============================================================" -ForegroundColor Red
Write-Host ""
Write-Host "  New Server (KEEPS scopes):  $NewServer" -ForegroundColor Green
Write-Host "  Old Server (LOSES scopes):  $OldServer" -ForegroundColor Yellow
Write-Host "  Failover Relationship:      $FailoverName" -ForegroundColor White
Write-Host ""
Write-Host "  This script will:" -ForegroundColor White
Write-Host "    1. Break the failover relationship" -ForegroundColor White
Write-Host "    2. Stop and disable DHCP on the old server" -ForegroundColor White
Write-Host "    3. Verify the new server is the sole DHCP authority" -ForegroundColor White
Write-Host ""

# ============================================================================
# STEP 1 - PRE-FLIGHT CHECKS
# ============================================================================
Write-Section "PRE-FLIGHT CHECKS"

# Check new server
Write-Host "  Testing $NewServer..." -NoNewline
if (-not (Test-Connection -ComputerName $NewServer -Count 2 -Quiet)) {
    Write-Fail "Cannot reach $NewServer. Both servers must be reachable for cutover."
    exit 1
}
try {
    $newServerScopes = @(Get-DhcpServerv4Scope -ComputerName $NewServer -ErrorAction Stop)
    Write-Success "Reachable, DHCP responding ($($newServerScopes.Count) scopes)."
}
catch {
    Write-Fail "Cannot query DHCP on $NewServer : $($_.Exception.Message)"
    exit 1
}

# Check old server
Write-Host "  Testing $OldServer..." -NoNewline
if (-not (Test-Connection -ComputerName $OldServer -Count 2 -Quiet)) {
    Write-Fail "Cannot reach $OldServer. Both servers must be reachable for a clean cutover."
    Write-Host "  If the old server is permanently offline, you can break failover with:" -ForegroundColor Yellow
    Write-Host "    Remove-DhcpServerv4Failover -ComputerName `"$NewServer`" -Name `"$FailoverName`" -Force" -ForegroundColor Cyan
    Write-Host "  The -Force flag will remove the relationship even if the partner is unreachable." -ForegroundColor Yellow
    exit 1
}
try {
    $oldServerScopes = @(Get-DhcpServerv4Scope -ComputerName $OldServer -ErrorAction Stop)
    Write-Success "Reachable, DHCP responding ($($oldServerScopes.Count) scopes)."
}
catch {
    Write-Fail "Cannot query DHCP on $OldServer : $($_.Exception.Message)"
    exit 1
}

# Check failover relationship exists
Write-Host "  Checking failover relationship '$FailoverName'..." -NoNewline
try {
    $foStatus = Get-DhcpServerv4Failover -ComputerName $NewServer -Name $FailoverName -ErrorAction Stop
    Write-Success "Found. State: $($foStatus.State), Mode: $($foStatus.Mode)"
}
catch {
    Write-Fail "Failover relationship '$FailoverName' not found on $NewServer."
    Write-Host "  Run Get-DhcpServerv4Failover -ComputerName `"$NewServer`" to list available relationships." -ForegroundColor Yellow
    exit 1
}

# Warn if failover is not in Normal state
if ($foStatus.State -ne "Normal") {
    Write-SkipWarn "Failover state is '$($foStatus.State)' (expected 'Normal')."
    Write-Host "  Cutting over while not in Normal state may result in incomplete lease data." -ForegroundColor Yellow
    Write-Host "  Consider running Invoke-DhcpServerv4FailoverReplication first." -ForegroundColor Yellow
    Write-Host ""
    $forceConfirm = Read-Host "  Continue anyway? (y/n)"
    if ($forceConfirm -ne 'y') {
        Write-Host "  Aborting. Fix the failover state first." -ForegroundColor Red
        exit 1
    }
}

# ============================================================================
# STEP 2 - PRE-CUTOVER SUMMARY
# ============================================================================
Write-Section "PRE-CUTOVER SUMMARY"

Write-Host "  Scopes on $NewServer (will be KEPT):" -ForegroundColor Green
foreach ($scope in $newServerScopes) {
    $leaseCount = @(Get-DhcpServerv4Lease -ComputerName $NewServer -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue).Count
    Write-Host "    $($scope.ScopeId)  [$($scope.Name)]  Leases: $leaseCount" -ForegroundColor White
}

Write-Host ""
Write-Host "  Scopes on $OldServer (will be REMOVED):" -ForegroundColor Yellow
foreach ($scope in $oldServerScopes) {
    Write-Host "    $($scope.ScopeId)  [$($scope.Name)]" -ForegroundColor White
}

# ============================================================================
# CONFIRMATION
# ============================================================================
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Red
Write-Host "  WARNING: This action is significant and cannot be easily undone." -ForegroundColor Red
Write-Host "  ============================================================" -ForegroundColor Red
Write-Host ""
Write-Host "  After this:" -ForegroundColor Yellow
Write-Host "    - The failover relationship '$FailoverName' will be broken" -ForegroundColor Yellow
Write-Host "    - All scopes will remain ONLY on $NewServer" -ForegroundColor Yellow
Write-Host "    - All scopes will be REMOVED from $OldServer" -ForegroundColor Yellow
Write-Host "    - The DHCP service on $OldServer will be stopped and disabled" -ForegroundColor Yellow
Write-Host ""

$confirm = Read-Host "  Type 'CUTOVER' (all caps) to proceed"
if ($confirm -ne 'CUTOVER') {
    Write-Host "  Aborting. No changes have been made." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# STEP 3 - BREAK FAILOVER RELATIONSHIP
# ============================================================================
Write-Section "BREAKING FAILOVER RELATIONSHIP"

# The Remove command is targeted at the NEW server via -ComputerName.
# Scopes are retained on whichever server is specified by -ComputerName.
# Scopes are removed from the partner (old server).
Write-Info "Running Remove-DhcpServerv4Failover on $NewServer (scopes will stay here)..."

try {
    if ($PSCmdlet.ShouldProcess("$NewServer failover '$FailoverName'", "Break failover relationship")) {
        Remove-DhcpServerv4Failover -ComputerName $NewServer -Name $FailoverName -Force -ErrorAction Stop
        Write-Success "Failover relationship '$FailoverName' removed successfully."
    }
}
catch {
    # The cmdlet may show a WARNING about the partner but still succeed locally.
    # Check if the relationship still exists on the new server.
    $stillExists = $null
    try {
        $stillExists = Get-DhcpServerv4Failover -ComputerName $NewServer -Name $FailoverName -ErrorAction SilentlyContinue
    }
    catch { }

    if ($stillExists) {
        Write-Fail "Failed to break failover: $($_.Exception.Message)"
        Write-Host "  The failover relationship still exists on $NewServer." -ForegroundColor Red
        Write-Host "  Try running manually: Remove-DhcpServerv4Failover -ComputerName `"$NewServer`" -Name `"$FailoverName`" -Force" -ForegroundColor Cyan
        exit 1
    }
    else {
        # Relationship was removed from new server, but partner removal may have warned
        Write-SkipWarn "Failover removed from $NewServer, but partner removal produced a warning."
        Write-Host "  This is normal if the old server was slow to respond: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Scopes remain on $NewServer. Continuing with cutover." -ForegroundColor Yellow
    }
}

# Wait a moment for the removal to propagate
Start-Sleep -Seconds 5

# ============================================================================
# STEP 4 - VERIFY SCOPES ON NEW SERVER
# ============================================================================
Write-Section "VERIFYING SCOPES ON NEW SERVER"

try {
    $postCutoverScopes = @(Get-DhcpServerv4Scope -ComputerName $NewServer -ErrorAction Stop)
    if ($postCutoverScopes.Count -ge $newServerScopes.Count) {
        Write-Success "$($postCutoverScopes.Count) scope(s) confirmed on $NewServer."
    }
    else {
        Write-Fail "Expected $($newServerScopes.Count) scopes but found $($postCutoverScopes.Count)."
        Write-Host "  Check the DHCP console on $NewServer immediately." -ForegroundColor Red
    }

    foreach ($scope in $postCutoverScopes) {
        $leaseCount = @(Get-DhcpServerv4Lease -ComputerName $NewServer -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue).Count
        Write-Host "    $($scope.ScopeId)  [$($scope.Name)]  State: $($scope.State)  Leases: $leaseCount" -ForegroundColor White
    }
}
catch {
    Write-Fail "Could not verify scopes on $NewServer : $($_.Exception.Message)"
}

# Verify no failover relationships remain
Write-Host ""
Write-Host "  Checking for remaining failover relationships..." -NoNewline
try {
    $remainingFo = @(Get-DhcpServerv4Failover -ComputerName $NewServer -ErrorAction SilentlyContinue)
    if ($remainingFo.Count -eq 0) {
        Write-Success "No failover relationships. $NewServer is standalone."
    }
    else {
        Write-SkipWarn "$($remainingFo.Count) failover relationship(s) still exist on $NewServer."
        foreach ($fo in $remainingFo) {
            Write-Host "    $($fo.Name) with $($fo.PartnerServer)" -ForegroundColor Yellow
        }
    }
}
catch {
    Write-Success "No failover relationships. $NewServer is standalone."
}

# ============================================================================
# STEP 5 - STOP AND DISABLE DHCP ON OLD SERVER
# ============================================================================
Write-Section "STOPPING DHCP ON OLD SERVER"

Write-Info "Stopping DHCP service on $OldServer..."
try {
    if ($PSCmdlet.ShouldProcess("$OldServer DHCPServer service", "Stop and disable")) {
        # Stop the service
        $svc = Get-Service -ComputerName $OldServer -Name "DHCPServer" -ErrorAction Stop
        if ($svc.Status -eq "Running") {
            Stop-Service -InputObject $svc -Force -ErrorAction Stop
            Write-Success "DHCP service stopped on $OldServer."
        }
        else {
            Write-Info "DHCP service was already in state: $($svc.Status)"
        }

        # Disable the service so it doesn't auto-start on reboot
        Set-Service -ComputerName $OldServer -Name "DHCPServer" -StartupType Disabled -ErrorAction Stop
        Write-Success "DHCP service set to Disabled on $OldServer (won't start on reboot)."
    }
}
catch {
    Write-Fail "Could not stop/disable DHCP on $OldServer : $($_.Exception.Message)"
    Write-Host "  You may need to do this manually:" -ForegroundColor Yellow
    Write-Host "    Stop-Service -Name DHCPServer -Force" -ForegroundColor Cyan
    Write-Host "    Set-Service -Name DHCPServer -StartupType Disabled" -ForegroundColor Cyan
}

# Verify old server service state
Write-Host ""
Write-Host "  Verifying old server DHCP state..." -NoNewline
try {
    $oldSvc = Get-Service -ComputerName $OldServer -Name "DHCPServer" -ErrorAction Stop
    if ($oldSvc.Status -eq "Stopped") {
        Write-Success "DHCP service is Stopped on $OldServer."
    }
    else {
        Write-SkipWarn "DHCP service is $($oldSvc.Status) on $OldServer. Expected Stopped."
    }
}
catch {
    Write-SkipWarn "Could not verify service state on $OldServer."
}

# Check if scopes were removed from old server
Write-Host "  Checking scopes on old server..." -NoNewline
try {
    $oldScopesPost = @(Get-DhcpServerv4Scope -ComputerName $OldServer -ErrorAction Stop)
    if ($oldScopesPost.Count -eq 0) {
        Write-Success "No scopes on $OldServer. Clean."
    }
    else {
        Write-SkipWarn "$($oldScopesPost.Count) scope(s) still present on $OldServer."
        Write-Host "  These are orphaned scopes from the broken failover." -ForegroundColor Yellow
        Write-Host "  Since the DHCP service is stopped, they won't cause issues." -ForegroundColor Yellow
        Write-Host "  You can remove them later when you fully decommission the server." -ForegroundColor Yellow
    }
}
catch {
    # Service is stopped, so we can't query scopes. That's expected.
    Write-Success "DHCP service stopped, scopes inaccessible (expected)."
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  CUTOVER COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  What's been done:" -ForegroundColor White
Write-Host "    - Failover relationship '$FailoverName' has been broken" -ForegroundColor White
Write-Host "    - All scopes are now exclusively on $NewServer" -ForegroundColor White
Write-Host "    - DHCP service on $OldServer is stopped and disabled" -ForegroundColor White
Write-Host "    - $NewServer is the sole DHCP authority" -ForegroundColor White
Write-Host ""
Write-Host "  IMPORTANT: What you need to do now" -ForegroundColor Yellow
Write-Host "  ====================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. UPDATE IP HELPERS: Remove $OldServer from all IP helper" -ForegroundColor Yellow
Write-Host "     configurations on your firewalls, routers, and L3 switches." -ForegroundColor Yellow
Write-Host "     $NewServer should be the ONLY IP helper listed." -ForegroundColor Yellow
Write-Host ""
Write-Host "  2. TEST: Renew DHCP leases on a few clients to confirm they" -ForegroundColor Yellow
Write-Host "     receive addresses from $NewServer :" -ForegroundColor Yellow
Write-Host "       ipconfig /release" -ForegroundColor Cyan
Write-Host "       ipconfig /renew" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. MONITOR: Keep an eye on the DHCP console for the next" -ForegroundColor Yellow
Write-Host "     few hours. Check lease counts are stable and growing." -ForegroundColor Yellow
Write-Host ""
Write-Host "  4. DECOMMISSION (when confident): Uninstall the DHCP role" -ForegroundColor Yellow
Write-Host "     from $OldServer and remove it from AD authorisation:" -ForegroundColor Yellow
Write-Host "       Remove-DhcpServerInDC -DnsName `"$OldServer`"" -ForegroundColor Cyan
Write-Host "       Uninstall-WindowsFeature DHCP -IncludeManagementTools" -ForegroundColor Cyan
Write-Host ""
Write-Host "  If something goes wrong and you need to roll back:" -ForegroundColor Red
Write-Host "    1. Re-enable and start DHCP on $OldServer :" -ForegroundColor Red
Write-Host "       Set-Service -ComputerName `"$OldServer`" -Name DHCPServer -StartupType Automatic" -ForegroundColor Cyan
Write-Host "       Get-Service -ComputerName `"$OldServer`" -Name DHCPServer | Start-Service" -ForegroundColor Cyan  
Write-Host "    2. Import the backup XML from the migration step:" -ForegroundColor Red
Write-Host "       Import-DhcpServer -ComputerName `"$OldServer`" -File `"<path-to-backup>\dhcp-export.xml`" -BackupPath `"C:\dhcpbackup`" -Leases" -ForegroundColor Cyan
Write-Host "    3. Restore old IP helpers on your firewalls/switches" -ForegroundColor Red
Write-Host ""
