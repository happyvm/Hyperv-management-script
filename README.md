# Hyperv-management-script

## SCVMM RVTools-like vInfo export

Use `Get-SCVMM-RVTools-vInfo.ps1` to export an RVTools-style VM inventory (vInfo-like CSV) directly from SCVMM.

The script is defensive against missing SCVMM properties (for example `HostCluster`) so it works across different SCVMM object versions.

### Example

```powershell
.\Get-SCVMM-RVTools-vInfo.ps1 -VMMServer "vmm01.contoso.local" -OutputPath ".\SCVMM-vInfo.csv"
```

Use `-Delimiter ';'` (default) for semicolon-separated CSV, or `-Delimiter ','` for comma-separated CSV.

### Output columns

- VM
- PowerState
- OS
- CPUs
- MemoryGB
- MemoryMinGB
- MemoryMaxGB
- DynamicMemory
- Host
- Cluster
- Cloud
- HighlyAvailable
- CreationTime
- Owner
- Description
- DiskProvisionedGB
- DiskUsedGB
- Firmware
- IntegrationServices
- NICCount
- CPUCompatibilityMode
- IPAddresses
- ConnectedNetworks
- HardwareVersion
- HostingVolume

## SCVMM cluster volume export

Use `Get-SCVMM-ClusterVolumes.ps1` to export CSV volume details (including LUN-related identity) for SCVMM-managed Hyper-V clusters.

For Pure Storage-backed disks, the script now prefers the disk serial number for the `LUN` column so the value maps more closely to Pure array-side volume identity.

## SCVMM cluster node + cluster IP list export

Use `Get-SCVMM-ClusterNodeIPs.ps1` to export IPs for:

- Admin/management host IPs
- Live migration network IPs
- Cluster traffic IPs
- Cluster virtual/service IPs (when exposed by SCVMM)
- Virtual switch interface IPs exposed on host adapters/switch objects
- Additional switch-level IP recovery via SCVMM virtual switch / virtual adapter cmdlets when available
- DNS host-name fallback when SCVMM adapter/switch objects expose no IPs

The CSV now exports one row per node with role-based columns:

- `Cluster`
- `Node`
- `AdminIPs`
- `AdminInterfaces`
- `LiveMigrationIPs`
- `LiveMigrationInterfaces`
- `ClusterTrafficIPs`
- `ClusterTrafficInterfaces`
- `NodeIPs`
- `NodeInterfaces`
- `ClusterIPs`

Each `*IPs` column is a semicolon-separated list of unique IP addresses.

## SCVMM network implementation from CSV

Use `New-SCVMM-NetworksFromCsv.ps1` to create VM networks + VM subnets in SCVMM from a CSV file.

Required CSV headers (case-insensitive):
- `Name`
- `VLAN id`
- `subnet` (CIDR, for example `10.10.20.0/24`)

### Example

```powershell
.\New-SCVMM-NetworksFromCsv.ps1 \
  -VMMServer "vmm01.contoso.local" \
  -LogicalSwitchName "Prod-LogicalSwitch" \
  -CsvPath ".\networks.csv" \
  -Verbose
```

Use `-WhatIf` first to validate what would be created without making changes.

## SCVMM node capacity audit (CPU / RAM / disque)

Use `Get-SCVMM-NodeCapacityAudit.ps1` to export per-node capacity and remaining resources for SCVMM-managed Hyper-V hosts.

### Example

```powershell
.\Get-SCVMM-NodeCapacityAudit.ps1 -VMMServer "vmm01.contoso.local" -OutputPath ".\SCVMM-NodeCapacityAudit.csv"
```

Exported columns include:

- `Cluster`
- `Node`
- `CPU_Logical_Total`
- `CPU_vCPU_Allocated`
- `CPU_Logical_Remaining`
- `RAM_Total_GB`
- `RAM_Allocated_GB`
- `RAM_Available_GB`
- `Disk_Total_GB`
- `Disk_Allocated_GB`
- `Disk_Available_GB`
- `VM_Count`

## Diagnostic Live Migration Hyper-V

Use `Get-HyperVLiveMigrationReadiness.ps1` to validate the main prerequisites for Hyper-V Live Migration inside one cluster and between two external Hyper-V clusters.

Because this repository targets SCVMM-managed Hyper-V environments, pass `-VMMServer` so the script discovers the nodes of each cluster from SCVMM (`Get-SCVMHost` / `HostCluster`). If `-VMMServer` is omitted or SCVMM discovery finds no host for a cluster, the script falls back to `Get-ClusterNode`.

The script performs non-destructive checks for:

- SCVMM-based cluster node discovery, with Failover Clustering fallback
- Failover Clustering / Hyper-V / WinRM / SMB services
- Hyper-V Live Migration settings (`Get-VMHost`)
- Live Migration authentication mode and performance option consistency
- allowed Live Migration networks
- virtual switch name consistency across nodes and clusters
- TCP connectivity between nodes for Live Migration (`6600` by default), SMB (`445`) and WinRM (`5985`)
- inter-cluster Active Directory / Kerberos delegation reminders

### Examples

Validate one SCVMM-managed Hyper-V cluster:

```powershell
.\Get-HyperVLiveMigrationReadiness.ps1 `
  -VMMServer "vmm01.contoso.local" `
  -SourceClusterName "HV-CLUS01" `
  -Verbose
```

Validate Live Migration readiness between two SCVMM-managed Hyper-V clusters:

```powershell
.\Get-HyperVLiveMigrationReadiness.ps1 `
  -VMMServer "vmm01.contoso.local" `
  -SourceClusterName "HV-CLUS01" `
  -DestinationClusterName "HV-CLUS02" `
  -OutputDirectory "C:\Temp\LM-Diag"
```

The script writes CSV and JSON reports under `HyperV-LiveMigrationReadiness` by default.

## VLAN vCenter vs SCVMM comparison

Use `Get-VLANComparison-vCenter-SCVMM.ps1` to list and compare VLAN IDs / VLAN names that exist in vCenter and in SCVMM.

### Example

```powershell
.\Get-VLANComparison-vCenter-SCVMM.ps1 \
  -VCenterServer "vcenter01.contoso.local" \
  -SCVMMServer "vmm01.contoso.local" \
  -OutputPath ".\VLAN-Comparison.csv"
```

Main output columns:

- `VLANID`
- `VLANName_vCenter`
- `VLANName_SCVMM`
- `In_vCenter`
- `In_SCVMM`
- `MatchStatus` (`PresentInBoth`, `OnlyInVCenter`, `OnlyInSCVMM`)
