$localAdministrators = @()
$localAdministratorsRemediated = @()
$allowedAdmins = @(
    "<GLOBAL ADMINISTRATOR SID>", # AAD Default Global Administrator Role | https://graph.microsoft.com/v1.0/directoryRoles?$filter=displayName eq 'Global Administrator' -> Convert group id to SID with known commands
    "<CLOUD DEVICE ADMINISTRATOR SID>"  # AAD Default Cloud Device Administrators Role | https://graph.microsoft.com/v1.0/directoryRoles?$filter=displayName eq 'Cloud Device Administrator'-> Convert group id to SID with known commands
)

try {
    $adminGroupSid = 'S-1-5-32-544'
    $adminGroup = New-Object System.Security.Principal.SecurityIdentifier($adminGroupSid)
    $adminGroupName = $adminGroup.Translate([System.Security.Principal.NTAccount]).Value -replace '.+\\'
    $administratorsGroup = ([ADSI]"WinNT://$env:COMPUTERNAME").psbase.children.find("$adminGroupName")

    $administratorsGroupMembers = $administratorsGroup.psbase.invoke("Members")

    foreach ($administrator in $administratorsGroupMembers) {
        $sid = (New-Object System.Security.Principal.SecurityIdentifier($administrator.GetType().InvokeMember('objectSid', 'GetProperty', $null, $administrator, $null), 0)).Value;
        $localAdministrators += $sid;

        if ($sid -like "*-500") { $allowedAdmins += $sid }
    }

    $compareArray = Compare-Object -ReferenceObject $allowedAdmins -DifferenceObject $localAdministrators -IncludeEqual
    # => Missing in Allowed Admins (Not allowed - to remove)
    $adminsToRemove = $compareArray | Where-Object { $_.SideIndicator -eq "=>" }
    # <= Missing in Local Admins (To be added)
    $adminsToAdd = $compareArray | Where-Object { $_.SideIndicator -eq "<=" }

    if ($adminsToRemove) {
        foreach ($admin in $adminsToRemove) {
            $admin = $admin.InputObject
            Write-Host "Working on: $admin"
            $administratorsGroup.Remove("WinNT://$admin")
            Write-Host "Successfully removed from Administrators: $admin"
        }
    }
    elseif ($adminsToAdd) {
        foreach ($admin in $adminsToAdd) {
            $admin = $admin.InputObject;
            Write-Host "Working on: $admin";
            $administratorsGroup.Add("WinNT://$admin");
            Write-Host "Successfully added to Administrators: $admin";
        }
    }

    # Check on the remediation
    $administratorsGroupMembers = $administratorsGroup.psbase.invoke("Members")
    foreach ($administrator in $administratorsGroupMembers) {
        $sid = (New-Object System.Security.Principal.SecurityIdentifier($administrator.GetType().InvokeMember('objectSid', 'GetProperty', $null, $administrator, $null), 0)).Value;
        $localAdministratorsRemediated += $sid;
    }
    $compareArray = Compare-Object -ReferenceObject $allowedAdmins -DifferenceObject $localAdministratorsRemediated
    # => Missing in Allowed Admins (Not allowed - to remove)
    $adminsToRemove = $compareArray | Where-Object { $_.SideIndicator -eq "=>" }
    # <= Missing in Local Admins (To be added)
    $adminsToAdd = $compareArray | Where-Object { $_.SideIndicator -eq "<=" }

    if (!$compareArray) {
        Write-Host "Remediated Local Admins group"
    }
    elseif ($adminsToRemove) {
        Write-Host "FAILED: Admins left to be removed: $adminsToRemove"
        exit 1
    }
    elseif ($adminsToAdd) {
        Write-Host "FAILED: Admins left to be added: $adminsToAdd"
        exit 1
    }
    else {
        Write-Host "Remediation failed"
        exit 1
    }
}
catch {
    $errorMessage = $_.Exception.Message
    Write-Error $errorMessage
    exit 1
}