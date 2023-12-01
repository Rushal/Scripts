Function Get-TaskSequenceStatus
{
    try
    {
        $TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment
    }
    catch {}

    if ($NULL -eq $TSEnv)
    {
        return $False
    }
    else
    {
        try
        {
            $SMSTSType = $TSEnv.Value("_SMSTSType")
        }
        catch {}

        if ($NULL -eq $SMSTSType)
        {
            return $False
        }
        else
        {
            return $True
        }
    }
}

Function Write-Log
{
    Param ([string]$string)
    $dateTime = "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    Write-Host "$dateTime - $string"
}


if (Get-TaskSequenceStatus)
{
    $TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment
    $LogsDirectory = $TSEnv.Value("_SMSTSLogPath")
}
else
{
    $LogsDirectory = "C:\Windows\Temp"
}

Start-Transcript -Path ($LogsDirectory + "\Set-LenovoUefiSettings.log")

# This was gotten via another script running on TS start. That would need to be moved here to get the current bios pw...
# See OSD_UefiPassword for this older setup using keepass
Write-Log "Checking for osdUefiPw"
if (Get-TaskSequenceStatus -and $null -ne $TSEnv.Value("osdUefiPw"))
{
    $biosPW = $TSEnv.Value("osdUefiPw")
    Write-Log "osdUefiPw found and set"
}

Write-Log "Setting up UefiWmi"
$UefiWmi = Get-WmiObject -Class Lenovo_SetBiosSetting -Namespace root\WMI
$model = (Get-WmiObject -Class Win32_ComputerSystemProduct -Property Version).Version

$settings = @(
    "LenovoCloudServices,Disable" # Not available on E15
    "WirelessAutoDisconnection,Enable"
    "OnByAcAttach,Enable"
    "BottomCoverTamperDetected,Enable" # Not available on E15
    "IPv4NetworkStack,Enable"
    "IPv6NetworkStack,Enable"
    "BootOrder,NVMe0:NVMe1:HDD0:HDD1"
)

# Load defaults
#(Get-WmiObject -Class Lenovo_LoadDefaultSettings -Namespace root\wmi).LoadDefaultSettings("$biosPW,ascii,us")
#(Get-WmiObject -Class Lenovo_SaveBiosSettings -Namespace root\wmi).SaveBiosSettings("$biosPW,ascii,us").Return

# Check all current settings
#gwmi -class Lenovo_BiosSetting -namespace root\wmi | ForEach-Object { if ($_.CurrentSetting -ne "") { Write-Host $_.CurrentSetting.replace(",", " = ") } }

# Set desired settings
foreach ($setting in $settings)
{
    $settingValues = $setting.split(",")
    # Skip for models without support
    if ( ($settingValues[0] -eq "LenovoCloudServices" -or $settingValues[0] -eq "BottomCoverTamperDetected") -and $model -like "*E15*" )
    {
        Write-Log "$model doesn't support $setting. Continuing"; continue
    }

    $currentValue = Get-WmiObject -Class Lenovo_BiosSetting -Namespace root\WMI | Where-Object { $_.CurrentSetting -match "\b$($settingValues[0])\b" } | Select-Object CurrentSetting
    if ( $settingValues[1] -eq $currentValue.CurrentSetting.split(",")[1] ) { Write-Log "Settings match for $setting. Continuing"; continue }

    Write-Log "Setting: $($settingValues[0]) to $($settingValues[1])"
    if ( $UefiWmi.SetBiosSetting("$($settingValues[0]),$($settingValues[1]),$biosPW,ascii,us").Return -ne "Success" )
    {
        Write-Log "Failed setting with password, trying again without password."
        if ( $UefiWmi.SetBiosSetting("$($settingValues[0]),$($settingValues[1])").Return -ne "Success" )
        {
            Write-Log "Error updating the UEFI setting: $($settingValues[0]) to $($settingValues[1])"
            Stop-Transcript
            exit 1
        }
    }

    Write-Log "Saving setting $setting..."
    if ( (Get-WmiObject -Class Lenovo_SaveBiosSettings -Namespace root\wmi).SaveBiosSettings("$biosPW,ascii,us").Return -ne "Success" )
    {
        Write-Log "Failed saving with password, trying again without password."
        if ( (Get-WmiObject -Class Lenovo_SaveBiosSettings -Namespace root\wmi).SaveBiosSettings().Return -ne "Success" )
        {
            Write-Log "Error saving the UEFI settings"
            Stop-Transcript
            exit 1
        }
    }
    else
    {
        Write-Log "Saved: $setting"
    }
}

$TSEnv.Value("osdUefiPw") = $null
Write-Log "OsdUefiPw removed"

if ( $TSEnv.Value("osdUefiPw") -ne "" )
{ 
    Write-Log "Error erasing osdUefiPw"
    Stop-Transcript
    exit 2
}

Stop-Transcript