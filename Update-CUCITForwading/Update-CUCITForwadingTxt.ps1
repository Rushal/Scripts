<#
   .Synopsis
   Update CUC forwarding for 214-880-8501 to the current on-call user

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
Start-Transcript -Path ($logFilePath + $logFileName) -Append
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

$cucmIP = ""
$from = ""
$to = ""
$smtp = ""

# Get on-call user from txt file
$onCallFile = ($logFilePath + "on-call.txt")
$onCall = Get-Content -Path $onCallFile

for ($i = 0; $i -lt $onCall.Length; $i++)
{
    $user = $onCall[$i].Split("|")

    if ($user[2])
    {
        Write-Log "$($user[0]) - Currently on-call.  Updating to the next person"

        if ( $i -eq ($onCall.Length - 1) )
        {
            $nextUser = $onCall[0].Split("|")
        }
        else
        {
            $nextUser = $onCall[$i + 1].Split("|")
        }

        $onCallUser = $nextUser[0]
        $onCallPhone = $nextUser[1]

        Write-Log "Updated on-call to: $onCallUser - $onCallPhone"
        Write-Log "Updating text file"

        (Get-Content $onCallFile).Replace("|oncall", "") | Set-Content $onCallFile
        (Get-Content $onCallFile).Replace("|$onCallPhone", "|$onCallPhone|oncall") | Set-Content $onCallFile

        Write-Log "Updated on-call, stopping loop and sending email"
        break
    }
}


# START CUC API
# Turn off SSL Verification since we're using self-signed certs
Write-Log "Disabling SSL Verifications since we're using self-signed certs"
Disable-SslVerification

# Set the REST url for the Desktop Support user call handler object from CUC
# GET: https://<IP>:8443/vmrest/users/2610750f-651c-45bb-90ef-e380c1685d26
$cucRestUrl = "https://$($cucmIP):8443/vmrest/handlers/callhandlers/67c7131f-20c7-4792-85bf-ca3b419f4f00/menuentries/1"

# Set the Auth Basic header to the user/pass hash
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($CUCCreds.UserName):$($CUCCreds.GetNetworkCredential().Password)"))
$headers = 
@{
    "Authorization" = "Basic $auth"
    "Content-Type"  = "application/xml"
}

# Put together the body for the request, adding in the correct phone number
$body = @"
    <MenuEntry>
        <Action>7</Action>
        "<TransferNumber>9$onCallPhone</TransferNumber>"
    </MenuEntry>
"@

# Send the request
$response = `
    try 
{
    Write-Log "Attempting to change the phone number to: 9$onCallPhone"
    Invoke-WebRequest -Headers $headers -Uri $cucRestUrl -Body $body -Method PUT
}
catch
{
    $_.Exception.ToString()
    Write-Log "Error updating the phone number"
    Write-Log "Error:" $error[0]

    Stop-Transcript
}

# Turn SSL Verification back on
Write-Log "Re-enabling SSL Verification"
Enable-SslVerification


# Email IT
$body = @"
<strong>Task Server:</strong> $env:COMPUTERNAME<br/>
<strong>Task name:</strong> Update IT On-Call Phone Number<br/><br/>
The on-call phone number has been updated.<br/>
    123-456-7890 (Voicemail handler for 123-456-7890)<br/><br/>
    <strong>Caller Input #1 set to:</strong> 9$onCallPhone<br/>
    <strong>Currently on-call:</strong> $onCallUser
"@

try
{
    Write-Log "Attempting to send email to IT about on-call update"

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