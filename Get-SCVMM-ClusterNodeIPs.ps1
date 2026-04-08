<#
.SYNOPSIS
Exports IP addresses used by each Hyper-V node managed by SCVMM.

.DESCRIPTION
Connects to SCVMM, enumerates Hyper-V hosts (nodes), attempts to discover their
IP addresses from SCVMM-exposed host properties and host network adapter data,
and exports the result to CSV.

.NOTES
- Requires the VirtualMachineManager PowerShell module.
- Output contains one row per node, with role-based IP columns.
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

    if ($Value -is [psobject] -and $Value -isnot [string]) {
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($propertyName in @('IPAddress', 'IPAddresses', 'IPv4Address', 'IPv6Address', 'IPv4Addresses', 'IPv6Addresses', 'Address', 'Addresses')) {
            if ($Value.PSObject.Properties.Name -contains $propertyName) {
                foreach ($nestedIp in (Get-IpValues -Value $Value.$propertyName)) {
                    $results.Add($nestedIp) | Out-Null
                }
            }
        }

        if ($results.Count -gt 0) {
            return $results.ToArray()
        }
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    $resultSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Direct value first (single IP case).
    if ($text -as [System.Net.IPAddress]) {
        [void]$resultSet.Add($text)
    }

    # Also parse lists and embedded text containing IP tokens.
    foreach ($token in ($text -split '[,\s;]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($token -as [System.Net.IPAddress]) {
            [void]$resultSet.Add($token)
        }
    }

    if ($resultSet.Count -gt 0) {
        return $resultSet.ToArray()
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

    if ($text -match 'cluster|heartbeat|csv|storage') {
        return 'ClusterTraffic'
    }

    if ($text -match 'admin|mgmt|management|host') {
        return 'Admin'
    }

    return 'Node'
}

function Add-IpToSet {
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$Set,

        [Parameter(Mandatory = $false)]
        $Values
    )

    foreach ($ip in (Get-IpValues -Value $Values)) {
        if (-not [string]::IsNullOrWhiteSpace($ip)) {
            [void]$Set.Add($ip)
        }
    }
}

function Join-IpSet {
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$Set
    )

    if ($Set.Count -eq 0) {
        return $null
    }

    return (@($Set | Sort-Object) -join ';')
}

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying Hyper-V hosts (nodes) from SCVMM...'
$vmHosts = @(Get-SCVMHost -VMMServer $server)

$hostNetworkAdapterCmd = Get-Command -Name Get-SCVMHostNetworkAdapter -ErrorAction SilentlyContinue

$rows = foreach ($vmHost in $vmHosts) {
    $hostCluster = Get-OptionalPropertyValue -Object $vmHost -PropertyName 'HostCluster'
    $clusterName = if ($hostCluster -and $hostCluster.Name) { $hostCluster.Name } else { 'Standalone' }

    $adminIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $liveMigrationIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $clusterTrafficIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $nodeIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $clusterIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Host properties map primarily to admin/management addressing.
    foreach ($propertyName in @('IPAddress', 'IPAddresses', 'IPv4Addresses', 'IPv6Addresses', 'ManagementIPAddress')) {
        if ($vmHost.PSObject.Properties.Name -contains $propertyName) {
            Add-IpToSet -Set $adminIps -Values $vmHost.$propertyName
        }
    }

    # Try to capture cluster IPs, if present on the cluster object.
    if ($hostCluster) {
        foreach ($clusterIpProperty in @('IPAddress', 'IPAddresses', 'IPv4Addresses', 'IPv6Addresses', 'ClusterIPAddress', 'ManagementIPAddress', 'VirtualIPAddress')) {
            if ($hostCluster.PSObject.Properties.Name -contains $clusterIpProperty) {
                Add-IpToSet -Set $clusterIps -Values $hostCluster.$clusterIpProperty
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
                [string](Get-OptionalPropertyValue -Object $adapter -PropertyName 'VMNetwork'),
                [string](Get-OptionalPropertyValue -Object $adapter -PropertyName 'NetworkName')
            )

            $roleSet = switch ($role) {
                'Admin' { $adminIps; break }
                'LiveMigration' { $liveMigrationIps; break }
                'ClusterTraffic' { $clusterTrafficIps; break }
                default { $nodeIps; break }
            }

            foreach ($propertyName in @('IPAddress', 'IPAddresses', 'IPv4Address', 'IPv6Address', 'IPv4Addresses', 'IPv6Addresses', 'Address', 'Addresses')) {
                if ($adapter.PSObject.Properties.Name -contains $propertyName) {
                    Add-IpToSet -Set $roleSet -Values $adapter.$propertyName
                }
            }
        }
    }

    [pscustomobject]@{
        Cluster           = $clusterName
        Node              = $vmHost.Name
        AdminIPs          = Join-IpSet -Set $adminIps
        LiveMigrationIPs  = Join-IpSet -Set $liveMigrationIps
        ClusterTrafficIPs = Join-IpSet -Set $clusterTrafficIps
        NodeIPs           = Join-IpSet -Set $nodeIps
        ClusterIPs        = Join-IpSet -Set $clusterIps
    }
}

$rows |
    Sort-Object Cluster, Node |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "Rows exported: $($rows.Count)"
