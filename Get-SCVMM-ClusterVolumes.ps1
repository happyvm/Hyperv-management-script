<#
.SYNOPSIS
Exports cluster volumes (CSV) and LUN-related details for SCVMM-managed Hyper-V clusters.

.DESCRIPTION
Connects to SCVMM to enumerate host clusters, then uses Failover Clustering and
Storage cmdlets to resolve each cluster shared volume with:
- Volume name
- Volume path
- Disk number
- Disk metadata
- LUN value (derived from disk location when available)

.NOTES
- Requires the VirtualMachineManager module.
- Requires the FailoverClusters and Storage modules on the machine running the script.
- The script must be run with permissions to query clusters and nodes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMMServer,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = '.\\SCVMM-ClusterVolumes.csv'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying host clusters from SCVMM...'
$clusters = Get-SCVMHostCluster -VMMServer $server

$rows = foreach ($cluster in $clusters) {
    $clusterName = $cluster.Name

    Write-Verbose "Querying CSV volumes on cluster '$clusterName'..."
    $csvs = Get-ClusterSharedVolume -Cluster $clusterName -ErrorAction SilentlyContinue

    foreach ($csv in $csvs) {
        $ownerNode = if ($csv.OwnerNode) { $csv.OwnerNode.Name } else { $null }
        $volumeName = $csv.Name
        $volumePath = $csv.SharedVolumeInfo.FriendlyVolumeName
        $partitionPath = $csv.SharedVolumeInfo.Partition.Name

        $diskNumber = $null
        $diskFriendlyName = $null
        $diskLocation = $null
        $diskSizeGb = $null
        $lun = $null

        if ($ownerNode) {
            $cim = New-CimSession -ComputerName $ownerNode
            try {
                # Match the CSV partition by its unique volume GUID path.
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

        [pscustomobject]@{
            Cluster          = $clusterName
            VolumeName       = $volumeName
            VolumePath       = $volumePath
            OwnerNode        = $ownerNode
            DiskNumber       = $diskNumber
            DiskFriendlyName = $diskFriendlyName
            DiskLocation     = $diskLocation
            LUN              = $lun
            SizeGB           = $diskSizeGb
        }
    }
}

$rows |
    Sort-Object Cluster, VolumeName |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "Rows exported: $($rows.Count)"
