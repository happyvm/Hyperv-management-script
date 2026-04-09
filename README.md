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
