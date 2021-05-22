<#
   .Synopsis
   Keep Git repo up to date

   .OUTPUTS
   For logs see: $logFilePath

   .VERSION
    1.0
    
    .AUTHOR
    Chucky A Ivey
#>


#Region Logging
$logFilePath = "D:\logs\tasks\Update-GitRepo\logs\"
$logFileName = "Update-GitRepo_Transcript_$(Get-Date -Format "MM-dd-yyyy").log"
$logAge = 7

if (-not( Test-Path -Path ($logFilePath + $logFileName) ))
{
    New-Item -ItemType File -Path $logFilePath -Name $logFileName -Force
}
else
{
    # Do some cleanup. If the files are older than the specified file age, delete them
    $logFiles = Get-ChildItem $logFilePath -Filter *.log | Where-Object LastWriteTime -LT (Get-Date).AddDays(-1 * $logAge)

    foreach ($logFile in $logFiles)
    {
        Remove-Item -Path $logFile.FullName
    }
}

Function Write-Log
{
    Param ([string]$string)

    $dateTime = "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    Write-Host "$dateTime - $string"
    #Add-Content ($logFilePath + $logFileName) -value "$dateTime - $string"
}

Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
Start-Transcript -Path ($logFilePath + $logFileName)
#Endregion


# Vars
$credentialFile = "D:\Update-GitRepo\Git_IT_Project.xml"
$credential = Import-Clixml -Path $credentialFile
$repoPath = "D:\_Git\it"

if ( Test-Path -Path $repoPath )
{
    try
    {
        Write-Log "Repo already exists"
        Write-Log "Setting location to $repoPath"
        Push-Location $repoPath

        Write-Log "Fetching the repo data"
        git fetch --all

        Write-Log "Data fetched, resetting to current origin/master"
        git reset --hard origin/master

        Write-Log "Repo reset, cleaning items that are not commited"
        git clean -f -d

        Write-Log "Repo cleaned, pulling updates"
        git pull
        
        Write-Log "Update done!"
    }
    catch
    {
        Write-Log "Failed to update repo"
        $emailBody = "Failed to update the repo, check the log"
    }
}
else
{
    Write-Log "Did not find the repo, changing location"
    Push-Location D:\_Git

    try
    {
        $username = $credential.UserName
        $password = $credential.GetNetworkCredential().Password

        Write-Log "Attempting to clone IT Repo"

        git clone https://$($username):$($password)@gitlab.domain.com/it/it.git

        Write-Log "Repo cloned"
    }
    catch
    {
        Write-Log "Repo clone failed"
        $emailBody = "Failed to clone the repo, check the log"
    }
}

# Email IT
if ($emailBody)
{
    $body = "<strong>Task Server:</strong> $env:COMPUTERNAME<br/>"
    $body += "<strong>Task name:</strong> Update Git Repo<br/><br/>"
    $body += $emailBody

    try
    {
        Write-Log "Attempting to send email to IT"

        Send-MailMessage -From 'Alerts <alerts@domain.com>' -To 'it@domain.com' `
            -Subject "ALERT: Git Repo update failed on $env:COMPUTERNAME" `
            -Body $body -BodyAsHtml `
            -SmtpServer smtp.domain.com
    }
    catch
    {
        Write-Log "Email failed to IT"
    }
}
Stop-Transcript