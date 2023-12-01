# Meant for Azure runbooks
[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [Parameter(Mandatory = $False)] [String] $TenantId = "",
    [Parameter(Mandatory = $False)] [String] $ClientId = "",
    [Parameter(Mandatory = $False)] [String] $AuthUrl = "https://login.windows.net/example.onmicrosoft.com",
    [Parameter(Mandatory = $False)] [String] $orgUnit = "",
    [Parameter(Mandatory = $False)] [String] $certPath = "X509:<I>DC=com,DC=example,CN=ca-name-CA<S>CN=",
    [Parameter(Mandatory = $False)] [Switch] $NameMap
)

Write-Output "Hybrid worker: $($env:COMPUTERNAME)"

# Get NuGet
Get-PackageProvider -Name "NuGet" -Force | Out-Null

# Get MS Graph
$module = Import-Module -Name Microsoft.Graph.Intune -PassThru -ErrorAction Ignore
if (-not $module)
{
    Write-Output "Installing module Microsoft.Graph.Intune"
    Install-Module Microsoft.Graph.Intune -Force
}
Import-Module Microsoft.Graph.Intune -Scope Global

# Get WindowsAutopilotIntune module (and dependencies)
$module = Import-Module WindowsAutopilotIntune -PassThru -ErrorAction Ignore
if (-not $module)
{
    Write-Output "Installing module WindowsAutopilotIntune"
    Install-Module WindowsAutopilotIntune -Force
}
Import-Module WindowsAutopilotIntune -Scope Global

# Connect to MSGraph with application credentials
$ClientSecret = Get-AutomationPSCredential -Name ''
$password = $ClientSecret.GetNetworkCredential().Password

# Connect-MSGraphApp -Tenant $TenantId -AppId $ClientId -AppSecret $ClientSecret
Update-MSGraphEnvironment -AppId $ClientId
Update-MSGraphEnvironment -AuthUrl $AuthUrl
Connect-MSGraph -ClientSecret $password -Quiet -ErrorAction Stop

# Pull latest Autopilot device information
$AutopilotDevices = Get-AutopilotDevice | Select-Object managedDeviceId
$IntuneDevices = Get-IntuneManagedDevice | Select-Object id, deviceName

# Create a hashtable to match device names to id's
$CombineData = @{}
$CombinedData = @()
foreach ($device in $AutopilotDevices)
{
    $CombineData[$device.managedDeviceId] = $device.managedDeviceId
}

$IntuneDevices | ForEach-Object {
    $OtherData = $CombineData[$_.id]

    $Data = [pscustomobject]@{
        AutoPilotId = $OtherData
        IntuneId    = $_.id
        Name        = $_.deviceName
    }

    $CombinedData += $Data
}

$FilteredDevices = @()
foreach ($Device in $CombinedData)
{
    if ($null -eq $Device.AutoPilotId) { continue }
    $FilteredDevices += $Device
}

# TEST FILTERING
#$FilteredDevices = $FilteredDevices | Where-Object { $_.Name -eq "ATX-D9BD1X2" }

# Create new Autopilot computer objects in AD while skipping already existing computer objects
foreach ($Device in $FilteredDevices)
{    
    if (Get-ADComputer -Filter "Name -eq ""$($Device.Name)""" -SearchBase $orgUnit -ErrorAction SilentlyContinue)
    {
        Write-Output "Skipping $($Device.Name) because it already exists."
    }
    else
    {
        # Create new AD computer object
        try
        {
            New-ADComputer -Name "$($Device.Name)" -SAMAccountName "$($Device.Name)`$" -ServicePrincipalNames "HOST/$($Device.Name)", "HOST/$($Device.Name).example.com" -Path $orgUnit
            Write-Output "Computer object created. ($($Device.Name))"
        }
        catch
        {
            Write-Output "Error. Skipping computer object creation. ($($Device.Name))"
        }
        
        # Perform name mapping
        try
        {
            Set-ADComputer -Identity "$($Device.Name)" -Add @{'altSecurityIdentities' = "$($certPath)$($Device.Name)" }
            Write-Output "Name mapping for computer object done. ($($certPath)$($Device.Name))"
        }
        catch
        {
            Write-Output "Error. Skipping name mapping. ($($Device.Name))"
        }
    }
}

# Reverse the process and remove any dummmy computer objects in AD that are no longer in Autopilot
$DummyDevices = Get-ADComputer -Filter * -SearchBase $orgUnit | Select-Object Name, SAMAccountName
foreach ($DummyDevice in $DummyDevices)
{
    if ($FilteredDevices.Name -contains $DummyDevice.Name)
    {
        Write-Output "$($DummyDevice.Name) exists in Autopilot."
    }
    else
    {
        Write-Output "$($DummyDevice.Name) does not exist in Autopilot."
        Remove-ADComputer -Identity $DummyDevice.SAMAccountName -Confirm:$False -WhatIf
    }
}