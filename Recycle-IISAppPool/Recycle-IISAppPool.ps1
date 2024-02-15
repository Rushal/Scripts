# Used via a Logic app with an HTTP trigger
<#
HTTP TRIGGER (&name=SERVERNAME&appPool=IISAppPoolName)
CREATE JOB (Azure Automation with below script)
RESPONSE
#>

[cmdletbinding()]
Param(
    [string]$ComputerName = "",
    [string]$AppPoolName = "",
    [string]$AutomationCred = ""
)

$creds = Get-AutomationPSCredential -Name "$AutomationCred"

$ScriptBlock = {
    $appPool = Get-WebAppPoolState -Name $Using:AppPoolName
    Write-Output "$($Using:AppPoolName) $($appPool.Value)"

    if ($appPool.Value -eq 'Started') {
        Write-Output "$($Using:AppPoolName) is Running. Attempting to recycle..."
        try {
            Restart-WebAppPool -Name "$($Using:AppPoolName)"
            Write-Output $appPool.Value
            return 0
        }
        catch { return 1 }
    }
    else {
        Write-Output "$($Using:AppPoolName) is not Running. Attempting to start..."
        try {
            Start-WebAppPool -Name "$($Using:AppPoolName)"
            Write-Output $appPool.Value
            return 0
        }
        catch { return 1 }
    }
}

Invoke-Command -ComputerName "$computerName" -Credential $creds -ScriptBlock $ScriptBlock