# Remove the existing broken cert
Get-ChildItem Cert:\LocalMachine\My | 
    Where-Object { $_.Subject -eq "CN=[DCFQDN]" } | 
    Remove-Item -Force

# Create a properly-formed replacement (Schannel CSP, all extensions correct)
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

Write-Host "Created: $($cert.Thumbprint)" -ForegroundColor Green

# Trust it (self-signed must be in Root for chain validation)
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
$store.Open('ReadWrite'); $store.Add($cert); $store.Close()
Write-Host "Added to Trusted Root" -ForegroundColor Green

# Move into NTDS\Personal so the DC picks it deterministically
$src = "HKLM:\SOFTWARE\Microsoft\SystemCertificates\MY\Certificates\$($cert.Thumbprint)"
$dst = "HKLM:\SOFTWARE\Microsoft\Cryptography\Services\NTDS\SystemCertificates\MY\Certificates\"
if (-not (Test-Path $dst)) { New-Item -Path $dst -Force | Out-Null }
Copy-Item -Path $src -Destination $dst -Recurse -Force
Remove-Item -Path $src -Recurse -Force
Write-Host "Moved into NTDS\Personal" -ForegroundColor Green

# Trigger AD DS to reload its cert without restarting
$root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dcFqdn/RootDSE")
$root.Properties["renewServerCertificate"].Add(1) | Out-Null
$root.CommitChanges()
Write-Host "Triggered renewServerCertificate" -ForegroundColor Green

Start-Sleep -Seconds 3
Test-NetConnection -ComputerName $dcFqdn -Port 636
