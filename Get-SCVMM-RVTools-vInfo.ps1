<#
.SYNOPSIS
Creates an RVTools-like vInfo CSV export from System Center Virtual Machine Manager (SCVMM).

.DESCRIPTION
Collects core VM inventory details from SCVMM and writes them to CSV in a shape
that is similar to RVTools vInfo output.

.NOTES
- Requires the VirtualMachineManager PowerShell module.
- Tested against SCVMM cmdlets: Get-SCVMMServer, Get-SCVirtualMachine.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMMServer,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\\SCVMM-vInfo.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-GiB {
    param(
        [Parameter(Mandatory = $false)]
        [double]$Value,

        [Parameter(Mandatory = $false)]
        [ValidateSet('MB', 'Bytes')]
        [string]$Unit = 'MB'
    )

    if ($null -eq $Value) {
        return $null
    }

    switch ($Unit) {
        'MB' { return [math]::Round($Value / 1024, 2) }
        'Bytes' { return [math]::Round($Value / 1GB, 2) }
    }
}

function Get-SafePropertyValue {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-SafeNestedName {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    $nestedObject = Get-SafePropertyValue -Object $Object -PropertyName $PropertyName
    return Get-SafePropertyValue -Object $nestedObject -PropertyName 'Name'
}

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying virtual machines from SCVMM...'
$vms = Get-SCVirtualMachine -VMMServer $server

$rows = foreach ($vm in $vms) {
    # Properties can differ by SCVMM version; read everything safely to avoid strict-mode failures.
    $hostName = Get-SafeNestedName -Object $vm -PropertyName 'VMHost'
    $clusterName = Get-SafeNestedName -Object $vm -PropertyName 'HostCluster'
    $cloudName = Get-SafeNestedName -Object $vm -PropertyName 'Cloud'

    $operatingSystemRaw = Get-SafePropertyValue -Object $vm -PropertyName 'OperatingSystem'
    $operatingSystemName = Get-SafePropertyValue -Object $operatingSystemRaw -PropertyName 'Name'
    $operatingSystem = if ($null -ne $operatingSystemName) { $operatingSystemName } else { $operatingSystemRaw }

    # Memory is usually exposed in MB on SCVMM VM objects.
    $memoryGb = ConvertTo-GiB -Value (Get-SafePropertyValue -Object $vm -PropertyName 'Memory') -Unit 'MB'

    # Try common dynamic memory properties if available.
    $dynamicMemoryEnabled = Get-SafePropertyValue -Object $vm -PropertyName 'DynamicMemoryEnabled'
    $memoryMinGb = ConvertTo-GiB -Value (Get-SafePropertyValue -Object $vm -PropertyName 'DynamicMemoryMinimumMB') -Unit 'MB'
    $memoryMaxGb = ConvertTo-GiB -Value (Get-SafePropertyValue -Object $vm -PropertyName 'DynamicMemoryMaximumMB') -Unit 'MB'

    # Build an RVTools-like vInfo row.
    [pscustomobject]@{
        VM              = Get-SafePropertyValue -Object $vm -PropertyName 'Name'
        PowerState      = Get-SafePropertyValue -Object $vm -PropertyName 'StatusString'
        OS              = $operatingSystem
        CPUs            = Get-SafePropertyValue -Object $vm -PropertyName 'CPUCount'
        MemoryGB        = $memoryGb
        MemoryMinGB     = $memoryMinGb
        MemoryMaxGB     = $memoryMaxGb
        DynamicMemory   = $dynamicMemoryEnabled
        Host            = $hostName
        Cluster         = $clusterName
        Cloud           = $cloudName
        HighlyAvailable = Get-SafePropertyValue -Object $vm -PropertyName 'IsHighlyAvailable'
        CreationTime    = Get-SafePropertyValue -Object $vm -PropertyName 'CreationTime'
        Owner           = Get-SafePropertyValue -Object $vm -PropertyName 'Owner'
        Description     = Get-SafePropertyValue -Object $vm -PropertyName 'Description'
    }
}

$rows |
    Sort-Object VM |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "VMs exported: $($rows.Count)"
