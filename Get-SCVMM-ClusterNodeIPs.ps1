[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMMServer,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = '.\\SCVMM-ClusterNodeIPs.csv',

    [Parameter(Mandatory = $false)]
    [string]$AdminNetworkPattern = 'admin|mgmt|management',

    [Parameter(Mandatory = $false)]
    [string]$LiveMigrationPattern = 'live\\s*migration|livemig|\\blm\\b',

    [Parameter(Mandatory = $false)]
    [string]$ClusterPattern = '^cluster$|heartbeat|csv|quorum'
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $currentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $windowsPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    return $windowsPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    Write-Warning "Ce script doit être exécuté en tant qu'administrateur."
    Write-Host "Demande d'élévation UAC..." -ForegroundColor Yellow

    if (-not $PSCommandPath) {
        throw "Impossible de relancer automatiquement le script avec élévation : PSCommandPath est vide."
    }

    $argList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$PSCommandPath`""
    )

    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        $argList += "-$key"
        $argList += "`"$value`""
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

function Join-Set {
    param([System.Collections.Generic.HashSet[string]]$Set)
    if ($null -eq $Set -or $Set.Count -eq 0) { return $null }
    return (@($Set | Sort-Object) -join ';')
}

function Convert-IPv4ToUInt32 {
    param([string]$IPAddress)
    $bytes = ([System.Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()
    [array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
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

Write-Verbose "Connexion à SCVMM $VMMServer"
$server = Get-SCVMMServer -ComputerName $VMMServer
$vmHosts = @(Get-SCVMHost -VMMServer $server)

$rows = foreach ($vmHost in $vmHosts) {

    Write-Verbose "Traitement de $($vmHost.Name)"

    $adminIps          = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $liveMigrationIps  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $clusterTrafficIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $nodeIps           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $clusterIps        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $warnings = [System.Collections.Generic.List[string]]::new()

    try {
        $remoteData = Invoke-Command -ComputerName $vmHost.Name -ErrorAction Stop -ScriptBlock {
            $localIPs = @(
                Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred |
                Where-Object {
                    $_.IPAddress -and
                    $_.IPAddress -notlike '169.254.*' -and
                    $_.IPAddress -ne '127.0.0.1'
                } |
                Select-Object IPAddress, InterfaceAlias, PrefixLength
            )

            $clusterNetworks = @(
                Get-ClusterNetwork |
                Select-Object Name, Role, Address, AddressMask
            )

            $clusterIPs = @(
                Get-ClusterResource |
                Where-Object ResourceType -eq 'IP Address' |
                Get-ClusterParameter -Name Address -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Value
            )

            $clusterName = $null
            try {
                $clusterName = (Get-Cluster).Name
            }
            catch {}

            [pscustomobject]@{
                LocalIPs        = $localIPs
                ClusterNetworks = $clusterNetworks
                ClusterIPs      = $clusterIPs
                ClusterName     = $clusterName
            }
        }
    }
    catch {
        $warnings.Add("Invoke-Command sur $($vmHost.Name) impossible : $($_.Exception.Message)")
        [pscustomobject]@{
            Cluster           = 'Unknown'
            Node              = $vmHost.Name
            AdminIPs          = $null
            LiveMigrationIPs  = $null
            ClusterTrafficIPs = $null
            NodeIPs           = $null
            ClusterIPs        = $null
            Warnings          = $warnings -join ' | '
        }
        continue
    }

    foreach ($ip in @($remoteData.ClusterIPs)) {
        if (-not [string]::IsNullOrWhiteSpace($ip)) {
            [void]$clusterIps.Add([string]$ip)
        }
    }

    foreach ($ipObj in @($remoteData.LocalIPs)) {
        $ip = [string]$ipObj.IPAddress
        if (-not [string]::IsNullOrWhiteSpace($ip)) {
            [void]$nodeIps.Add($ip)
        }
    }

    foreach ($ipObj in @($remoteData.LocalIPs)) {
        $ip = [string]$ipObj.IPAddress
        $matched = $false

        foreach ($net in @($remoteData.ClusterNetworks)) {
            $netName = [string]$net.Name
            $role    = [string]$net.Role
            $addr    = [string]$net.Address
            $mask    = [string]$net.AddressMask

            if (-not (Test-IPv4InMaskNetwork -IPAddress $ip -NetworkAddress $addr -SubnetMask $mask)) {
                continue
            }

            $matched = $true

            if ($netName -match $LiveMigrationPattern) {
                [void]$liveMigrationIps.Add($ip)
                continue
            }

            if ($netName -match $AdminNetworkPattern -or $role -match 'ClusterAndClient|Client') {
                [void]$adminIps.Add($ip)
                continue
            }

            if ($netName -match $ClusterPattern -or $role -match '^Cluster$|Internal') {
                [void]$clusterTrafficIps.Add($ip)
                continue
            }
        }

        if (-not $matched) {
            # Pas dans un réseau cluster connu
            # on le laisse dans NodeIPs seulement
            $null = $null
        }
    }

    # fallback admin depuis SCVMM si vide
    if ($adminIps.Count -eq 0) {
        foreach ($prop in @('IPAddress','IPAddresses')) {
            $value = $vmHost.PSObject.Properties[$prop]
            if ($value) {
                foreach ($item in @($value.Value)) {
                    if ($item) {
                        [void]$adminIps.Add([string]$item)
                    }
                }
            }
        }
    }

    $otherNodeIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in $nodeIps) {
        if (-not $adminIps.Contains($ip) -and
            -not $liveMigrationIps.Contains($ip) -and
            -not $clusterTrafficIps.Contains($ip)) {
            [void]$otherNodeIps.Add($ip)
        }
    }

    [pscustomobject]@{
        Cluster           = if ($remoteData.ClusterName) { $remoteData.ClusterName } else { 'Standalone' }
        Node              = $vmHost.Name
        AdminIPs          = Join-Set $adminIps
        LiveMigrationIPs  = Join-Set $liveMigrationIps
        ClusterTrafficIPs = Join-Set $clusterTrafficIps
        NodeIPs           = Join-Set $otherNodeIps
        ClusterIPs        = Join-Set $clusterIps
        Warnings          = if ($warnings.Count -gt 0) { $warnings -join ' | ' } else { $null }
    }
}

$rows |
    Sort-Object Cluster, Node |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export completed: $OutputPath"
Write-Host "Rows exported: $($rows.Count)"
