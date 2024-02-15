<#
   .Synopsis
   Send a heartbeat every 10 minutes to OpsGenie

   .DESCRIPTION
   If this heartbeat isn't sent to OpsGenie within 10 minutes, it will trigger an alert for the on-call user

   .OUTPUTS
   For logs see: $logFilePath

   .VERSION
    1.0
    
    .AUTHOR
    Chucky A Ivey
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#Region Logging
$logFilePath = "D:\logs\Send-OpsGenieHearbeat\"
$logFileName = "Send-OpsGenieHeartbeat_Transcript_$(Get-Date -Format "MM-dd-yyyy").log"
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
Start-Transcript -Path ($logFilePath + $logFileName) -Append
#Endregion

$filePath = "D:\_Git\Send-OpsGenieHearbeat\"
$credsFile = Import-Clixml "$($filePath)OpsGenieAPI_${env:USERNAME}_${env:COMPUTERNAME}.xml"

$from = ""
$to = ""
$smtp = ""

try
{
    Write-Log "Sending heartbeat to https://api.opsgenie.com/v2/heartbeats/Solarwinds/ping"
    $r = Invoke-RestMethod -Uri "https://api.opsgenie.com/v2/heartbeats/Solarwinds/ping" -Headers @{ "Authorization" = "GenieKey $($credsFile.GetNetworkCredential().Password)" } -Method POST

    Write-Log "Response: $r"
    Write-Log "NOTE: The response is asyncronous, so this doesn't mean the this heartbeat exists on OpsGenie"
}
catch
{
    try
    {
        Write-Log "Attempting to send email it IT about heartbeat failure"
        $body = "<strong>Task Server:</strong> $env:COMPUTERNAME<br/>"
        $body += "<strong>Task name:</strong> Send OpsGenie a heartbeat from Solarwinds<br/><br/>"
        $body += "The heartbeat to OpsGenie failed"

        Send-MailMessage -From $from -To $to `
            -Subject 'ALERT: Solarwinds Heartbeat failed to api.opsgenie.com' `
            -Body $body -BodyAsHtml `
            -SmtpServer $smtp
    }
    catch
    {
        Write-Log "Email failed to IT"
    }
}

Stop-Transcript