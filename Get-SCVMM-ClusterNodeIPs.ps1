<#
.SYNOPSIS
Exports IP addresses used by each Hyper-V node managed by SCVMM.

.DESCRIPTION
Connects to SCVMM, enumerates Hyper-V hosts (nodes), and exports role-based
IP addresses to CSV.

Role sourcing:
  - Admin: VMHost IPAddress/IPAddresses + adapters marked UsedForManagement
  - LiveMigration: Hyper-V migration networks on the host (Get-VMMigrationNetwork)
  - ClusterTraffic: Failover cluster network interfaces for the node
  - ClusterIPs: Cluster virtual IP address resources

.NOTES
- Requires the VirtualMachineManager PowerShell module.
- For best results on Live Migration / Cluster traffic, run from a system that
  can query Hyper-V and Failover Clustering on the hosts/clusters.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMMServer,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = '.\SCVMM-ClusterNodeIPs.csv'
)

$ErrorActionPreference = 'Stop'

function Get-SafeProperty {
    param(
        [object]$Object,
        [string]$Property
    )
    if ($null -eq $Object) { return $null }
    try {
        if ($Object.PSObject.Properties.Name -contains $Property) {
            return $Object.$Property
        }
    }
    catch {
        Write-Verbose "Could not read '$Property': $($_.Exception.Message)"
    }
    return $null
}

function Get-CleanIps {
    param($Value)

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($raw in @($Value)) {
        if ($null -eq $raw) { continue }

        if ($raw -is [System.Net.IPAddress]) {
            [void]$seen.Add($raw.IPAddressToString)
            continue
        }

        if ($raw.PSObject -and ($raw.PSObject.Properties.Name -contains 'IPAddressToString')) {
            [void]$seen.Add([string]$raw.IPAddressToString)
            continue
        }

        if ($raw.PSObject -and ($raw.PSObject.Properties.Name -contains 'Address')) {
            foreach ($ip in (Get-CleanIps -Value $raw.Address)) {
                [void]$seen.Add($ip)
            }
            continue
        }

        foreach ($token in ([string]$raw -split '[,;\s]+')) {
            $token = $token.Trim()
            if ([string]::IsNullOrWhiteSpace($token)) { continue }

            if ($token -match '^(.+)/\d+$') {
                $token = $Matches[1]
            }

            if ($token -as [System.Net.IPAddress]) {
                [void]$seen.Add($token)
            }
        }
    }

    return $seen
}

function Join-Set {
    param([object]$Set)
    if ($null -eq $Set -or $Set.Count -eq 0) { return $null }
    return (@($Set | Sort-Object) -join ';')
}

function Add-ValuesToSet {
    param(
        [object]$TargetSet,
        $Value
    )
    foreach ($ip in (Get-CleanIps -Value $Value)) {
        [void]$TargetSet.Add($ip)
    }
}

function Get-HostManagementIpsFromScvmm {
    param(
        [object]$VMHost,
        [object]$AdminIps
    )

    foreach ($prop in @('IPAddress', 'IPAddresses')) {
        Add-ValuesToSet -TargetSet $AdminIps -Value (Get-SafeProperty -Object $VMHost -Property $prop)
    }

    try {
        $physAdapters = @(Get-SCVMHostNetworkAdapter -VMHost $VMHost -ErrorAction SilentlyContinue)
    }
    catch {
        $physAdapters = @()
        Write-Verbose "Get-SCVMHostNetworkAdapter failed for '$($VMHost.Name)': $($_.Exception.Message)"
    }

    foreach ($adapter in $physAdapters) {
        $usedForMgmt = Get-SafeProperty -Object $adapter -Property 'UsedForManagement'
        if ($usedForMgmt -eq $true) {
            foreach ($prop in @('IPAddresses', 'IPAddress', 'IPv4Addresses', 'IPv6Addresses', 'Addresses', 'IPv4Address', 'IPv6Address')) {
                Add-ValuesToSet -TargetSet $AdminIps -Value (Get-SafeProperty -Object $adapter -Property $prop)
            }
        }
    }

    try {
        $vAdapters = @(Get-SCVMHostVirtualNetworkAdapter -VMHost $VMHost -ErrorAction SilentlyContinue)
    }
    catch {
        $vAdapters = @()
        Write-Verbose "Get-SCVMHostVirtualNetworkAdapter failed for '$($VMHost.Name)': $($_.Exception.Message)"
    }

    foreach ($adapter in $vAdapters) {
        $usedForMgmt = Get-SafeProperty -Object $adapter -Property 'UsedForManagement'
        if ($usedForMgmt -eq $true) {
            foreach ($prop in @('IPAddresses', 'IPAddress', 'IPv4Addresses', 'IPv6Addresses', 'Addresses', 'IPv4Address', 'IPv6Address')) {
                Add-ValuesToSet -TargetSet $AdminIps -Value (Get-SafeProperty -Object $adapter -Property $prop)
            }
        }
    }
}

function Get-LiveMigrationIps {
    param(
        [string]$ComputerName,
        [object]$LiveMigrationIps
    )

    try {
        $migrationNetworks = @(Get-VMMigrationNetwork -ComputerName $ComputerName -ErrorAction Stop)
        foreach ($net in $migrationNetworks) {
            foreach ($prop in @('Subnet', 'Network', 'IPAddress', 'IPAddresses', 'Address')) {
                Add-ValuesToSet -TargetSet $LiveMigrationIps -Value (Get-SafeProperty -Object $net -Property $prop)
            }
        }
    }
    catch {
        Write-Verbose "Get-VMMigrationNetwork failed for '$ComputerName': $($_.Exception.Message)"
    }
}

function Get-ClusterTrafficIps {
    param(
        [string]$ClusterName,
        [string]$NodeName,
        [object]$ClusterTrafficIps
    )

    try {
        $clusterIfs = @(Get-ClusterNetworkInterface -Cluster $ClusterName -Node $NodeName -ErrorAction Stop)
        foreach ($if in $clusterIfs) {
            foreach ($prop in @('IPv4Addresses', 'IPv6Addresses', 'IPAddresses', 'Address', 'IPAddress')) {
                Add-ValuesToSet -TargetSet $ClusterTrafficIps -Value (Get-SafeProperty -Object $if -Property $prop)
            }
        }
    }
    catch {
        Write-Verbose "Get-ClusterNetworkInterface failed for node '$NodeName' on cluster '$ClusterName': $($_.Exception.Message)"
    }
}

function Get-ClusterVirtualIps {
    param(
        [string]$ClusterName,
        [object]$ClusterIps
    )

    try {
        $ipResources = @(Get-ClusterResource -Cluster $ClusterName -ErrorAction Stop | Where-Object { $_.ResourceType -eq 'IP Address' })
        foreach ($res in $ipResources) {
            try {
                $addressParam = Get-ClusterParameter -InputObject $res -Name 'Address' -ErrorAction Stop
                Add-ValuesToSet -TargetSet $ClusterIps -Value $addressParam.Value
            }
            catch {
                Write-Verbose "Could not read Address parameter from cluster IP resource '$($res.Name)' on '$ClusterName': $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-Verbose "Get-ClusterResource failed for cluster '$ClusterName': $($_.Exception.Message)"
    }
}

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying Hyper-V hosts from SCVMM...'
$vmHosts = @(Get-SCVMHost -VMMServer $server)

$rows = foreach ($vmHost in $vmHosts) {
    $adminIps          = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $liveMigrationIps  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $clusterTrafficIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $nodeIps           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $clusterIps        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $hostCluster = Get-SafeProperty -Object $vmHost -Property 'HostCluster'
    $clusterName = if ($hostCluster -and (Get-SafeProperty -Object $hostCluster -Property 'Name')) {
        $hostCluster.Name
    } else {
        'Standalone'
    }

    # 1) Admin IPs from SCVMM host object + adapters explicitly marked for management
    Get-HostManagementIpsFromScvmm -VMHost $vmHost -AdminIps $adminIps

    # 2) Live Migration IPs from Hyper-V migration network configuration
    Get-LiveMigrationIps -ComputerName $vmHost.Name -LiveMigrationIps $liveMigrationIps

    # 3) Cluster traffic IPs from cluster network interfaces
    if ($clusterName -ne 'Standalone') {
        Get-ClusterTrafficIps -ClusterName $clusterName -NodeName $vmHost.Name -ClusterTrafficIps $clusterTrafficIps

        # 4) Cluster virtual IP(s)
        Get-ClusterVirtualIps -ClusterName $clusterName -ClusterIps $clusterIps
    }

    # 5) Fallback node/admin DNS resolution if still empty
    if ($adminIps.Count -eq 0) {
        try {
            foreach ($addr in [System.Net.Dns]::GetHostAddresses($vmHost.Name)) {
                [void]$adminIps.Add($addr.IPAddressToString)
            }
        }
        catch {
            Write-Verbose "DNS lookup failed for '$($vmHost.Name)': $($_.Exception.Message)"
        }
    }

    $fqdn = Get-SafeProperty -Object $vmHost -Property 'FullyQualifiedDomainName'
    if ($nodeIps.Count -eq 0 -and $fqdn -and $fqdn -ne $vmHost.Name) {
        try {
            foreach ($addr in [System.Net.Dns]::GetHostAddresses($fqdn)) {
                [void]$nodeIps.Add($addr.IPAddressToString)
            }
        }
        catch {
            Write-Verbose "DNS lookup failed for '$fqdn': $($_.Exception.Message)"
        }
    }

    [pscustomobject]@{
        Cluster           = $clusterName
        Node              = $vmHost.Name
        AdminIPs          = Join-Set -Set $adminIps
        LiveMigrationIPs  = Join-Set -Set $liveMigrationIps
        ClusterTrafficIPs = Join-Set -Set $clusterTrafficIps
        NodeIPs           = Join-Set -Set $nodeIps
        ClusterIPs        = Join-Set -Set $clusterIps
    }
}

$rows |
    Sort-Object Cluster, Node |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "Rows exported: $($rows.Count)"
