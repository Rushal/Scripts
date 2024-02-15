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
    $isUefi = $TSEnv.Value("_SMSTSBootUEFI")
    
    if (-not $TSEnv.Value("osdTpmCleared") -or $TSEnv.Value("osdTpmCleared") -eq "") { $TSEnv.Value("osdTpmCleared") = $false }
}
else
{
    $LogsDirectory = "C:\Windows\Temp"
}

Start-Transcript -Path ($LogsDirectory + "\Set-DellUefiSettings.log") -Append

# See OSDUefiPassword script
Write-Log "Checking for osdUefiPw"
if (Get-TaskSequenceStatus -and $null -ne $TSEnv.Value("osdUefiPw"))
{
    $biosPW = $TSEnv.Value("osdUefiPw")
    Write-Log "osdUefiPw found and set"
}

Write-Log "Setting Model"
$model = (Get-WmiObject -Class Win32_ComputerSystem).Model

Write-Log "Setting path to C:\_SMSTaskSequence\Packages\<CCTK PACKAGE ID>"
Set-Location -Path C:\_SMSTaskSequence\Packages\<CCTK PACKAGE ID>

Write-Log "Get current settings:"
$LegacyRom = .\cctk --legacyorom
$SecureBoot = .\cctk --secureboot
$UefiNetwork = .\cctk --uefinwstack
$TPM = .\cctk --tpm
$TPMActive = .\cctk --tpmactivation
$ACPower = .\cctk --acpower
$Fastboot = .\cctk --fastboot

Write-Log "Check for Legacy BIOS and convert"
if ($isUefi -eq $false)
{
    Write-Log "Setting avtive boot list to UEFI"
    $activeBootList = .\cctk bootorder --activebootlist=uefi --valsetuppwd=$biosPW
    Write-Log "$activeBootList"

    Write-Log "Try to move the HDD to the top of the boot list"
    $uefiBootOrder = .\cctk bootorder --bootlisttype=uefi --sequence=uefi.3 --valsetuppwd=$biosPW
    $legacyBootOrder = .\cctk bootorder --sequence=hdd, hdd.2, embnic --valsetuppwd=$biosPW
    Write-Log "$uefiBootOrder"
    Write-Log "$legacyBootOrder"

    $TSEnv.Value("udiUefiSwitch") = $true

    <# Reboot TS and Retry
    $TSEnv.Value("SMSTSRebootRequested") = "WinPE"
    $TSEnv.Value("SMSTSRetryRequested") = $true#>
}


# Set desired settings
if ( $TSEnv.Value("XHWChassisType") -ne "Desktop" -And $TSEnv.Value("type") -ne "Desktop" -And $model -ne "Latitude 3590" -And $model -ne "Latitude E7240" -And $model -ne "Latitude E7250" -And $model -ne "Latitude E7270" -And $model -ne "Latitude E6510" -And $model -ne "Latitude E6520" -And $model -ne "Latitude 3500" )
{
    Write-Log "Updating Thunderbolt settings"
    
    $Thunderbolt = .\cctk --thunderbolt=enable --valsetuppwd=$biosPW
    $ThunderboltBootSupport = .\cctk --thunderboltbootsupport=enable --valsetuppwd=$biosPW
    $ThunderboltPrebootModule = .\cctk --thunderboltprebootmodule=enable --valsetuppwd=$biosPW
    
    # Get settings
    if ($Thunderbolt -eq "thunderbolt=enable")
    { $TSEnv.Value("DellThunderbolt") = "Enabled" } else { $TSEnv.Value("DellThunderbolt") = "Disabled" }
		
    if ($ThunderboltBootSupport -eq "thunderboltbootsupport=enable")
    { $TSEnv.Value("DellThunderboltBootSupport") = "Enabled" } else { $TSEnv.Value("DellThunderboltBootSupport") = "Disabled" }
		
    if ($ThunderboltPrebootModule -eq "thunderboltprebootmodule=enable")
    { $TSEnv.Value("DellThunderboltPrebootModule") = "Enabled" } else { $TSEnv.Value("DellThunderboltPrebootModule") = "Disabled" }

    Write-Log "$Thunderbolt"
    Write-Log "$ThunderboltBootSupport"
    Write-Log "$ThunderboltPrebootModule"
}

# Fastboot
if ($Fastboot -ne "fastboot=thorough")
{
    Write-Log "Setting fastboot to thorough"
    $Fastboot = .\cctk --fastboot=thorough --valsetuppwd=$biosPW
    Write-Log "$Fastboot"
}

# Disable legacy rom
if ($LegacyRom -ne "legacyorom=disable")
{
    Write-Log "Disabling Legacy Rom"    
    $LegacyRom = .\cctk --legacyorom=disable --valsetuppwd=$biosPW
    Write-Log "$LegacyRom"
}

# Enable secure boot
if ($SecureBoot -ne "secureboot=enable")
{
    Write-Log "Enabling Secure Boot" 
    $SecureBoot = .\cctk --secureboot=enable --valsetuppwd=$biosPW
    Write-Log "$SecureBoot"
}

# Disable UEFI networking (PXE)
if ($UefiNetwork -ne "uefinwstack=disable")
{
    Write-Log "Disabling UEFI Network stack"
    $UefiNetwork = .\cctk --uefinwstack=disable --valsetuppwd=$biosPW
    Write-Log "$UefiNetwork"
}

# Set PC to power on after power loss
if ($ACPower -ne "acpower=on")
{
    Write-Log "Turning on AC after power loss"
    $ACPower = .\cctk --acpower=on --valsetuppwd=$biosPW
    Write-Log "$ACPower"
}

# Turn on TPM
if ($TPM -ne "tpm=on")
{
    Write-Log "Turning on the TPM"
    $TPM = .\cctk --tpm=on --valsetuppwd=$biosPW
    Write-Log "$TPM"

    $TPMAcpi = .\cctk --tpmppiacpi=enable --valsetuppwd=$biosPW
    Write-Log "$TPMAcpi"
    $TPMPo = .\cctk --tpmppipo=enable --valsetuppwd=$biosPW
    Write-Log "$TPMPo"
    <#$TPMDpo = .\cctk --tpmppidpo=enable --valsetuppwd=$biosPW
    Write-Log "$TPMDpo"#>

    # Reboot TS and Retry
    Write-Log "Setting TS Reboot and Retry options"
    $TSEnv.Value("SMSTSRebootRequested") = "WinPE"
    $TSEnv.Value("SMSTSRetryRequested") = "true"
    $TSEnv.Value("SMSTSRebootDelay") = "1"
    $TSEnv.Value("SMSTSRebootMessage") = "TPM Turned on, restarting"

    Start-Sleep 5
}

# Clear TPM
if ($TPM -eq "tpm=on" -and $TSEnv.Value("osdTpmCleared") -eq $false)
{
    Write-Log "Clearing the TPM"
    $TPMClear = .\cctk --tpmclear=enable --valsetuppwd=$biosPW
    Write-Log "$TPMClear"

    if ($TPMClear -match "read-only")
    {
        Write-Log "TPM clear is read-only, trying via WMI"
        (Get-WmiObject -Namespace root/cimv2/Security/MicrosoftTPM -Class Win32_TPM).SetPhysicalPresenceRequest(10)
    }
    
    $TSEnv.Value("osdTpmCleared") = $true

    # Reboot TS and Retry
    Write-Log "Setting TS Reboot and Retry options"
    $TSEnv.Value("SMSTSRebootRequested") = "WinPE"
    $TSEnv.Value("SMSTSRetryRequested") = "true"
    $TSEnv.Value("SMSTSRebootDelay") = "1"
    $TSEnv.Value("SMSTSRebootMessage") = "TPM cleared, restarting"

    Start-Sleep 5
}

# Activate TPM
if ($TPMActive -ne "tpmactivation=activate")
{
    Write-Log "Activating the TPM"
    $TPMActive = .\cctk --tpmactivation=activate --valsetuppwd=$biosPW
    Write-Log "$TPMActive"

    if ($TPMActive -match "Error in Setting the Value")
    {
        Write-Log "Error activating the TPM. Try clearing the TPM and/or activating manually."
        Stop-Transcript
        exit 1

        <#$TSEnv.Value("SMSTSRebootRequested") = "WinPE"
        $TSEnv.Value("SMSTSRetryRequested") = "true"
        $TSEnv.Value("SMSTSRebootDelay") = "120"
        $TSEnv.Value("SMSTSRebootMessage") = "TPM Could not be activated, please activate manually during reboot"#>
    }

    # Reboot TS and Retry
    Write-Log "Setting TS Reboot and Retry options"
    $TSEnv.Value("SMSTSRebootRequested") = "WinPE"
    $TSEnv.Value("SMSTSRetryRequested") = "true"
    $TSEnv.Value("SMSTSRebootDelay") = "1"
    $TSEnv.Value("SMSTSRebootMessage") = "TPM activated, restarting"

    Start-Sleep 5
}


#############
# Get updated BIOS variables
$LegacyRom = .\cctk --legacyorom
$SecureBoot = .\cctk --secureboot
$UefiNetwork = .\cctk --uefinwstack
$TPM = .\cctk --tpm
$TPMActive = .\cctk --tpmactivation
$ACPower = .\cctk --acpower
$Fastboot = .\cctk --fastboot

# Gather BIOS info
if ($LegacyRom -eq "legacyorom=enable")
{ $TSEnv.Value("DellLegacyRom") = "Enabled" } else { $TSEnv.Value("DellLegacyRom") = "Disabled" }
	
if ($SecureBoot -eq "secureboot=enable")
{ $TSEnv.Value("DellSecureBoot") = "Enabled" } else { $TSEnv.Value("DellSecureBoot") = "Disabled" }
	
if ($UefiNetwork -eq "uefinwstack=enable")
{ $TSEnv.Value("DellUefiNetwork") = "Enabled" } else { $TSEnv.Value("DellUefiNetwork") = "Disabled" }
	
if ($TPM -eq "tpm=on")
{ $TSEnv.Value("DellTPMEnabled") = "Enabled" } else { $TSEnv.Value("DellTPMEnabled") = "Disabled" }
	
if ($TPMActive -eq "tpmactivation=activate")
{ $TSEnv.Value("DellTPMActive") = "Activate" } else { $TSEnv.Value("DellTPMActive") = "Disabled" }

if ($ACPower -eq "acpower=on")
{ $TSEnv.Value("DellACPower") = "On" } else { $TSEnv.Value("DellACPower") = "Off" }
	
if ($Fastboot -eq "fastboot=thorough")
{ $TSEnv.Value("DellFastboot") = "Thorough" }
elseif ($Fastboot -eq "fastboot=minimal")
{ $TSEnv.Value("DellFastboot") = "Minimal" }
elseif ($Fastboot -eq "fastboot=auto")
{ $TSEnv.Value("DellFastboot") = "Auto" }
else { $TSEnv.Value("DellFastboot") = "Disabled" }


# Try to clear the PW Var
if ($TSEnv.Value("osdTpmCleared") -eq "true" -and $TPMActive -eq "tpmactivation=activate")
{
    $TSEnv.Value("osdUefiPw") = $null
    Write-Log "OsdUefiPw removed"

    if ( $TSEnv.Value("osdUefiPw") -ne "" )
    { 
        Write-Log "Error erasing osdUefiPw"
        Stop-Transcript
        exit 2
    }
}

Stop-Transcript