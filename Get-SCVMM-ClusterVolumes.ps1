<#
.SYNOPSIS
Exports cluster volumes and LUN-related details for SCVMM-managed Hyper-V clusters.

.DESCRIPTION
Connects to SCVMM to enumerate host clusters and cluster nodes. For each cluster,
this script tries to connect over WinRM to one SCVMM-managed host from that cluster,
then runs FailoverClusters/Storage cmdlets remotely to collect CSV/disk/LUN data.

If WinRM or required cmdlets are unavailable, the script falls back to exporting
basic volume-like information from SCVMM object properties.

.NOTES
- Requires the VirtualMachineManager module.
- Preferred collection path requires WinRM connectivity to at least one node per cluster.
- Advanced collection path requires FailoverClusters and Storage cmdlets on the remote host.
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
        [string]$DataSource,
        [string]$Comment
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
        Comment          = $Comment
    }
}

function Get-ClusterHostNames {
    param(
        [Parameter(Mandatory = $true)]
        $Cluster,

        [Parameter(Mandatory = $true)]
        [object[]]$AllHosts
    )

    $clusterName = $Cluster.Name
    $names = [System.Collections.Generic.List[string]]::new()

    foreach ($h in $AllHosts) {
        $hostCluster = Get-OptionalPropertyValue -Object $h -PropertyName 'HostCluster'
        if ($hostCluster -and $hostCluster.Name -eq $clusterName) {
            $names.Add($h.Name) | Out-Null
        }
    }

    $vmHosts = Get-OptionalPropertyValue -Object $Cluster -PropertyName 'VMHosts'
    if ($vmHosts) {
        foreach ($h in $vmHosts) {
            $name = Get-OptionalPropertyValue -Object $h -PropertyName 'Name'
            if ($name) {
                $names.Add($name) | Out-Null
            }
        }
    }

    return $names | Sort-Object -Unique
}

$remoteCollector = {
    param([string]$ClusterName)

    $clusterCmd = Get-Command -Name Get-ClusterSharedVolume -ErrorAction SilentlyContinue
    $volumeCmd = Get-Command -Name Get-Volume -ErrorAction SilentlyContinue
    $partitionCmd = Get-Command -Name Get-Partition -ErrorAction SilentlyContinue
    $diskCmd = Get-Command -Name Get-Disk -ErrorAction SilentlyContinue

    if (-not ($clusterCmd -and $volumeCmd -and $partitionCmd -and $diskCmd)) {
        return [pscustomobject]@{
            RecordType = 'Error'
            Error      = 'Missing one or more required cmdlets on remote host: Get-ClusterSharedVolume/Get-Volume/Get-Partition/Get-Disk.'
        }
    }

    $csvs = Get-ClusterSharedVolume -Cluster $ClusterName -ErrorAction SilentlyContinue
    if (-not $csvs) {
        return [pscustomobject]@{
            RecordType = 'Error'
            Error      = 'No Cluster Shared Volumes returned or cluster not reachable from remote host.'
        }
    }

    foreach ($csv in $csvs) {
        $ownerNode = if ($csv.OwnerNode) { $csv.OwnerNode.Name } else { $null }
        $volumeName = $csv.Name
        $sharedVolumeInfo = $csv.SharedVolumeInfo
        $volumePath = if ($sharedVolumeInfo) { $sharedVolumeInfo.FriendlyVolumeName } else { $null }
        $partitionPath = if ($sharedVolumeInfo -and $sharedVolumeInfo.Partition) { $sharedVolumeInfo.Partition.Name } else { $null }

        $diskNumber = $null
        $diskFriendlyName = $null
        $diskLocation = $null
        $diskSizeGb = $null
        $lun = $null

        if ($partitionPath) {
            $volume = Get-Volume -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $partitionPath } |
                Select-Object -First 1

            if ($volume) {
                $partition = Get-Partition -ErrorAction SilentlyContinue |
                    Where-Object { $_.AccessPaths -contains $volume.Path } |
                    Select-Object -First 1

                if ($partition) {
                    $diskNumber = $partition.DiskNumber
                    $disk = Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue

                    if ($disk) {
                        $diskFriendlyName = $disk.FriendlyName
                        $diskLocation = $disk.Location
                        $diskSizeGb = [math]::Round($disk.Size / 1GB, 2)

                        if ($diskLocation) {
                            $match = [regex]::Match($diskLocation, 'LUN\s*(\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                            if ($match.Success) {
                                $lun = [int]$match.Groups[1].Value
                            }
                        }
                    }
                }
            }
        }

        [pscustomobject]@{
            RecordType       = 'Volume'
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

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying host clusters from SCVMM...'
$clusters = Get-SCVMHostCluster -VMMServer $server
$allHosts = Get-SCVMHost -VMMServer $server

$rows = foreach ($cluster in $clusters) {
    $clusterName = $cluster.Name
    $hostNames = Get-ClusterHostNames -Cluster $cluster -AllHosts $allHosts

    $remoteResults = $null
    $remoteSource = $null

    foreach ($hostName in $hostNames) {
        if (-not (Test-WSMan -ComputerName $hostName -ErrorAction SilentlyContinue)) {
            continue
        }

        $remoteResults = Invoke-Command -ComputerName $hostName -ScriptBlock $remoteCollector -ArgumentList $clusterName -ErrorAction SilentlyContinue
        if ($remoteResults) {
            $remoteSource = $hostName
            break
        }
    }

    if ($remoteResults) {
        $errors = $remoteResults | Where-Object { $_.RecordType -eq 'Error' }
        $volumes = $remoteResults | Where-Object { $_.RecordType -eq 'Volume' }

        foreach ($item in $volumes) {
            New-VolumeRow -Cluster $clusterName -VolumeName $item.VolumeName -VolumePath $item.VolumePath -OwnerNode $item.OwnerNode -DiskNumber $item.DiskNumber -DiskFriendlyName $item.DiskFriendlyName -DiskLocation $item.DiskLocation -LUN $item.LUN -SizeGB $item.SizeGB -DataSource 'Remote-WinRM-FailoverClusters' -Comment "Collected from $remoteSource"
        }

        if (-not $volumes -and $errors) {
            foreach ($err in $errors) {
                New-VolumeRow -Cluster $clusterName -VolumeName $null -VolumePath $null -OwnerNode $null -DiskNumber $null -DiskFriendlyName $null -DiskLocation $null -LUN $null -SizeGB $null -DataSource 'Remote-WinRM-Error' -Comment $err.Error
            }
        }

        if ($volumes -or $errors) {
            continue
        }
    }

    # Fallback: SCVMM-only introspection.
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

            New-VolumeRow -Cluster $clusterName -VolumeName $name -VolumePath $path -OwnerNode $owner -DiskNumber $null -DiskFriendlyName $null -DiskLocation $null -LUN $null -SizeGB $null -DataSource 'SCVMM-Fallback' -Comment 'WinRM or required remote cmdlets unavailable'
            $generatedRows++
        }
    }

    if ($generatedRows -eq 0) {
        New-VolumeRow -Cluster $clusterName -VolumeName $null -VolumePath $null -OwnerNode $null -DiskNumber $null -DiskFriendlyName $null -DiskLocation $null -LUN $null -SizeGB $null -DataSource 'SCVMM-Fallback-NoVolumePropertyFound' -Comment 'No volume-like properties found on SCVMM cluster object'
    }
}

$rows |
    Sort-Object Cluster, VolumeName |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "Rows exported: $($rows.Count)"
