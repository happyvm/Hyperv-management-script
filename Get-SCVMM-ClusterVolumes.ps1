<#
.SYNOPSIS
Exports cluster volumes and LUN-related details for SCVMM-managed Hyper-V clusters.

.DESCRIPTION
Connects to SCVMM to enumerate host clusters and cluster nodes. For each cluster,
this script tries to connect over WinRM to one SCVMM-managed host from that cluster,
then runs FailoverClusters/Storage cmdlets in that node's local cluster context
to collect CSV/disk/LUN data.
WinRM targets prefer FQDN host names when available.

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

        [AllowNull()]
        [object[]]$AllHosts = @()
    )

    $clusterName = $Cluster.Name
    $names = [System.Collections.Generic.List[string]]::new()

    function Add-HostConnectionNames {
        param(
            [Parameter(Mandatory = $true)]
            $HostObject
        )

        $results = [System.Collections.Generic.List[string]]::new()

        foreach ($propertyName in @('FullyQualifiedDomainName', 'FQDN', 'ComputerName', 'Name')) {
            $value = Get-OptionalPropertyValue -Object $HostObject -PropertyName $propertyName
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                $results.Add([string]$value) | Out-Null
            }
        }

        return $results
    }

    foreach ($h in $AllHosts) {
        $hostCluster = Get-OptionalPropertyValue -Object $h -PropertyName 'HostCluster'
        if ($hostCluster -and $hostCluster.Name -eq $clusterName) {
            foreach ($candidateName in (Add-HostConnectionNames -HostObject $h)) {
                $names.Add($candidateName) | Out-Null
            }
        }
    }

    $vmHosts = Get-OptionalPropertyValue -Object $Cluster -PropertyName 'VMHosts'
    if ($vmHosts) {
        foreach ($h in $vmHosts) {
            foreach ($candidateName in (Add-HostConnectionNames -HostObject $h)) {
                $names.Add($candidateName) | Out-Null
            }
        }
    }

    return $names |
        Sort-Object -Unique @{
            Expression = {
                if ($_ -like '*.*') { 0 } else { 1 }
            }
        }, @{
            Expression = { $_ }
        }
}

$remoteCollector = {
    param([string]$ExpectedClusterName)

    function Normalize-ClusterName {
        param([AllowNull()][string]$Name)

        if ([string]::IsNullOrWhiteSpace($Name)) {
            return $null
        }

        return $Name.Trim().ToLowerInvariant()
    }

    function Get-ShortClusterName {
        param([AllowNull()][string]$Name)

        $normalized = Normalize-ClusterName -Name $Name
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            return $null
        }

        $dotIndex = $normalized.IndexOf('.')
        if ($dotIndex -gt 0) {
            return $normalized.Substring(0, $dotIndex)
        }

        return $normalized
    }

    function Get-PreferredLunId {
        param(
            [Parameter(Mandatory = $true)]
            $Disk
        )

        $isPureStorageDisk = $false
        foreach ($propertyName in @('FriendlyName', 'Model', 'Location', 'Path')) {
            $value = $Disk.$propertyName
            if (-not [string]::IsNullOrWhiteSpace([string]$value) -and [string]$value -match 'pure') {
                $isPureStorageDisk = $true
                break
            }
        }

        # For Pure Storage volumes, prefer serial because it aligns better with array-side volume identity.
        if ($isPureStorageDisk -and -not [string]::IsNullOrWhiteSpace([string]$Disk.SerialNumber)) {
            return [string]$Disk.SerialNumber
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$Disk.UniqueId)) {
            return [string]$Disk.UniqueId
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$Disk.SerialNumber)) {
            return [string]$Disk.SerialNumber
        }

        return $null
    }

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

    $cluster = Get-Cluster -ErrorAction SilentlyContinue
    if (-not $cluster) {
        return [pscustomobject]@{
            RecordType = 'Error'
            Error      = 'Unable to resolve local cluster context on remote host.'
        }
    }

    $actualClusterName = Normalize-ClusterName -Name $cluster.Name
    $expectedClusterNameNormalized = Normalize-ClusterName -Name $ExpectedClusterName
    $actualClusterShortName = Get-ShortClusterName -Name $cluster.Name
    $expectedClusterShortName = Get-ShortClusterName -Name $ExpectedClusterName

    $namesMatch =
        $expectedClusterNameNormalized -and
        (
            $actualClusterName -eq $expectedClusterNameNormalized -or
            $actualClusterShortName -eq $expectedClusterShortName
        )

    if ($ExpectedClusterName -and (-not $namesMatch)) {
        return [pscustomobject]@{
            RecordType = 'Error'
            Error      = "Connected node belongs to cluster '$($cluster.Name)' but expected '$ExpectedClusterName'."
        }
    }

    $csvs = Get-ClusterSharedVolume -ErrorAction SilentlyContinue
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
                        $lun = Get-PreferredLunId -Disk $disk
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
