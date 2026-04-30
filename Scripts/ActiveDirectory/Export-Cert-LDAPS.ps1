$dcFqdn = ([System.Net.Dns]::GetHostByName($env:COMPUTERNAME)).HostName
$cert = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -eq "CN=$dcFqdn" } | Select-Object -First 1
Export-Certificate -Cert $cert -FilePath "C:\Temp\dc-ldaps-public.cer" -Type CERT
Write-Host "Public cert exported to C:\Temp\dc-ldaps-public.cer — copy this to the firewall"
