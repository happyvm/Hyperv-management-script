<#
.SYNOPSIS
Exports IP addresses used by each Hyper-V node managed by SCVMM.

.DESCRIPTION
Connects to SCVMM, enumerates Hyper-V hosts (nodes), attempts to discover their
IP addresses from SCVMM-exposed host properties and host network adapter data,
and exports the result to CSV.

.NOTES
- Requires the VirtualMachineManager PowerShell module.
- Output contains one row per node/IP pair.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMMServer,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = '.\\SCVMM-ClusterNodeIPs.csv'
)

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

function Get-IpValues {
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            foreach ($nestedIp in (Get-IpValues -Value $item)) {
                $results.Add($nestedIp) | Out-Null
            }
        }
        return $results.ToArray()
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    # Keep only valid IPv4/IPv6 values.
    if ($text -as [System.Net.IPAddress]) {
        return @($text)
    }

    return @()
}

function Get-NetworkRoleFromText {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$TextValues
    )

    $text = (($TextValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'Node'
    }

    if ($text -match 'live[\s\-_]*migration|\blm\b') {
        return 'LiveMigration'
    }

    if ($text -match 'cluster|heartbeat|csv') {
        return 'ClusterTraffic'
    }

    if ($text -match 'admin|mgmt|management|host') {
        return 'Admin'
    }

    return 'Node'
}

function Add-IpEntry {
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[psobject]]$List,

        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$KeySet,

        [Parameter(Mandatory = $true)]
        [string]$Cluster,

        [Parameter(Mandatory = $true)]
        [string]$Node,

        [Parameter(Mandatory = $true)]
        [string]$IP,

        [Parameter(Mandatory = $true)]
        [string]$Role
    )

    if ([string]::IsNullOrWhiteSpace($IP)) {
        return
    }

    $key = "$Cluster|$Node|$IP|$Role"
    if (-not $KeySet.Add($key)) {
        return
    }

    $List.Add([pscustomobject]@{
            Cluster = $Cluster
            Node    = $Node
            IP      = $IP
            Role    = $Role
        }) | Out-Null
}

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying Hyper-V hosts (nodes) from SCVMM...'
$vmHosts = @(Get-SCVMHost -VMMServer $server)

$hostNetworkAdapterCmd = Get-Command -Name Get-SCVMHostNetworkAdapter -ErrorAction SilentlyContinue

$rows = foreach ($vmHost in $vmHosts) {
    $hostCluster = Get-OptionalPropertyValue -Object $vmHost -PropertyName 'HostCluster'
    $clusterName = if ($hostCluster -and $hostCluster.Name) { $hostCluster.Name } else { 'Standalone' }

    $entries = [System.Collections.Generic.List[psobject]]::new()
    $entryKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Collect candidate IP values from common SCVMM host properties.
    foreach ($propertyName in @('IPAddress', 'IPAddresses', 'IPv4Addresses', 'IPv6Addresses', 'ManagementIPAddress')) {
        if ($vmHost.PSObject.Properties.Name -contains $propertyName) {
            foreach ($ipValue in (Get-IpValues -Value $vmHost.$propertyName)) {
                Add-IpEntry -List $entries -KeySet $entryKeys -Cluster $clusterName -Node $vmHost.Name -IP $ipValue -Role 'Admin'
            }
        }
    }

    # Try to capture cluster IPs, if present on the cluster object.
    if ($hostCluster) {
        foreach ($clusterIpProperty in @('IPAddress', 'IPAddresses', 'IPv4Addresses', 'IPv6Addresses', 'ClusterIPAddress', 'ManagementIPAddress', 'VirtualIPAddress')) {
            if ($hostCluster.PSObject.Properties.Name -contains $clusterIpProperty) {
                foreach ($ipValue in (Get-IpValues -Value $hostCluster.$clusterIpProperty)) {
                    Add-IpEntry -List $entries -KeySet $entryKeys -Cluster $clusterName -Node '(cluster)' -IP $ipValue -Role 'Cluster'
                }
            }
        }
    }

    # Collect candidate IP values from SCVMM host network adapter objects if cmdlet exists.
    if ($hostNetworkAdapterCmd) {
        $adapters = @(Get-SCVMHostNetworkAdapter -VMHost $vmHost -ErrorAction SilentlyContinue)
        foreach ($adapter in $adapters) {
            $role = Get-NetworkRoleFromText -TextValues @(
                [string](Get-OptionalPropertyValue -Object $adapter -PropertyName 'Name'),
                [string](Get-OptionalPropertyValue -Object $adapter -PropertyName 'Description'),
                [string](Get-OptionalPropertyValue -Object $adapter -PropertyName 'ConnectionName'),
                [string](Get-OptionalPropertyValue -Object $adapter -PropertyName 'LogicalNetwork'),
                [string](Get-OptionalPropertyValue -Object $adapter -PropertyName 'VMNetwork')
            )

            foreach ($propertyName in @('IPAddress', 'IPAddresses', 'IPv4Addresses', 'IPv6Addresses')) {
                if ($adapter.PSObject.Properties.Name -contains $propertyName) {
                    foreach ($ipValue in (Get-IpValues -Value $adapter.$propertyName)) {
                        Add-IpEntry -List $entries -KeySet $entryKeys -Cluster $clusterName -Node $vmHost.Name -IP $ipValue -Role $role
                    }
                }
            }
        }
    }

    if ($entries.Count -eq 0) {
        [pscustomobject]@{
            Cluster = $clusterName
            Node    = $vmHost.Name
            IP      = $null
            Role    = 'Unknown'
        }
        continue
    }

    $entries
}

$rows = @($rows | Where-Object { $null -ne $_ })

$rows |
    Sort-Object Cluster, Node, Role, IP -Unique |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "Rows exported: $($rows.Count)"
