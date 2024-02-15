<# Current Example Output
{
  "device-owner": [
    "AD SID,AAD SID"
  ],
  "trustType": "AzureAd",
  "users": []
}
#>

$localGroupToResourceJson = @'
[
    {
        "group": "Administrators",
        "sid": "S-1-5-32-544",
        "spoFieldName": "AdminApproval"
    },
    {
        "group": "Network Configuration Operators",
        "sid": "S-1-5-32-556",
        "spoFieldName": "NetworkAdmin"
    }
]
'@
$localGroupToResource = ConvertFrom-Json -InputObject $localGroupToResourceJson
$hostname = $env:COMPUTERNAME
$adsi = ([ADSI]"WinNT://$env:COMPUTERNAME")
$lapsAdmin = ""

try {
    foreach ($groupObject in $localGroupToResource) {
        $localGroupMembers = @()
        $allowedMembers = @()
        $matchedMembers = @()
        $membersToAdd = @()
        $membersToRemove = @()
        $groupRemediated = @()

        $uri = "<LOGICAPP-HTTPENDPOINT>&hostname=$hostname&spoListFieldName=$($groupObject.spoFieldName)"
        $response = Invoke-RestMethod -Uri $uri

        $groupSid = "$($groupObject.sid)" 
        $group = New-Object System.Security.Principal.SecurityIdentifier($groupSid)
        $groupName = $group.Translate([System.Security.Principal.NTAccount]).Value -replace '.+\\'
        $group = $adsi.psbase.children.find("$groupName")
        $groupMembers = $group.psbase.invoke("Members")

        if ($groupObject.group -eq "Administrators") {
            $allowedMembers = @(
                "<GLOBAL ADMINISTRATOR SID>", # AAD Default Global Administrator Role | https://graph.microsoft.com/v1.0/directoryRoles?$filter=displayName eq 'Global Administrator' -> Convert group id to SID with known commands
                "<CLOUD DEVICE ADMINISTRATOR SID>"  # AAD Default Cloud Device Administrators Role | https://graph.microsoft.com/v1.0/directoryRoles?$filter=displayName eq 'Cloud Device Administrator'-> Convert group id to SID with known commands
            )

            # Add LAPS admin as allowed
            if ($adsi.Children | Where-Object { $_.SchemaClassName -eq 'user' -and $_.Name -eq "$lapsAdmin" }) {
                $id = New-Object System.Security.Principal.NTAccount("$lapsAdmin")
                $allowedMembers += $id.Translate( [System.Security.Principal.SecurityIdentifier] ).toString()
            }
        }

        # Current group members
        foreach ($member in $groupMembers) {
            $sid = (New-Object System.Security.Principal.SecurityIdentifier($member.GetType().InvokeMember('objectSid', 'GetProperty', $null, $member, $null), 0)).Value
            $localGroupMembers += $sid

            if ($sid -like "*-500") { $allowedMembers += $sid } # Known ADMIN SID, different for each computer
        }      

        # Members that should be in the group
        # Checking on AAD native VS AD join, to pull the correct SID
        if ($response.trustType -eq "AzureAd") {
            if ($null -ne $response.'device-owner' -and $response.'device-owner'.count -gt 0) { $allowedMembers += "$($response.'device-owner')".Split(',')[1] }
            if ($response.users.Count -gt 0) {
                foreach ($user in $response.users) {
                    $allowedMembers += "$user".Split(',')[1]
                }
            }
        }
        else {
            if ($null -ne $response.'device-owner' -and $response.'device-owner'.count -gt 0) { $allowedMembers += "$($response.'device-owner')".Split(',')[0] }
            if ($response.users.Count -gt 0) {
                foreach ($user in $response.users) {
                    $allowedMembers += "$user".Split(',')[0]
                }
            }
        }        

        $compareArray = Compare-Object -ReferenceObject $allowedMembers -DifferenceObject $localGroupMembers
        # => Missing in Allowed Members (Not allowed - to be removed)
        $membersToRemove = $compareArray | Where-Object { $_.SideIndicator -eq "=>" }
        # <= Missing in Local Group (To be added)
        $membersToAdd = $compareArray | Where-Object { $_.SideIndicator -eq "<=" }

        if ($membersToRemove) {
            foreach ($member in $membersToRemove) {
                $member = $member.InputObject
                Write-Host "Working on: $member"
                $group.Remove("WinNT://$member")
                Write-Host "Successfully removed from $($groupObject.group): $member"
            }
        }
        elseif ($membersToAdd) {
            foreach ($member in $membersToAdd) {
                $member = $member.InputObject
                Write-Host "Working on: $member"
                $group.Add("WinNT://$member")
                Write-Host "Successfully added to $($groupObject.group): $member"
            }
        }

        # Check on the remediation
        $groupMembers = $group.psbase.invoke("Members")
        foreach ($member in $groupMembers) {
            $sid = (New-Object System.Security.Principal.SecurityIdentifier($member.GetType().InvokeMember('objectSid', 'GetProperty', $null, $member, $null), 0)).Value
            $groupRemediated += $sid
        }
        $compareArray = Compare-Object -ReferenceObject $allowedMembers -DifferenceObject $groupRemediated

        if (!$compareArray) { Write-Host "Remediated: $($groupObject.group) | Added: $(@($membersToAdd).Count) | Removed: $(@($membersToRemove).Count)" }
        else { Write-Host "Remediation failed: $($groupObject.group)" }
    }

    if ($compareArray) { exit 1 }
}
catch {
    $errorMessage = $_.Exception.Message
    Write-Error $errorMessage
    exit 1
}