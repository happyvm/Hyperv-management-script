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

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying virtual machines from SCVMM...'
$vms = Get-SCVirtualMachine -VMMServer $server

$rows = foreach ($vm in $vms) {
    # Many properties vary by SCVMM version; guard with null checks.
    $hostName = if ($vm.VMHost -and $vm.VMHost.Name) { $vm.VMHost.Name } else { $null }
    $clusterName = if ($vm.HostCluster -and $vm.HostCluster.Name) { $vm.HostCluster.Name } else { $null }
    $cloudName = if ($vm.Cloud -and $vm.Cloud.Name) { $vm.Cloud.Name } else { $null }
    $operatingSystem = if ($vm.OperatingSystem -and $vm.OperatingSystem.Name) { $vm.OperatingSystem.Name } else { $vm.OperatingSystem }

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
