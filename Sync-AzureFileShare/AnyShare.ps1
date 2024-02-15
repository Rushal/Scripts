Param (
    [Parameter(Mandatory = $true)]
    [String] $ResourceGroupName = "",
    [Parameter(Mandatory = $true)]
    [String] $StorageSyncServiceName = "",
    [Parameter(Mandatory = $true)]
    [String] $SyncGroupName = "",
    [Parameter(Mandatory = $false)]
    [String] $CloudEndpointName = "", # ID From storage sync portal
    [String] $DirectoryPath = ""
)

# TODO: Convert to Managed ID
# Paired with a logic app
<#
HTTP TRIGGER (&endpoint=$SyncGroupName&folder=$directoryPath)
VAR - endpoint (from http query)
VAR - folder (from http query)
Run Automation with below script
RESPONSE
#>

Write-Output "Pulling in Shared Assests"
try {
    $Credential = Get-AutomationPSCredential -Name ""
    $Tenant = Get-AutomationVariable -Name 'Tenant ID'
    $SubscriptionID = Get-AutomationVariable -Name 'Sub-ID'
}
catch {
    Write-Error "Issue with pulling Automation Creds"
    throw 
}

#Connecting to Azure using SPN
Write-Output "Connecting to Azure"
try {
    Connect-AzAccount -Credential $Credential -Tenant $Tenant -Subscription $SubscriptionID -ServicePrincipal
}
catch {
    Write-Error "Issue connecting to Azure"
    throw 
}

if ($DirectoryPath -ne "") {
    Write-Output "Check for files and directories changes for $StorageSyncServiceName in $SyncGroupName"
    Invoke-AzStorageSyncChangeDetection -ResourceGroupName $ResourceGroupName -StorageSyncServiceName $StorageSyncServiceName `
        -SyncGroupName $SyncGroupName -CloudEndpointName $CloudEndpointName -DirectoryPath "$DirectoryPath" -Recursive

    Write-Output "Sync Running for $SyncGroupName - $DirectoryPath"
}
else {
    Write-Output "Check for files and directories changes for $StorageSyncServiceName in $SyncGroupName"
    Invoke-AzStorageSyncChangeDetection -ResourceGroupName $ResourceGroupName -StorageSyncServiceName $StorageSyncServiceName `
        -SyncGroupName $SyncGroupName -CloudEndpointName $CloudEndpointName

    Write-Output "Sync Running - Check cloud enpoint in portal for status"
}
