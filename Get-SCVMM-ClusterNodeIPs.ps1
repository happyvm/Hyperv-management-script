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
        return @($results)
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
            return @($results)
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
        return @($resultSet)
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

function Get-TextValues {
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return @()
        }
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            foreach ($text in (Get-TextValues -Value $item)) {
                $results.Add($text) | Out-Null
            }
        }
        return @($results)
    }

    if ($Value -is [psobject]) {
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($propertyName in @('Name', 'Description', 'ConnectionName', 'NetworkName', 'LogicalNetwork', 'LogicalNetworkDefinition', 'VMNetwork', 'Label', 'DisplayName', 'Role', 'RoleType', 'Usage')) {
            if ($Value.PSObject.Properties.Name -contains $propertyName) {
                foreach ($text in (Get-TextValues -Value $Value.$propertyName)) {
                    $results.Add($text) | Out-Null
                }
            }
        }

        if ($results.Count -gt 0) {
            return @($results)
        }
    }

    $rendered = [string]$Value
    if ([string]::IsNullOrWhiteSpace($rendered)) {
        return @()
    }

    return @($rendered)
}

function Add-IpToSet {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Set,

        [Parameter(Mandatory = $false)]
        $Values
    )

    if ($null -eq $Set) {
        throw 'Set cannot be null.'
    }

    if (-not ($Set -is [System.Collections.Generic.HashSet[string]])) {
        throw "Set must be of type HashSet[string]. Actual type: $($Set.GetType().FullName)"
    }

    foreach ($ip in (Get-IpValues -Value $Values)) {
        if (-not [string]::IsNullOrWhiteSpace($ip)) {
            [void]$Set.Add($ip)
        }
    }
}

function Join-IpSet {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Set
    )

    if ($null -eq $Set) {
        throw 'Set cannot be null.'
    }

    if (-not ($Set -is [System.Collections.Generic.HashSet[string]])) {
        throw "Set must be of type HashSet[string]. Actual type: $($Set.GetType().FullName)"
    }

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
            $roleHints = [System.Collections.Generic.List[string]]::new()
            foreach ($propertyName in @(
                'Name',
                'Description',
                'ConnectionName',
                'LogicalNetwork',
                'LogicalNetworkDefinition',
                'VMNetwork',
                'NetworkName',
                'Role',
                'RoleType',
                'Usage'
            )) {
                foreach ($text in (Get-TextValues -Value (Get-OptionalPropertyValue -Object $adapter -PropertyName $propertyName))) {
                    $roleHints.Add($text) | Out-Null
                }
            }

            $role = Get-NetworkRoleFromText -TextValues @($roleHints)

            # HashSet objects are enumerable; emit them as single objects (NoEnumerate)
            # so an empty set does not collapse to $null through switch output.
            $roleSet = switch ($role) {
                'Admin' { Write-Output -NoEnumerate $adminIps; break }
                'LiveMigration' { Write-Output -NoEnumerate $liveMigrationIps; break }
                'ClusterTraffic' { Write-Output -NoEnumerate $clusterTrafficIps; break }
                default { Write-Output -NoEnumerate $nodeIps; break }
            }

            foreach ($propertyName in @(
                'IPAddress',
                'IPAddresses',
                'IPv4Address',
                'IPv6Address',
                'IPv4Addresses',
                'IPv6Addresses',
                'Address',
                'Addresses',
                'ManagementIPAddress',
                'ManagementIPAddresses',
                'VirtualIPAddress'
            )) {
                if ($adapter.PSObject.Properties.Name -contains $propertyName) {
                    Add-IpToSet -Set $roleSet -Values $adapter.$propertyName
                }
            }

            foreach ($nestedProperty in @('IPConfiguration', 'IPConfigurations', 'NetworkAdapterIPAddresses', 'HostNetworkAdapterIPConfiguration')) {
                if ($adapter.PSObject.Properties.Name -contains $nestedProperty) {
                    Add-IpToSet -Set $roleSet -Values $adapter.$nestedProperty
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
