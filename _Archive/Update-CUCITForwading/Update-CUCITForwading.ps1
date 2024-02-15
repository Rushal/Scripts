<#
   .Synopsis
   Check PagerDuty for the current on-call user and update the CUC forwarding number accordingly

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
$logFilePath = "D:\logs\Update-CUCITForwading\"
$logFileName = "Update-CUCITForwarding_Transcript_$(Get-Date -Format "MM-dd-yyyy").log"
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

Add-Type -AssemblyName System.Web

$filePath = "D:\_Git\Update-CUCITForwading\"
$PDCreds = Import-Clixml ($filePath + "PDAPI_${env:USERNAME}_${env:COMPUTERNAME}.xml")
$CUCCreds = Import-Clixml ($filePath + "CUC_${env:USERNAME}_${env:COMPUTERNAME}.xml")
$onCallStartTime = [System.Web.HttpUtility]::UrlEncode( ( Get-Date (Get-Date).AddHours(9) -Format s ) )

# Functions
function Disable-SslVerification
{
    if (-not ([System.Management.Automation.PSTypeName]"TrustEverything").Type)
    {
        Add-Type -TypeDefinition  @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class TrustEverything
{
    private static bool ValidationCallback(object sender, X509Certificate certificate, X509Chain chain,
        SslPolicyErrors sslPolicyErrors) { return true; }
    public static void SetCallback() { System.Net.ServicePointManager.ServerCertificateValidationCallback = ValidationCallback; }
    public static void UnsetCallback() { System.Net.ServicePointManager.ServerCertificateValidationCallback = null; }
}
"@
    }
    [TrustEverything]::SetCallback()
}

function Enable-SslVerification
{
    if (([System.Management.Automation.PSTypeName]"TrustEverything").Type)
    {
        [TrustEverything]::UnsetCallback()
    }
}

#START PAGERDUTY API
# Gather the current on-call user and their number from pager duty
$header = @{ 'Authorization' = "Token token=$($PDCreds.GetNetworkCredential().Password)" }
$url = "https://api.pagerduty.com"

$from = ""
$to = ""
$smtp = ""

$liveCallRoutingNumber = ""

try
{
    Write-Log "Calling PagerDuty API to find current on-call user"

    # Schedule ID ties to IT On-Call Schedule in PD
    $response = Invoke-RestMethod -UseBasicParsing -Headers $header -Uri "$url/oncalls?schedule_ids<ID-HERE>&since=$onCallStartTime&until=$onCallStartTime"
    $onCallUser = $response.oncalls.user.summary

    Write-Log "Current on-call user found: $onCallUser"
    Write-Log "Attempting to find their mobile phone number"

    $response = Invoke-RestMethod -UseBasicParsing -Uri "$($response.oncalls.user.self)" -Headers $header
    $mobilePhoneReference = $response.user.contact_methods | Where-Object { $_.type -eq "phone_contact_method_reference" -and $_.summary -eq "Mobile" }

    # Finally get the mobile number
    $response = Invoke-RestMethod -UseBasicParsing -Uri "$($mobilePhoneReference.self)" -Headers $header

    # Save the phone number to use later
    $onCallPhone = $response.contact_method.address | Select-Object -First 1

    Write-Log "Currently on-call: $onCallUser - $onCallPhone"
}
catch
{
    Write-Log "Failed to call PagerDuty API: $_"
    Stop-Transcript

    # Email IT
    $body = "Failed to call PagerDuty API: $_"
    try
    {
        Write-Log "Attempting to send email to IT about failure:"

        Send-MailMessage -From $from -To $to `
            -Subject 'ALERT: On-Call phone number update FAILED' `
            -Body $body -BodyAsHtml `
            -Attachments ($logFilePath + $logFileName) `
            -SmtpServer $smtp
    }
    catch
    {
        Write-Log "Email failed to IT"
        exit
    }

    exit
}

# Set Execution Policy back to Default
Set-ExecutionPolicy Default -ErrorAction SilentlyContinue -Force
Write-Log "Execution Policy is now set back to: $(Get-ExecutionPolicy)"

# Email IT
$body = @"
<strong>Task Server:</strong> $env:COMPUTERNAME<br/>
<strong>Task name:</strong> Update IT On-Call Phone Number<br/><br/>
The on-call phone number has been updated.<br/>
    123-456-7890 (Voicemail handler for 123-456-7890)<br/><br/>
    <strong>Caller Input #1 set to:</strong> $liveCallRoutingNumber<br/>
    <strong>Currently on-call:</strong> $onCallUser ($onCallPhone)
"@

try
{
    Write-Log "Attempting to send email to IT about on-call update:"

    Send-MailMessage -From $from -To $to `
        -Subject 'ALERT: On-Call phone number updated' `
        -Body $body -BodyAsHtml `
        -SmtpServer $smtp
}
catch
{
    Write-Log "Email failed to IT"
    Stop-Transcript
}

Stop-Transcript