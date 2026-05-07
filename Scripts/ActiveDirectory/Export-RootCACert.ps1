# Export the issuing CA cert that signed the DC's LDAPS certificate
$dcCert = Get-ChildItem Cert:\LocalMachine\My | 
    Where-Object { $_.EnhancedKeyUsageList.FriendlyName -contains "Server Authentication" } |
    Sort-Object NotAfter -Descending | Select-Object -First 1

# Walk the chain and export each CA cert
$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chain.Build($dcCert) | Out-Null

$chain.ChainElements | ForEach-Object {
    if ($_.Certificate.Subject -ne $dcCert.Subject) {
        $name = ($_.Certificate.Subject -split ',')[0] -replace 'CN=','' -replace '[^\w]','_'
        $path = "C:\temp\$name.cer"
        [System.IO.File]::WriteAllBytes($path, $_.Certificate.Export('Cert'))
        Write-Host "Exported: $path"
    }
}
