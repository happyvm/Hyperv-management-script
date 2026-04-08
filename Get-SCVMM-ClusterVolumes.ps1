<#
.SYNOPSIS
Exports cluster volumes and LUN-related details for SCVMM-managed Hyper-V clusters.

.DESCRIPTION
Connects to SCVMM to enumerate host clusters and exports volume details.
When Failover Clustering cmdlets are available, the script resolves CSV disk
metadata and derives LUN from disk location text.
When Failover Clustering cmdlets are not available, it still exports basic
cluster/volume information using SCVMM object properties.

.NOTES
- Requires the VirtualMachineManager module.
- For advanced CSV + disk/LUN resolution, install/enable FailoverClusters and Storage cmdlets.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMMServer,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = '.\SCVMM-ClusterVolumes.csv'
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

function Resolve-LunFromLocation {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Location
    )

    if ([string]::IsNullOrWhiteSpace($Location)) {
        return $null
    }

    $match = [regex]::Match($Location, 'LUN\s*(\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return [int]$match.Groups[1].Value
    }

    return $null
}

function New-VolumeRow {
    param(
        [string]$Cluster,
        [string]$VolumeName,
        [string]$VolumePath,
        [string]$OwnerNode,
        $DiskNumber,
        [string]$DiskFriendlyName,
        [string]$DiskLocation,
        $LUN,
        $SizeGB,
        [string]$DataSource
    )

    [pscustomobject]@{
        Cluster          = $Cluster
        VolumeName       = $VolumeName
        VolumePath       = $VolumePath
        OwnerNode        = $OwnerNode
        DiskNumber       = $DiskNumber
        DiskFriendlyName = $DiskFriendlyName
        DiskLocation     = $DiskLocation
        LUN              = $LUN
        SizeGB           = $SizeGB
        DataSource       = $DataSource
    }
}

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying host clusters from SCVMM...'
$clusters = Get-SCVMHostCluster -VMMServer $server

$clusterCmd = Get-Command -Name Get-ClusterSharedVolume -ErrorAction SilentlyContinue
$volumeCmd = Get-Command -Name Get-Volume -ErrorAction SilentlyContinue
$partitionCmd = Get-Command -Name Get-Partition -ErrorAction SilentlyContinue
$diskCmd = Get-Command -Name Get-Disk -ErrorAction SilentlyContinue

$canDoAdvanced = $null -ne $clusterCmd -and $null -ne $volumeCmd -and $null -ne $partitionCmd -and $null -ne $diskCmd

if (-not $clusterCmd) {
    Write-Warning 'Get-ClusterSharedVolume cmdlet not found. Falling back to SCVMM cluster object properties (basic output only).'
}

$rows = foreach ($cluster in $clusters) {
    $clusterName = $cluster.Name

    if ($canDoAdvanced) {
        $csvs = Get-ClusterSharedVolume -Cluster $clusterName -ErrorAction SilentlyContinue

        foreach ($csv in $csvs) {
            $ownerNodeObj = Get-OptionalPropertyValue -Object $csv -PropertyName 'OwnerNode'
            $ownerNode = if ($ownerNodeObj -and $ownerNodeObj.Name) { $ownerNodeObj.Name } else { $null }
            $volumeName = Get-OptionalPropertyValue -Object $csv -PropertyName 'Name'

            $sharedVolumeInfo = Get-OptionalPropertyValue -Object $csv -PropertyName 'SharedVolumeInfo'
            $partitionObj = Get-OptionalPropertyValue -Object $sharedVolumeInfo -PropertyName 'Partition'
            $volumePath = Get-OptionalPropertyValue -Object $sharedVolumeInfo -PropertyName 'FriendlyVolumeName'
            $partitionPath = Get-OptionalPropertyValue -Object $partitionObj -PropertyName 'Name'

            $diskNumber = $null
            $diskFriendlyName = $null
            $diskLocation = $null
            $diskSizeGb = $null
            $lun = $null

            if ($ownerNode -and $partitionPath) {
                $cim = New-CimSession -ComputerName $ownerNode
                try {
                    $volume = Get-Volume -CimSession $cim -ErrorAction SilentlyContinue |
                        Where-Object { $_.Path -eq $partitionPath } |
                        Select-Object -First 1

                    if ($volume) {
                        $partition = Get-Partition -CimSession $cim -ErrorAction SilentlyContinue |
                            Where-Object { $_.AccessPaths -contains $volume.Path } |
                            Select-Object -First 1

                        if ($partition) {
                            $diskNumber = $partition.DiskNumber

                            $disk = Get-Disk -CimSession $cim -Number $diskNumber -ErrorAction SilentlyContinue
                            if ($disk) {
                                $diskFriendlyName = $disk.FriendlyName
                                $diskLocation = $disk.Location
                                $diskSizeGb = [math]::Round($disk.Size / 1GB, 2)
                                $lun = Resolve-LunFromLocation -Location $diskLocation
                            }
                        }
                    }
                }
                finally {
                    Remove-CimSession -CimSession $cim -ErrorAction SilentlyContinue
                }
            }

            New-VolumeRow -Cluster $clusterName -VolumeName $volumeName -VolumePath $volumePath -OwnerNode $ownerNode -DiskNumber $diskNumber -DiskFriendlyName $diskFriendlyName -DiskLocation $diskLocation -LUN $lun -SizeGB $diskSizeGb -DataSource 'FailoverClusters+Storage'
        }

        continue
    }

    # Basic fallback: extract whatever volume-like info exists directly on SCVMM cluster object.
    $fallbackVolumeLists = @('SharedVolumes', 'ClusterSharedVolumes', 'Volumes', 'StorageVolumes')
    $generatedRows = 0

    foreach ($listProperty in $fallbackVolumeLists) {
        $volumeList = Get-OptionalPropertyValue -Object $cluster -PropertyName $listProperty
        if ($null -eq $volumeList) {
            continue
        }

        foreach ($item in $volumeList) {
            $name = Get-OptionalPropertyValue -Object $item -PropertyName 'Name'
            if (-not $name) {
                $name = [string]$item
            }

            $path = Get-OptionalPropertyValue -Object $item -PropertyName 'Path'
            $owner = Get-OptionalPropertyValue -Object $item -PropertyName 'OwnerNode'
            if ($owner -and $owner.PSObject.Properties.Name -contains 'Name') {
                $owner = $owner.Name
            }

            New-VolumeRow -Cluster $clusterName -VolumeName $name -VolumePath $path -OwnerNode $owner -DiskNumber $null -DiskFriendlyName $null -DiskLocation $null -LUN $null -SizeGB $null -DataSource 'SCVMM-Fallback'
            $generatedRows++
        }
    }

    if ($generatedRows -eq 0) {
        New-VolumeRow -Cluster $clusterName -VolumeName $null -VolumePath $null -OwnerNode $null -DiskNumber $null -DiskFriendlyName $null -DiskLocation $null -LUN $null -SizeGB $null -DataSource 'SCVMM-Fallback-NoVolumePropertyFound'
    }
}

$rows |
    Sort-Object Cluster, VolumeName |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "Rows exported: $($rows.Count)"
