param (
    [switch] $GetPW,
    $manufacturer,
    $serialNumber
)

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

function GetPwEntry($serialNumber, $manufacturer)
{
    Write-Log "Getting password from KeePass"
    $GetEntry = & $PSScriptRoot\KeePass\KPScript.exe -c:GetEntryString "$path\bios.kdbx" -pw:"<YOUR PW HERE>" -keyfile:"$path\bios.key" -Field:Password -ref-Title:$serialNumber -refx-Group:$manufacturer
        
    if ( $GetEntry.Substring(0, 2) -eq "E:" -or ( $GetEntry.Count -gt 1 -and $GetEntry[0].Substring(0, 2) -eq "E:" ) )
    {
        Write-Log "There was an error getting the password entry"
        Write-Log "$($GetEntry)"
        try { net use K: /delete /y } catch {}
        exit 1
    }

    if ( $GetEntry.Count -eq 1 )
    {
        Write-Log "There are no previous passwords set, using default"
        return "<YOUR FALLBACK HERE>"
    }
    else
    {
        return $GetEntry[-2]
    } 
}

# Old, to be cleaned up
Function Get-StringHash([String] $String, $HashName = "SHA1")
{
    $StringBuilder = New-Object System.Text.StringBuilder
    [System.Security.Cryptography.HashAlgorithm]::Create($HashName).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($String)) | ForEach-Object {
        [Void]$StringBuilder.Append($_.ToString("x2"))
    }
    $StringBuilder.ToString()
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

Start-Transcript -Path ($LogsDirectory + "\Set-UefiPassword.log")

if (Get-TaskSequenceStatus)
{
    Write-Log "Attempting to map K:"
    net use K: \\<PATH TO KEEPASS DB> /user:<DOMAIN\USER> <PASSWORD>
    $path = "K:"
}
else { $path = "\\<PATH TO KEEPASS DB>" }


if ( -not $GetPW )
{
    Add-Type -AssemblyName 'System.Web'
    $length = 16

    if ( (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer -eq "LENOVO" )
    {
        $manufacturer = "lenovo"
        $nonAlphaChars = 6

        $biosPW = [System.Web.Security.Membership]::GeneratePassword($length, $nonAlphaChars)
    }
    else
    {
        $manufacturer = "dell"
        $nonAlphaChars = 0

        $biosPW = [System.Web.Security.Membership]::GeneratePassword($length, $nonAlphaChars)

        # Remove punctuation...
        $biosPW = $biosPW -replace "[^a-zA-Z0-9]", (Get-Random -InputObject (65..90) | ForEach-Object { [char]$_ })
    }

    $serialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
    #$biosPW = (Get-StringHash "$serialNumber" "SHA1").substring(0, 16)
    $currentBiosPw = GetPwEntry $serialNumber $manufacturer
    $notes = "$($TSEnv.Value("OSDComputerName")) - $((Get-WmiObject -Class Win32_ComputerSystem).Model) - $((Get-WmiObject -Class Win32_ComputerSystem).SystemFamily)"

    Write-Log "Attempting to add password to KeePass"
    $AddEntry = & .\KeePass\KPScript.exe -c:AddEntry "$path\bios.kdbx" -pw:<YOU DB PW HERE> -keyfile:"$path\bios.key" -Title:"$serialNumber" -Password:"$biosPW" -GroupName:$manufacturer -Notes:$notes
    
    if ( $AddEntry.Substring(0, 2) -eq "E:" -or ( $AddEntry.Count -gt 1 -and $AddEntry[0].Substring(0, 2) -eq "E:" ) )
    {
        Write-Log "There was an error adding the password entry"
        Write-Log "$($AddEntry)"
        Stop-Transcript
        exit 1
    }
    elseif ( $AddEntry -eq "OK: Operation completed successfully." )
    {
        Write-Log "KeePass: $AddEntry"
        Write-Log "Updating Bios Password"        

        if ( $manufacturer -eq "lenovo" )
        {
            Write-Log "Attempting to set Lenovo BIOS bassword"
            $pwWmi = Get-WmiObject -Class Lenovo_SetBiosPassword -Namespace root\WMI
            if ( $pwWmi.SetBiosPassword("pap,$currentBiosPw,$biosPW,ascii,us").Return -eq "Success" )
            {
                Write-Log "The password has been successfully set"
                if (Get-TaskSequenceStatus)
                { 
                    Write-Log "Setting osdUefiPw"
                    $TSEnv.Value("osdUefiPw") = "$biosPW"
                }
            }
            else
            {
                Write-Log "There was an error setting the password"
                Write-Log "Attempting to move password to KeePass Recycle Bin"
                $DeleteEntry = & .\KeePass\KPScript.exe -c:MoveEntry "$path\bios.kdbx" -pw:<YOUR DB PW HERE> -keyfile:"$path\bios.key" -ref-Title:"$serialNumber" -ref-Password:"$biosPW" -GroupName:$manufacturer -GroupPath:"Recycle Bin"
                if ( $DeleteEntry -eq "OK: Operation completed successfully." )
                {
                    Write-Log "KeePass: $DeleteEntry"
                    Write-Log "Deleted PW: $biosPW"
                }
                else
                {
                    Write-Log "ERROR: Could not remove the password."
                    Write-Log "KeePass: $DeleteEntry"
                    Write-Log "Deleted PW: $biosPW"
                }
                Stop-Transcript
                exit 1
            }
        }
        if ( $manufacturer -eq "dell" )
        {
            # Set a new admin password
            Write-Log "Attempting to set Dell BIOS bassword"
            #Write-Log "$currentBiosPw || $biosPW" # For testing

            Write-Log "Setting path to: C:\_SMSTaskSequence\Packages\<CCTK PACKAGE ID>"
            Set-Location -Path C:\_SMSTaskSequence\Packages\<CCTK PACKAGE ID>

            Write-Log "Attempting to set Dell BIOS bassword"
            try
            {
                Write-Log "Trying with no password"
                $setPW = .\cctk --setuppwd=$biosPW
                Write-Log $setPW

                if ($setPW -notmatch "Password is set successfully") { throw }
            }
            catch
            {
                Write-Log "Tring with old password"
                $setPW = .\cctk --setuppwd=$biosPW --valsetuppwd=$currentBiosPw
                Write-Log $setPW
            }
            
            if ( $setPW -match "Password is set successfully" -or $setPW -match "Password is changed successfully" )
            {
                Write-Log "The password has been successfully set"
                if (Get-TaskSequenceStatus)
                { 
                    Write-Log "Setting osdUefiPw"
                    $TSEnv.Value("osdUefiPw") = "$biosPW"
                }
            }
            else
            {
                Write-Log "There was an error setting the password"
                Write-Log "Setting location back to: C:\_SMSTaskSequence\Packages\<THIS PACKAGE ID>"
                Set-Location -Path C:\_SMSTaskSequence\Packages\<THIS PACKAGE ID>

                Write-Log "Attempting to delete password from KeePass"
                $DeleteEntry = & .\KeePass\KPScript.exe -c:MoveEntry "$path\bios.kdbx" -pw:<YOUR DB PW HERE> -keyfile:"$path\bios.key" -ref-Title:"$serialNumber" -ref-Password:"$biosPW" -GroupName:$manufacturer -GroupPath:"Recycle Bin"
                if ( $DeleteEntry -eq "OK: Operation completed successfully." )
                {
                    Write-Log "KeePass: $DeleteEntry"
                    Write-Log "Deleted PW: $biosPW"
                }
                else
                {
                    Write-Log "ERROR: Could not remove the password."
                    Write-Log "KeePass: $DeleteEntry"
                    Write-Log "Deleted PW: $biosPW"
                }
                Stop-Transcript
                exit 1
            }
        }
        Write-Log "$biosPW"
        Stop-Transcript
        exit 0
    }
}
else
{
    Write-Log "Get password switch used."
    Write-Log "$manufacturer / $serialNumber"
    GetPwEntry $serialNumber $manufacturer
}

if ( -not $GetPW ) { try { net use K: /delete /y } catch {} }
Stop-Transcript