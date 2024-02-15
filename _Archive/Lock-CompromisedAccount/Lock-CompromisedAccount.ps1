<#
   .Synopsis
   Check https://<domain>.portal.cloudappsecurity.com via API for impossible logins
   Email the user and lock the account after an hour

   .DESCRIPTION
   Check for new impossible travel alerts every hour
   If there is an alert with a successful login, notify the user so they can change their password
   If the password isn't changed within an hour, reset the password and disable the account
   Send notifications to IT along the way 

   .INPUTS
   N/A

   .OUTPUTS
   For logs see: $filePath

   .NOTES
   5/5/2020 - Initial

   .TODO
   Move email body to external files
#>


#Region Logging
$logFilePath = "D:\logs\tasks\Lock-CompromisedAccount\"
$logFileName = "Lock-CompromisedAccount_Transcript_$(Get-Date -Format "MM-dd-yyyy").log"
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

try { Stop-Transcript } catch {}
Start-Transcript -Path ($logFilePath + $logFileName) -Append
#Endregion

#Region Vars
$filePath = "C:\_Git\Tasks\Lock-CompromisedAccount\"
$lastRunFileName = "lastRun.json"
$usersNotified = ""
$usersNotNotified = ""
$usersDisabled = ""
$previousAlerts = ""
$timespan = New-TimeSpan -Hours 1
$now = (Get-Date).ToUniversalTime()
$from = ""
$to = ""
$smtp = ""
$url = "https://<domain>.us2.portal.cloudappsecurity.com/api/v1/alerts/resolve/"

# Setup the email body - FAILURE
$failureEmailBody = @"
<strong>Task Server:</strong> $env:COMPUTERNAME<br/>
<strong>Task name:</strong>Lock Compromised Accounts<br/><br/>
There was an error when resolving the MCAS alert.  Check the log for more info.<br/>
($filePath + $logFileName)<br/><br/>
$_
"@
#Endregion

#Region Attempt to import the MCAS powershell module
if (Get-Module -ListAvailable -Name MCAS)
{
    Write-Log "Module is available, executing script"
} 
else
{
    Write-Log "Module is not available, attempting to install"
    Install-Module -Name MCAS -Force

    # Check for the module
    if (Get-InstalledModule -Name MCAS -ErrorAction SilentlyContinue)
    {
        Write-Log "Module installed, continuing"
    }
    else
    {
        Write-Log "There was trouble installing the MCAS module, script exiting"
        break
    }
}
#Endregion

# Encrypted password file
$credentials = $filePath + "Lock-CompromisedAccount.xml"

# Setup the credentials so we don't have to enter them manually
try
{
    $CASCredential = Import-Clixml -Path $credentials
}
catch
{
    try
    {
        Write-Log "Attempting to send failure email"
        Write-Log "Failed to get credentials"
        
        $failedEmailBody = @"
            <strong>Task Server:</strong> $env:COMPUTERNAME<br/>
            <strong>Task name:</strong>Lock Compromised Accounts<br/><br/>
            The script was unable to access the credentials, please check the location: $credentials
"@

        Send-MailMessage -From $from -To $to `
            -Subject 'ALERT: MCAS Impossible Travel Alert - FAILED TO GET CREDENTIALS' `
            -Body $failedEmailBody -BodyAsHtml `
            -SmtpServer $smtp
    }
    catch
    {
        Write-Log "Email failed to send"
    }
}

# Get any alerts that are stored in the lastRun file (create the file if it's missing)
if ( Test-Path ($filePath + $lastRunFileName) )
{
    $previousAlerts = Get-Content -Path ($filePath + $lastRunFileName)
    # Remove the trailing ,
    $previousAlerts -replace ".$" | ConvertFrom-Json
}
else
{
    New-Item -ItemType File -Path $filePath -Name $lastRunFileName
}

# Get any alerts in the last hour that didn't fail sign in
Write-Log "Gathering alerts for the past hour"
$alerts = Get-MCASAlert -SortBy Date -SortDirection Descending -ResolutionStatus Open | `
        Where-Object { `
            $_.title -imatch "Impossible travel activity" `
            -and $_.description -inotmatch "failed sign in" `
            -and ((ConvertFrom-MCASTimestamp $_.timestamp).ToUniversalTime().AddHours(1) -ge $now) `
    }

#Region If there are new alerts
if ($alerts)
{
    Write-Log "Alerts found, continuing..."

    foreach ($alert in $alerts)
    {
        # Gather data
        $id = $alert._id
        $email = $alert.entities | Where-Object { $_.type -eq 'user' } | Select-Object id -Unique
        $alertDescription = $alert.description.Replace("<p>", "").Replace("</p>", "") -split '<br>'

        # Setup the email body - USERS
        $userEmailBody = @"
            <strong>ALERT: YOUR PASSWORD MAY BE COMPROMISED</strong><br/>
            Our security monitoring solution has raised an impossible travel alert.<br/>
            $($alertDescription[0])<br/>
            $($alertDescription[1])<br/>
            <br/>
            <strong>USER ACTIONS</strong><br/>
            You will need to change your password within the next hour to avoid your account being automatically disabled.<br/>
            <br/>
            <strong>IT FOLLOWUP ACTIONS</strong><br/>
            If you do not update your password within the next hour, your user account will be automatically disabled to prevent any further security risks.<br/>
            <br/>
            If you have any questions, please contact the service desk.<br/>
            <br/>
            <br/>
            Thank you,<br/> 
            Information Technology
"@

        # Compare alert to what we already have
        if ($previousAlerts)
        {
            Write-Log "Found alerts in the lastRun.json file. Comparing them to the current alert."

            foreach ($previousAlert in $previousAlerts)
            {                
                if ($previousAlert._id -ne $id) { continue; }

                Write-Log "Current alert id: $id | ID from alert file: $($previousAlert._id)"

                # If this alert is already in the file, let's make sure we're not sending additonal emails
                if ($previousAlert._id -eq $id -and $previousAlert.emailSent -eq $true)
                {
                    # If it's been an hour since the email was sent and the password was not updated, disable the account
                    $emailSentTime = $previousAlert.emailSentTime

                    if (($now - $emailSentTime) -gt $timespan)
                    {
                        Write-Log "It's been an hour since the email was sent to: $($email.id)"
                        $lastPasswordChange = Get-AdUser -Filter { EmailAddress -eq "$($email.id)" } -Properties passwordlastset
                        
                        if ($lastPasswordChange.passwordlastset -ge $emailSentTime)
                        {
                            Write-Log "The password for $($email.id) was changed at: $($lastPasswordChange.passwordlastset). After the email was sent: $emailSentTime"
                            
                            # There is no resolve function in the Set-MCASAlert file, so we're doing it manually.
                            try
                            {
                                Write-Log "Attempting to resolve MCAS Alert: $($previousAlert.URL)"
                                $header = @{ 'Authorization' = "Token $($CASCredential.GetNetworkCredential().Password)" }
                                $body = @{
                                    'comment' = "Password was changed since the last email was sent. Password changed on: $($lastPasswordChange.passwordlastset)"
                                    'filters' = @{
                                        'id' = @{ 'eq' = @("$id") }
                                    }
                                } | ConvertTo-Json -Depth 5
                                $url = "https://<domain>.us2.portal.cloudappsecurity.com/api/v1/alerts/resolve/"

                                $response = Invoke-RestMethod -Headers $header -Body $body -Method Post -Uri $url
                                Write-Log "$($response.data)"
                            }
                            catch
                            {
                                Write-Log "Error calling MCAS API. The exception was: $_"
                                try
                                {
                                    Send-MailMessage -From $from -To $to `
                                        -Subject 'ALERT: MCAS Impossible Travel Alert - Script failure' `
                                        -Body $failureEmailBody -BodyAsHtml `
                                        -SmtpServer $smtp
                                }
                                catch
                                {
                                    Write-Log "Email failed to send"
                                }                                
                            }
                        }
                        else
                        {
                            # Reset PW, disable user
                            Write-Log "The password for $($email.id) hasn't been changed after an hour.  Disabling the account and changing the password."
                            Write-Log "Last Password change: $($lastPasswordChange.passwordlastset). Email was sent: $emailSentTime"
                        
                            # Reset password
                            $pw = [System.Web.Security.Membership]::GeneratePassword(16, 1)
                            $securePw = ConvertTo-SecureString $pw -AsPlainText -Force

                            # Disable account
                            $lastPasswordChange | Set-ADAccountPassword -NewPassword $securePw -Reset
                            $lastPasswordChange | Disable-ADAccount
                            $lastPasswordChange | Set-ADUser -Description "Account disabled by MCAS script"
                            
                            $usersDisabled += "$($email.id) | Last Password Change: $($lastPasswordChange.passwordlastset) | Email sent: $emailSentTime <br/>"
                        }
                    }
                    else
                    {
                        Write-Log "It hasn't been an hour since the email was sent to: $email"
                    }
                }
                else
                {
                    # Send the initial email to the user
                    Write-Log "No similar alert was found in the file, attempting to email the user: $($email.id)"

                    try
                    {
                        Send-MailMessage -From $from -To "$($email.id)" `
                            -Subject 'ALERT: Please update your password' `
                            -Body "$userEmailBody" -BodyAsHtml `
                            -Priority "High" `
                            -SmtpServer $smtp
                        
                        $usersNotified += "$($email.id)<br/>"

                        # Update the object and add the info into a file
                        $alert | Add-Member -Type NoteProperty -Name 'emailSent' -Value 'True'
                        $alert | Add-Member -Type NoteProperty -Name 'emailSentTime' -Value "$now"
                        $alert = $alert | ConvertTo-Json
                        $alert += ","
                        $updateLastRunFile = ($alert | Add-Content $lastRunFile)
                    }
                    catch
                    {
                        Write-Log "The email failed to send to $($email.id)"
                        $usersNotNotified += "$($email.id)<br/>"
                        $updateLastRunFile = ($alert | Add-Content $lastRunFile)
                    }
                }
            }
        }
        else
        {
            # Send the initial email to the user
            Write-Log "There are no previous alerts, attempting to email the user: $($email.id)"

            try
            {
                Send-MailMessage -From $from -To "$($email.id)" `
                    -Subject 'ALERT: Please update your password' `
                    -Body "$userEmailBody" -BodyAsHtml `
                    -Priority "High" `
                    -SmtpServer $smtp

                $usersNotified += "$($email.id)<br/>"
                
                # Update the object and add the info into a file
                $alert | Add-Member -Type NoteProperty -Name 'emailSent' -Value 'True'
                $alert | Add-Member -Type NoteProperty -Name 'emailSentTime' -Value "$now"
                $alert = $alert | ConvertTo-Json
                $alert += ","
                $updateLastRunFile = ($alert | Add-Content ($filePath + $lastRunFileName))
            }
            catch
            {
                Write-Log "The email failed to send to $($email.id)"
                $usersNotNotified += "$($email.id)<br/>"
                $updateLastRunFile = ($alert | Add-Content ($filePath + $lastRunFileName))
            }
        }
    }
}
#Endregion

#Region No new alerts, check on previous alerts file
elseif (!$alerts -and $previousAlerts)
{
    Write-Log "There are no new alerts. Lets look at the previous alerts"

    foreach ($previousAlert in $previousAlerts)
    {
        $alertDescription = $previousAlert.description.Replace("<p>", "").Replace("</p>", "") -split '<br>'
        $email = $previousAlert.entities | Where-Object { $_.type -eq 'user' } | Select-Object id -Unique

        # If the email has been sent
        if ($previousAlert.emailSent -eq $true)
        {
            # If it's been an hour since the email was sent and the password was not updated, disable the account
            $emailSentTime = $previousAlert.emailSentTime

            if (($now - $emailSentTime) -gt $timespan)
            {
                Write-Log "It's been an hour since the email was sent to: $($email.id)"
                $lastPasswordChange = Get-AdUser -Filter { EmailAddress -eq "$($email.id)" } -Properties passwordlastset

                if ($lastPasswordChange.passwordlastset -ge $emailSentTime)
                {
                    Write-Log "The password for $($email.id) was changed at: $($lastPasswordChange.passwordlastset) after the email was sent: $emailSentTime"

                    # There is no resolve function in the Set-MCASAlert file, so we're doing it manually.
                    try
                    {
                        Write-Log "Attempting to resolve MCAS Alert: $($previousAlert.URL)"
                        $header = @{ 'Authorization' = "Token $($CASCredential.GetNetworkCredential().Password)" }
                        $body = @{
                            'comment' = "Password was changed since the last email was sent. Password changed on: $($lastPasswordChange.passwordlastset)"
                            'filters' = @{
                                'id' = @{ 'eq' = @("$id") }
                            }
                        } | ConvertTo-Json -Depth 5

                        $response = Invoke-RestMethod -Headers $header -Body $body -Method Post -Uri $url
                        Write-Log "$($response.data)"
                    }
                    catch
                    {
                        Write-Log "Error calling MCAS API. The exception was: $_"
                        try
                        {
                            Send-MailMessage -From $from -To $to `
                                -Subject 'ALERT: MCAS Impossible Travel Alert - Script failure' `
                                -Body $failureEmailBody -BodyAsHtml `
                                -SmtpServer $smtp
                        }
                        catch
                        {
                            Write-Log "Email failed to send"
                        }                                
                    }
                }
                else
                {
                    # Reset PW, disable user
                    Write-Log "The password for $($email.id) hasn't been changed after an hour.  Disabling the account and changing the password."
                    Write-Log "Last Password change: $($lastPasswordChange.passwordlastset). Email was sent: $emailSentTime"
            
                    # Reset password
                    $pw = [System.Web.Security.Membership]::GeneratePassword(16, 1)
                    $securePw = ConvertTo-SecureString $pw -AsPlainText -Force

                    # Disable account
                    $lastPasswordChange | Set-ADAccountPassword -NewPassword $securePw -Reset
                    $lastPasswordChange | Disable-ADAccount
                    $lastPasswordChange | Set-ADUser -Description "Account disabled by MCAS script"
                
                    $usersDisabled += "$($email.id) | Last Password Change: $($lastPasswordChange.passwordlastset) | Email sent: $emailSentTime <br/>"
                }
            }
            else
            {
                Write-Log "It hasn't been an hour since the email was sent to: $($email.id)"
            }
        }
    }
}
else
{
    Write-Log "There are no new or previous alerts."
}

# Setup the email body - IT Users NOTIFIED
$initialEmailBody = @"
<strong>Task Server:</strong> $env:COMPUTERNAME<br/>
<strong>Task name:</strong>Lock Compromised Accounts<br/>
<br/>
Initial email was sent to the following users:<br/>
$usersNotified
"@

if ($usersNotNotified)
{
    $initialEmailBody += "<br/>Initial email <strong>FAILED</strong> to the following users:<br/>$usersNotNotified"
}

# Setup the email body - IT Users DISABLED
$disabledEmailBody = @"
<strong>Task Server:</strong> $env:COMPUTERNAME<br/>
<strong>Task name:</strong>Lock Compromised Accounts<br/><br/>
Accounts below have been disabled and passwords reset because the password was not changed within one hour of the notification email.<br/><br/>
$usersDisabled
"@

# Email IT
if ($usersNotified -or $usersNotNotified)
{
    try
    {
        Write-Log "Attempting to send email it IT about initial emails:"
        Write-Log "Notified : $usersNotified"
        Write-Log "Not Notified : $usersNotNotified"

        Send-MailMessage -From $from -To $to `
            -Subject 'ALERT: MCAS Impossible Travel Alert - Initial email sent to users' `
            -Body $initialEmailBody -BodyAsHtml `
            -SmtpServer $smtp
    }
    catch
    {
        Write-Log "Email failed to IT"
    }
}

if ($usersDisabled)
{
    try
    {
        Write-Log "Attempting to send email it IT about disabled accounts:"
        Write-Log "$usersDisabled"

        Send-MailMessage -From $from -To $to `
            -Subject 'ALERT: MCAS Impossible Travel Alert - Password reset and account disabled' `
            -Body $disabledEmailBody -BodyAsHtml `
            -SmtpServer $smtp
    }
    catch
    {
        Write-Log "Email failed to IT"
    }
}

Write-Log "-----------------------------------------------------------------------------"

Stop-Transcript
