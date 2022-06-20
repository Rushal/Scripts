<#
   .SYNOPSIS
   Push content filter changes to all networks in an org

   .DESCRIPTION

   .OUTPUTS
   For logs see: $logFilePath

   .PARAMETER OrgID
   The organization ID you want to work with.  You can get this by going to: https://dashboard.meraki.com/api/v0/organizations

   .PARAMETER OutputDir
   The directory that you want to store the content filtering files gathered for each network
   Defaults to: C:\Windows\Temp\logs\Update-MerakiContentFilters\

   .PARAMETER FilterFile
   Full path to the default filter that should be applied to all of the networks
   Defaults to: $PSScriptRoot\defaultFilter.json

   .PARAMETER AddToWhiteList
   Add an array of URLs to the whitelist for all networks

   .PARAMETER AddToBlackList
   Add an array of URLs to the blacklist for all networks

   .PARAMETER GetOnly
   Only return the updated content filtering files, do not make any changes to the networks

   .EXAMPLE
   
   The -GetOnly switch will not make any changes to the networks. It will only return the content filter rules for each network.
   Update-MerakiConentFilters -GetOnly -OutputDir "C:\Windows\Temp\logs\"

   .EXAMPLE

   Add sites to the blocked and allowed URL patterns in the Meraki dashboard
   Update-MerakiContentFilters -AddToBlackList "www.hulu.com","msn.com" -AddToWhiteList "onrr.gov","office365.com"
   
   .NOTES
    v1.0
    AUTHOR
        Chucky A Ivey

    TODO
        Write cmd changes back to the default file
        Add switches to allow removal of urls
        Add switches to adjust the categories
        Add GUI option to edit the content filter
#>


[CmdletBinding()]
param (
    [String]
    $ApiKey,

    [String]
    $OrgID = "ENTER YOUR ID",

    [String]
    $OutputDir = "C:\Windows\Temp\logs\Update-MerakiContentFilters\",

    [String]
    $FilterFile = "$PSScriptRoot\defaultFilter.json",
    
    [String[]]
    $AddToWhiteList,
    
    [String[]]
    $AddToBlackList,
    
    [Switch]
    $GetOnly
)

#Region Logging
$logFilePath = "C:\Windows\Temp\logs\Update-MerakiContentFilters\"
$logFileName = "Update-MerakiContentFilters_Transcript_$(Get-Date -Format "MM-dd-yyyy").log"
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

Start-Transcript -Path ($logFilePath + $logFileName) -Append
#Endregion

function ValidateAndCleanURL($url)
{
    $regex = "^(?:(?:https?|ftp):\/\/)?(?:(?!(?:10|127)(?:\.\d{1,3}){3})(?!(?:169\.254|192\.168)(?:\.\d{1,3}){2})(?!172\.(?:1[6-9]|2\d|3[0-1])(?:\.\d{1,3}){2})(?:[1-9]\d?|1\d\d|2[01]\d|22[0-3])(?:\.(?:1?\d{1,2}|2[0-4]\d|25[0-5])){2}(?:\.(?:[1-9]\d?|1\d\d|2[0-4]\d|25[0-4]))|(?:(?:[a-z\u00a1-\uffff0-9]-*)*[a-z\u00a1-\uffff0-9]+)(?:\.(?:[a-z\u00a1-\uffff0-9]-*)*[a-z\u00a1-\uffff0-9]+)*(?:\.(?:[a-z\u00a1-\uffff]{2,})))(?::\d{2,5})?(?:\/\S*)?$"

    if ($url -match $regex)
    {
        Write-Log "Cleaning up URL: $url"
        $url = $url -replace '(http|ftp|https)(:\/\/)', ""
        $url = $url -replace '(www\.)', ""
        $url = $url -split "/"
        $url = $url[0]

        Write-Log "Valid: $url"
        return $url
    }
}

# Check for API Key
if (-not $ApiKey)
{
    Write-Log "You need to enter an API Key in order to continue."
    Write-Log "Log into https://dashboard.meraki.com, click on your username near the top right and choose My Profile.  Scroll down to API Access and Generate a new API key."
    Stop-Transcript
    throw "Please enter and API Key to continue"
}

# Set email creds
if (-not $GetOnly)
{
    $emailCreds = Get-Credential -Message "Please enter the SMTP user account for O365"
    if (-not $emailCreds)
    {
        Write-Log "ERROR: SMTP Email credentials cannot be blank"
        Stop-Transcript
        exit 1
    }
}

# Set TLS to 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Vars
$from = "$($emailCreds.UserName)"
$to = ""
$smtp = "smtp.office365.com"
$emailBody = "<strong>Script run from:</strong> $env:COMPUTERNAME<br/>"
$emailBody += "<strong>Username:</strong> $env:USERNAME<br/><br/>"
$emailBodyAppend = ""
$currentlyAllowed = ""
$currentlyBlocked = ""
$networksChanged = $false
$blockedCategories = @()
$defaultFilter = Get-Content $FilterFile -Raw | ConvertFrom-Json
$unmodifiedFilter = Get-Content $FilterFile -Raw | ConvertFrom-Json
$headers = @{
    "X-Cisco-Meraki-API-Key" = "$ApiKey"
    "Content-Type"           = "application/json"
    "Accept"                 = "*/*"
}
$networksURL = "https://dashboard.meraki.com/api/v1/organizations/$OrgID/networks"

Write-Log "Getting all networks in OrgID: $OrgID"
$networks = Invoke-RestMethod -Uri $networksURL -Headers $headers -Method 'GET'
$networks = $networks | Sort-Object name

#Region Add to Content Filter via CMD
if ($AddToWhiteList -or $AddToBlackList)
{
    $emailBodyAppend += "<br/><hr/><strong>Content filter changes made via command line</strong>"
    
    if ($AddToWhiteList)
    {
        $validUrlsWL = @()
        $currentlyAllowed = $defaultFilter.allowedUrlPatterns
        $emailBodyAppend += "<br/><strong>Added to the whitelist via command line:</strong><br/>"

        foreach ($url in $AddToWhiteList)
        {
            $validUrlsWL += ValidateAndCleanURL($url)
        }
        $validUrlsWL = $validUrlsWL -join ","
        Write-Log "Valid URLs to be added to the whitelist: $validUrlsWL"

        $validUrlsWL -split "," | ForEach-Object {
            $currentlyAllowed += $_
            $emailBodyAppend += "$_<br/>"
        }
        $currentlyAllowed = $currentlyAllowed | Sort-Object
        $defaultFilter.allowedUrlPatterns = $currentlyAllowed
    }
    if ($AddToBlackList)
    {
        $validUrlsBL = @()
        $currentlyBlocked = $defaultFilter.blockedUrlPatterns
        $emailBodyAppend += "<br/><strong>Added to the blacklist via command line:</strong><br/>"

        foreach ($url in $AddToBlackList)
        {
            $validUrlsBL += ValidateAndCleanURL($url)
        }
        $validUrlsBL = $validUrlsBL -join ","
        Write-Log "Valid URLs to be added to the blacklist: $validUrlsBL"

        $validUrlsBL -split "," | ForEach-Object {
            $currentlyBlocked += $_
            $emailBodyAppend += "$_<br/>"
        }
        $currentlyBlocked = $currentlyBlocked | Sort-Object
        $defaultFilter.blockedUrlPatterns = $currentlyBlocked
    }
}
#endregion

foreach ($network in $networks)
{
    Write-Log "Working on $($network.name) - $($network.productTypes)"
    $networkID = $network.ID
    $contentFilteringOutputFile = ($network.name + ".json")
    $contentFilteringURL = "https://dashboard.meraki.com/api/v1/networks/$networkID/appliance/contentFiltering"

    # Check for wireless network or Z1/Z3 and skip network
    if ($network.productTypes -notcontains "appliance") { continue }
    try
    {
        Write-Log "Getting the devices in this network"
        $deviceURL = "https://dashboard.meraki.com/api/v1/networks/$networkID/devices"
        $device = Invoke-RestMethod -Uri $deviceURL -Headers $headers -Method 'GET'

        if ( $device.model -like "Z*" -or $null -eq $device.model <#-or $device.model -like "MS*"#> )
        { 
            Write-Log "Found a $($device.model), skipping"
            continue
        }
    }
    catch
    {
        Write-Log "Could not get devices in this network, continuing"
    }

    try
    {
        $contentFiltering = Invoke-RestMethod -Uri $contentFilteringURL -Headers $headers -Method 'GET'

        # Output the content filtering for each network to a file
        Write-Log "Trying to write file: $OutputDir$contentFilteringOutputFile"
        if (-not( Test-Path -Path ($OutputDir + $contentFilteringOutputFile) ))
        {
            New-Item -ItemType File -Path $OutputDir -Name $contentFilteringOutputFile -Force
            $contentFiltering | ConvertTo-Json | Out-File ($OutputDir + $contentFilteringOutputFile)
        }
        else
        {
            $contentFiltering | ConvertTo-Json | Out-File ($OutputDir + $contentFilteringOutputFile)
        }
    }
    catch
    {
        Write-Log "There was an error connecting to: $contentFilteringURL | $($network.name)"
        Stop-Transcript
        throw "There was an error connecting to: $contentFilteringURL"
    }    
    
    # Let's update the networks
    if (-not $GetOnly)
    {
        Write-Log "GetOnly switch is NOT set.  Updating networks."

        #Region File Comparison to Network
        Write-Log "Comparing the unmodified JSON file to the current network to check for changes"
        $changedCategories = Compare-Object -ReferenceObject $contentFiltering.blockedUrlCategories -DifferenceObject $unmodifiedFilter.blockedUrlCategories
        $changedBL = Compare-Object -ReferenceObject $contentFiltering.blockedUrlPatterns -DifferenceObject $unmodifiedFilter.blockedUrlPatterns
        $changedWL = Compare-Object -ReferenceObject $contentFiltering.allowedUrlPatterns -DifferenceObject $unmodifiedFilter.allowedUrlPatterns

        if ($changedBL -or $changedWL -or $changedCategories)
        {
            $emailBody += "<br/><strong>NETWORK: $($network.name)</strong><br/>"
            $emailBody += "<strong>Content filter changes made via defaultFilter.json</strong>"

            if ($changedCategories.SideIndicator -contains "=>")
            {
                $emailBody += "<br/><strong>Added categories via file:</strong><br/>"
                $changedCategories | Where-Object { $_.SideIndicator -eq "=>" } |
                    ForEach-Object {
                        $emailBody += "$($_.InputObject)<br/>"
                    }
            }
            if ($changedCategories.SideIndicator -contains "<=")
            {
                $emailBody += "<br/><strong>Removed categories via file:</strong><br/>"
                $changedCategories | Where-Object { $_.SideIndicator -eq "<=" } |
                    ForEach-Object {
                        $emailBody += "$($_.InputObject)<br/>"
                    }
            }

            if ($changedWL.SideIndicator -contains "=>")
            {
                $emailBody += "<br/><strong>Added to the whitelist via file:</strong><br/>"
                $changedWL | Where-Object { $_.SideIndicator -eq "=>" } |
                    ForEach-Object {
                        $emailBody += "$($_.InputObject)<br/>"
                    }
            }
            if ($changedWL.SideIndicator -contains "<=")
            {
                $emailBody += "<br/><strong>Removed from the whitelist via file:</strong><br/>"
                $changedWL | Where-Object { $_.SideIndicator -eq "<=" } |
                    ForEach-Object {
                        $emailBody += "$($_.InputObject)<br/>"
                    }
            }

            if ($changedBL.SideIndicator -contains "=>")
            {
                $emailBody += "<br/><strong>Added to the blacklist via file:</strong><br/>"
                $changedBL | Where-Object { $_.SideIndicator -eq "=>" } |
                    ForEach-Object {
                        $emailBody += "$($_.InputObject)<br/>"
                    }
            }
            if ($changedBL.SideIndicator -contains "<=")
            {
                $emailBody += "<br/><strong>Removed from the blacklist via file:</strong><br/>"
                $changedBL | Where-Object { $_.SideIndicator -eq "<=" } |
                    ForEach-Object {
                        $emailBody += "$($_.InputObject)<br/>"
                    }
            }
        }
        #endregion

        try
        {
            # Convert the blocked url categories from the API GET into just URLs for the PUT to work
            $blockedCategories = @()
            $blockedCategoriesJson = $defaultFilter.blockedUrlCategories
            $blockedCategoriesJson |
                ForEach-Object {
                    $blockedCategories += $_.ID
                }
            $defaultFilter.blockedUrlCategories = $blockedCategories
            Write-Log "BlockedCategories has been updated to:"
            Write-Log "$blockedCategories"

            # Setup the body and send the update
            $body = ConvertTo-Json $defaultFilter
            Write-Log "Updating content filter on network: $($network.name)"

            $response = Invoke-RestMethod -Uri $contentFilteringURL -Headers $headers -Body $body -Method 'PUT'
        }
        catch
        {
            Write-Log "There was an error setting the content filter on network: $($network.name)"
        }

        # Set the default filter .blockedUrlCategories back to JSON with ID and Name
        $defaultFilter.blockedUrlCategories = $blockedCategoriesJson

        $networksChanged = $true
    }

    # Slow down calls so we don't hit the API limit.
    # This needs to be reworked when we deploy powershell 6+
    Start-Sleep 1
}

if ($networksChanged)
{
    # Write changes into the defaultFilter.json
    Write-Log "Updating the defaultFilter file to include changes"
    $updatedFilter = Out-File $FilterFile -InputObject ($defaultFilter | ConvertTo-Json) -Force


    Write-Log "Email to send: $($emailBody + $emailBodyAppend)"

    # Email IT on completion
    try
    {
        Write-Log "Attempting to send email it IT"

        Send-MailMessage -From $from -To $to `
            -Subject 'ALERT: Meraki API used to change content filters' `
            -Body ($emailBody + $emailBodyAppend) -BodyAsHtml `
            -SmtpServer $smtp `
            -Port 587 `
            -Credential $emailCreds `
            -UseSsl
    }
    catch
    {
        Write-Log "Email failed to IT"
    }
}

Stop-Transcript