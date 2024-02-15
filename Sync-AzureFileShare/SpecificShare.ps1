Param (
    [Parameter(Mandatory = $true)]
    [String] $ResourceGroupName = "",
    [Parameter(Mandatory = $true)]
    [String] $StorageSyncServiceName = ""
)

# TODO: Convert to Managed ID
<#
HTTP TRIGGER
Run Automation with below script
RESPONSE
#>

$errorActionPreference = "Stop"

$SyncGroupName = @("GROUP1", "GROUP2", "GROUP3")
$CloudEndpointName = @("GROUP1-ID", "GROUP2-ID", "GROUP3-ID")
$DirectoryPath = ""

Write-Output "Pulling in Shared Assests"
try {
    $Credential = Get-AutomationPSCredential -Name ""
    $Tenant = Get-AutomationVariable -Name 'Tenant ID'
    $SubscriptionID = Get-AutomationVariable -Name 'Sub-ID'
}
catch {
    Write-Output "Issue with pulling Automation Creds"
    throw 
}

#Connecting to Azure using SPN
Write-Output "Connecting to Azure"
try {
    Connect-AzAccount -Credential $Credential -Tenant $Tenant -Subscription $SubscriptionID -ServicePrincipal
}
catch {
    Write-Output "Issue connecting to Azure"
    Wtrie-Output $_
    throw 
}

for ($i = 0; $i -lt $CloudEndpointName.Count; $i++) {
    Write-Output "Check for files and directories changes for $StorageSyncServiceName in $($SyncGroupName[$i])"

    try {
        Invoke-AzStorageSyncChangeDetection -ResourceGroupName $ResourceGroupName -StorageSyncServiceName $StorageSyncServiceName `
            -SyncGroupName $SyncGroupName[$i] -CloudEndpointName $CloudEndpointName[$i] -DirectoryPath "$DirectoryPath" -Recursive

        Write-Output "Sync Running for $SyncGroupName - $DirectoryPath"
    }
    catch {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}