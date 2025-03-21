<#
.VERSION 1.1.0

.AUTHOR
    Chucky Ivey

.DESCRIPTION 
    Adds private and public DNS entries for privatelinks to work correctly
    Requires correct DNS setup and a DNS resolver in Azure... See MS Docs
    This was setup to be run from an Azure Runbook
#> 

param (
    [Parameter(Mandatory=$true)]
    [string] $RecordName,
    [Parameter(Mandatory=$true)]
    [string] $PrivateIP,
    [string] $PublicIP,
    [string] $PublicZoneName = "test.com",
    [string] $PrivateZoneName = "privatelink.test.com",
    [string] $PrivateResourceGroup = "private.rg",
    [string] $PublicResourceGroup = "public.rg",
    [string] $PrivateSubscriptionId = "",
    [string] $PublicSubscriptionId = ""
)

function Cleanup-DnsRecords {
    param (
        [Parameter(Mandatory=$true)]
        [object] $RecordSet
    )

    $retries = 5
    $delay = 5 # seconds

    for ($i = 1; $i -le $retries; $i++) {
        try {
            if ($RecordSet) {
                Write-Output "Removing DNS record: $($RecordSet.Name).$($RecordSet.ZoneName) (Attempt $i)"
                if ($RecordSet.GetType().Name -eq "PSPrivateDnsRecordSet") {
                    Set-AzContext -Subscription $PrivateSubscriptionId
                    Remove-AzPrivateDnsRecordSet -RecordSet $RecordSet -ErrorAction Stop
                } else {
                    Set-AzContext -Subscription $PublicSubscriptionId
                    Remove-AzDnsRecordSet -RecordSet $RecordSet -ErrorAction Stop
                }
                Write-Output "Record removed successfully"
                return # Exit the function if removal succeeds
            }
        } catch {
            Write-Warning "Error removing record (Attempt $i): $_"
            if ($i -eq $retries) {
                Write-Error "Failed to remove record after $retries attempts."
            } else {
                Write-Warning "Retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
            }
        }
    }
}

Write-Output "Connecting to Azure Account"
$Credential = Get-AutomationPSCredential -Name "<your automation info>"
$TenantId = Get-AutomationVariable -Name "<your automation info>"
Connect-AzAccount -Credential $Credential -Tenant $TenantId -Subscription $PrivateSubscriptionId -ServicePrincipal -ErrorAction Stop

if (-not (Get-AzPrivateDnsRecordSet -ResourceGroupName $PrivateResourceGroup -ZoneName $PrivateZoneName -Name $RecordName -RecordType A -ErrorAction SilentlyContinue)) {
    try {
        Write-Output "Creating DNS record in: $PrivateZoneName"
        Write-Output "$RecordName - $PrivateIP"
        $PrivateEntry = New-AzPrivateDnsRecordSet -Name $RecordName -RecordType A -ZoneName $PrivateZoneName `
            -ResourceGroupName $PrivateResourceGroup -Ttl 10 `
            -PrivateDnsRecords (New-AzPrivateDnsRecordConfig -IPv4Address $PrivateIP) -ErrorAction Stop
    } catch {
        Write-Output "Error creating private DNS record: $_"
        exit 1
    }
} else {
    Write-Output "Private record already exists with this name"
}

# Change context to the public subscription to create the public DNS records
Write-Output "Changing context to $PublicSubscriptionId"
Set-AzContext -Subscription $PublicSubscriptionId

if (-not (Get-AzDnsRecordSet -ZoneName $PublicZoneName -ResourceGroupName $PublicResourceGroup -Name $RecordName -RecordType CNAME -ErrorAction SilentlyContinue)) {
    Write-Output "Creating DNS records in: $PublicZoneName"
    if ($PublicIP) {
        try {
            Write-Output "$RecordName-a - $PublicIP"
            $Public_A = New-AzDnsRecordSet -Name "$RecordName-a" -RecordType A -ZoneName $PublicZoneName `
                -ResourceGroupName $PublicResourceGroup -Ttl 600 `
                -DnsRecords (New-AzDnsRecordConfig -IPv4Address $PublicIP) -ErrorAction Stop
            Write-Output "$RecordName-a created"
        } catch {
            Write-Output "Error creating public A record: $_"

            Write-Output "Cleaning up records..."
            Cleanup-DnsRecords -RecordSet $PrivateEntry
            throw "Public A record creation failed."
        }
        
        try {
            Write-Output "Creating privatelink CNAME DNS records in: $PublicZoneName"
            Write-Output "$RecordName.$(($PrivateZoneName).Split(".")[0])"
            $Public_PL = New-AzDnsRecordSet -Name "$RecordName.$(($PrivateZoneName).Split(".")[0])" -RecordType CNAME -ZoneName $PublicZoneName `
                -ResourceGroupName $PublicResourceGroup -Ttl 600 `
                -DnsRecords (New-AzDnsRecordConfig -Cname "$RecordName-a.$PublicZoneName") -ErrorAction Stop
            Write-Output "$RecordName.$(($PrivateZoneName).Split(".")[0]) record created"
        } catch {
            Write-Output "Error creating public CNAME record for .privatelink: $_"

            Write-Output "Cleaning up records..."
            Cleanup-DnsRecords -RecordSet $PrivateEntry
            Cleanup-DnsRecords -RecordSet $Public_A
            throw "Public CNAME record creation failed."
        }        
    }

    try {
        Write-Output "Creating CNAME DNS records in: $PublicZoneName"
        Write-Output "$RecordName.$PublicZoneName"
        New-AzDnsRecordSet -Name $RecordName -RecordType CNAME -ZoneName $PublicZoneName `
            -ResourceGroupName $PublicResourceGroup -Ttl 600 `
            -DnsRecords (New-AzDnsRecordConfig -Cname "$RecordName.$PrivateZoneName") -ErrorAction Stop
        Write-Output "$RecordName.$PublicZoneName DNS record created"
    } catch {
        Write-Output "Error creating public CNAME record: $_"

        Write-Output "Cleaning up records..."
        Cleanup-DnsRecords -RecordSet $PrivateEntry
        Cleanup-DnsRecords -RecordSet $Public_A
        Cleanup-DnsRecords -RecordSet $Public_PL
        throw "Final public CNAME record creation failed."
    }
} else {
    Write-Output "Public records already exists with this name"
}