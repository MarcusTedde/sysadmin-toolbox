$cert = Get-ChildItem Cert:\LocalMachine\My | 
    Where-Object { $_.Subject -eq "CN=[DCFQDN]" } | 
    Select-Object -First 1

Write-Host "Thumbprint        : $($cert.Thumbprint)"
Write-Host "Provider          : $($cert.PrivateKey.CspKeyContainerInfo.ProviderName)" -ErrorAction SilentlyContinue

# Modern check via certutil — works for both CSP and KSP
$ct = certutil -store My $cert.Thumbprint | Out-String
if ($ct -match 'Provider\s*=\s*(.+)')   { Write-Host "Provider (certutil): $($Matches[1].Trim())" }
if ($ct -match 'Key Container')          { Write-Host ($ct -split "`n" | Select-String 'Key Container|Provider|KeySpec') }

# Is it trusted by the DC itself?
$inRoot = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
Write-Host "`nIn Trusted Root   : $(if($inRoot){'YES'}else{'NO  <-- self-signed certs MUST also be in Root'})"

# Test the chain
$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chainOk = $chain.Build($cert)
Write-Host "Chain validates   : $chainOk"
if (-not $chainOk) { $chain.ChainStatus | ForEach-Object { Write-Host "   $($_.Status): $($_.StatusInformation)" } }
