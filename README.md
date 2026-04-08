# Hyperv-management-script

## SCVMM RVTools-like vInfo export

Use `Get-SCVMM-RVTools-vInfo.ps1` to export an RVTools-style VM inventory (vInfo-like CSV) directly from SCVMM.

### Example

```powershell
.\Get-SCVMM-RVTools-vInfo.ps1 -VMMServer "vmm01.contoso.local" -OutputPath ".\SCVMM-vInfo.csv"
```

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


## SCVMM Hyper-V node IP export

Use `Get-SCVMM-ClusterNodeIPs.ps1` to export the IPs used by each Hyper-V node (clustered or standalone) managed by SCVMM.

### Example

```powershell
.\Get-SCVMM-ClusterNodeIPs.ps1 -VMMServer "vmm01.contoso.local" -OutputPath ".\SCVMM-ClusterNodeIPs.csv"
```

### Output columns

- Cluster
- Node
- IP

## SCVMM Hyper-V cluster volume + LUN export

Use `Get-SCVMM-ClusterVolumes.ps1` to export cluster shared volumes with volume name and LUN-related details.

### Example

```powershell
.\Get-SCVMM-ClusterVolumes.ps1 -VMMServer "vmm01.contoso.local" -OutputPath ".\SCVMM-ClusterVolumes.csv"
```

### Output columns

- Cluster
- VolumeName
- VolumePath
- OwnerNode
- DiskNumber
- DiskFriendlyName
- DiskLocation
- LUN
- SizeGB
