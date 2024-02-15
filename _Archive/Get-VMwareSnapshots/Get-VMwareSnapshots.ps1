<#
   .SYNOPSIS
   Get current snapshots on the VMware servers and alert IT

   .OUTPUTS
   For logs see: $logFilePath
   
   .VERSION
    1.0
    
    .AUTHOR
    Chucky A Ivey
#>


#Region Logging
$logFilePath = "D:\logs\tasks\Get-VMwareSnapshots\"
$logFileName = "Get-VMwareSnapshots_Transcript_$(Get-Date -Format "MM-dd-yyyy").log"
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
}

Start-Transcript -Path ($logFilePath + $logFileName) -Append
#Endregion

$vcenter = "FQDN HERE"

Write-Log "Connecting to $vcenter"
Connect-VIServer $vcenter

Write-Log "Finding snapshots..."
$array = @()
foreach ($snap in Get-VM | Get-Snapshot)
{
    if ($snap -like "SVT_*") { continue }

    $snapevent = Get-VIEvent -Entity $snap.VM -Types Info -Finish $snap.Created -MaxSamples 1 |
        Where-Object {
            $_.FullFormattedMessage -imatch 'Task: Create virtual machine snapshot'
        }

    if ($snapevent -ne $null)
    {
        $createdBy = $snapevent.UserName
    }
    else
    {
        $createdBy = "Can't find event, snapshot is older than 30 days."
    }

    $obj = New-Object -TypeName PSObject
    $obj | Add-Member -MemberType NoteProperty -Name VM -Value $snap.VM
    $obj | Add-Member -MemberType NoteProperty -Name Snapshot -Value $snap
    $obj | Add-Member -MemberType NoteProperty -Name CreatedOn -Value $snap.Created.DateTime
    $obj | Add-Member -MemberType NoteProperty -Name CreatedBy -Value $createdBy

    Write-Log "Snapshot found:"
    Write-Log "$obj"

    $array += $obj
}

# Send email
$from = "EMAIL"
$to = "EMAIL"
$smtp = "SERVER"

if ($array)
{
    $body = "<html>
    <style>
        table { border: 1px solid black; border-collapse: collapse; }
        th { border: 1px solid #969595; background: #ddd; padding: 5px; text-align: left; }
        td { border: 1px solid #969595; padding: 5px; }
    </style>
    <body>"

    $body += "<strong>Task Server:</strong> $env:COMPUTERNAME<br/>"
    $body += "<strong>Task name:</strong>VMware Stale Snapshots<br/>"
    $body += "Please clean up the following snapshots if you no longer need them.<br/><br/>"
    $body += $array.ForEach( { [PSCustomObject]$_ } ) | ConvertTo-Html -Fragment | Out-String

    $body += "</body></html>"

    try
    {
        Write-Log "Attempting to send email to IT"

        Send-MailMessage -From $from -To $to `
            -Subject 'ALERT: Cleanup Old VMware Snapshots' `
            -Body $body -BodyAsHtml `
            -SmtpServer $smtp
    }
    catch
    {
        Write-Log "Email failed to IT"
    }
}

Disconnect-VIServer $vcenter -Confirm:$false

Stop-Transcript