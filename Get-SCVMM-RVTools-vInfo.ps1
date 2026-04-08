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
    [string]$OutputPath = ".\\SCVMM-vInfo.csv",

    [Parameter(Mandatory = $false)]
    [ValidateSet(',', ';', "`t")]
    [string]$Delimiter = ';'
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

function Get-FirstAvailablePropertyValue {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        $value = Get-SafePropertyValue -Object $Object -PropertyName $propertyName
        if ($null -ne $value -and $value -ne '') {
            return $value
        }
    }

    return $null
}

function Join-UniqueValues {
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Values
    )

    if ($null -eq $Values) {
        return $null
    }

    $result = @(
        $Values |
            Where-Object { $null -ne $_ -and $_ -ne '' } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )

    if ($result.Count -eq 0) {
        return $null
    }

    return ($result -join '; ')
}

function Convert-SizeValueToBytes {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Value,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Bytes', 'MB', 'KB')]
        [string]$Unit = 'Bytes'
    )

    if ($null -eq $Value -or $Value -eq '') {
        return $null
    }

    $numeric = [double]$Value

    if ($Unit -eq 'MB') {
        return $numeric * 1MB
    }

    if ($Unit -eq 'KB') {
        return $numeric * 1KB
    }

    # Most SCVMM storage size properties are exposed as Bytes when no unit is in the name.
    return $numeric
}

function Get-DriveItems {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    $direct = Get-SafePropertyValue -Object $Vm -PropertyName 'VirtualDiskDrives'
    if ($null -ne $direct) {
        return @($direct)
    }

    try {
        $disks = Get-SCVirtualDiskDrive -VM $Vm -ErrorAction Stop
        return @($disks)
    }
    catch {
        return @()
    }
}

function Get-NicItems {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    $direct = Get-SafePropertyValue -Object $Vm -PropertyName 'VirtualNetworkAdapters'
    if ($null -ne $direct) {
        return @($direct)
    }

    try {
        $nics = Get-SCVirtualNetworkAdapter -VM $Vm -ErrorAction Stop
        return @($nics)
    }
    catch {
        return @()
    }
}

function Get-ClusterNameForVm {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    $clusterName = Get-FirstAvailablePropertyValue -Object $Vm -PropertyNames @(
        'HostClusterName',
        'ClusterName'
    )
    if ($null -ne $clusterName) {
        return $clusterName
    }

    $clusterName = Get-SafeNestedName -Object $Vm -PropertyName 'HostCluster'
    if ($null -ne $clusterName) {
        return $clusterName
    }

    $vmHost = Get-SafePropertyValue -Object $Vm -PropertyName 'VMHost'
    if ($null -ne $vmHost) {
        $hostClusterName = Get-SafeNestedName -Object $vmHost -PropertyName 'HostCluster'
        if ($null -ne $hostClusterName) {
            return $hostClusterName
        }
    }

    return $null
}

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying virtual machines from SCVMM...'
$vms = Get-SCVirtualMachine -VMMServer $server

$rows = foreach ($vm in $vms) {
    # Properties can differ by SCVMM version; read everything safely to avoid strict-mode failures.
    $hostName = Get-SafeNestedName -Object $vm -PropertyName 'VMHost'
    $clusterName = Get-ClusterNameForVm -Vm $vm
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

    # Firmware and hardware version (best effort across VMM versions).
    $generation = Get-SafePropertyValue -Object $vm -PropertyName 'Generation'
    $firmwareType = Get-FirstAvailablePropertyValue -Object $vm -PropertyNames @('FirmwareType', 'BootType')
    if ($null -eq $firmwareType) {
        if ($generation -eq 2) {
            $firmwareType = 'UEFI'
        }
        elseif ($generation -eq 1) {
            $firmwareType = 'BIOS'
        }
    }

    $hardwareVersion = Get-FirstAvailablePropertyValue -Object $vm -PropertyNames @(
        'VirtualHardwareVersion',
        'Version',
        'VirtualMachineSubType',
        'VirtualMachineType'
    )

    # Integration services health/state (best effort).
    $integrationServices = Get-FirstAvailablePropertyValue -Object $vm -PropertyNames @(
        'IntegrationServicesState',
        'IntegrationServicesVersion',
        'GuestServicesEnabled',
        'Heartbeat',
        'VMAdditions'
    )

    # EVC equivalent (CPU compatibility mode for migration on Hyper-V).
    $cpuCompatibilityEnabled = Get-FirstAvailablePropertyValue -Object $vm -PropertyNames @(
        'CPUCompatibilityMode',
        'CPULimitForMigration',
        'CompatibilityForMigrationEnabled',
        'LimitProcessorFeatures',
        'CPULimitFunctionality'
    )

    # VM storage: sum provisioned/used if available and collect hosting volumes.
    $driveItems = Get-DriveItems -Vm $vm
    $provisionedBytes = 0.0
    $usedBytes = 0.0
    $hostingVolumes = @()

    foreach ($drive in $driveItems) {
        $vhd = Get-SafePropertyValue -Object $drive -PropertyName 'VirtualHardDisk'

        $sizeProperty = Get-FirstAvailablePropertyValue -Object $drive -PropertyNames @(
            'MaximumSize',
            'VirtualHardDiskSize',
            'Size'
        )
        if ($null -eq $sizeProperty -and $null -ne $vhd) {
            $sizeProperty = Get-FirstAvailablePropertyValue -Object $vhd -PropertyNames @(
                'MaximumSize',
                'Size'
            )
        }
        $sizePropertyMb = Get-FirstAvailablePropertyValue -Object $drive -PropertyNames @('MaximumSizeMB', 'SizeMB')
        if ($null -eq $sizePropertyMb -and $null -ne $vhd) {
            $sizePropertyMb = Get-FirstAvailablePropertyValue -Object $vhd -PropertyNames @('MaximumSizeMB', 'SizeMB')
        }

        if ($null -ne $sizeProperty) {
            $resolvedSizeBytes = Convert-SizeValueToBytes -Value $sizeProperty -Unit 'Bytes'
            if ($resolvedSizeBytes -gt 0) {
                $provisionedBytes += [double]$resolvedSizeBytes
            }
        }
        elseif ($null -ne $sizePropertyMb) {
            $resolvedSizeBytes = Convert-SizeValueToBytes -Value $sizePropertyMb -Unit 'MB'
            if ($resolvedSizeBytes -gt 0) {
                $provisionedBytes += [double]$resolvedSizeBytes
            }
        }

        $usedCandidate = Get-FirstAvailablePropertyValue -Object $drive -PropertyNames @(
            'FileSize',
            'CurrentFileSize',
            'UsedSpace'
        )
        if ($null -eq $usedCandidate -and $null -ne $vhd) {
            $usedCandidate = Get-FirstAvailablePropertyValue -Object $vhd -PropertyNames @(
                'FileSize',
                'CurrentFileSize',
                'UsedSpace'
            )
        }
        $usedCandidateMb = Get-FirstAvailablePropertyValue -Object $drive -PropertyNames @('FileSizeMB', 'UsedSpaceMB')
        if ($null -eq $usedCandidateMb -and $null -ne $vhd) {
            $usedCandidateMb = Get-FirstAvailablePropertyValue -Object $vhd -PropertyNames @('FileSizeMB', 'UsedSpaceMB')
        }
        if ($null -ne $usedCandidate) {
            $resolvedUsedBytes = Convert-SizeValueToBytes -Value $usedCandidate -Unit 'Bytes'
            if ($resolvedUsedBytes -gt 0) {
                $usedBytes += [double]$resolvedUsedBytes
            }
        }
        elseif ($null -ne $usedCandidateMb) {
            $resolvedUsedBytes = Convert-SizeValueToBytes -Value $usedCandidateMb -Unit 'MB'
            if ($resolvedUsedBytes -gt 0) {
                $usedBytes += [double]$resolvedUsedBytes
            }
        }

        $path = Get-FirstAvailablePropertyValue -Object $drive -PropertyNames @('Location', 'Path')
        if ($null -eq $path -and $null -ne $vhd) {
            $path = Get-FirstAvailablePropertyValue -Object $vhd -PropertyNames @('Location', 'Path')
        }
        if ($null -ne $path) {
            # Extract host volume info for common Hyper-V paths.
            if ($path -match '^[A-Za-z]:\\ClusterStorage\\([^\\]+)') {
                $hostingVolumes += $matches[1]
            }
            elseif ($path -match '^[A-Za-z]:') {
                $hostingVolumes += $matches[0]
            }
            elseif ($path -match '^\\\\[^\\]+\\[^\\]+') {
                $hostingVolumes += $matches[0]
            }
            else {
                $hostingVolumes += $path
            }
        }
    }

    $diskProvisionedGb = if ($provisionedBytes -gt 0) { ConvertTo-GiB -Value $provisionedBytes -Unit 'Bytes' } else { $null }
    $diskUsedGb = if ($usedBytes -gt 0) { ConvertTo-GiB -Value $usedBytes -Unit 'Bytes' } else { $null }
    $hostingVolume = Join-UniqueValues -Values $hostingVolumes

    # Network: NIC count, IP addresses, and connected network names.
    $nicItems = Get-NicItems -Vm $vm
    $nicCount = @($nicItems).Count
    $ipAddresses = @()
    $networkNames = @()

    foreach ($nic in $nicItems) {
        $nicIps = Get-FirstAvailablePropertyValue -Object $nic -PropertyNames @('IPv4Addresses', 'IPAddresses', 'IPAddress')
        if ($null -ne $nicIps) {
            $ipAddresses += @($nicIps)
        }

        $networkName = Get-FirstAvailablePropertyValue -Object $nic -PropertyNames @('VMNetworkName', 'LogicalNetworkName')
        if ($null -eq $networkName) {
            $vmNetwork = Get-SafePropertyValue -Object $nic -PropertyName 'VMNetwork'
            $networkName = Get-SafePropertyValue -Object $vmNetwork -PropertyName 'Name'
        }
        if ($null -ne $networkName) {
            $networkNames += $networkName
        }
    }

    # Build an RVTools-like vInfo row plus extra requested fields.
    [pscustomobject]@{
        VM                    = Get-SafePropertyValue -Object $vm -PropertyName 'Name'
        PowerState            = Get-SafePropertyValue -Object $vm -PropertyName 'StatusString'
        OS                    = $operatingSystem
        CPUs                  = Get-SafePropertyValue -Object $vm -PropertyName 'CPUCount'
        MemoryGB              = $memoryGb
        MemoryMinGB           = $memoryMinGb
        MemoryMaxGB           = $memoryMaxGb
        DynamicMemory         = $dynamicMemoryEnabled
        Host                  = $hostName
        Cluster               = $clusterName
        Cloud                 = $cloudName
        HighlyAvailable       = Get-SafePropertyValue -Object $vm -PropertyName 'IsHighlyAvailable'
        CreationTime          = Get-SafePropertyValue -Object $vm -PropertyName 'CreationTime'
        Owner                 = Get-SafePropertyValue -Object $vm -PropertyName 'Owner'
        Description           = Get-SafePropertyValue -Object $vm -PropertyName 'Description'

        DiskProvisionedGB     = $diskProvisionedGb
        DiskUsedGB            = $diskUsedGb
        Firmware              = $firmwareType
        IntegrationServices   = $integrationServices
        NICCount              = $nicCount
        CPUCompatibilityMode  = $cpuCompatibilityEnabled
        IPAddresses           = Join-UniqueValues -Values $ipAddresses
        ConnectedNetworks     = Join-UniqueValues -Values $networkNames
        HardwareVersion       = $hardwareVersion
        HostingVolume         = $hostingVolume
    }
}

$rows |
    Sort-Object VM |
    Export-Csv -Path $OutputPath -Delimiter $Delimiter -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "VMs exported: $($rows.Count)"
