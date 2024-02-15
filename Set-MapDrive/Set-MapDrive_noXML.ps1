Start-Transcript -Path $(Join-Path $env:temp "DriveMapping.log") -Append

<# To get the base64 hash on that user/computer, run:
    Add-Type -AssemblyName System.Security
    $scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    $toCipher = [System.Text.Encoding]::UTF8.GetBytes("<PASSWORD HERE>")
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($toCipher, $null, $scope)
    [string] $base64 = [Convert]::ToBase64String($protected)
    $base64
#>

#Region Use Windows Data Protection API to create the credentials
try {
    Add-Type -AssemblyName System.Security

    $base64 = ""
    [byte[]] $hashArray = [System.Convert]::FromBase64String($base64)

    $scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    $securePassword = ConvertTo-SecureString ([System.Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect($hashArray, $null, $scope))) -AsPlainText -Force

    $username = "<USERNAME-FOR-MAPPED-DRIVE>"
    [pscredential]$creds = New-Object System.Management.Automation.PSCredential ($username, $securePassword)
}
catch {
    Write-Error "Failed to process credentials"
    Write-Error $_.Exception.Message
    exit 1
}
#EndRegion

$driveMappingJson = `
    '[
	{
	  "Path": "\\\\path\\to\\share",
	  "DriveLetter": "Z",
	  "Label": "SHARE NAME"
	}
  ]'

$driveMappingConfig = $driveMappingJson | ConvertFrom-Json -ErrorAction Stop

# Get current drives
$currentDrives = Get-PSDrive | Where-Object {
    $_.Provider.Name -eq "FileSystem" -and $_.Root -notin @("$env:SystemDrive\")
} | Select-Object @{
    N = "DriveLetter";
    E = { $_.Name }
},
@{
    N = "Path";
    E = { $_.DisplayRoot }
}

# Remove the drives first
foreach ($drive in $driveMappingConfig) {
    try {
        $exists = $currentDrives | Where-Object { $_.Path -eq $drive.Path -or $_.DriveLetter -eq $drive.DriveLetter }
        
        if ( $exists ) {
            Write-Output "Found old '$($drive.DriveLetter):\ - $($exists.Path)' - Trying to remove"
            try {
                Get-PSDrive | Where-Object { $_.DisplayRoot -eq $drive.Path -or $_.Name -eq $drive.DriveLetter } | Remove-PSDrive -Force -EA Stop
                Get-SmbMapping | Where-Object { $_.LocalPath -eq "$($drive.DriveLetter):" } | Remove-SmbMapping -Force -EA Stop
                Write-Output "Drive removed`n"
            }
            catch {
                Write-Output "ERROR: Could not remove drive"
            }  				
        }
    }
    catch {
        $available = Test-Path $($drive.Path)
        if (-not $available) {
            Write-Error "Unable to access path '$($drive.Path)' verify permissions and authentication!"
            exit 1
        }
        else {
            Write-Error $_.Exception.Message
            exit 1
        }
    }
}

# Now map the drives
foreach ($drive in $driveMappingConfig) {
    Start-Sleep -Seconds 5
    try {
        Write-Output "Mapping network drive $($drive.Path)"
        $null = New-PSDrive -PSProvider FileSystem -Name $drive.DriveLetter -Root $drive.Path -Description $drive.Label -Credential $creds -Persist -Scope global -EA Stop
        Start-Sleep -Seconds 5
    }
    catch {
        Write-Output "ERROR: Failed to add PSDrive: $($drive.DriveLetter)"
        exit 1
    }
    
    try {
        Write-Output "PSDrive added, trying to add to explorer"
        (New-Object -ComObject Shell.Application).NameSpace("$($drive.DriveLetter):").Self.Name = $drive.Label
        Write-Output "Added to explorer`n"
    }
    catch {
        Write-Output "ERROR: Failed to add drive to explorer"
        Write-Output "Removing PSDrive: $($drive.DriveLetter)"
        Remove-PSDrive -Name $drive.DriveLetter
        exit 1
    }
}

Stop-Transcript