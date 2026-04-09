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
    $totalMemoryBytes = Get-FirstNonNull -Object $nodeHost -PropertyNames @('TotalMemory', 'Memory')
    $availableMemoryBytes = Get-FirstNonNull -Object $nodeHost -PropertyNames @('AvailableMemory', 'MemoryAvailable')

    # Certaines versions exposent la mémoire en MB
    if ($null -eq $totalMemoryBytes) {
        $totalMemoryMB = Get-FirstNonNull -Object $nodeHost -PropertyNames @('TotalMemoryMB', 'MemoryMB')
        if ($null -ne $totalMemoryMB) {
            $totalMemoryBytes = [double]$totalMemoryMB * 1MB
        }
    }
    if ($null -eq $availableMemoryBytes) {
        $availableMemoryMB = Get-FirstNonNull -Object $nodeHost -PropertyNames @('AvailableMemoryMB', 'MemoryAvailableMB')
        if ($null -ne $availableMemoryMB) {
            $availableMemoryBytes = [double]$availableMemoryMB * 1MB
        }
    }

    # VM rattachées à ce nœud
    $hostVMs = @(
        $allVMs | Where-Object {
            $vmHost = Get-OptionalPropertyValue -Object $_ -PropertyName 'VMHost'
            $vmHostName = if ($vmHost) { [string](Get-FirstNonNull -Object $vmHost -PropertyNames @('ComputerName', 'Name')) } else { '' }
            $vmHostName -eq $hostName
        }
    )

    [int]$allocatedvCPU = 0
    [double]$allocatedMemoryBytes = 0

    foreach ($vm in $hostVMs) {
        $cpuCount = Get-FirstNonNull -Object $vm -PropertyNames @('CPUCount', 'VirtualCPUCount')
        if ($null -ne $cpuCount) {
            $allocatedvCPU += [int]$cpuCount
        }

        $vmMemBytes = Get-FirstNonNull -Object $vm -PropertyNames @('Memory', 'MemoryAssigned')
        if ($null -eq $vmMemBytes) {
            $vmMemMB = Get-FirstNonNull -Object $vm -PropertyNames @('MemoryMB', 'StartupMemory')
            if ($null -ne $vmMemMB) {
                $vmMemBytes = [double]$vmMemMB * 1MB
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

    $totalDiskBytes = 0.0
    $freeDiskBytes = 0.0

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

        if ($null -ne $sizeBytes) { $totalDiskBytes += [double]$sizeBytes }
        if ($null -ne $freeBytes) { $freeDiskBytes += [double]$freeBytes }
    }

    $allocatedDiskBytes = $null
    if ($totalDiskBytes -gt 0) {
        $allocatedDiskBytes = $totalDiskBytes - $freeDiskBytes
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
        Disk_Total_GB           = if ($totalDiskBytes -gt 0) { Convert-ToGB -Value $totalDiskBytes } else { $null }
        Disk_Allocated_GB       = if ($null -ne $allocatedDiskBytes) { Convert-ToGB -Value $allocatedDiskBytes } else { $null }
        Disk_Available_GB       = if ($freeDiskBytes -gt 0) { Convert-ToGB -Value $freeDiskBytes } else { $null }
        VM_Count                = $hostVMs.Count
    }
}

$rows |
    Sort-Object Cluster, Node |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter

Write-Host "Audit exporté: $OutputPath"
