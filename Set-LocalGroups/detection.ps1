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

        $compareArray = Compare-Object -ReferenceObject $allowedMembers -DifferenceObject $localGroupMembers -IncludeEqual
        $matchedMembers = $compareArray | Where-Object { $_.SideIndicator -eq "==" }
        # => Missing in Allowed Members (Not allowed - to remove)
        $membersToRemove = $compareArray | Where-Object { $_.SideIndicator -eq "=>" }
        # <= Missing in Local Group (To be added)
        $membersToAdd = $compareArray | Where-Object { $_.SideIndicator -eq "<=" }

        if ($membersToRemove -or $membersToAdd) {
            Write-Host "$($groupObject.group) members: $($localGroupMembers.Count) | Allowed: $($allowedMembers.Count) | Matching: $(@($matchedMembers).Count) | To Add: $(@($membersToAdd).Count) | To Remove: $(@($membersToRemove).Count)"
        }
        else {
            Write-Host "$($groupObject.group) matches the allowed user list.`nLocal members: $($localGroupMembers.Count) | Allowed: $($allowedMembers.Count) | Matching: $(@($matchedMembers).Count) | To Add: $(@($membersToAdd).Count) | To Remove: $(@($membersToRemove).Count)"
        }
    }

    if ($membersToRemove -or $membersToAdd) { exit 1 } else { exit 0 }
}
catch {
    $errorMessage = $_.Exception.Message
    Write-Error $errorMessage
    exit 1
}