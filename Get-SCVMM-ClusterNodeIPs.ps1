<#
.SYNOPSIS
Exports IP addresses used by each Hyper-V node managed by SCVMM.

.DESCRIPTION
Connects to SCVMM, enumerates Hyper-V hosts (nodes), discovers their
IP addresses from host properties and host network adapter data,
and exports the result to CSV.

Role classification priority (per adapter):
  1. UsedForManagement / UsedForLiveMigration / UsedForCluster boolean properties
  2. Associated LogicalNetwork name keyword matching
  3. Adapter name / description keyword matching

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

# ---------------------------------------------------------------------------
# Safely read a property that may not exist or may throw on certain objects.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Extract valid IP strings from any value: string, CIDR, or array of either.
# Strips CIDR prefix (e.g. "10.0.0.1/24" -> "10.0.0.1").
# ---------------------------------------------------------------------------
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
        # Handle comma / semicolon / space separated lists in a single string
        foreach ($token in ([string]$raw -split '[,;\s]+')) {
            $token = $token.Trim()
            if ([string]::IsNullOrWhiteSpace($token)) { continue }
            # Strip CIDR prefix
            if ($token -match '^(.+)/\d+$') { $token = $Matches[1] }
            if ($token -as [System.Net.IPAddress]) {
                [void]$seen.Add($token)
            }
        }
    }

    return $seen
}

# ---------------------------------------------------------------------------
# Determine an adapter's network role.
# Checks explicit boolean flags first, then keyword matches on hint strings.
# ---------------------------------------------------------------------------
function Get-AdapterRole {
    param(
        [object]$Adapter   # HostNetworkAdapter or VMHostVirtualNetworkAdapter
    )

    # Priority 1: explicit boolean properties (present in most SCVMM versions)
    $usedForLM   = Get-SafeProperty -Object $Adapter -Property 'UsedForLiveMigration'
    $usedForMgmt = Get-SafeProperty -Object $Adapter -Property 'UsedForManagement'
    $usedForClus = Get-SafeProperty -Object $Adapter -Property 'UsedForCluster'

    if ($usedForLM   -eq $true) { return 'LiveMigration' }
    if ($usedForMgmt -eq $true) { return 'Admin' }
    if ($usedForClus -eq $true) { return 'ClusterTraffic' }

    # Priority 2: logical network name
    $lnName = $null
    $ln = Get-SafeProperty -Object $Adapter -Property 'LogicalNetwork'
    if ($ln) { $lnName = Get-SafeProperty -Object $ln -Property 'Name' }
    if (-not $lnName) {
        $lnName = Get-SafeProperty -Object $Adapter -Property 'LogicalNetworkDefinitionName'
    }

    # Priority 3: adapter name / description / connection name
    $adapterName = Get-SafeProperty -Object $Adapter -Property 'Name'
    $description = Get-SafeProperty -Object $Adapter -Property 'Description'
    $connName    = Get-SafeProperty -Object $Adapter -Property 'ConnectionName'
    $vmNetName   = Get-SafeProperty -Object $Adapter -Property 'VMNetworkName'

    $parts = @($lnName, $adapterName, $description, $connName, $vmNetName) |
             Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $text  = if ($parts) { ($parts -join ' ').ToLowerInvariant() } else { '' }

    if ($text -match 'live.?migr|livemig|\blm\b|migration')  { return 'LiveMigration' }
    if ($text -match 'cluster|heartbeat|\bcsv\b|quorum')    { return 'ClusterTraffic' }
    if ($text -match 'storage|\bsmb\b|backup|iscsi')        { return 'ClusterTraffic' }
    if ($text -match 'admin|mgmt|management|host.?mgmt')    { return 'Admin' }

    return 'Node'
}

# ---------------------------------------------------------------------------
# Add IPs from an adapter into the correct role-based HashSet.
# ---------------------------------------------------------------------------
function Add-AdapterIps {
    param(
        [object]$Adapter,
        [object]$AdminIps,
        [object]$LiveMigrationIps,
        [object]$ClusterTrafficIps,
        [object]$NodeIps
    )

    $role = Get-AdapterRole -Adapter $Adapter

    $targetSet = $NodeIps
    switch ($role) {
        'Admin'          { $targetSet = $AdminIps }
        'LiveMigration'  { $targetSet = $LiveMigrationIps }
        'ClusterTraffic' { $targetSet = $ClusterTrafficIps }
    }

    foreach ($ipProp in @('IPAddresses', 'IPAddress', 'IPv4Addresses', 'IPv6Addresses', 'Addresses')) {
        $ipAddresses = Get-SafeProperty -Object $Adapter -Property $ipProp
        foreach ($ip in (Get-CleanIps -Value $ipAddresses)) {
            [void]$targetSet.Add($ip)
        }
    }
}

# ---------------------------------------------------------------------------
# Join a HashSet into a semicolon-separated string, or null if empty.
# ---------------------------------------------------------------------------
function Join-IpSet {
    param([object]$Set)
    if ($null -eq $Set -or $Set.Count -eq 0) { return $null }
    return (@($Set | Sort-Object) -join ';')
}

# ===========================================================================
# Main
# ===========================================================================

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

    # ------------------------------------------------------------------
    # 1. Management IP from the VMHost object itself (most reliable).
    #    IPAddress is a single string in most SCVMM versions.
    # ------------------------------------------------------------------
    foreach ($prop in @('IPAddress', 'IPAddresses')) {
        foreach ($ip in (Get-CleanIps -Value (Get-SafeProperty -Object $vmHost -Property $prop))) {
            [void]$adminIps.Add($ip)
        }
    }

    # ------------------------------------------------------------------
    # 2. Live migration IPs — pulled directly from VMHost properties.
    #    MigrationIPAddressList is set by SCVMM when migration networks
    #    are configured and is the authoritative source.
    # ------------------------------------------------------------------
    foreach ($prop in @('MigrationIPAddressList', 'LiveMigrationIPAddressList',
                        'MigrationIPAddress',     'LiveMigrationIPAddress')) {
        foreach ($ip in (Get-CleanIps -Value (Get-SafeProperty -Object $vmHost -Property $prop))) {
            [void]$liveMigrationIps.Add($ip)
        }
    }
    # ------------------------------------------------------------------
    # 3. Cluster virtual IP and per-node cluster network IPs.
    # ------------------------------------------------------------------
    $hostCluster = Get-SafeProperty -Object $vmHost -Property 'HostCluster'
    $clusterName = if ($hostCluster -and (Get-SafeProperty -Object $hostCluster -Property 'Name')) {
        $hostCluster.Name
    } else {
        'Standalone'
    }

    if ($hostCluster) {
        # Virtual IP of the cluster itself (client access point)
        foreach ($prop in @('IPAddress', 'IPAddresses', 'ClusterIPAddress', 'VirtualIPAddress')) {
            foreach ($ip in (Get-CleanIps -Value (Get-SafeProperty -Object $hostCluster -Property $prop))) {
                [void]$clusterIps.Add($ip)
            }
        }

        # Cluster networks expose per-node addresses for heartbeat / CSV traffic
        $clusterNetworks = Get-SafeProperty -Object $hostCluster -Property 'ClusterNetworks'
        if (-not $clusterNetworks) {
            $clusterNetworks = Get-SafeProperty -Object $hostCluster -Property 'Networks'
        }
        if ($clusterNetworks) {
            foreach ($net in @($clusterNetworks)) {
                foreach ($prop in @('IPAddress', 'IPAddresses', 'Address')) {
                    foreach ($ip in (Get-CleanIps -Value (Get-SafeProperty -Object $net -Property $prop))) {
                        [void]$clusterTrafficIps.Add($ip)
                    }
                }
            }
        }
    }

    # ------------------------------------------------------------------
    # 4. Physical host network adapters.
    #    These carry the per-NIC IP addresses and role flags.
    # ------------------------------------------------------------------
    try {
        $physAdapters = @(Get-SCVMHostNetworkAdapter -VMHost $vmHost -ErrorAction SilentlyContinue)
    }
    catch {
        $physAdapters = @()
        Write-Verbose "Get-SCVMHostNetworkAdapter failed for '$($vmHost.Name)': $($_.Exception.Message)"
    }

    foreach ($adapter in $physAdapters) {
        Add-AdapterIps -Adapter $adapter `
            -AdminIps $adminIps `
            -LiveMigrationIps $liveMigrationIps `
            -ClusterTrafficIps $clusterTrafficIps `
            -NodeIps $nodeIps
    }

    # ------------------------------------------------------------------
    # 4. Host virtual network adapters (management OS vNICs bound to a
    #    virtual switch — these carry IPs for the host partition).
    # ------------------------------------------------------------------
    try {
        $vAdapters = @(Get-SCVMHostVirtualNetworkAdapter -VMHost $vmHost -ErrorAction SilentlyContinue)
    }
    catch {
        $vAdapters = @()
        Write-Verbose "Get-SCVMHostVirtualNetworkAdapter failed for '$($vmHost.Name)': $($_.Exception.Message)"
    }

    foreach ($vAdapter in $vAdapters) {
        Add-AdapterIps -Adapter $vAdapter `
            -AdminIps $adminIps `
            -LiveMigrationIps $liveMigrationIps `
            -ClusterTrafficIps $clusterTrafficIps `
            -NodeIps $nodeIps
    }

    # ------------------------------------------------------------------
    # 5. DNS fallback — only if we still have no IPs at all.
    # ------------------------------------------------------------------
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
