<#
.SYNOPSIS
Exports IP addresses used by each Hyper-V node managed by SCVMM.

.DESCRIPTION
Connects to SCVMM, enumerates Hyper-V hosts, then queries each host directly
to retrieve:
  - Admin IPs
  - Live Migration IPs
  - Cluster Traffic IPs
  - Cluster Virtual IPs

This version avoids relying on weak/inconsistent SCVMM adapter properties
for LM / Cluster and instead uses:
  - local host IP configuration
  - Get-VMMigrationNetwork (migration subnets)
  - Get-ClusterNetwork (cluster network role/address/mask)
  - Get-ClusterResource + Get-ClusterParameter Address (cluster IP resources)

.NOTES
- Requires VirtualMachineManager module on the machine running the script.
- Requires PowerShell remoting to Hyper-V hosts.
- Best run with an account allowed to query Hyper-V hosts and cluster info.
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

function Convert-IPv4ToUInt32 {
    param([string]$IPAddress)

    $bytes = ([System.Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()
    [array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-IPv4InCidr {
    param(
        [string]$IPAddress,
        [string]$Cidr
    )

    if ([string]::IsNullOrWhiteSpace($IPAddress) -or [string]::IsNullOrWhiteSpace($Cidr)) {
        return $false
    }

    if ($IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        return $false
    }

    if ($Cidr -notmatch '^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$') {
        return $false
    }

    $network = $Matches[1]
    $prefix = [int]$Matches[3]

    if ($prefix -lt 0 -or $prefix -gt 32) {
        return $false
    }

    $ipValue = Convert-IPv4ToUInt32 -IPAddress $IPAddress
    $netValue = Convert-IPv4ToUInt32 -IPAddress $network

    $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $prefix) }

    return (($ipValue -band $mask) -eq ($netValue -band $mask))
}

function Test-IPv4InMaskNetwork {
    param(
        [string]$IPAddress,
        [string]$NetworkAddress,
        [string]$SubnetMask
    )

    if ([string]::IsNullOrWhiteSpace($IPAddress) -or
        [string]::IsNullOrWhiteSpace($NetworkAddress) -or
        [string]::IsNullOrWhiteSpace($SubnetMask)) {
        return $false
    }

    try {
        $ipValue   = Convert-IPv4ToUInt32 -IPAddress $IPAddress
        $netValue  = Convert-IPv4ToUInt32 -IPAddress $NetworkAddress
        $maskValue = Convert-IPv4ToUInt32 -IPAddress $SubnetMask

        return (($ipValue -band $maskValue) -eq ($netValue -band $maskValue))
    }
    catch {
        return $false
    }
}

function Get-RemoteHostData {
    param(
        [string]$ComputerName
    )

    try {
        Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
            $warnings = [System.Collections.Generic.List[string]]::new()

            try {
                $localIPv4 = @(
                    Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction Stop |
                    Where-Object {
                        $_.IPAddress -and
                        $_.IPAddress -notlike '169.254.*' -and
                        $_.IPAddress -ne '127.0.0.1'
                    } |
                    Select-Object IPAddress, PrefixLength, InterfaceAlias, InterfaceIndex, SkipAsSource
                )
            }
            catch {
                $localIPv4 = @()
                $warnings.Add("Get-NetIPAddress failed: $($_.Exception.Message)")
            }

            try {
                $defaultGatewayIPs = @(
                    Get-NetIPConfiguration -ErrorAction Stop |
                    Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
                    ForEach-Object {
                        foreach ($addr in @($_.IPv4Address)) {
                            $addr.IPAddress
                        }
                    }
                )
            }
            catch {
                $defaultGatewayIPs = @()
                $warnings.Add("Get-NetIPConfiguration failed: $($_.Exception.Message)")
            }

            $migrationSubnets = @()
            try {
                Import-Module Hyper-V -ErrorAction Stop | Out-Null
                $migrationSubnets = @(
                    Get-VMMigrationNetwork -ErrorAction Stop |
                    Select-Object -ExpandProperty Subnet
                )
            }
            catch {
                $warnings.Add("Live Migration query failed: $($_.Exception.Message)")
            }

            $clusterName     = $null
            $clusterNetworks = @()
            $clusterIPs      = @()

            try {
                Import-Module FailoverClusters -ErrorAction Stop | Out-Null
                $cluster = Get-Cluster -ErrorAction Stop
                $clusterName = $cluster.Name

                $clusterNetworks = @(
                    Get-ClusterNetwork -ErrorAction Stop |
                    Select-Object Name, Role, Address, AddressMask
                )

                $clusterIPs = @(
                    Get-ClusterResource -ErrorAction Stop |
                    Where-Object { $_.ResourceType -eq 'IP Address' } |
                    Get-ClusterParameter -Name Address -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Value
                )
            }
            catch {
                $warnings.Add("Cluster query failed: $($_.Exception.Message)")
            }

            [pscustomobject]@{
                LocalIPv4         = $localIPv4
                DefaultGatewayIPs = $defaultGatewayIPs
                MigrationSubnets  = $migrationSubnets
                ClusterName       = $clusterName
                ClusterNetworks   = $clusterNetworks
                ClusterIPs        = $clusterIPs
                Warnings          = @($warnings)
            }
        }
    }
    catch {
        return [pscustomobject]@{
            LocalIPv4         = @()
            DefaultGatewayIPs = @()
            MigrationSubnets  = @()
            ClusterName       = $null
            ClusterNetworks   = @()
            ClusterIPs        = @()
            Warnings          = @("Invoke-Command failed on $ComputerName : $($_.Exception.Message)")
        }
    }
}

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose "Querying Hyper-V hosts from SCVMM..."
$vmHosts = @(Get-SCVMHost -VMMServer $server)

$rows = foreach ($vmHost in $vmHosts) {
    $adminIps          = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $liveMigrationIps  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $clusterTrafficIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $nodeIps           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $clusterIps        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1) Admin from SCVMM host object
    foreach ($prop in @('IPAddress', 'IPAddresses')) {
        Add-ValuesToSet -TargetSet $adminIps -Value (Get-SafeProperty -Object $vmHost -Property $prop)
    }

    # 2) Get local data directly from the host
    $remote = Get-RemoteHostData -ComputerName $vmHost.Name

    foreach ($ipObj in @($remote.LocalIPv4)) {
        if ($ipObj.IPAddress) {
            [void]$nodeIps.Add([string]$ipObj.IPAddress)
        }
    }

    # 3) Admin fallback from default gateway interfaces
    if ($adminIps.Count -eq 0) {
        foreach ($ip in @($remote.DefaultGatewayIPs)) {
            Add-ValuesToSet -TargetSet $adminIps -Value $ip
        }
    }

    # 4) Live Migration = local IPs whose address belongs to migration subnets
    foreach ($ipObj in @($remote.LocalIPv4)) {
        $ip = [string]$ipObj.IPAddress
        foreach ($subnet in @($remote.MigrationSubnets)) {
            if (Test-IPv4InCidr -IPAddress $ip -Cidr ([string]$subnet)) {
                [void]$liveMigrationIps.Add($ip)
            }
        }
    }

    # 5) Cluster traffic = local IPs on cluster networks whose role includes InternalUse bit
    foreach ($net in @($remote.ClusterNetworks)) {
        $role = 0
        try { $role = [int]$net.Role } catch { $role = 0 }

        # Bit 1 => InternalUse / intra-cluster communication
        if (($role -band 1) -eq 1) {
            $networkAddress = [string](Get-SafeProperty -Object $net -Property 'Address')
            $subnetMask     = [string](Get-SafeProperty -Object $net -Property 'AddressMask')

            foreach ($ipObj in @($remote.LocalIPv4)) {
                $ip = [string]$ipObj.IPAddress
                if (Test-IPv4InMaskNetwork -IPAddress $ip -NetworkAddress $networkAddress -SubnetMask $subnetMask) {
                    [void]$clusterTrafficIps.Add($ip)
                }
            }
        }
    }

    # 6) Cluster virtual IPs
    foreach ($ip in @($remote.ClusterIPs)) {
        Add-ValuesToSet -TargetSet $clusterIps -Value $ip
    }

    # 7) Last DNS fallback for admin if still empty
    if ($adminIps.Count -eq 0) {
        try {
            foreach ($addr in [System.Net.Dns]::GetHostAddresses($vmHost.Name)) {
                [void]$adminIps.Add($addr.IPAddressToString)
            }
        }
        catch {
            # no-op
        }
    }

    # NodeIPs = local IPs minus already classified IPs
    $otherNodeIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in @($nodeIps)) {
        if (-not $adminIps.Contains($ip) -and
            -not $liveMigrationIps.Contains($ip) -and
            -not $clusterTrafficIps.Contains($ip)) {
            [void]$otherNodeIps.Add($ip)
        }
    }

    [pscustomobject]@{
        Cluster           = if ($remote.ClusterName) { $remote.ClusterName } else { 'Standalone' }
        Node              = $vmHost.Name
        AdminIPs          = Join-Set -Set $adminIps
        LiveMigrationIPs  = Join-Set -Set $liveMigrationIps
        ClusterTrafficIPs = Join-Set -Set $clusterTrafficIps
        NodeIPs           = Join-Set -Set $otherNodeIps
        ClusterIPs        = Join-Set -Set $clusterIps
        Warnings          = if ($remote.Warnings -and $remote.Warnings.Count -gt 0) { $remote.Warnings -join ' | ' } else { $null }
    }
}

$rows |
    Sort-Object Cluster, Node |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "Rows exported: $($rows.Count)"
