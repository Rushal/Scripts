$pePrefix = "<private endpoint prefix>"
$region = "southcentralus"
$privateDnsRg = ""
Connect-AzAccount

# Sub 1
Set-AzContext -Subscription ""
$SQLServers = Get-AzSqlServer #-ServerName "<server name>"

# Sub 2
Set-AzContext -Subscription ""
$SQLServers += Get-AzSqlServer

# Sub 3
Set-AzContext -Subscription ""
$sub3Rg = "<RG>"
$sub3Vnet = "<Vnet>"
$sub3Subnet = "<subnet>"
$virtualNetwork = Get-AzVirtualNetwork -ResourceGroupName  "$sub3Rg" -Name "$sub3Vnet"
$subnet = $virtualNetwork | Select-Object -ExpandProperty subnets | Where-Object { $_.Name -eq "$sub3Subnet" }

foreach ($SQLServer in $SQLServers)
{
    if (Get-AzPrivateEndpoint -Name "$pePrefix$($SQLServer.ServerName)")
    {
        Write-Host "There is already a Private Endpoint with this name: $pePrefix$($SQLServer.ServerName). Skipping"
        continue
    }

    Write-Host "Setting up Private Endpoint for: $($SQLServer.ServerName)"

    # Setup private endpoint connection (pending approval)
    $privateEndpointConnection = New-AzPrivateLinkServiceConnection -RequestMessage "<message> - $($SQLServer.ServerName)" -Name "$pePrefix$($SQLServer.ServerName)" -PrivateLinkServiceId $SQLserver.ResourceId -GroupId "sqlServer"
    $privateEndpointForSQLServer = New-AzPrivateEndpoint -ByManualRequest -ResourceGroupName "$sub3RG" -Name "$pePrefix$($SQLServer.ServerName)" -Location "$region" -Subnet $subnet -PrivateLinkServiceConnection $privateEndpointConnection

    Write-Host "Setting up Private DNS for: $pePrefix$($SQLServer.ServerName)"
    # Add private endpoint dns 
    $zone = Get-AzPrivateDnsZone -ResourceGroupName "$privateDnsRg" -Name "privatelink.database.windows.net"
    $config = New-AzPrivateDnsZoneConfig -Name "privatelink.database.windows.net" -PrivateDnsZoneId $zone.ResourceId
    $dnsEntry = New-AzPrivateDnsZoneGroup -ResourceGroupName "$sub3Rg" -PrivateEndpointName "$pePrefix$($SQLServer.ServerName)" -Name "$pePrefix$($SQLServer.ServerName)" -PrivateDnsZoneConfig $config
}