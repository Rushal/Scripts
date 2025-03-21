# Meant for Azure Runbook
# Needs Hybrid worker
# This syncs AADJ computers to a non-synced OU
#   Then finds the certs for the device and adds them into the correct attribute so that MS RADIUS/NPS works correctly
# Then finds the users accounts in AD and does the same mapping for certs
# TODO: Make the additional OU var an array...

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [Parameter(Mandatory = $False)] [String] $TenantId = "",
    [Parameter(Mandatory = $False)] [String] $ClientId = "",
    [Parameter(Mandatory = $False)] [String] $AuthUrl = "https://login.windows.net/<YOURDOMAIN>.onmicrosoft.com",
    [Parameter(Mandatory = $False)] [String] $OrgUnit = "",
    [Parameter(Mandatory = $False)] [String] $AdditionalOrgUnit = "",
    [Parameter(Mandatory = $False)] [String] $CertPath = "X509:<SHA1-PUKEY>",
    [Parameter(Mandatory = $False)] [String] $LocalDomain = "contoso.com"
)

$account = Get-AutomationPSCredential -Name '<YOUR AUTOMAION ACCOUNT>'
$ClientSecret = $account.GetNetworkCredential().Password

$requiredModules = "ActiveDirectory", "Microsoft.Graph", "Microsoft.Graph.Groups", "Microsoft.Graph.Identity.DirectoryManagement", "PSPKI"
$aadDevices = @{}

Write-Output "Hybrid worker: $($env:COMPUTERNAME)"

# Get NuGet
Get-PackageProvider -Name "NuGet" -Force | Out-Null

# Setup modules
Write-Output "Setting up required modules..."
foreach ($module in $requiredModules) {
    if ($moduleChecks) {
        # Check if installed version = online version, if not then update it
        [Version]$onlineVersion = (Find-Module -Name $module -ErrorAction SilentlyContinue).Version
        [Version]$installedVersion = (Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object Version -First 1).Version
        if ($onlineVersion -gt $installedVersion) {
            Write-Output "Updating module $($module)..."
            Update-Module -Name $Module -Force
        }
        elseif (!$installedVersion) {
            Write-Output "Installing module $($module)..."
            Install-Module -Name $Module -Force -AllowClobber
        }
    }

    # Import modules
    if (!(Get-Module -Name $module)) {
        if ($module -eq "Microsoft.Graph") { continue }

        Write-Output "Importing module $($module)"
        Import-Module -Name $module -Force -Scope Global
    }
}

# Connect to MSGraph with application credentials
Write-Output "Conecting to Microsoft Graph..."
try {
    Connect-MgGraph -AccessToken (ConvertTo-SecureString -String ((Invoke-RestMethod -Uri https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token `
                    -Method POST `
                    -Body @{
                    Grant_Type = "client_credentials";
                    Scope = "https://graph.microsoft.com/.default";
                    Client_Id = $clientId; Client_Secret = $clientSecret
                }).access_token) -AsPlainText -Force) `
        -ErrorAction Stop
}
catch {
    Write-Output "Something went wrong while connecting to MS Graph! Exiting script..."
    throw
}

###############################################################################################################
# AADJ
# Get all AADJ devices and add to AD
Write-Output "AADJ | Fetching all Azure AD joined devices..."
$devices = Get-MgDevice -Filter "trustType eq 'AzureAD'" -All

foreach ($device in $devices) {
    $deviceName = $device.DisplayName
    $guid = $device.DeviceId
    Write-Output "AADJ | Processing device: $deviceName | ID: $guid"

    if (!($aadDevices.ContainsKey($guid))) {
        $aadDevices.Add($guid, $deviceName)
    }

    #$guid -match "^([0-9a-fA-F]{8})(-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-)([0-9a-fA-F]{11})([0-9a-fA-F])$" | Out-Null
    #$samAccountName = "$($matches[1])"+"$($matches[3])"+"$"
    $samAccountName = "$($deviceName.subString(0, [System.Math]::Min(15, $deviceName.Length)))`$"

    try {
        if (($adDevice = Get-ADComputer -Filter "Name -eq `"$($deviceName)`"" -SearchBase $orgUnit)) {
            Write-Output "AADJ | Updating AD object for: $deviceName | ID: $guid"

            $adDevice | Set-ADComputer -Replace @{
                "servicePrincipalName" = @(
                    "HOST/$($deviceName)",
                    "HOST/$($deviceName).$LocalDomain"
                )
                "samAccountName"       = "$($samAccountName)"
                "description"          = "AAD Object ID: $($guid)"
            }
        }
        else {
            Write-Output "AADJ | Adding AD object for: $deviceName | ID: $guid"

            $adDevice = New-ADComputer -Name $deviceName -ServicePrincipalNames "HOST/$deviceName", "HOST/$deviceName.$LocalDomain" `
                -SamAccountName $samAccountName `
                -Description "AAD Object ID: $guid" `
                -Path $orgUnit `
                -AccountPassword $NULL -PasswordNotRequired $False -PassThru
        }
        $adDevice = Get-ADComputer -Filter "Name -eq `"$($deviceName)`"" -SearchBase $orgUnit
    }
    catch {
        Write-Output "AADJ | ERROR Something went wrong while adding/updating AD object for: $deviceName | ID: $guid"
    }
}

###############################################################################################################
# CERTS
# Find all certs that are not expired
# Create an array of them including the SAN
try {
    foreach ($CAHost in Get-CertificationAuthority) {
        Write-Output "CERT | Getting all issued, non-expired certs from $($CAHost.ComputerName)"
        $IssuedRaw = Get-IssuedRequest -CertificationAuthority $CAHost -Property RequestID, ConfigString, CommonName, CertificateHash, RawCertificate -Filter "NotAfter -gt $(Get-Date)" -ErrorAction Stop
        $IssuedCerts += $IssuedRaw | Select-Object -Property RequestID, ConfigString, CommonName, CertificateHash, @{
            name       = 'SANPrincipalName';
            expression = {
                (
                    $(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `
                            -ArgumentList @(, [Convert]::FromBase64String($_.RawCertificate))).Extensions | `
                            Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }
                    ).Format(0) -match "^(.*)(Principal Name=)([^,]*)(,?)(.*)$" | Out-Null;
                
                    if ($matches.GetEnumerator() | Where-Object Value -EQ "Principal Name=") {
                        $n = ($matches.GetEnumerator() | Where-Object Value -EQ "Principal Name=").Name + 1;
                        $matches[$n]
                    }
                }
            },
            @{
                name       = 'DNSName';
                expression = {
                    (
                        $(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `
                                -ArgumentList @(, [Convert]::FromBase64String($_.RawCertificate))).Extensions | `
                                Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }
                        ).Format(0) -match "^(.*)(DNS Name=)([^,]*)(,?)(.*)$" | Out-Null;
                
                        if ($matches.GetEnumerator() | Where-Object Value -EQ "DNS Name=") {
                            $n = ($matches.GetEnumerator() | Where-Object Value -EQ "DNS Name=").Name + 1;
                            $matches[$n]
                        }
                    }
                }
            }
        }
        catch {
            Write-Output "$($_.Exception.Message)" 
            Write-Output "CERT | Error getting issued certificates from ADCS servers"
        }

        # Get AADJ computer objects that are already created in AD
        # Get AD Users
        try { 
            Write-Output "CERT | Getting AD objects..."
            $aadjDevices = Get-ADComputer -Filter '(objectClass -eq "computer")' -SearchBase $orgUnit -Property Name, altSecurityIdentities, SamAccountName, Description -ErrorAction Stop | Sort-Object -Property Name
            $combinedDevices = Get-ADComputer -Filter '(objectClass -eq "computer")' -SearchBase $AdditionalOrgUnit -SearchScope Subtree -Property Name, altSecurityIdentities, SamAccountName, Description -ErrorAction Stop | Sort-Object -Property Name
            $combinedDevices += $aadjDevices
            $combinedDevices = $combinedDevices | Sort-Object -Property Name

            $adUsers = Get-ADUser -Filter "(UserPrincipalName -Like '*')" -Property Name, altSecurityIdentities -ErrorAction Stop | Sort-Object -Property Name
        }
        catch {
            Write-Output "$($_.Exception.Message)" 
            Write-Output "CERT | Error getting AAD computers or AD users for hash sync"
        }

        foreach ($device in $combinedDevices) {
            Write-Output "CERT | START Device $($device.Name)"
            $certs = $IssuedCerts | Where-Object DNSName -Like "$($device.Name)*"
            if ($certs) {
                $a = @()
                $b = @()

                foreach ($cert in $certs) {
                    $hash = ($cert.CertificateHash) -Replace '\s', ''
                    $a += "$CertPath$hash" # X509:<SHA1-PUKEY>xyz
                    $b += "($($cert.ConfigString)-$($cert.RequestID))$hash"
                }
                [Array]::Reverse($a)
                try {
                    if (!((-Join $device.altSecurityIdentities) -eq (-Join $a))) {
                        [Array]::Reverse($a)
                        $hashTable = @{ "altSecurityIdentities" = $a }
                        Write-Output "CERT | Mapping AADJ computer '$($device.Name) ($($device.Description))' to (CA-RequestID) SHA-hash '$($b -Join ',')'"
                        Get-ADComputer -Filter "(servicePrincipalName -like 'HOST/$($device.Name)')" | Set-ADComputer -Add $hashTable
                    }
                }
                catch {
                    Write-Output "$($_.Exception.Message)" 
                    Write-Output "CERT | ERROR mapping AADJ computer object '$($device.Name) ($($device.Description))' to (CA-RequestID) SHA1-hash '$($b -Join ',')'"
                }
            }
        }

        foreach ($user in $adUsers) {
            $certs = $IssuedCerts | Where-Object SANPrincipalName -Like "$($user.UserPrincipalName)"
            if ($certs) {
                $a = @()
                $b = @()
                foreach ($cert in $certs) {
                    $hash = ($cert.CertificateHash) -Replace '\s', ''
                    $a += "$CertPath$hash" # X509:<SHA1-PUKEY>xyz
                    $b += "($($cert.ConfigString)-$($cert.RequestID))$hash"
                }
                [Array]::Reverse($a)
                try {
                    if (!((-Join $user.altSecurityIdentities) -eq (-Join $a))) {
                        [Array]::Reverse($a)
                        $hashTable = @{"altSecurityIdentities" = $a }
                        Write-Output "CERT | Mapping AD user '$($user.UserPrincipalName)' to (CA-RequestID) SHA1-hash '$($b -Join ',')'"
                        $user | Set-ADUser -Add $hashTable
                    }
                }
                catch {
                    Write-Output "$($_.Exception.Message)"
                    Write-Output "CERT | ERROR mapping AD user object '$($user.UserPrincipalName)' to (CA-RequestID) SHA1-hash '$($b -Join ',')'"
                }
            }
        }

        ###############################################################################################################
        # CLEANUP
        # Remove any AADJ computer objects in AD that are no longer in AzureAD
        #$dummyDevices = Get-ADComputer -Filter * -SearchBase $orgUnit | Select-Object Name, SamAccountName
        foreach ($device in $aadjDevices) {
            if ($aadDevices.Contains($device.Name) -or $aadDevices.Values -contains $device.Name) {
                Write-Output "CLEANUP | SKIPPING - $($device.Name) ($($device.Description)) exists in AzureAD."
            }
            else {
                Write-Output "CLEANUP | DELETING - $($device.Name) ($($device.Description)) does not exist in AzureAD."
                Remove-ADComputer -Identity $device.SamAccountName -Confirm:$False
            }
        }