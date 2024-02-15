<#
   .SYNOPSIS
   Push content filter changes to all networks in an org

   .DESCRIPTION

   .OUTPUTS
   For logs see: $logFilePath
   
   .NOTES
    v1.0
    AUTHOR
        Chucky A Ivey
#>

#Region Logging
$logFilePath = "C:\Windows\Temp\logs\"
$logFileName = "Update-DesktopCentralRegistry_Transcript_$(Get-Date -Format "MM-dd-yyyy").log"
$logAge = 7

if (-not( Test-Path -Path ($logFilePath + $logFileName) )) {
    New-Item -ItemType File -Path $logFilePath -Name $logFileName -Force
}
else {
    # Do some cleanup. If the files are older than the specified file age, delete them
    $logFiles = Get-ChildItem $logFilePath -Filter *.log | Where-Object LastWriteTime -LT (Get-Date).AddDays(-1 * $logAge)

    foreach ($logFile in $logFiles) {
        Remove-Item -Path $logFile.FullName
    }
}

Function Write-Log {
    Param ([string]$string)

    $dateTime = "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    Write-Host "$dateTime - $string"
    #Add-Content ($logFilePath + $logFileName) -value "$dateTime - $string"
}

Start-Transcript -Path ($logFilePath + $logFileName) -Append
#Endregion

$regPath = "HKLM:\SOFTWARE\WOW6432Node\AdventNet\DesktopCentral\DCAgent\ServerInfo"
$newHttp = "80"
$newHttps = "443"
$newIP = "<Desktop Central URL>"

if (Test-Path $regPath) {
    Write-Log "Found Desktop Central Registry. Updating"

    $httpPort = Get-ItemProperty -Path $regPath -Name "DCServerPort"
    $httpsPort = Get-ItemProperty -Path $regPath -Name "DCServerSecurePort"
    $secondaryIP = Get-ItemProperty -Path $regPath -Name "DCServerSecIPAddress"

    if ($httpPort.DCServerPort -ne $newHttp) {
        Write-Log "Updating http port from $($httpPort.DCServerPort) to $newHttp"
        $httpPort | Set-ItemProperty -Name "DCServerPort" -Value $newHttp
    }
    if ($httpsPort.DCServerSecurePort -ne $newHttps) {
        Write-Log "Updating https port from $($httpsPort.DCServerSecurePort) to $newHttps"
        $httpsPort | Set-ItemProperty -Name "DCServerSecurePort" -Value $newHttps
    }
    if ($secondaryIP.DCServerSecIPAddress -ne $newIp) {
        Write-Log "Updating secondary ip from $($secondaryIP.DCServerSecIPAddress) to $newIP"
        $secondaryIP | Set-ItemProperty -Name "DCServerSecIPAddress" -Value $newIP
    }

    Write-Log "Stopping agent service to apply changes"
    Stop-Process -Name dcagentservice -Force

    Start-Sleep -Seconds 5

    Write-Log "Starting agent service"
    Start-Service -Name 'ManageEngine Desktop Central - Agent'
}
Stop-Transcript