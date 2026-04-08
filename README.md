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
