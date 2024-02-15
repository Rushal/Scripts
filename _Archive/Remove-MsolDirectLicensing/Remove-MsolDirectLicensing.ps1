<#
   .Synopsis
   Remove direct user licenses on M365

   .DESCRIPTION
   Script came from: https://docs.microsoft.com/en-us/azure/active-directory/users-groups-roles/licensing-ps-examples#remove-direct-licenses-for-users-with-group-licenses
   Tweaked to run through all licensed users

   .OUTPUTS
   For logs see: $logFilePath

   .VERSION
    1.0
    
    .AUTHOR
    Chucky A Ivey
#>


#Region Logging
$logFilePath = "D:\logs\Remove-MsolDirectLicensing\"
$logFileName = "Remove-MsolDirectLicensing_Transcript_$(Get-Date -Format "MM-dd-yyyy").log"
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

# Returns TRUE if the user has the license assigned directly
function UserHasLicenseAssignedDirectly
{
    Param([Microsoft.Online.Administration.User]$user, [string]$skuId)

    $license = GetUserLicense $user $skuId

    if ($license -ne $null)
    {
        #GroupsAssigningLicense contains a collection of IDs of objects assigning the license
        #This could be a group object or a user object (contrary to what the name suggests)
        #If the collection is empty, this means the license is assigned directly - this is the case for users who have never been licensed via groups in the past
        if ($license.GroupsAssigningLicense.Count -eq 0)
        {
            return $true
        }

        #If the collection contains the ID of the user object, this means the license is assigned directly
        #Note: the license may also be assigned through one or more groups in addition to being assigned directly
        foreach ($assignmentSource in $license.GroupsAssigningLicense)
        {
            if ($assignmentSource -ieq $user.ObjectId)
            {
                return $true
            }
        }
        return $false
    }
    return $false
}

# Returns the license object corresponding to the skuId. Returns NULL if not found
function GetUserLicense
{
    Param([Microsoft.Online.Administration.User]$user, [string]$skuId, [Guid]$groupId)
    #we look for the specific license SKU in all licenses assigned to the user
    foreach ($license in $user.Licenses)
    {
        if ($license.AccountSkuId -ieq $skuId)
        {
            return $license
        }
    }
    return $null
}

# Vars
$credentials = "D:\_Git\Remove-MsolDirectLicensing\Remove-MsolDirectLicensing_USERNAME_SERVER.xml"
$emailBody = ""
$emailBuildBody = ""
$domain = ""

$from = ""
$to = ""
$smtp = ""

# Connect to MSOL
$credential = Import-Clixml -Path $credentials
try 
{
    Write-Log "Attempting to connect to MSO"
    Connect-MsolService -Credential $credential
    Write-Log "Connected to MSO"
}
catch
{
    Write-Log "Could not connect to MSO"
}

# Licenses to be removed
# domain:ENTERPRISEPACK - Office 365 E3
# domain:ENTERPRISEPREMIUM - Office 365 E5
# domain:EMS - Enterprise Mobility and Security E3
# domain:EMSPREMIUM - Enterprise Mobility and Security E5
$skuIds = @("$($domain):FLOW_FREE", "$($domain):POWER_BI_STANDARD", "$($domain):TEAMS_EXPLORATORY", "$($domain):ENTERPRISEPACK", "$($domain):ENTERPRISEPREMIUM", "$($domain):EMS", "$($domain):EMSPREMIUM")
try
{
    foreach ( $skuId in $skuIds )
    {
        $emailBuildHeader = "<strong>$skuId</strong><br/>"

        $usersToProcess = Get-MsolUser -All | Where-Object { $_.isLicensed -eq $true <#-and ($_.UserPrincipalName -eq "test@domain.com")#> } | foreach {
            $user = $_;
            $operationResult = "";

            Write-Log "Processing: $skuId | User: $($user.DisplayName)"
            # Check if Direct license exists on the user
            if (UserHasLicenseAssignedDirectly $user $skuId)
            {
                Write-Log "User has a directly assigned license: $skuId, attemtping to remove"

                # Remove the direct license from user
                try
                {
                    Set-MsolUserLicense -ObjectId $user.ObjectId -RemoveLicenses $skuId -ErrorAction Stop
                    $operationResult = "Removed direct license [$skuId] from user: $($user.DisplayName)"
                    Write-Log "Removed direct license [$skuId] from user: $($user.DisplayName)"

                    $emailBuildBody += "$($user.DisplayName) | $operationResult<br/>"
                }
                catch
                {
                    $operationResult = "<strong>FAILED:</strong> removing direct license [$skuId] from user: $($user.DisplayName)"
                    Write-Log "FAILED: removing direct license [$skuId] from user: $($user.DisplayName)"

                    $emailBuildBody += "$($user.DisplayName) | $operationResult<br/>"
                }
            }
            else
            {
                Write-Log "User has no direct license to remove. Skipping."
                $operationResult = "$($user.DisplayName) has no direct license to remove. Skipping."
            }

            # Format output
            New-Object Object |
                Add-Member -NotePropertyName SkuToRemove -NotePropertyValue $skuId -PassThru |
                Add-Member -NotePropertyName User -NotePropertyValue $user.DisplayName -PassThru |
                Add-Member -NotePropertyName OperationResult -NotePropertyValue $operationResult -PassThru
            } | Format-Table

        if ($emailBuildBody)
        {
            $emailBody += $emailBuildHeader + $emailBuildBody + "<br/>"
            $emailBuildBody = ""
        }
    }
}
catch
{
    try
    {
        Write-Log "Attempting to send email to IT about failure"

        Send-MailMessage -From $from -To $to `
            -Subject 'ALERT: FAILED: MSOL Remove Direct License' `
            -Body "Script failed to run.  Check the log file on $($env:COMPUTERNAME)" -BodyAsHtml `
            -SmtpServer $smtp
    }
    catch
    {
        Write-Log "Email failed to IT"
        Stop-Transcript
    }
}

# Email IT
if ($emailBody)
{
    $body = "<strong>Task Server:</strong> $env:COMPUTERNAME<br/>"
    $body += "<strong>Task name:</strong> Delete MSOL Direct Licensing<br/><br/>"
    $body += "Please make sure that any users that had their direct licensing removed have the licenses they need assigned via one of the <LICENSE> groups in AD<br/><br/>"
    $body += "Removed:<br/>$emailBody"

    try
    {
        Write-Log "Attempting to send email to IT about removed MSOL Direct licensing"

        Send-MailMessage -From $from -To $to `
            -Subject 'ALERT: MSOL Remove Direct License - Users removed' `
            -Body $body -BodyAsHtml `
            -SmtpServer $smtp
    }
    catch
    {
        Write-Log "Email failed to IT"
        Stop-Transcript
    }
}

Stop-Transcript