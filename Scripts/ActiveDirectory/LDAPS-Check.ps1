$dcFqdn = ([System.Net.Dns]::GetHostByName($env:COMPUTERNAME)).HostName
Write-Host "Checking LDAPS cert candidates for: $dcFqdn`n" -ForegroundColor Cyan

$stores = @(
    @{ Name = 'NTDS\Personal (preferred)'; Path = 'Cert:\LocalMachine\My' },  # placeholder, NTDS handled below
    @{ Name = 'LocalMachine\My (fallback)'; Path = 'Cert:\LocalMachine\My' }
)

# NTDS store needs special access via service account store
$ntdsCerts = @()
try {
    $ntdsPath = 'HKLM:\SOFTWARE\Microsoft\Cryptography\Services\NTDS\SystemCertificates\MY\Certificates'
    if (Test-Path $ntdsPath) {
        $ntdsCerts = (Get-ChildItem $ntdsPath).PSChildName
    }
} catch {}

Write-Host "=== NTDS\Personal store ===" -ForegroundColor Yellow
if ($ntdsCerts.Count -eq 0) { Write-Host "  (empty)" } else { Write-Host "  Thumbprints: $($ntdsCerts -join ', ')" }

Write-Host "`n=== LocalMachine\My store ===" -ForegroundColor Yellow
$candidates = Get-ChildItem Cert:\LocalMachine\My
if ($candidates.Count -eq 0) { Write-Host "  (empty)"; return }

foreach ($c in $candidates) {
    $hasServerAuth = $c.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1'
    $hasPrivateKey = $c.HasPrivateKey
    $sans = ($c.Extensions | Where-Object {$_.Oid.Value -eq '2.5.29.17'}).Format($false)
    $nameMatches = ($c.Subject -match [regex]::Escape($dcFqdn)) -or ($sans -match [regex]::Escape($dcFqdn))
    $expired = $c.NotAfter -lt (Get-Date)

    Write-Host "`n  Subject : $($c.Subject)"
    Write-Host "  Issuer  : $($c.Issuer)"
    Write-Host "  Expires : $($c.NotAfter)"
    Write-Host "  Server Auth EKU : $(if($hasServerAuth){'YES'}else{'NO  <-- disqualifies for LDAPS'})"
    Write-Host "  Private Key     : $(if($hasPrivateKey){'YES'}else{'NO  <-- disqualifies for LDAPS'})"
    Write-Host "  Name matches DC : $(if($nameMatches){'YES'}else{'NO  <-- disqualifies for LDAPS'})"
    Write-Host "  Expired         : $(if($expired){'YES <-- disqualifies'}else{'no'})"
}
