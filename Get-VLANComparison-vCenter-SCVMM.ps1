<#
.SYNOPSIS
Compares VLAN IDs and VLAN names between vCenter and SCVMM.

.DESCRIPTION
Connects to a vCenter server (VMware PowerCLI) and a SCVMM server
(VirtualMachineManager module), inventories VLAN definitions from each platform,
and exports a comparison report.

vCenter sources:
- Standard Port Groups (Get-VirtualPortGroup)
- Distributed Port Groups (Get-VDPortgroup)

SCVMM sources:
- VM networks + VM subnets (Get-SCVMNetwork / Get-SCVMSubnet)
- VLAN IDs extracted from SubnetVLans

The output highlights which VLAN IDs are present in vCenter, in SCVMM, or both.

.NOTES
- Requires VMware PowerCLI and VirtualMachineManager modules.
- Designed for environments where VLAN IDs are the main matching key.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VCenterServer,

    [Parameter(Mandatory = $true)]
    [string]$SCVMMServer,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\VLAN-Comparison-vCenter-SCVMM.csv",

    [Parameter(Mandatory = $false)]
    [ValidateSet(';', ',')]
    [string]$Delimiter = ';'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Join-DistinctValues {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Values
    )

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return ''
    }

    $distinct = $Values |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { [string]$_ } |
        Sort-Object -Unique

    return ($distinct -join ' | ')
}

function Add-Entry {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Table,

        [Parameter(Mandatory = $true)]
        [string]$VlanId,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$Source = ''
    )

    if (-not $Table.ContainsKey($VlanId)) {
        $Table[$VlanId] = [System.Collections.Generic.List[pscustomobject]]::new()
    }

    $Table[$VlanId].Add([pscustomobject]@{
            Name   = $Name
            Source = $Source
        })
}

Write-Verbose "Loading required modules..."
Import-Module VMware.PowerCLI -ErrorAction Stop
Import-Module VirtualMachineManager -ErrorAction Stop

Write-Verbose "Connecting to vCenter '$VCenterServer'..."
$null = Connect-VIServer -Server $VCenterServer -ErrorAction Stop

Write-Verbose "Connecting to SCVMM '$SCVMMServer'..."
$null = Get-SCVMMServer -ComputerName $SCVMMServer -ErrorAction Stop

$vcenterByVlan = @{}
$scvmmByVlan = @{}

try {
    Write-Verbose "Collecting standard port groups from vCenter..."
    $standardPortGroups = @(Get-VirtualPortGroup -ErrorAction SilentlyContinue)
    foreach ($pg in $standardPortGroups) {
        $vlanId = $null
        if ($null -ne $pg.VLanId) {
            $vlanId = [string]$pg.VLanId
        }

        if ([string]::IsNullOrWhiteSpace($vlanId)) {
            continue
        }

        Add-Entry -Table $vcenterByVlan -VlanId $vlanId -Name ([string]$pg.Name) -Source 'StandardPG'
    }

    Write-Verbose "Collecting distributed port groups from vCenter..."
    $distributedPortGroups = @(Get-VDPortgroup -ErrorAction SilentlyContinue)
    foreach ($dpg in $distributedPortGroups) {
        $vlanId = $null

        if ($null -ne $dpg.VlanConfiguration) {
            if ($null -ne $dpg.VlanConfiguration.VlanId) {
                $vlanId = [string]$dpg.VlanConfiguration.VlanId
            }
            elseif ($null -ne $dpg.VlanConfiguration.StartVlanId -and $null -ne $dpg.VlanConfiguration.EndVlanId) {
                $start = [string]$dpg.VlanConfiguration.StartVlanId
                $end = [string]$dpg.VlanConfiguration.EndVlanId
                $vlanId = if ($start -eq $end) { $start } else { "$start-$end" }
            }
        }

        if ([string]::IsNullOrWhiteSpace($vlanId)) {
            continue
        }

        Add-Entry -Table $vcenterByVlan -VlanId $vlanId -Name ([string]$dpg.Name) -Source 'DistributedPG'
    }

    Write-Verbose "Collecting VM networks/subnets from SCVMM..."
    $vmNetworks = @(Get-SCVMNetwork -VMMServer $SCVMMServer -ErrorAction SilentlyContinue)
    foreach ($vmNetwork in $vmNetworks) {
        $subnets = @(Get-SCVMSubnet -VMMServer $SCVMMServer -VMNetwork $vmNetwork -ErrorAction SilentlyContinue)
        if ($subnets.Count -eq 0) {
            continue
        }

        foreach ($subnet in $subnets) {
            $subnetVlans = @($subnet.SubnetVLans)
            foreach ($subnetVlan in $subnetVlans) {
                if ($null -eq $subnetVlan) {
                    continue
                }

                $vlanId = $null
                if ($null -ne $subnetVlan.VLanID) {
                    $vlanId = [string]$subnetVlan.VLanID
                }

                if ([string]::IsNullOrWhiteSpace($vlanId)) {
                    continue
                }

                $scvmmName = if (-not [string]::IsNullOrWhiteSpace([string]$subnet.Name)) {
                    [string]$subnet.Name
                }
                else {
                    [string]$vmNetwork.Name
                }

                Add-Entry -Table $scvmmByVlan -VlanId $vlanId -Name $scvmmName -Source 'SCVMM-VMSubnet'
            }
        }
    }

    $allVlans = @($vcenterByVlan.Keys + $scvmmByVlan.Keys) | Sort-Object -Unique

    $results = foreach ($vlan in $allVlans) {
        $vcenterEntries = if ($vcenterByVlan.ContainsKey($vlan)) { @($vcenterByVlan[$vlan]) } else { @() }
        $scvmmEntries = if ($scvmmByVlan.ContainsKey($vlan)) { @($scvmmByVlan[$vlan]) } else { @() }

        $inVCenter = $vcenterEntries.Count -gt 0
        $inScvmm = $scvmmEntries.Count -gt 0

        [pscustomobject]@{
            VLANID         = $vlan
            VLANName_vCenter = Join-DistinctValues -Values ($vcenterEntries | ForEach-Object { $_.Name })
            VLANName_SCVMM = Join-DistinctValues -Values ($scvmmEntries | ForEach-Object { $_.Name })
            In_vCenter     = $inVCenter
            In_SCVMM       = $inScvmm
            MatchStatus    = if ($inVCenter -and $inScvmm) { 'PresentInBoth' } elseif ($inVCenter) { 'OnlyInVCenter' } else { 'OnlyInSCVMM' }
        }
    }

    $results |
        Sort-Object {
            $asInt = 0
            if ([int]::TryParse($_.VLANID, [ref]$asInt)) {
                return $asInt
            }
            return [int]::MaxValue
        }, VLANID |
        Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Delimiter $Delimiter -Encoding UTF8

    Write-Host "Comparison completed. Output: $OutputPath"
    Write-Host "Total VLAN IDs compared: $($results.Count)"
}
finally {
    if ($global:DefaultVIServer) {
        Disconnect-VIServer -Server $global:DefaultVIServer -Confirm:$false | Out-Null
    }
}
