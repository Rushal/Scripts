[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ApiKey = ""
$headers = @{
    "X-Cisco-Meraki-API-Key" = "$ApiKey"
    "Content-Type"           = "application/json"
    "Accept"                 = "application/json"
}

$clientURL = "https://api.meraki.com/api/v1/devices/<DEVICE ID>/switch/ports/cycle"

$body = @{
    "ports" = @("25")
}

Invoke-RestMethod -Uri $clientURL -Headers $headers -Body (ConvertTo-Json $body) -Method 'POST'