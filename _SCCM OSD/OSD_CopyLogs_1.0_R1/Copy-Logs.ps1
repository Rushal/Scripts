param (
    [switch] $upgrade
)

Function Get-TaskSequenceStatus {
    try {
        $TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment
    }
    catch {}

    if ($NULL -eq $TSEnv) {
        return $False
    }
    else {
        try {
            $SMSTSType = $TSEnv.Value("_SMSTSType")
        }
        catch {}

        if ($NULL -eq $SMSTSType) {
            return $False
        }
        else {
            return $True
        }
    }
}

Function Write-Log {
    Param ([string]$string)
    $dateTime = "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    Write-Host "$dateTime - $string"
}


if (Get-TaskSequenceStatus) {
    $TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment
    $LogsDirectory = $TSEnv.Value("_SMSTSLogPath")
}
else {
    $LogsDirectory = "C:\Windows\Temp"
}

Start-Transcript -Path ($LogsDirectory + "\Copy-Logs.log")

if ($upgrade) {
    $sourcePath = "C:\Windows\CCM\Logs"
    $destinationPath = "L:\$($TSEnv.Value("OSDComputerName"))\_Upgrade\$((Get-Date).ToString('MMddyyyy_HHmmss'))"
}
else {
    $sourcePath = $TSEnv.Value("_SMSTSLogPath")
    $destinationPath = "L:\$($TSEnv.Value("OSDComputerName"))\$((Get-Date).ToString('MMddyyyy_HHmmss'))"
}

Write-Log "Source: $sourcePath"
Write-Log "Destination Folder: $destinationPath"

Write-Log "Checking for existing folder in \\<PATH TO LOGS FOLDER>"
if (-not(Test-Path -Path $destinationPath)) {
    New-Item -Path $destinationPath -ItemType Directory -Force
    Write-Log "Created folder: $destinationPath"
}

Write-Log "Trying to copy logs"
if (-not (Copy-Item -Path $sourcePath -Destination $destinationPath -Recurse -Force -PassThru)) {
    Write-Log "Copy Failed"
}
else {
    Write-Log "Copy complete"
}

Stop-Transcript