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
    [string]$OutputPath = '.\SCVMM-ClusterNodeIPs.csv'
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
        try {
            return $Object.$PropertyName
        }
        catch {
            Write-Verbose "Could not read property '$PropertyName' from object of type '$($Object.GetType().FullName)': $($_.Exception.Message)"
            return $null
        }
    }

    return $null
}

function Get-IpValues {
    param(
        [Parameter(Mandatory = $false)]
        $Value,

        [Parameter(Mandatory = $false)]
        [int]$Depth = 0,

        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 4
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Depth -ge $MaxDepth) {
        return @()
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            foreach ($nestedIp in (Get-IpValues -Value $item -Depth ($Depth + 1) -MaxDepth $MaxDepth)) {
                $results.Add($nestedIp) | Out-Null
            }
        }
        return @($results)
    }

    if ($Value -is [psobject] -and $Value -isnot [string]) {
        $results = [System.Collections.Generic.List[string]]::new()
        $knownIpPropertyNames = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@('IPAddress', 'IPAddresses', 'IPv4Address', 'IPv6Address', 'IPv4Addresses', 'IPv6Addresses', 'Address', 'Addresses'),
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($propertyName in $knownIpPropertyNames) {
            if ($Value.PSObject.Properties.Name -contains $propertyName) {
                foreach ($nestedIp in (Get-IpValues -Value $Value.$propertyName -Depth ($Depth + 1) -MaxDepth $MaxDepth)) {
                    $results.Add($nestedIp) | Out-Null
                }
            }
        }

        foreach ($property in @($Value.PSObject.Properties)) {
            if ($knownIpPropertyNames.Contains($property.Name)) {
                continue
            }
            if ($property.Name -match '(?i)ip|address') {
                foreach ($nestedIp in (Get-IpValues -Value $property.Value -Depth ($Depth + 1) -MaxDepth $MaxDepth)) {
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
        $candidateToken = $token.Trim('[](){}')
        if ($candidateToken -match '/') {
            $candidateToken = $candidateToken.Split('/')[0]
        }
        if ($candidateToken -as [System.Net.IPAddress]) {
            [void]$resultSet.Add($candidateToken)
        }
    }

    # Fallback regex scan for embedded IPv4 and IPv6 tokens inside arbitrary text.
    foreach ($ipv4 in [System.Text.RegularExpressions.Regex]::Matches($text, '(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)')) {
        $candidate = $ipv4.Value
        if ($candidate -as [System.Net.IPAddress]) {
            [void]$resultSet.Add($candidate)
        }
    }

    foreach ($ipv6 in [System.Text.RegularExpressions.Regex]::Matches($text, '(?i)(?<![0-9a-f:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![0-9a-f:])')) {
        $candidate = $ipv6.Value.Trim(':')
        if ($candidate -as [System.Net.IPAddress]) {
            [void]$resultSet.Add($candidate)
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
        $Value,

        [Parameter(Mandatory = $false)]
        [int]$Depth = 0,

        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 3
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Depth -ge $MaxDepth) {
        $renderedDepth = [string]$Value
        if ([string]::IsNullOrWhiteSpace($renderedDepth)) {
            return @()
        }
        return @($renderedDepth)
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
            foreach ($text in (Get-TextValues -Value $item -Depth ($Depth + 1) -MaxDepth $MaxDepth)) {
                $results.Add($text) | Out-Null
            }
        }
        return @($results)
    }

    if ($Value -is [psobject]) {
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($propertyName in @('Name', 'Description', 'ConnectionName', 'NetworkName', 'LogicalNetwork', 'LogicalNetworkDefinition', 'VMNetwork', 'Label', 'DisplayName', 'Role', 'RoleType', 'Usage')) {
            if ($Value.PSObject.Properties.Name -contains $propertyName) {
                foreach ($text in (Get-TextValues -Value $Value.$propertyName -Depth ($Depth + 1) -MaxDepth $MaxDepth)) {
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

function Add-AdapterIpCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Set,

        [Parameter(Mandatory = $true)]
        [object]$Adapter
    )

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
        if ($Adapter.PSObject.Properties.Name -contains $propertyName) {
            Add-IpToSet -Set $Set -Values $Adapter.$propertyName
        }
    }

    foreach ($nestedProperty in @(
        'IPConfiguration',
        'IPConfigurations',
        'NetworkAdapterIPAddresses',
        'HostNetworkAdapterIPConfiguration',
        'VMHostNetworkAdapterIPAddresses',
        'VirtualNetworkAdapter',
        'VMHostVirtualNetworkAdapter',
        'HostVirtualNetworkAdapter',
        'VirtualSwitchInterface'
    )) {
        if ($Adapter.PSObject.Properties.Name -contains $nestedProperty) {
            Add-IpToSet -Set $Set -Values $Adapter.$nestedProperty
        }
    }
}

function Add-VirtualSwitchInterfaceIpCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Set,

        [Parameter(Mandatory = $true)]
        [object]$Adapter
    )

    foreach ($switchProperty in @(
        'VirtualSwitch',
        'VMHostVirtualSwitch',
        'HostVirtualSwitch',
        'LogicalSwitch',
        'VirtualSwitchInterface'
    )) {
        if ($Adapter.PSObject.Properties.Name -contains $switchProperty) {
            Add-IpToSet -Set $Set -Values $Adapter.$switchProperty
        }
    }

    foreach ($interfaceCollectionProperty in @(
        'VirtualSwitchInterfaces',
        'VMHostVirtualNetworkAdapters',
        'HostVirtualNetworkAdapters',
        'VirtualNetworkAdapters',
        'NetworkAdapters'
    )) {
        if ($Adapter.PSObject.Properties.Name -contains $interfaceCollectionProperty) {
            Add-IpToSet -Set $Set -Values $Adapter.$interfaceCollectionProperty
        }
    }
}

function Add-ResolvedHostIpCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Set,

        [Parameter(Mandatory = $false)]
        [string]$HostName
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return
    }

    try {
        foreach ($address in [System.Net.Dns]::GetHostAddresses($HostName)) {
            if ($null -ne $address) {
                [void]$Set.Add($address.IPAddressToString)
            }
        }
    }
    catch {
        Write-Verbose "DNS lookup failed for host '$HostName': $($_.Exception.Message)"
    }
}

function Get-RoleIpSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Role,

        [Parameter(Mandatory = $true)]
        [object]$AdminIps,

        [Parameter(Mandatory = $true)]
        [object]$LiveMigrationIps,

        [Parameter(Mandatory = $true)]
        [object]$ClusterTrafficIps,

        [Parameter(Mandatory = $true)]
        [object]$NodeIps
    )

    switch ($Role) {
        'Admin' { Write-Output -NoEnumerate $AdminIps; return }
        'LiveMigration' { Write-Output -NoEnumerate $LiveMigrationIps; return }
        'ClusterTraffic' { Write-Output -NoEnumerate $ClusterTrafficIps; return }
        default { Write-Output -NoEnumerate $NodeIps; return }
    }
}

function Add-HostConfigurationIpCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object]$VMHost,

        [Parameter(Mandatory = $true)]
        [object]$AdminIps,

        [Parameter(Mandatory = $true)]
        [object]$LiveMigrationIps,

        [Parameter(Mandatory = $true)]
        [object]$ClusterTrafficIps,

        [Parameter(Mandatory = $true)]
        [object]$NodeIps
    )

    foreach ($property in @($VMHost.PSObject.Properties)) {
        $propertyName = $property.Name
        if ($propertyName -notmatch '(?i)network|adapter|migration|cluster|management|admin|ip|address|switch') {
            continue
        }

        $value = $property.Value
        if ($null -eq $value) {
            continue
        }

        $candidates = if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { @($value) } else { @($value) }
        foreach ($candidate in $candidates) {
            if ($null -eq $candidate) {
                continue
            }

            $roleHints = [System.Collections.Generic.List[string]]::new()
            $roleHints.Add($propertyName) | Out-Null

            foreach ($text in (Get-TextValues -Value $candidate)) {
                $roleHints.Add($text) | Out-Null
            }

            foreach ($nestedName in @(
                'Name',
                'Description',
                'ConnectionName',
                'LogicalNetwork',
                'LogicalNetworkDefinition',
                'VMNetwork',
                'NetworkName',
                'VirtualSwitch',
                'VMHostVirtualSwitch',
                'Role',
                'RoleType',
                'Usage',
                'Purpose'
            )) {
                foreach ($text in (Get-TextValues -Value (Get-OptionalPropertyValue -Object $candidate -PropertyName $nestedName))) {
                    $roleHints.Add($text) | Out-Null
                }
            }

            $role = Get-NetworkRoleFromText -TextValues @($roleHints)
            $roleSet = Get-RoleIpSet -Role $role -AdminIps $AdminIps -LiveMigrationIps $LiveMigrationIps -ClusterTrafficIps $ClusterTrafficIps -NodeIps $NodeIps

            Add-IpToSet -Set $roleSet -Values $candidate

            if ($candidate -is [psobject]) {
                Add-AdapterIpCandidates -Set $roleSet -Adapter $candidate
                Add-VirtualSwitchInterfaceIpCandidates -Set $roleSet -Adapter $candidate
            }
        }
    }
}

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying Hyper-V hosts (nodes) from SCVMM...'
$vmHosts = @(Get-SCVMHost -VMMServer $server)

$hostNetworkAdapterCmd = Get-Command -Name Get-SCVMHostNetworkAdapter -ErrorAction SilentlyContinue
$hostVirtualAdapterCmd = Get-Command -Name Get-SCVMHostVirtualNetworkAdapter -ErrorAction SilentlyContinue
$hostVirtualSwitchCmd = Get-Command -Name Get-SCVMHostVirtualSwitch -ErrorAction SilentlyContinue

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
                'VirtualSwitch',
                'VMHostVirtualSwitch',
                'Role',
                'RoleType',
                'Usage'
            )) {
                foreach ($text in (Get-TextValues -Value (Get-OptionalPropertyValue -Object $adapter -PropertyName $propertyName))) {
                    $roleHints.Add($text) | Out-Null
                }
            }

            $role = Get-NetworkRoleFromText -TextValues @($roleHints)
            $roleSet = Get-RoleIpSet -Role $role -AdminIps $adminIps -LiveMigrationIps $liveMigrationIps -ClusterTrafficIps $clusterTrafficIps -NodeIps $nodeIps

            Add-AdapterIpCandidates -Set $roleSet -Adapter $adapter
            Add-VirtualSwitchInterfaceIpCandidates -Set $roleSet -Adapter $adapter
        }
    }

    # Fallback: pull role/IP data directly from VMHost configuration properties.
    Add-HostConfigurationIpCandidates -VMHost $vmHost -AdminIps $adminIps -LiveMigrationIps $liveMigrationIps -ClusterTrafficIps $clusterTrafficIps -NodeIps $nodeIps

    if ($hostVirtualAdapterCmd) {
        $virtualAdapters = @(Get-SCVMHostVirtualNetworkAdapter -VMHost $vmHost -ErrorAction SilentlyContinue)
        foreach ($virtualAdapter in $virtualAdapters) {
            Add-AdapterIpCandidates -Set $nodeIps -Adapter $virtualAdapter
            Add-VirtualSwitchInterfaceIpCandidates -Set $nodeIps -Adapter $virtualAdapter
        }
    }

    if ($hostVirtualSwitchCmd) {
        $virtualSwitches = @(Get-SCVMHostVirtualSwitch -VMHost $vmHost -ErrorAction SilentlyContinue)
        foreach ($virtualSwitch in $virtualSwitches) {
            Add-IpToSet -Set $nodeIps -Values $virtualSwitch
            Add-VirtualSwitchInterfaceIpCandidates -Set $nodeIps -Adapter $virtualSwitch
        }
    }

    if ($adminIps.Count -eq 0) {
        Add-ResolvedHostIpCandidates -Set $adminIps -HostName $vmHost.Name
    }
    if ($nodeIps.Count -eq 0) {
        Add-ResolvedHostIpCandidates -Set $nodeIps -HostName $vmHost.FullyQualifiedDomainName
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
