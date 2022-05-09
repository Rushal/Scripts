$pePrefix = "<private endpoint prefix>"
Connect-AzAccount

# Sub 1
Set-AzContext -Subscription ""
$SQLServers = Get-AzSqlServer #-ServerName "atx-alibabaazure-dev"

# Sub 2
Set-AzContext -Subscription ""
$SQLServers += Get-AzSqlServer

# Sub 3
Set-AzContext -Subscription ""
$virtualNetwork = Get-AzVirtualNetwork -ResourceGroupName  "<RG>" -Name "<VNET>"
$subnet = $virtualNetwork | select -ExpandProperty subnets | Where-Object { $_.Name -eq '<subnet>' }

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
    $privateEndpointForSQLServer = New-AzPrivateEndpoint -ByManualRequest -ResourceGroupName "<rg>" -Name "$pePrefix$($SQLServer.ServerName)" -Location "southcentralus" -Subnet $subnet -PrivateLinkServiceConnection $privateEndpointConnection

    Write-Host "Setting up Private DNS for: $pePrefix$($SQLServer.ServerName)"
    # Add private endpoint dns 
    $zone = Get-AzPrivateDnsZone -ResourceGroupName "<rg>" -Name "privatelink.database.windows.net"
    $config = New-AzPrivateDnsZoneConfig -Name "privatelink.database.windows.net" -PrivateDnsZoneId $zone.ResourceId
    $dnsEntry = New-AzPrivateDnsZoneGroup -ResourceGroupName "<RG>" -PrivateEndpointName "$pePrefix$($SQLServer.ServerName)" -Name "$pePrefix$($SQLServer.ServerName)" -PrivateDnsZoneConfig $config
}