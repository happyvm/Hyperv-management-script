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

function Add-IpValues {
    param(
        [AllowNull()]
        $Target,

        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) {
        return
    }

    if ($null -eq $Target) {
        return
    }

    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            Add-IpValues -Target $Target -Value $item
        }
        return
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    # Keep only valid IPv4/IPv6 values.
    if ($text -as [System.Net.IPAddress]) {
        if ($Target -is [System.Collections.IList]) {
            $Target.Add($text) | Out-Null
        }
    }
}

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
$server = Get-SCVMMServer -ComputerName $VMMServer

Write-Verbose 'Querying Hyper-V hosts (nodes) from SCVMM...'
$hosts = Get-SCVMHost -VMMServer $server

$hostNetworkAdapterCmd = Get-Command -Name Get-SCVMHostNetworkAdapter -ErrorAction SilentlyContinue

$rows = foreach ($vmHost in $hosts) {
    $hostCluster = Get-OptionalPropertyValue -Object $vmHost -PropertyName 'HostCluster'
    $clusterName = if ($hostCluster -and $hostCluster.Name) { $hostCluster.Name } else { 'Standalone' }

    $ips = [System.Collections.Generic.List[string]]::new()

    # Collect candidate IP values from common SCVMM host properties.
    foreach ($propertyName in @('IPAddress', 'IPAddresses', 'IPv4Addresses', 'IPv6Addresses', 'ManagementIPAddress')) {
        if ($vmHost.PSObject.Properties.Name -contains $propertyName) {
            Add-IpValues -Target $ips -Value $vmHost.$propertyName
        }
    }

    # Collect candidate IP values from SCVMM host network adapter objects if cmdlet exists.
    if ($hostNetworkAdapterCmd) {
        $adapters = Get-SCVMHostNetworkAdapter -VMHost $vmHost -ErrorAction SilentlyContinue
        foreach ($adapter in $adapters) {
            foreach ($propertyName in @('IPAddress', 'IPAddresses', 'IPv4Addresses', 'IPv6Addresses')) {
                if ($adapter.PSObject.Properties.Name -contains $propertyName) {
                    Add-IpValues -Target $ips -Value $adapter.$propertyName
                }
            }
        }
    }

    $uniqueIps = @(
        $ips |
            Sort-Object -Unique
    )

    if ($uniqueIps.Count -eq 0) {
        [pscustomobject]@{
            Cluster = $clusterName
            Node    = $vmHost.Name
            IP      = $null
        }
        continue
    }

    foreach ($ip in $uniqueIps) {
        [pscustomobject]@{
            Cluster = $clusterName
            Node    = $vmHost.Name
            IP      = $ip
        }
    }
}

$rows |
    Sort-Object Cluster, Node, IP |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "Rows exported: $($rows.Count)"
