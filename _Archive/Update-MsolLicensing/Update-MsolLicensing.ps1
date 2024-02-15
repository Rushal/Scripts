<#
   .Synopsis
   Make sure that any new users added to the various department groups are added to the correct M365 licensing groups

   .DESCRIPTION
    

   .INPUTS
   N/A

   .OUTPUTS
   For logs see: $logFilePath

   .VERSION
    1.0
    
    .AUTHOR
    Chucky A Ivey
#>


#Region Logging
$logFilePath = "D:\logs\tasks\Update-MsolLicensing\"
$logFileName = "Update_MsolLicensing_Transcript_$(Get-Date -Format "MM-dd-yyyy").log"
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

$filePath = "D:\_Git\Azure\Tasks\Update-MsolLicensing\"
$licenseCsvFile = "MSOL-Licensing.csv"
$emailBody = ""
$users = ""

# Import the CSV that contains the Department to License mapping
Write-Log "Grabbing the groups from the CSV"
$licenseCsv = Import-Csv ($filePath + $licenseCsvFile)
$licenseHeaders = ($licenseCsv | Get-Member -MemberType NoteProperty).Name

# Loop through the groups and add new users
foreach ($license in $licenseHeaders)
{
    Write-Log "Currently working on licence group: $license"

    # Loop through each dept group in the license group
    foreach ($group in $($licenseCsv.$license))
    {
        if (! $group) { Write-Log "No department groups or users listed under $license"; break }
        switch ($license)
        {
            "M365E3"
            {
                Write-Log "License: M365 E3 | AD Group/User: $group"
                $licenseAdGroup = "GG.MSO.Microsoft365-E3"
            }
            "M365E5"
            {
                Write-Log "License: M365 E5 | AD Group/User: $group"
                $licenseAdGroup = "GG.MSO.Microsoft365-E5"
            }
            "Teams"
            {
                Write-Host "License: MS Teams | AD Group/User: $group"
                $licenseAdGroup = "GG.MSO.Teams"
            }
            "MFA"
            {
                Write-Host "License: Azure MFA/AIP | AD Group/User: $group"
                $licenseAdGroup = "GG.MSO.MFA"
            }
            "ProjectP3"
            {
                Write-Host "License: Project Online Plan 3 | AD Group/User: $group"
                $licenseAdGroup = "GG.MSO.Project-P3"
            }
            "VisioP2"
            {
                Write-Host "License: Visio Online Plan 2 | AD Group/User: $group"
                $licenseAdGroup = "GG.MSO.Visio-P2"
            }
        }

        # Find and add new users, find and remove disabled users
        try
        {
            Write-Log "Getting the members in $licenseAdGroup and $group"
            $membersInMsoGroup = Get-ADGroupMember $licenseAdGroup

            # Try assuming a group is listed, otherwise assume it's a user
            try
            {
                $membersInDeptGroup = Get-ADGroupMember $group -ErrorAction Stop | Get-AdUser | `
                        Where-Object { `
                            $_.SamAccountName -notlike 'test*' `
                            -and $_.Enabled -eq $true }

                Write-Log "Looking for disabled accounts in $licenseAdGroup"
                $disabledUsers = Get-ADGroupMember $licenseAdGroup | Get-AdUser | Where-Object { $_.Enabled -eq $false }
            }
            catch
            {
                Write-Log "No group found, checking for a user instead"
                $membersInDeptGroup = Get-AdUser $group | `
                        Where-Object { `
                            $_.SamAccountName -notlike "test*" `
                            -and $_.Enabled -eq $true }

                Write-Log "Checking if user $group is disabled"
                $disabledUsers = Get-AdUser $group | Where-Object { $_.Enabled -eq $false }
            }
                
            if ($membersInMsoGroup)
            {
                Write-Log "There are members in the $licenseAdGroup group, comparing to $group to find new users"

                # If the user is in the difference object (the dept group) and not in the MSOL Group
                $usersToAdd = Compare-Object -ReferenceObject $membersInMsoGroup -DifferenceObject $membersInDeptGroup | Where-Object { $_.SideIndicator -eq "=>" }
                $usersToCompare = $true
            }
            else
            {
                Write-Log "There are no users in the $licenseAdGroup group, adding all $group members"
                $usersToAdd = $membersInDeptGroup
                $usersToCompare = $false
            }

            if ($usersToAdd -or $disabledUsers) { $emailBody += "<strong>$licenseAdGroup</strong><br/>" }

            if ($usersToAdd)
            {
                Write-Log "Found new users to add to $licenseAdGroup"
                $users = ""
                
                if ($usersToCompare)
                {
                    $usersToAdd.InputObject | ForEach-Object { $users += "$($_.Name)<br/>" }
                    $usersToAdd.InputObject | Add-ADPrincipalGroupMembership -MemberOf $licenseAdGroup
                }
                else
                {
                    $usersToAdd | ForEach-Object { $users += "$($_.Name)<br/>" }
                    $usersToAdd | Add-ADPrincipalGroupMembership -MemberOf $licenseAdGroup
                }

                Write-Log "Added the following members: $users"

                $emailBody += "<strong>$group</strong><br/>"
                $emailBody += "$users<br/><br/>"
            }
            else
            {
                Write-Log "No users to add"
            }
            
            if ($disabledUsers)
            {
                Write-Log "Removing disabled users: $($disabledUsers.Name)"
                $disabledUsers | Remove-ADPrincipalGroupMembership -MemberOf $licenseAdGroup -Confirm:$false
                $disabledUsers | ForEach-Object { $removedUsers += "$($_.Name)<br/>" }

                $emailBody += "<strong>REMOVED DISABLED USERS:</strong><br/>"
                $emailBody += "$removedUsers"
                $removedUsers = ""    
            }
            else
            {
                Write-Log "No disabled users to remove"
            }
        }
        catch
        {
            Write-Log "There was an issue updating the $licenseAdGroup group"
            # Send failure email?
        }
    }
}


# Email IT
if ($emailBody)
{
    $body = "<strong>Task Server:</strong> $env:COMPUTERNAME<br/>"
    $body += "<strong>Task name:</strong> Update MSOL Licensing<br/><br/>"
    if ($usersToAdd) { $body += "Added:<br/><br/>" }
    $body += "$emailBody"

    try
    {
        Write-Log "Attempting to send email to IT about updated MSOL licensing"

        Send-MailMessage -From 'Alerts <alerts@domain.com>' -To 'it@domain.com' `
            -Subject 'ALERT: MSOL License groups updated' `
            -Body $body -BodyAsHtml `
            -SmtpServer smtp.domain.com
    }
    catch
    {
        Write-Log "Email failed to IT"
        Stop-Transcript
    }
}

Stop-Transcript