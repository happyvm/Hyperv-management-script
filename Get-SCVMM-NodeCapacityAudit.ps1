<#
.SYNOPSIS
Audite la capacité restante CPU/RAM/stockage de chaque nœud Hyper-V dans SCVMM.

.DESCRIPTION
Se connecte au serveur SCVMM, récupère les hôtes Hyper-V (nœuds) et exporte:
- CPU physique total (processeurs logiques)
- vCPU alloués aux VM du nœud
- CPU restant (indicatif = CPU physique - vCPU alloués)
- RAM totale, allouée et disponible
- Espace disque total/alloué/disponible (agrégé sur les volumes hôte)

Le script est défensif vis-à-vis des différences de propriétés SCVMM selon versions.

.NOTES
- Module requis: VirtualMachineManager
- Recommandé: exécuter avec un compte ayant des droits de lecture sur SCVMM
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMMServer,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = '.\\SCVMM-NodeCapacityAudit.csv',

    [Parameter(Mandatory = $false)]
    [ValidateSet(';', ',')]
    [string]$Delimiter = ';'
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

    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $PropertyName) {
        return $Object.$PropertyName
    }

    return $null
}

function Convert-ToGB {
    param(
        [AllowNull()]$Value,
        [double]$Divisor = 1GB
    )

    if ($null -eq $Value) { return $null }

    try {
        return [Math]::Round(([double]$Value / $Divisor), 2)
    }
    catch {
        return $null
    }
}

function Convert-MBToBytes {
    param(
        [AllowNull()]$Value
    )

    if ($null -eq $Value) { return $null }

    try {
        return [double]$Value * 1MB
    }
    catch {
        return $null
    }
}

function Get-FirstNonNull {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    foreach ($name in $PropertyNames) {
        $value = Get-OptionalPropertyValue -Object $Object -PropertyName $name
        if ($null -ne $value) {
            return $value
        }
    }

    return $null
}

function Get-NormalizedHostShortName {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return $Value.Trim().ToLowerInvariant().Split('.')[0]
}

Import-Module VirtualMachineManager -ErrorAction Stop

Write-Verbose "Connexion à SCVMM: $VMMServer"
$null = Get-SCVMMServer -ComputerName $VMMServer

# Récupère tous les hôtes Hyper-V connus de SCVMM
$hosts = @(Get-SCVMHost)
if ($hosts.Count -eq 0) {
    Write-Warning 'Aucun hôte SCVMM trouvé.'
    @() | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter
    Write-Host "CSV vide exporté: $OutputPath"
    return
}

# Récupère les VM une fois pour limiter les appels
$allVMs = @(Get-SCVirtualMachine)

$rows = foreach ($nodeHost in $hosts) {
    $hostName = [string](Get-FirstNonNull -Object $nodeHost -PropertyNames @('ComputerName', 'FullyQualifiedDomainName', 'Name'))
    $clusterObj = Get-OptionalPropertyValue -Object $nodeHost -PropertyName 'HostCluster'
    $clusterName = if ($clusterObj) { [string]$clusterObj.Name } else { '' }

    # CPU physique
    $logicalCpu = Get-FirstNonNull -Object $nodeHost -PropertyNames @('LogicalProcessorCount', 'NumberOfLogicalProcessors', 'ProcessorCount')

    # RAM hôte
    $totalMemoryBytes = Get-FirstNonNull -Object $nodeHost -PropertyNames @('TotalMemory', 'Memory', 'MemoryCapacity')
    $availableMemoryBytes = Get-FirstNonNull -Object $nodeHost -PropertyNames @('AvailableMemory', 'MemoryAvailable', 'AvailableHostMemory')

    # Certaines versions exposent la mémoire en MB
    if ($null -eq $totalMemoryBytes) {
        $totalMemoryMB = Get-FirstNonNull -Object $nodeHost -PropertyNames @('TotalMemoryMB', 'MemoryMB')
        if ($null -ne $totalMemoryMB) {
            $totalMemoryBytes = Convert-MBToBytes -Value $totalMemoryMB
        }
    }
    if ($null -eq $availableMemoryBytes) {
        $availableMemoryMB = Get-FirstNonNull -Object $nodeHost -PropertyNames @('AvailableMemoryMB', 'MemoryAvailableMB', 'AvailableHostMemoryMB')
        if ($null -ne $availableMemoryMB) {
            $availableMemoryBytes = Convert-MBToBytes -Value $availableMemoryMB
        }
    }

    # VM rattachées à ce nœud
    $hostVMs = @(
        $allVMs | Where-Object {
            $vmHost = Get-OptionalPropertyValue -Object $_ -PropertyName 'VMHost'
            $vmHostName = if ($vmHost) { [string](Get-FirstNonNull -Object $vmHost -PropertyNames @('ComputerName', 'Name')) } else { '' }
            $normalizedHostName = Get-NormalizedHostShortName -Value $hostName
            $normalizedVmHostName = Get-NormalizedHostShortName -Value $vmHostName
            $hostFqdnLower = if ([string]::IsNullOrWhiteSpace($hostName)) { '' } else { $hostName.Trim().ToLowerInvariant() }
            $vmHostFqdnLower = if ([string]::IsNullOrWhiteSpace($vmHostName)) { '' } else { $vmHostName.Trim().ToLowerInvariant() }

            (
                -not [string]::IsNullOrWhiteSpace($normalizedHostName) -and
                -not [string]::IsNullOrWhiteSpace($normalizedVmHostName) -and
                $normalizedVmHostName -eq $normalizedHostName
            ) -or (
                -not [string]::IsNullOrWhiteSpace($hostFqdnLower) -and
                -not [string]::IsNullOrWhiteSpace($vmHostFqdnLower) -and
                $vmHostFqdnLower -eq $hostFqdnLower
            )
        }
    )

    [int]$allocatedvCPU = 0
    [double]$allocatedMemoryBytes = 0

    foreach ($vm in $hostVMs) {
        $cpuCount = Get-FirstNonNull -Object $vm -PropertyNames @('CPUCount', 'VirtualCPUCount')
        if ($null -ne $cpuCount) {
            $allocatedvCPU += [int]$cpuCount
        }

        $vmMemBytes = Get-FirstNonNull -Object $vm -PropertyNames @('Memory', 'MemoryAssigned', 'MemoryDemand')
        if ($null -eq $vmMemBytes) {
            $vmMemMB = Get-FirstNonNull -Object $vm -PropertyNames @('MemoryMB', 'MemoryAssignedMB', 'MemoryDemandMB', 'StartupMemory', 'DynamicMemoryMaximumMB')
            if ($null -ne $vmMemMB) {
                $vmMemBytes = Convert-MBToBytes -Value $vmMemMB
            }
        }

        if ($null -ne $vmMemBytes) {
            $allocatedMemoryBytes += [double]$vmMemBytes
        }
    }

    $remainingCPU = $null
    if ($null -ne $logicalCpu) {
        $remainingCPU = [int]$logicalCpu - [int]$allocatedvCPU
    }

    [Nullable[double]]$totalDiskBytes = $null
    [Nullable[double]]$freeDiskBytes = $null

    # 1) Voie privilégiée: cmdlet SCVMM si disponible
    $volumes = @()
    if (Get-Command -Name Get-SCVMHostVolume -ErrorAction SilentlyContinue) {
        try {
            $volumes = @(Get-SCVMHostVolume -VMHost $nodeHost)
        }
        catch {
            $volumes = @()
        }
    }

    # 2) Fallback: propriétés embarquées sur l'objet host
    if ($volumes.Count -eq 0) {
        $embeddedVolumes = Get-FirstNonNull -Object $nodeHost -PropertyNames @('Volumes', 'VMHostVolumes', 'StorageVolumes')
        if ($embeddedVolumes) {
            $volumes = @($embeddedVolumes)
        }
    }

    foreach ($volume in $volumes) {
        $sizeBytes = Get-FirstNonNull -Object $volume -PropertyNames @('Capacity', 'Size', 'TotalCapacity', 'TotalSize')
        $freeBytes = Get-FirstNonNull -Object $volume -PropertyNames @('FreeSpace', 'AvailableSpace', 'AvailableCapacity')

        if ($null -ne $sizeBytes) {
            if ($null -eq $totalDiskBytes) { $totalDiskBytes = 0.0 }
            $totalDiskBytes += [double]$sizeBytes
        }
        if ($null -ne $freeBytes) {
            if ($null -eq $freeDiskBytes) { $freeDiskBytes = 0.0 }
            $freeDiskBytes += [double]$freeBytes
        }
    }

    # 3) Fallback host-level properties (souvent exposées en MB)
    if ($null -eq $totalDiskBytes) {
        $hostTotalDisk = Get-FirstNonNull -Object $nodeHost -PropertyNames @('TotalStorageCapacity', 'StorageCapacity', 'DiskSpaceCapacity')
        if ($null -ne $hostTotalDisk) {
            $totalDiskBytes = [double]$hostTotalDisk
        }
        else {
            $hostTotalDiskMB = Get-FirstNonNull -Object $nodeHost -PropertyNames @('TotalStorageCapacityMB', 'StorageCapacityMB', 'DiskSpaceCapacityMB')
            if ($null -ne $hostTotalDiskMB) {
                $totalDiskBytes = Convert-MBToBytes -Value $hostTotalDiskMB
            }
        }
    }

    if ($null -eq $freeDiskBytes) {
        $hostFreeDisk = Get-FirstNonNull -Object $nodeHost -PropertyNames @('AvailableStorageCapacity', 'StorageAvailable', 'DiskSpaceAvailable')
        if ($null -ne $hostFreeDisk) {
            $freeDiskBytes = [double]$hostFreeDisk
        }
        else {
            $hostFreeDiskMB = Get-FirstNonNull -Object $nodeHost -PropertyNames @('AvailableStorageCapacityMB', 'StorageAvailableMB', 'DiskSpaceAvailableMB')
            if ($null -ne $hostFreeDiskMB) {
                $freeDiskBytes = Convert-MBToBytes -Value $hostFreeDiskMB
            }
        }
    }

    $allocatedDiskBytes = $null
    if (($null -ne $totalDiskBytes) -and ($null -ne $freeDiskBytes)) {
        $allocatedDiskBytes = [double]$totalDiskBytes - [double]$freeDiskBytes
    }

    [pscustomobject]@{
        Cluster                 = $clusterName
        Node                    = $hostName
        CPU_Logical_Total       = $logicalCpu
        CPU_vCPU_Allocated      = $allocatedvCPU
        CPU_Logical_Remaining   = $remainingCPU
        RAM_Total_GB            = Convert-ToGB -Value $totalMemoryBytes
        RAM_Allocated_GB        = Convert-ToGB -Value $allocatedMemoryBytes
        RAM_Available_GB        = Convert-ToGB -Value $availableMemoryBytes
        Disk_Total_GB           = if ($null -ne $totalDiskBytes) { Convert-ToGB -Value $totalDiskBytes } else { $null }
        Disk_Allocated_GB       = if ($null -ne $allocatedDiskBytes) { Convert-ToGB -Value $allocatedDiskBytes } else { $null }
        Disk_Available_GB       = if ($null -ne $freeDiskBytes) { Convert-ToGB -Value $freeDiskBytes } else { $null }
        VM_Count                = $hostVMs.Count
    }
}

$rows |
    Sort-Object Cluster, Node |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter

Write-Host "Audit exporté: $OutputPath"
