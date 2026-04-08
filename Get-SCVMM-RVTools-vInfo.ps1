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


function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object.PSObject.Properties.Name -contains $PropertyName) {
        return $Object.$PropertyName
    }

    return $null
}

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

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying virtual machines from SCVMM...'
$vms = Get-SCVirtualMachine -VMMServer $server

$rows = foreach ($vm in $vms) {
    # Many properties vary by SCVMM version; guard with null checks.
    $vmHost = Get-OptionalPropertyValue -Object $vm -PropertyName 'VMHost'
    $hostCluster = Get-OptionalPropertyValue -Object $vm -PropertyName 'HostCluster'
    $cloud = Get-OptionalPropertyValue -Object $vm -PropertyName 'Cloud'
    $operatingSystemRaw = Get-OptionalPropertyValue -Object $vm -PropertyName 'OperatingSystem'

    $hostName = if ($vmHost -and $vmHost.Name) { $vmHost.Name } else { $null }
    $clusterName = if ($hostCluster -and $hostCluster.Name) { $hostCluster.Name } else { $null }
    $cloudName = if ($cloud -and $cloud.Name) { $cloud.Name } else { $null }
    $operatingSystem = if ($operatingSystemRaw -and $operatingSystemRaw.Name) { $operatingSystemRaw.Name } else { $operatingSystemRaw }

    # Memory is usually exposed in MB on SCVMM VM objects.
    $memoryGb = ConvertTo-GiB -Value $vm.Memory -Unit 'MB'

    # Try common dynamic memory properties if available.
    $dynamicMemoryEnabled = $null
    $memoryMinGb = $null
    $memoryMaxGb = $null

    if ($vm.PSObject.Properties.Name -contains 'DynamicMemoryEnabled') {
        $dynamicMemoryEnabled = $vm.DynamicMemoryEnabled
    }
    if ($vm.PSObject.Properties.Name -contains 'DynamicMemoryMinimumMB') {
        $memoryMinGb = ConvertTo-GiB -Value $vm.DynamicMemoryMinimumMB -Unit 'MB'
    }
    if ($vm.PSObject.Properties.Name -contains 'DynamicMemoryMaximumMB') {
        $memoryMaxGb = ConvertTo-GiB -Value $vm.DynamicMemoryMaximumMB -Unit 'MB'
    }

    # Build an RVTools-like vInfo row.
    [pscustomobject]@{
        VM            = $vm.Name
        PowerState    = $vm.StatusString
        OS            = $operatingSystem
        CPUs          = $vm.CPUCount
        MemoryGB      = $memoryGb
        MemoryMinGB   = $memoryMinGb
        MemoryMaxGB   = $memoryMaxGb
        DynamicMemory = $dynamicMemoryEnabled
        Host          = $hostName
        Cluster       = $clusterName
        Cloud         = $cloudName
        HighlyAvailable = $vm.IsHighlyAvailable
        CreationTime  = $vm.CreationTime
        Owner         = $vm.Owner
        Description   = $vm.Description
    }
}

$rows |
    Sort-Object VM |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "VMs exported: $($rows.Count)"
