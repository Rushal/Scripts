[cmdletbinding()]
Param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$computerName
)

$creds = Get-AutomationPSCredential -Name ""
$automationVarName = ''
$sharedKey = Get-AutomationVariable -name $automationVarName

$ScriptBlock = {
    function Write-OMSLogfile
    {
        <#
        .SYNOPSIS
        Inputs a hashtable, date and workspace type and writes it to a Log Analytics Workspace.
        .DESCRIPTION
        Given a  value pair hash table, this function will write the data to an OMS Log Analytics workspace.
        Certain variables, such as Customer ID and Shared Key are specific to the OMS workspace data is being written to.
        This function will not write to multiple OMS workspaces.  Build-signature and post-analytics function from Microsoft documentation
        at https://docs.microsoft.com/en-us/azure/log-analytics/log-analytics-data-collector-api
        .PARAMETER DateTime
        date and time for the log.  DateTime value
        .PARAMETER Type
        Name of the logfile or Log Analytics "Type".  Log Analytics will append _CL at the end of custom logs  String Value
        .PARAMETER LogData
        A series of key, value pairs that will be written to the log.  Log file are unstructured but the key should be consistent
        withing each source.
        .INPUTS
        The parameters of data and time, type and logdata.  Logdata is converted to JSON to submit to Log Analytics.
        .OUTPUTS
        The Function will return the HTTP status code from the Post method.  Status code 200 indicates the request was received.
        .NOTES
        Version:        2.0
        Author:         Travis Roberts
        Creation Date:  7/9/2018
        Purpose/Change: Crating a stand alone function.
        .EXAMPLE
        This Example will log data to the "LoggingTest" Log Analytics table
        $type = 'LoggingTest'
        $dateTime = Get-Date
        $data = @{
            ErrorText   = 'This is a test message'
            ErrorNumber = 1985
        }
        $returnCode = Write-OMSLogfile $dateTime $type $data -Verbose
        write-output $returnCode
        #>
        [cmdletbinding()]
        Param(
            [Parameter(Mandatory = $true, Position = 0)]
            [datetime]$dateTime,
            [parameter(Mandatory = $true, Position = 1)]
            [string]$type,
            [Parameter(Mandatory = $true, Position = 2)]
            [Hashtable]$logdata
        )
        Write-Verbose -Message "DateTime: $dateTime"
        Write-Verbose -Message ('DateTimeKind:' + $dateTime.kind)
        Write-Verbose -Message "Type: $type"
        Write-Verbose -Message "LogData: $logdata"

        #region Workspace ID and Key
        # Workspace ID for the workspace
        $CustomerID = ''
        #endregion

        # Supporting Functions
        # Function to create the auth signature
        function Build-signature ($CustomerID, $SharedKey, $Date, $ContentLength, $method, $ContentType, $resource)
        {
            $xheaders = 'x-ms-date:' + $Date
            $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
            $bytesToHash = [text.Encoding]::UTF8.GetBytes($stringToHash)
            $keyBytes = [Convert]::FromBase64String($SharedKey)
            $sha256 = New-Object System.Security.Cryptography.HMACSHA256
            $sha256.key = $keyBytes
            $calculateHash = $sha256.ComputeHash($bytesToHash)
            $encodeHash = [convert]::ToBase64String($calculateHash)
            $authorization = 'SharedKey {0}:{1}' -f $CustomerID, $encodeHash
            return $authorization
        }
        # Function to create and post the request
        Function Post-LogAnalyticsData ($CustomerID, $SharedKey, $Body, $Type)
        {
            $method = "POST"
            $ContentType = 'application/json'
            $resource = '/api/logs'
            $rfc1123date = ($dateTime).ToString('r')
            $ContentLength = $Body.Length
            $signature = Build-signature `
                -customerId $CustomerID `
                -sharedKey $Using:SharedKey `
                -date $rfc1123date `
                -contentLength $ContentLength `
                -method $method `
                -contentType $ContentType `
                -resource $resource
            $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
            $headers = @{
                "Authorization"        = $signature;
                "Log-Type"             = $type;
                "x-ms-date"            = $rfc1123date
                "time-generated-field" = $dateTime
            }
            $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $ContentType -Headers $headers -Body $body -UseBasicParsing
            Write-Verbose -Message ('Post Function Return Code ' + $response.statuscode)
            return $response.statuscode
        }

        # Check if time is UTC, Convert to UTC if not.

        if ($dateTime.kind.tostring() -ne 'Utc')
        {
            $dateTime = $dateTime.ToUniversalTime()
            Write-Verbose -Message $dateTime
        }

        # Add DateTime to hashtable
        $logdata.add("DateTime", $dateTime)

        #Build the JSON file
        $logMessage = ConvertTo-Json $logdata
        Write-Verbose -Message $logMessage

        #Submit the data
        $returnCode = Post-LogAnalyticsData -CustomerID $CustomerID -SharedKey $Using:SharedKey -Body ([System.Text.Encoding]::UTF8.GetBytes($logMessage)) -Type $type
        Write-Verbose -Message "Post Statement Return Code $returnCode"
        return $returnCode
    }


    $process = Get-Process -Name "DB" -IncludeUserName -EA SilentlyContinue
    if ($process) { $processStatus = "Running" } else { $processStatus = "NotRunning" }

    $type = 'RunningProcessCheck'
    $dateTime = Get-Date
    $data = @{
        ComputerName  = $env:COMPUTERNAME
        ProcessName   = "$($process.Name)"
        ProcessPath   = "$($process.Path)"
        RunningUser   = "$($process.Username)"
        ProcessStatus = $processStatus
    }
    $returnCode = Write-OMSLogfile $dateTime $type $data -Verbose
    Write-Output $data
    Write-Output $returnCode
}

Invoke-Command -ComputerName "$computerName" -Credential $creds -ScriptBlock $ScriptBlock