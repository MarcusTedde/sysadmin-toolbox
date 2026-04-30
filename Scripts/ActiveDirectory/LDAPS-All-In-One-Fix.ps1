# === 0) Backup the existing broken cert (safety net) ===
$oldThumb = 'B50C62E5C33ECD192326476578576400848D1669'
$oldCert  = Get-Item "Cert:\LocalMachine\My\$oldThumb" -ErrorAction SilentlyContinue
if ($oldCert) {
    if (-not (Test-Path C:\Temp)) { New-Item -ItemType Directory -Path C:\Temp | Out-Null }
    $pwd = ConvertTo-SecureString 'TempBackupP@ssw0rd!' -Force -AsPlainText
    Export-PfxCertificate -Cert $oldCert -FilePath "C:\Temp\dc-cert-backup-$(Get-Date -Format yyyyMMdd-HHmm).pfx" -Password $pwd | Out-Null
    Write-Host "Backed up old cert to C:\Temp\" -ForegroundColor Green
}

# === 1) Remove the broken KSP cert ===
if ($oldCert) {
    Remove-Item "Cert:\LocalMachine\My\$oldThumb" -Force
    Write-Host "Removed old cert" -ForegroundColor Green
}

# === 2) Create a properly-formed replacement using Schannel CSP ===
$dcFqdn = ([System.Net.Dns]::GetHostByName($env:COMPUTERNAME)).HostName
$cert = New-SelfSignedCertificate `
    -Subject "CN=$dcFqdn" `
    -DnsName $dcFqdn, $env:COMPUTERNAME `
    -CertStoreLocation 'Cert:\LocalMachine\My' `
    -KeyAlgorithm RSA -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -TextExtension '2.5.29.37={text}1.3.6.1.5.5.7.3.1' `
    -NotAfter (Get-Date).AddYears(2) `
    -Provider 'Microsoft RSA SChannel Cryptographic Provider'

Write-Host "Created new cert: $($cert.Thumbprint)" -ForegroundColor Green

# === 3) Add to Trusted Root so chain validation succeeds ===
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
$store.Open('ReadWrite'); $store.Add($cert); $store.Close()
Write-Host "Added to Trusted Root" -ForegroundColor Green

# === 4) Move to NTDS\Personal so the DC picks IT, deterministically ===
$src = "HKLM:\SOFTWARE\Microsoft\SystemCertificates\MY\Certificates\$($cert.Thumbprint)"
$dst = "HKLM:\SOFTWARE\Microsoft\Cryptography\Services\NTDS\SystemCertificates\MY\Certificates\"
if (-not (Test-Path $dst)) { New-Item -Path $dst -Force | Out-Null }
Copy-Item -Path $src -Destination $dst -Recurse -Force
Remove-Item -Path $src -Recurse -Force
Write-Host "Moved into NTDS\Personal" -ForegroundColor Green

# === 5) Tell AD DS to reload its cert without restarting ===
$root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dcFqdn/RootDSE")
$root.Properties["renewServerCertificate"].Add(1) | Out-Null
$root.CommitChanges()
Write-Host "Triggered renewServerCertificate" -ForegroundColor Green

# === 6) Verify ===
Start-Sleep -Seconds 3
Test-NetConnection -ComputerName $dcFqdn -Port 636
Write-Host "`nNow retry ldp.exe -> localhost:636 with SSL ticked" -ForegroundColor Cyan
