<#
.SYNOPSIS
Creates SCVMM VM networks and subnets from CSV input.

.DESCRIPTION
Reads a CSV file that contains Name, VLAN id, and subnet columns and creates (or validates)
matching VM networks and VM subnets in SCVMM. The target Logical Switch is provided at
runtime via the -LogicalSwitchName parameter.

The script is idempotent:
- Existing VM networks are reused.
- Existing VM subnets are reused.
- Existing subnet/VLAN combinations are detected and not recreated.

CSV columns (header names are case-insensitive):
- Name        (required): VM network and subnet name.
- VLAN id     (required): VLAN ID (1-4094).
- subnet      (required): IPv4/IPv6 CIDR notation (for example 10.10.20.0/24).

.NOTES
- Requires the VirtualMachineManager PowerShell module.
- Designed for System Center Virtual Machine Manager (SCVMM).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMMServer,

    [Parameter(Mandatory = $true)]
    [string]$LogicalSwitchName,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RowValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,

        [Parameter(Mandatory = $true)]
        [string[]]$ColumnNames,

        [Parameter(Mandatory = $false)]
        [switch]$Required
    )

    foreach ($columnName in $ColumnNames) {
        if ($Row.PSObject.Properties.Name -contains $columnName) {
            $value = [string]$Row.$columnName
            if ($null -ne $value) {
                $value = $value.Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    if ($Required.IsPresent) {
        throw "Missing required value. Accepted column names: $($ColumnNames -join ', ')"
    }

    return $null
}

Write-Verbose "Connecting to SCVMM server '$VMMServer'..."
Import-Module VirtualMachineManager -ErrorAction Stop
$null = Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop

$logicalSwitch = Get-SCLogicalSwitch -VMMServer $VMMServer -Name $LogicalSwitchName -ErrorAction SilentlyContinue
if ($null -eq $logicalSwitch) {
    throw "Logical switch '$LogicalSwitchName' was not found on VMM server '$VMMServer'."
}

Write-Verbose "Logical switch '$LogicalSwitchName' found."
$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -eq 0) {
    throw "CSV '$CsvPath' contains no data rows."
}

foreach ($row in $rows) {
    $networkName = Get-RowValue -Row $row -ColumnNames @('Name', 'name') -Required
    $vlanText = Get-RowValue -Row $row -ColumnNames @('VLAN id', 'VLAN Id', 'vlan id', 'VLAN', 'vlan') -Required
    $subnet = Get-RowValue -Row $row -ColumnNames @('subnet', 'Subnet') -Required

    $parsedVlan = 0
    if (-not [int]::TryParse($vlanText, [ref]$parsedVlan)) {
        throw "Row '$networkName' has invalid VLAN id '$vlanText'."
    }

    $vlanId = [int]$parsedVlan
    if ($vlanId -lt 1 -or $vlanId -gt 4094) {
        throw "Row '$networkName' has VLAN id '$vlanId' out of range (1-4094)."
    }

    # Validate CIDR format quickly.
    if ($subnet -notmatch '^.+\/\d{1,3}$') {
        throw "Row '$networkName' has invalid subnet '$subnet'. Expected CIDR format (example: 10.10.20.0/24)."
    }

    $existingVmNetwork = Get-SCVMNetwork -VMMServer $VMMServer -Name $networkName -ErrorAction SilentlyContinue
    if ($null -eq $existingVmNetwork) {
        if ($PSCmdlet.ShouldProcess($networkName, "Create VM network on logical network '$LogicalSwitchName'")) {
            Write-Host "Creating VM network '$networkName'..."
            $existingVmNetwork = New-SCVMNetwork -VMMServer $VMMServer -Name $networkName -LogicalNetwork $logicalSwitch.LogicalNetwork
        }
    }
    else {
        Write-Host "VM network '$networkName' already exists. Reusing it."
    }

    $existingVmSubnet = Get-SCVMSubnet -VMMServer $VMMServer -VMNetwork $existingVmNetwork -Name $networkName -ErrorAction SilentlyContinue
    if ($null -eq $existingVmSubnet) {
        $subnetVlan = New-SCVMSubnetVLAN -Subnet $subnet -VLanID $vlanId
        if ($PSCmdlet.ShouldProcess($networkName, "Create VM subnet '$networkName' ($subnet / VLAN $vlanId)")) {
            Write-Host "Creating VM subnet '$networkName' on '$networkName' with subnet '$subnet' and VLAN '$vlanId'..."
            $null = New-SCVMSubnet -VMMServer $VMMServer -Name $networkName -VMNetwork $existingVmNetwork -SubnetVLan $subnetVlan
        }
    }
    else {
        $matchesSubnetVlan = $false
        $subnetVlans = @($existingVmSubnet.SubnetVLans)
        foreach ($item in $subnetVlans) {
            if ($item.Subnet -eq $subnet -and $item.VLanID -eq $vlanId) {
                $matchesSubnetVlan = $true
                break
            }
        }

        if ($matchesSubnetVlan) {
            Write-Host "VM subnet '$networkName' already exists with subnet '$subnet' and VLAN '$vlanId'."
        }
        else {
            Write-Warning "VM subnet '$networkName' exists but with different subnet/VLAN settings. No changes were made."
        }
    }
}

Write-Host "Completed processing CSV '$CsvPath'."
