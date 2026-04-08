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
