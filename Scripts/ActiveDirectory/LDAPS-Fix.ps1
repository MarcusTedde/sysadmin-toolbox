# 1) Create a self-signed cert that meets every LDAPS requirement
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

Write-Host "Created cert: $($cert.Thumbprint)" -ForegroundColor Green

# 2) Move it to NTDS\Personal so the DC picks IT, not some random IIS/WinRM cert
$src = "HKLM:\SOFTWARE\Microsoft\SystemCertificates\MY\Certificates\$($cert.Thumbprint)"
$dst = "HKLM:\SOFTWARE\Microsoft\Cryptography\Services\NTDS\SystemCertificates\MY\Certificates\"
if (-not (Test-Path $dst)) { New-Item -Path $dst -Force | Out-Null }
Copy-Item -Path $src -Destination $dst -Recurse -Force
Remove-Item -Path $src -Recurse -Force
Write-Host "Moved cert into NTDS\Personal" -ForegroundColor Green

# 3) Tell AD DS to reload the cert without restarting (the magic rootDSE op)
$root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dcFqdn/RootDSE")
$root.Properties["renewServerCertificate"].Add(1) | Out-Null
$root.CommitChanges()
Write-Host "Triggered renewServerCertificate — LDAPS should now be live" -ForegroundColor Green

# 4) Test
Start-Sleep -Seconds 3
Test-NetConnection -ComputerName $dcFqdn -Port 636
