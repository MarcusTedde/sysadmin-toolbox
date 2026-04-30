$thumb = (Get-ChildItem Cert:\LocalMachine\My | 
    Where-Object { $_.Subject -eq "CN=[DCFQDN]" }).Thumbprint

Write-Host "Checking usages of cert: $thumb`n" -ForegroundColor Cyan

# 1) RDP listener
$rdp = Get-WmiObject -Namespace root\cimv2\TerminalServices -Class Win32_TSGeneralSetting -ErrorAction SilentlyContinue
if ($rdp.SSLCertificateSHA1Hash -eq $thumb) {
    Write-Host "RDP listener   : USING THIS CERT (will fall back to auto-generated)" -ForegroundColor Yellow
} else {
    Write-Host "RDP listener   : not using it (using $($rdp.SSLCertificateSHA1Hash))"
}

# 2) WinRM HTTPS listener
$winrm = winrm enumerate winrm/config/Listener 2>$null | Out-String
if ($winrm -match $thumb) {
    Write-Host "WinRM HTTPS    : USING THIS CERT" -ForegroundColor Yellow
} else {
    Write-Host "WinRM HTTPS    : not using it"
}

# 3) IIS bindings (if IIS happens to be installed)
if (Get-Module -ListAvailable WebAdministration) {
    Import-Module WebAdministration
    $iis = Get-ChildItem IIS:\SslBindings -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb }
    if ($iis) { Write-Host "IIS bindings   : USING THIS CERT" -ForegroundColor Yellow } 
    else      { Write-Host "IIS bindings   : not using it" }
} else {
    Write-Host "IIS bindings   : IIS not installed"
}

# 4) Generic netsh http SSL bindings (covers WinRM, WSUS, custom services)
$netsh = netsh http show sslcert 2>$null | Out-String
if ($netsh -match $thumb) {
    Write-Host "HTTP.sys binds : USING THIS CERT (run 'netsh http show sslcert' for details)" -ForegroundColor Yellow
} else {
    Write-Host "HTTP.sys binds : not using it"
}

# 5) Is it referenced by AD DS already? (it shouldn't be — that's why LDAPS is broken)
$ntdsPath = 'HKLM:\SOFTWARE\Microsoft\Cryptography\Services\NTDS\SystemCertificates\MY\Certificates'
if ((Test-Path $ntdsPath) -and (Get-ChildItem $ntdsPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq $thumb })) {
    Write-Host "NTDS\Personal  : present" -ForegroundColor Yellow
} else {
    Write-Host "NTDS\Personal  : not present (expected)"
}
