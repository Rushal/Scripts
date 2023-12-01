<#
   .Synopsis
   Update the Azure AD SSO Key

   .DESCRIPTION
   See MS Doc: https://docs.microsoft.com/en-us/azure/active-directory/hybrid/how-to-connect-sso-faq
   This is intended to be used with Azure Runbooks
   This script will use an on-prem service account that is disabled
   
   .OUTPUTS
   For logs see: $logFilePath
   
   .VERSION
    1.0
    
    .AUTHOR
    Chucky A Ivey
#>
param (
    [Parameter (Mandatory = $true)]
    [string] $AADConnectPC
)

# Update with your service account info
$domain = "example.com"
$adServiceAccount = "svc.example"
$automationCloudAccount = "svc.example-cloud"
$automationLocalAccount = "svc.example-local"

Write-Output "Running host: $env:computername"

# Add service account to domain admins
Write-Output "Enabling $adServiceAccount"
Enable-ADAccount -Identity $adServiceAccount -Confirm:$false

Write-Output "Adding $adServiceAccount to domain admins"
Add-ADGroupMember -Identity "Domain Admins" -Members $adServiceAccount

Write-Output "Forcing replication"
$replication = repadmin /syncall /AdeP | select -Skip 9 | ? { ![string]::IsNullOrWhiteSpace($_) }
$replication | select -Last 1

$cloudCreds = Get-AutomationPSCredential -Name "$automationCloudAccount"
$creds = Get-AutomationPSCredential -Name "$automationLocalAccount"
$session = New-PSSession -ComputerName $AADConnectPC -Credential $creds

$Job = Invoke-Command -Session $session -AsJob -ScriptBlock {
    Start-Transcript -Path "C:\Windows\Temp\Update-AadSso.log" -Append

    Function Write-Log
    {
        Param ([string]$string)
        $dateTime = "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
        Write-Output "$dateTime - $string"
    }

    Write-Log "Running host: $env:computername"

    Write-Log "Delta Sync AAD"
    Start-ADSyncSyncCycle -PolicyType Delta

    Write-Log "Connecting to Azure to check on account enablement"
    while ($azureConnection.Account -eq $null)
    {
        $azureConnection = Connect-AzureAD -Credential $using:cloudCreds -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }
    Write-Log "$adServiceAccount is enabled, disconnecting"
    Disconnect-AzureAd

    #Region Attempt to import the AADSSO powershell module
    try
    {
        Write-Log "Attempting to import the AAD SSO Module"
        Import-Module "C:\Program Files\Microsoft Azure Active Directory Connect\AzureADSSO.psd1" -ErrorAction Stop
        Write-Log "AAD SSO Module successfully imported"
    }
    catch
    {
        Write-Log "Failed to import: C:\Program Files\Microsoft Azure Active Directory Connect\AzureADSSO.psd1"
        Stop-Transcript
        exit
    }
    #Endregion

    try
    {
        Write-Log "Trying to set Azure AD SSO Auth Context"
        New-AzureADSSOAuthenticationContext -CloudCredentials $using:cloudCreds -ErrorAction Stop

        Write-Log "Attempting to recycle the AAD SSO Key"
        Update-AzureADSSOForest -OnPremCredentials $using:creds -ErrorAction Stop
        Write-Log "SSO Key recycled"
    }
    catch
    {
        Write-Log "Update-AzureADSSOForest failed to run"
        Stop-Transcript
    }
    <# This requires Global Admin... Manual process for now
    try {
        Write-Log "Trying to rotate Azure AD Cloud Kerberos Key"
        Set-AzureADKerberosServer -Domain "$domain" -CloudCredential $using:cloudCreds -DomainCredential $using:creds -RotateServerKey -ErrorAction Stop
        Write-Log "Cloud Kerberos Key rotated"
    } catch {
        Write-Log "Set-AzureADKerberosServer failed to run"
        Stop-Transcript
    }
#>
    Stop-Transcript
}

Write-Output "Waiting for Job to run on AAD Connect server"
Wait-Job -Job $Job

Write-Output "Job output:"
Receive-Job $Job

# Remove service account from domain admins
Write-Output "Removing $adServiceAccount from domain admins"
Remove-ADGroupMember -Identity "Domain Admins" -Members $adServiceAccount -Confirm:$false

Write-Output "Disabling $adServiceAccount"
Disable-ADAccount -Identity $adServiceAccount -Confirm:$false

Write-Output "Forcing replication"
$replication = repadmin /syncall /AdeP | select -Skip 9 | ? { ![string]::IsNullOrWhiteSpace($_) }
$replication | select -Last 1

Write-Output "Run Delta Sync AAD"
Invoke-Command -Session $session -ScriptBlock { Start-ADSyncSyncCycle -PolicyType Delta }