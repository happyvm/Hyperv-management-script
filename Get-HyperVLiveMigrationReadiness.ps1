<#
.SYNOPSIS
Diagnostique les prérequis Live Migration Hyper-V intra-cluster et inter-clusters.

.DESCRIPTION
Ce script exécute des contrôles non destructifs sur un ou plusieurs clusters Hyper-V afin de valider les paramètres nécessaires au bon fonctionnement de la Live Migration:
- disponibilité des modules/outils d'administration côté poste d'exécution;
- découverte des nœuds via SCVMM lorsque -VMMServer est fourni, avec repli possible via Failover Clustering;
- état des nœuds et services Cluster / Hyper-V / WinRM;
- configuration Live Migration Hyper-V (activation, authentification, performance, nombre de migrations simultanées, réseaux autorisés);
- cohérence des commutateurs virtuels entre nœuds;
- connectivité réseau entre nœuds sur les ports usuels de Live Migration, SMB et WinRM;
- points d'attention spécifiques aux migrations inter-clusters / shared-nothing.

Le script n'applique aucune correction. Il produit un rapport console et des exports CSV/JSON.

.PARAMETER VMMServer
Nom du serveur SCVMM à utiliser pour découvrir les nœuds des clusters Hyper-V.
Lorsque ce paramètre est fourni, la découverte des nœuds utilise Get-SCVMHost et les objets HostCluster SCVMM avant tout repli Failover Clustering.

.PARAMETER SourceClusterName
Nom du cluster Hyper-V source à contrôler.

.PARAMETER DestinationClusterName
Nom d'un cluster Hyper-V externe/destination. Lorsque renseigné, le script ajoute des contrôles inter-clusters.

.PARAMETER Credential
Identifiants optionnels utilisés pour les commandes distantes Invoke-Command.

.PARAMETER OutputDirectory
Dossier de sortie des rapports CSV et JSON.

.PARAMETER Delimiter
Délimiteur CSV.

.PARAMETER SkipNetworkConnectivity
Ignore les tests Test-NetConnection entre nœuds.

.PARAMETER LiveMigrationPort
Port TCP Live Migration Hyper-V à tester. La valeur par défaut est 6600.

.EXAMPLE
.\Get-HyperVLiveMigrationReadiness.ps1 -VMMServer VMM01 -SourceClusterName HV-CLUS01 -Verbose

.EXAMPLE
.\Get-HyperVLiveMigrationReadiness.ps1 -VMMServer VMM01 -SourceClusterName HV-CLUS01 -DestinationClusterName HV-CLUS02 -OutputDirectory C:\Temp\LM-Diag

.NOTES
Modules recommandés côté poste d'exécution: VirtualMachineManager si -VMMServer est utilisé, FailoverClusters pour le repli local, Hyper-V.
Droits recommandés: administrateur local sur les nœuds Hyper-V et droits de lecture sur les clusters.
Pour les migrations inter-clusters avec Kerberos, vérifier aussi la délégation contrainte Active Directory des comptes ordinateurs Hyper-V vers les services Microsoft Virtual System Migration Service et CIFS si nécessaire.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$VMMServer,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceClusterName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationClusterName,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = '.\HyperV-LiveMigrationReadiness',

    [Parameter(Mandatory = $false)]
    [ValidateSet(';', ',')]
    [string]$Delimiter = ';',

    [Parameter(Mandatory = $false)]
    [switch]$SkipNetworkConnectivity,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 65535)]
    [int]$LiveMigrationPort = 6600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$findings = [System.Collections.Generic.List[object]]::new()
$nodeInventories = [System.Collections.Generic.List[object]]::new()
$connectivityRows = [System.Collections.Generic.List[object]]::new()
$vmmConnection = $null
$scvmmHosts = @()

function Add-Finding {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Warning', 'Fail', 'Info')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Details,
        [Parameter(Mandatory = $false)][string]$Recommendation = ''
    )

    $findings.Add([pscustomobject]@{
        Scope          = $Scope
        Target         = $Target
        Check          = $Check
        Status         = $Status
        Details        = $Details
        Recommendation = $Recommendation
    }) | Out-Null
}

function Join-Value {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }

    try {
        return (@($Value) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique) -join ', '
    }
    catch {
        return [string]$Value
    }
}

function Test-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $PropertyName) {
        return $Object.$PropertyName
    }

    return $null
}

function Get-NormalizedInventoryName {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return $Name.Trim().ToLowerInvariant()
}

function Get-ShortInventoryName {
    param([AllowNull()][string]$Name)

    $normalized = Get-NormalizedInventoryName -Name $Name
    if ([string]::IsNullOrWhiteSpace($normalized)) { return '' }

    $dotIndex = $normalized.IndexOf('.')
    if ($dotIndex -gt 0) {
        return $normalized.Substring(0, $dotIndex)
    }

    return $normalized
}

function Test-InventoryNameMatch {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    $leftFull = Get-NormalizedInventoryName -Name $Left
    $rightFull = Get-NormalizedInventoryName -Name $Right
    $leftShort = Get-ShortInventoryName -Name $Left
    $rightShort = Get-ShortInventoryName -Name $Right

    return (
        -not [string]::IsNullOrWhiteSpace($leftFull) -and
        -not [string]::IsNullOrWhiteSpace($rightFull) -and
        ($leftFull -eq $rightFull -or $leftShort -eq $rightShort)
    )
}

function Get-SCVMMHostConnectionName {
    param([Parameter(Mandatory = $true)]$VMHost)

    foreach ($propertyName in @('FullyQualifiedDomainName', 'FQDN', 'ComputerName', 'Name')) {
        $value = Get-OptionalPropertyValue -Object $VMHost -PropertyName $propertyName
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }

    return $null
}

function Get-SCVMMHostClusterNames {
    param([Parameter(Mandatory = $true)]$VMHost)

    $names = [System.Collections.Generic.List[string]]::new()
    $hostCluster = Get-OptionalPropertyValue -Object $VMHost -PropertyName 'HostCluster'
    if ($hostCluster) {
        foreach ($propertyName in @('Name', 'ClusterName', 'FullyQualifiedDomainName', 'FQDN')) {
            $value = Get-OptionalPropertyValue -Object $hostCluster -PropertyName $propertyName
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                $names.Add([string]$value) | Out-Null
            }
        }
    }

    foreach ($propertyName in @('HostClusterName', 'ClusterName')) {
        $value = Get-OptionalPropertyValue -Object $VMHost -PropertyName $propertyName
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $names.Add([string]$value) | Out-Null
        }
    }

    return @($names | Sort-Object -Unique)
}

function Get-ClusterNodeNamesFromSCVMM {
    param([Parameter(Mandatory = $true)][string]$ClusterName)

    if ([string]::IsNullOrWhiteSpace($VMMServer) -or $scvmmHosts.Count -eq 0) {
        return @()
    }

    $matchingHosts = @(
        $scvmmHosts |
        Where-Object {
            $clusterNames = @(Get-SCVMMHostClusterNames -VMHost $_)
            @($clusterNames | Where-Object { Test-InventoryNameMatch -Left $_ -Right $ClusterName }).Count -gt 0
        }
    )

    if ($matchingHosts.Count -eq 0) {
        Add-Finding -Scope 'SCVMM' -Target $ClusterName -Check 'Découverte des nœuds' -Status 'Warning' -Details "Aucun hôte SCVMM rattaché à ce cluster n'a été trouvé." -Recommendation 'Vérifier le nom du cluster dans SCVMM ou utiliser le nom court/FQDN exact exposé par HostCluster.'
        return @()
    }

    foreach ($vmHost in $matchingHosts) {
        $hostName = Get-SCVMMHostConnectionName -VMHost $vmHost
        $stateValues = @()
        foreach ($propertyName in @('OverallState', 'Status', 'State', 'ComputerState')) {
            $value = Get-OptionalPropertyValue -Object $vmHost -PropertyName $propertyName
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                $stateValues += ("{0}={1}" -f $propertyName, $value)
            }
        }

        $stateDetails = if ($stateValues.Count -gt 0) { $stateValues -join '; ' } else { 'État SCVMM non exposé.' }
        $status = if ($stateDetails -match 'NeedsAttention|NotResponding|Unresponsive|Error|Failed|Pending') { 'Warning' } else { 'Info' }
        Add-Finding -Scope 'SCVMM' -Target $hostName -Check "Hôte découvert pour $ClusterName" -Status $status -Details $stateDetails -Recommendation 'Si SCVMM indique une anomalie, corriger l’état de l’hôte avant de lancer une Live Migration.'
    }

    $nodeNames = @(
        $matchingHosts |
        ForEach-Object { Get-SCVMMHostConnectionName -VMHost $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Sort-Object -Unique
    )

    Add-Finding -Scope 'SCVMM' -Target $ClusterName -Check 'Découverte des nœuds' -Status 'Pass' -Details ("{0} nœud(s): {1}" -f $nodeNames.Count, (Join-Value $nodeNames))
    return $nodeNames
}

function Invoke-RemoteNodeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $false)][object[]]$ArgumentList = @()
    )

    $invokeParams = @{
        ComputerName = $ComputerName
        ScriptBlock  = $ScriptBlock
        ErrorAction  = 'Stop'
    }

    if ($ArgumentList.Count -gt 0) {
        $invokeParams.ArgumentList = $ArgumentList
    }

    if ($null -ne $Credential) {
        $invokeParams.Credential = $Credential
    }

    Invoke-Command @invokeParams
}

function Get-ClusterNodeNamesSafe {
    param([Parameter(Mandatory = $true)][string]$ClusterName)

    $scvmmNodeNames = @(Get-ClusterNodeNamesFromSCVMM -ClusterName $ClusterName)
    if ($scvmmNodeNames.Count -gt 0) {
        return $scvmmNodeNames
    }

    try {
        $nodes = @(Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop)
        if ($nodes.Count -eq 0) {
            Add-Finding -Scope 'Cluster' -Target $ClusterName -Check 'Nœuds du cluster' -Status 'Fail' -Details 'Aucun nœud retourné par Get-ClusterNode.' -Recommendation 'Vérifier le nom du cluster et les droits utilisés.'
            return @()
        }

        foreach ($node in $nodes) {
            $state = [string]$node.State
            if ($state -eq 'Up') {
                Add-Finding -Scope 'Cluster' -Target $ClusterName -Check "État du nœud $($node.Name)" -Status 'Pass' -Details "Le nœud est $state."
            }
            else {
                Add-Finding -Scope 'Cluster' -Target $ClusterName -Check "État du nœud $($node.Name)" -Status 'Fail' -Details "Le nœud est $state." -Recommendation 'La Live Migration nécessite des nœuds de cluster en état Up.'
            }
        }

        return @($nodes | Select-Object -ExpandProperty Name)
    }
    catch {
        $recommendation = if ([string]::IsNullOrWhiteSpace($VMMServer)) {
            'Installer le module FailoverClusters, vérifier le DNS/RPC et les droits sur le cluster, ou fournir -VMMServer pour découvrir les nœuds via SCVMM.'
        }
        else {
            'La découverte SCVMM n’a pas retourné de nœud et le repli FailoverClusters a échoué. Vérifier le nom du cluster dans SCVMM, DNS/RPC et les droits.'
        }
        Add-Finding -Scope 'Cluster' -Target $ClusterName -Check 'Lecture des nœuds du cluster' -Status 'Fail' -Details $_.Exception.Message -Recommendation $recommendation
        return @()
    }
}

function Get-NodeInventory {
    param(
        [Parameter(Mandatory = $true)][string]$ClusterName,
        [Parameter(Mandatory = $true)][string]$NodeName
    )

    Write-Verbose "Inventaire du nœud $NodeName"

    try {
        $data = Invoke-RemoteNodeCommand -ComputerName $NodeName -ScriptBlock {
            $vmHost = $null
            $vmHostError = $null
            try {
                Import-Module Hyper-V -ErrorAction Stop
                $vmHost = Get-VMHost -ErrorAction Stop
            }
            catch {
                $vmHostError = $_.Exception.Message
            }

            $clusterNetworks = @()
            try {
                Import-Module FailoverClusters -ErrorAction Stop
                $clusterNetworks = @(
                    Get-ClusterNetwork |
                    ForEach-Object {
                        $roleValue = [int]$_.Role
                        [pscustomobject]@{
                            Name                 = $_.Name
                            Role                 = $roleValue
                            Address              = $_.Address
                            AddressMask          = $_.AddressMask
                            Metric               = $_.Metric
                            AutoMetric           = $_.AutoMetric
                            AllowsClusterTraffic = (($roleValue -band 1) -eq 1)
                        }
                    }
                )
            }
            catch {
                $clusterNetworks = @()
            }

            $switches = @()
            try {
                $switches = @(Get-VMSwitch | Select-Object Name, SwitchType, NetAdapterInterfaceDescription)
            }
            catch {
                $switches = @()
            }

            $ips = @()
            try {
                $ips = @(
                    Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred |
                    Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
                    Select-Object IPAddress, InterfaceAlias, PrefixLength
                )
            }
            catch {
                $ips = @()
            }

            $adapters = @()
            try {
                $adapters = @(
                    Get-NetAdapter |
                    Where-Object { $_.Status -ne 'Disabled' } |
                    Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress
                )
            }
            catch {
                $adapters = @()
            }

            $services = foreach ($serviceName in @('vmms', 'clussvc', 'WinRM', 'LanmanServer', 'W32Time')) {
                try {
                    Get-Service -Name $serviceName -ErrorAction Stop | Select-Object Name, Status, StartType
                }
                catch {
                    [pscustomobject]@{ Name = $serviceName; Status = 'NotFound'; StartType = $null }
                }
            }

            $firewallProfiles = @()
            try {
                $firewallProfiles = @(Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction)
            }
            catch {
                $firewallProfiles = @()
            }

            $firewallRules = @()
            try {
                $firewallRules = @(
                    Get-NetFirewallRule -DisplayGroup 'Hyper-V' -ErrorAction SilentlyContinue |
                    Select-Object DisplayName, Enabled, Direction, Action, Profile
                )
                if ($firewallRules.Count -eq 0) {
                    $firewallRules = @(
                        Get-NetFirewallRule -DisplayName '*Hyper-V*' -ErrorAction SilentlyContinue |
                        Select-Object DisplayName, Enabled, Direction, Action, Profile
                    )
                }
            }
            catch { $firewallRules = @() }

            $ntpSource = 'Unknown'
            $ntpType   = 'Unknown'
            try {
                $w32tParams = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction Stop
                if ($w32tParams.PSObject.Properties.Name -contains 'NtpServer') { $ntpSource = [string]$w32tParams.NtpServer }
                if ($w32tParams.PSObject.Properties.Name -contains 'Type')      { $ntpType   = [string]$w32tParams.Type }
            }
            catch {}

            [pscustomobject]@{
                ComputerName                               = $env:COMPUTERNAME
                FullyQualifiedDomainName                   = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName)
                Domain                                     = (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
                VMHostReadError                            = $vmHostError
                VirtualMachineMigrationEnabled             = if ($vmHost) { $vmHost.VirtualMachineMigrationEnabled } else { $null }
                VirtualMachineMigrationAuthenticationType  = if ($vmHost) { [string]$vmHost.VirtualMachineMigrationAuthenticationType } else { $null }
                VirtualMachineMigrationPerformanceOption   = if ($vmHost) { [string]$vmHost.VirtualMachineMigrationPerformanceOption } else { $null }
                MaximumVirtualMachineMigrations            = if ($vmHost) { $vmHost.MaximumVirtualMachineMigrations } else { $null }
                VirtualMachineMigrationNetworks            = if ($vmHost) { @($vmHost.VirtualMachineMigrationNetworks) } else { @() }
                NumaSpanningEnabled                        = if ($vmHost) { $vmHost.NumaSpanningEnabled } else { $null }
                Services                                   = @($services)
                ClusterNetworks                            = @($clusterNetworks)
                VMSwitches                                 = @($switches)
                IPv4Addresses                              = @($ips)
                NetAdapters                                = @($adapters)
                FirewallProfiles                           = @($firewallProfiles)
                FirewallRules                              = @($firewallRules)
                NtpSource                                  = $ntpSource
                NtpType                                    = $ntpType
            }
        }

        $inventory = [pscustomobject]@{
            ClusterName                                = $ClusterName
            NodeName                                   = $NodeName
            ComputerName                               = $data.ComputerName
            FullyQualifiedDomainName                   = $data.FullyQualifiedDomainName
            Domain                                     = $data.Domain
            VMHostReadError                            = $data.VMHostReadError
            VirtualMachineMigrationEnabled             = $data.VirtualMachineMigrationEnabled
            VirtualMachineMigrationAuthenticationType  = $data.VirtualMachineMigrationAuthenticationType
            VirtualMachineMigrationPerformanceOption   = $data.VirtualMachineMigrationPerformanceOption
            MaximumVirtualMachineMigrations            = $data.MaximumVirtualMachineMigrations
            VirtualMachineMigrationNetworks            = @($data.VirtualMachineMigrationNetworks)
            NumaSpanningEnabled                        = $data.NumaSpanningEnabled
            Services                                   = @($data.Services)
            ClusterNetworks                            = @($data.ClusterNetworks)
            VMSwitches                                 = @($data.VMSwitches)
            IPv4Addresses                              = @($data.IPv4Addresses)
            NetAdapters                                = @($data.NetAdapters)
            FirewallProfiles                           = @($data.FirewallProfiles)
            FirewallRules                              = @($data.FirewallRules)
            NtpSource                                  = $data.NtpSource
            NtpType                                    = $data.NtpType
        }

        $nodeInventories.Add($inventory) | Out-Null
        return $inventory
    }
    catch {
        Add-Finding -Scope 'Node' -Target $NodeName -Check 'Inventaire distant' -Status 'Fail' -Details $_.Exception.Message -Recommendation 'Vérifier WinRM/PowerShell Remoting, DNS, pare-feu et droits administrateur local.'
        return $null
    }
}

function Test-NodeInventory {
    param([Parameter(Mandatory = $true)]$Inventory)

    $target = $Inventory.NodeName

    if ([string]::IsNullOrWhiteSpace($Inventory.VMHostReadError)) {
        Add-Finding -Scope 'Node' -Target $target -Check 'Module Hyper-V / Get-VMHost' -Status 'Pass' -Details 'Get-VMHost a retourné la configuration Hyper-V.'
    }
    else {
        Add-Finding -Scope 'Node' -Target $target -Check 'Module Hyper-V / Get-VMHost' -Status 'Fail' -Details $Inventory.VMHostReadError -Recommendation 'Installer le rôle/outils Hyper-V et vérifier les droits.'
        return
    }

    foreach ($serviceName in @('vmms', 'clussvc', 'WinRM', 'LanmanServer')) {
        $service = @($Inventory.Services | Where-Object { $_.Name -eq $serviceName } | Select-Object -First 1)
        if ($service.Count -eq 0 -or [string]$service[0].Status -eq 'NotFound') {
            Add-Finding -Scope 'Node' -Target $target -Check "Service $serviceName" -Status 'Fail' -Details 'Service introuvable.' -Recommendation 'Vérifier le rôle Windows installé sur le nœud.'
        }
        elseif ([string]$service[0].Status -eq 'Running') {
            Add-Finding -Scope 'Node' -Target $target -Check "Service $serviceName" -Status 'Pass' -Details 'Service démarré.'
        }
        else {
            Add-Finding -Scope 'Node' -Target $target -Check "Service $serviceName" -Status 'Fail' -Details "État: $($service[0].Status)." -Recommendation 'Démarrer le service et corriger sa cause d’arrêt.'
        }
    }

    if ($Inventory.VirtualMachineMigrationEnabled -eq $true) {
        Add-Finding -Scope 'Node' -Target $target -Check 'Live Migration activée' -Status 'Pass' -Details 'VirtualMachineMigrationEnabled = True.'
    }
    else {
        Add-Finding -Scope 'Node' -Target $target -Check 'Live Migration activée' -Status 'Fail' -Details "VirtualMachineMigrationEnabled = $($Inventory.VirtualMachineMigrationEnabled)." -Recommendation 'Activer les migrations dynamiques dans les paramètres Hyper-V ou via Set-VMHost -VirtualMachineMigrationEnabled $true.'
    }

    if ([string]::IsNullOrWhiteSpace($Inventory.VirtualMachineMigrationAuthenticationType)) {
        Add-Finding -Scope 'Node' -Target $target -Check 'Authentification Live Migration' -Status 'Warning' -Details 'Type non déterminé.' -Recommendation 'Vérifier Get-VMHost sur le nœud.'
    }
    elseif ($Inventory.VirtualMachineMigrationAuthenticationType -eq 'Kerberos') {
        Add-Finding -Scope 'Node' -Target $target -Check 'Authentification Live Migration' -Status 'Pass' -Details 'Kerberos est configuré.'
    }
    elseif ($Inventory.VirtualMachineMigrationAuthenticationType -eq 'CredSSP') {
        Add-Finding -Scope 'Node' -Target $target -Check 'Authentification Live Migration' -Status 'Warning' -Details 'CredSSP est configuré.' -Recommendation 'CredSSP fonctionne surtout pour une migration lancée depuis une session interactive sur le nœud source. Pour l’orchestration distante/inter-clusters, Kerberos avec délégation contrainte est généralement recommandé.'
    }
    else {
        Add-Finding -Scope 'Node' -Target $target -Check 'Authentification Live Migration' -Status 'Warning' -Details "Type: $($Inventory.VirtualMachineMigrationAuthenticationType)." -Recommendation 'Valider que ce mode correspond au scénario opérationnel.'
    }

    if ($null -ne $Inventory.MaximumVirtualMachineMigrations -and [int]$Inventory.MaximumVirtualMachineMigrations -gt 0) {
        Add-Finding -Scope 'Node' -Target $target -Check 'Migrations simultanées' -Status 'Pass' -Details "MaximumVirtualMachineMigrations = $($Inventory.MaximumVirtualMachineMigrations)."
    }
    else {
        Add-Finding -Scope 'Node' -Target $target -Check 'Migrations simultanées' -Status 'Warning' -Details "MaximumVirtualMachineMigrations = $($Inventory.MaximumVirtualMachineMigrations)." -Recommendation 'Configurer une valeur supérieure à 0.'
    }

    $lmNetworks = @($Inventory.VirtualMachineMigrationNetworks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($lmNetworks.Count -gt 0) {
        Add-Finding -Scope 'Node' -Target $target -Check 'Réseaux Live Migration autorisés' -Status 'Pass' -Details ("Réseaux: {0}" -f (Join-Value $lmNetworks))
    }
    else {
        Add-Finding -Scope 'Node' -Target $target -Check 'Réseaux Live Migration autorisés' -Status 'Warning' -Details 'Aucun réseau dédié listé dans Get-VMHost.' -Recommendation 'Définir explicitement les sous-réseaux Live Migration pour éviter l’usage d’un mauvais réseau.'
    }

    $clusterLmNetworks = @($Inventory.ClusterNetworks | Where-Object { $_.AllowsClusterTraffic -eq $true })
    if ($clusterLmNetworks.Count -gt 0) {
        Add-Finding -Scope 'Node' -Target $target -Check 'Réseaux cluster autorisant le trafic cluster' -Status 'Pass' -Details ("Réseaux: {0}" -f (Join-Value ($clusterLmNetworks | ForEach-Object { $_.Name })))
    }
    else {
        Add-Finding -Scope 'Node' -Target $target -Check 'Réseaux cluster autorisant le trafic cluster' -Status 'Warning' -Details 'Aucun réseau cluster avec Role autorisant le trafic cluster trouvé.' -Recommendation 'Vérifier Get-ClusterNetwork et le rôle des réseaux utilisés par le cluster.'
    }

    $externalSwitches = @($Inventory.VMSwitches | Where-Object { $_.SwitchType -eq 'External' })
    if ($externalSwitches.Count -gt 0) {
        Add-Finding -Scope 'Node' -Target $target -Check 'Commutateurs virtuels externes' -Status 'Pass' -Details ("Switches: {0}" -f (Join-Value ($externalSwitches | ForEach-Object { $_.Name })))
    }
    else {
        Add-Finding -Scope 'Node' -Target $target -Check 'Commutateurs virtuels externes' -Status 'Warning' -Details 'Aucun vSwitch externe détecté.' -Recommendation 'Les VM migrées doivent retrouver un commutateur virtuel compatible sur le nœud cible.'
    }

    $ipv4 = @($Inventory.IPv4Addresses)
    if ($ipv4.Count -gt 0) {
        Add-Finding -Scope 'Node' -Target $target -Check 'Adresses IPv4 utilisables' -Status 'Pass' -Details ("IPv4: {0}" -f (Join-Value ($ipv4 | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)[$($_.InterfaceAlias)]" })))
    }
    else {
        Add-Finding -Scope 'Node' -Target $target -Check 'Adresses IPv4 utilisables' -Status 'Fail' -Details 'Aucune IPv4 non APIPA/loopback trouvée.' -Recommendation 'Vérifier la configuration réseau du nœud.'
    }

    if ($null -ne $Inventory.NumaSpanningEnabled) {
        $numaStatus = if ($Inventory.NumaSpanningEnabled -eq $true) { 'Pass' } else { 'Warning' }
        $numaRec    = if ($Inventory.NumaSpanningEnabled -eq $true) { '' } else { 'Activer le NUMA Spanning pour permettre les migrations entre nœuds avec des topologies NUMA différentes (Set-VMHost -NumaSpanningEnabled $true).' }
        Add-Finding -Scope 'Node' -Target $target -Check 'NUMA Spanning' -Status $numaStatus -Details "NumaSpanningEnabled = $($Inventory.NumaSpanningEnabled)." -Recommendation $numaRec
    }

    $hvInboundRules = @($Inventory.FirewallRules | Where-Object { [string]$_.Direction -eq 'Inbound' })
    if ($hvInboundRules.Count -eq 0) {
        Add-Finding -Scope 'Node' -Target $target -Check 'Règles pare-feu Hyper-V (entrantes)' -Status 'Warning' `
            -Details 'Aucune règle pare-feu du groupe Hyper-V (entrante) trouvée.' `
            -Recommendation "Activer les règles Windows Firewall du groupe 'Hyper-V' pour autoriser la Live Migration (TCP $LiveMigrationPort) et SMB (TCP 445)."
    }
    else {
        $disabledRules = @($hvInboundRules | Where-Object { -not $_.Enabled })
        if ($disabledRules.Count -gt 0) {
            Add-Finding -Scope 'Node' -Target $target -Check 'Règles pare-feu Hyper-V (entrantes)' -Status 'Warning' `
                -Details ("Règles entrantes Hyper-V désactivées: {0}" -f (Join-Value ($disabledRules | ForEach-Object { $_.DisplayName }))) `
                -Recommendation 'Activer les règles pare-feu Live Migration désactivées ou vérifier les règles équivalentes (GPO, pare-feu tiers).'
        }
        else {
            Add-Finding -Scope 'Node' -Target $target -Check 'Règles pare-feu Hyper-V (entrantes)' -Status 'Pass' `
                -Details ("Toutes les règles entrantes du groupe Hyper-V sont actives ({0} règle(s))." -f $hvInboundRules.Count)
        }
    }

    $ntpDetails = "NtpServer=$($Inventory.NtpSource); Type=$($Inventory.NtpType)"
    if ($Inventory.NtpType -eq 'NT5DS') {
        Add-Finding -Scope 'Node' -Target $target -Check 'Synchronisation horaire (NTP)' -Status 'Pass' `
            -Details "$ntpDetails — Synchronisation via hiérarchie de domaine AD."
    }
    elseif ($Inventory.NtpType -eq 'NTP' -or $Inventory.NtpType -eq 'AllSync') {
        Add-Finding -Scope 'Node' -Target $target -Check 'Synchronisation horaire (NTP)' -Status 'Info' `
            -Details $ntpDetails `
            -Recommendation 'Vérifier que le décalage horaire avec les autres nœuds est inférieur à 5 minutes (limite Kerberos).'
    }
    else {
        Add-Finding -Scope 'Node' -Target $target -Check 'Synchronisation horaire (NTP)' -Status 'Warning' `
            -Details "$ntpDetails — Type de synchronisation non standard ou indéterminé." `
            -Recommendation 'Vérifier la configuration W32Time. La synchronisation NTP est critique pour Kerberos (décalage maximal de 5 minutes entre nœuds).'
    }
}

function Compare-ClusterNodeSettings {
    param(
        [Parameter(Mandatory = $true)][string]$ClusterName,
        [Parameter(Mandatory = $true)][object[]]$Inventories
    )

    if ($Inventories.Count -lt 2) { return }

    $authTypes = @($Inventories | ForEach-Object { $_.VirtualMachineMigrationAuthenticationType } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    if ($authTypes.Count -le 1) {
        Add-Finding -Scope 'Cluster' -Target $ClusterName -Check 'Cohérence authentification Live Migration' -Status 'Pass' -Details ("Valeur commune: {0}" -f (Join-Value $authTypes))
    }
    else {
        Add-Finding -Scope 'Cluster' -Target $ClusterName -Check 'Cohérence authentification Live Migration' -Status 'Warning' -Details ("Valeurs différentes: {0}" -f (Join-Value $authTypes)) -Recommendation 'Harmoniser le mode d’authentification entre les nœuds.'
    }

    $performanceOptions = @($Inventories | ForEach-Object { $_.VirtualMachineMigrationPerformanceOption } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    if ($performanceOptions.Count -le 1) {
        Add-Finding -Scope 'Cluster' -Target $ClusterName -Check 'Cohérence option de performance Live Migration' -Status 'Pass' -Details ("Valeur commune: {0}" -f (Join-Value $performanceOptions))
    }
    else {
        Add-Finding -Scope 'Cluster' -Target $ClusterName -Check 'Cohérence option de performance Live Migration' -Status 'Warning' -Details ("Valeurs différentes: {0}" -f (Join-Value $performanceOptions)) -Recommendation 'Harmoniser TCP/IP, Compression ou SMB selon votre standard.'
    }

    $allSwitchNames = @($Inventories | ForEach-Object { $_.VMSwitches } | Where-Object { $_.SwitchType -eq 'External' } | ForEach-Object { $_.Name } | Sort-Object -Unique)
    foreach ($switchName in $allSwitchNames) {
        $missingNodes = @($Inventories | Where-Object { @($_.VMSwitches | Where-Object { $_.Name -eq $switchName }).Count -eq 0 } | ForEach-Object { $_.NodeName })
        if ($missingNodes.Count -eq 0) {
            Add-Finding -Scope 'Cluster' -Target $ClusterName -Check "Présence vSwitch '$switchName'" -Status 'Pass' -Details 'Le vSwitch est présent sur tous les nœuds inventoriés.'
        }
        else {
            Add-Finding -Scope 'Cluster' -Target $ClusterName -Check "Présence vSwitch '$switchName'" -Status 'Warning' -Details ("Absent de: {0}" -f (Join-Value $missingNodes)) -Recommendation 'Créer/renommer les vSwitches pour que les VM puissent se connecter après migration.'
        }
    }
}

function Test-NodeConnectivity {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$SourceNode,
        [Parameter(Mandatory = $true)][string]$TargetNode,
        [Parameter(Mandatory = $true)][int[]]$Ports
    )

    if ($SourceNode -eq $TargetNode) { return }

    foreach ($port in $Ports) {
        Write-Verbose "Test réseau $SourceNode -> $TargetNode TCP/$port"
        try {
            $result = Invoke-RemoteNodeCommand -ComputerName $SourceNode -ScriptBlock {
                param([string]$RemoteComputer, [int]$RemotePort)
                $test = Test-NetConnection -ComputerName $RemoteComputer -Port $RemotePort -WarningAction SilentlyContinue
                [pscustomobject]@{
                    ComputerName     = $RemoteComputer
                    RemoteAddress    = $test.RemoteAddress
                    RemotePort       = $RemotePort
                    TcpTestSucceeded = $test.TcpTestSucceeded
                    SourceAddress    = $test.SourceAddress
                    InterfaceAlias   = $test.InterfaceAlias
                }
            } -ArgumentList @($TargetNode, $port)

            $status = if ($result.TcpTestSucceeded) { 'Pass' } else { 'Fail' }
            $details = "SourceAddress=$($result.SourceAddress); RemoteAddress=$($result.RemoteAddress); Interface=$($result.InterfaceAlias); TcpTestSucceeded=$($result.TcpTestSucceeded)"
            $recommendation = if ($result.TcpTestSucceeded) { '' } else { 'Vérifier routage, pare-feu Windows/intermédiaire, DNS et filtrage entre les réseaux Live Migration/management.' }

            $connectivityRows.Add([pscustomobject]@{
                Scope            = $Scope
                SourceNode       = $SourceNode
                TargetNode       = $TargetNode
                Port             = $port
                TcpTestSucceeded = $result.TcpTestSucceeded
                SourceAddress    = $result.SourceAddress
                RemoteAddress    = $result.RemoteAddress
                InterfaceAlias   = $result.InterfaceAlias
            }) | Out-Null

            Add-Finding -Scope $Scope -Target "$SourceNode -> $TargetNode" -Check "Connectivité TCP/$port" -Status $status -Details $details -Recommendation $recommendation
        }
        catch {
            $connectivityRows.Add([pscustomobject]@{
                Scope            = $Scope
                SourceNode       = $SourceNode
                TargetNode       = $TargetNode
                Port             = $port
                TcpTestSucceeded = $false
                SourceAddress    = ''
                RemoteAddress    = ''
                InterfaceAlias   = ''
            }) | Out-Null

            Add-Finding -Scope $Scope -Target "$SourceNode -> $TargetNode" -Check "Connectivité TCP/$port" -Status 'Fail' -Details $_.Exception.Message -Recommendation 'Vérifier PowerShell Remoting vers le nœud source puis la connectivité réseau vers le nœud cible.'
        }
    }
}

function Test-ConnectivityMatrix {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string[]]$SourceNodes,
        [Parameter(Mandatory = $true)][string[]]$TargetNodes,
        [Parameter(Mandatory = $true)][int[]]$Ports
    )

    foreach ($sourceNode in $SourceNodes) {
        foreach ($targetNode in $TargetNodes) {
            Test-NodeConnectivity -Scope $Scope -SourceNode $sourceNode -TargetNode $targetNode -Ports $Ports
        }
    }
}

function Test-KerberosDelegation {
    param(
        [Parameter(Mandatory = $true)][string]$SourceNodeFQDN,
        [Parameter(Mandatory = $true)][string[]]$TargetNodeFQDNs
    )

    $sourceShort = $SourceNodeFQDN.Split('.')[0]

    try {
        $searcher = [ADSISearcher]"(&(objectClass=computer)(cn=$sourceShort))"
        $searcher.PropertiesToLoad.AddRange([string[]]@('msDS-AllowedToDelegateTo', 'userAccountControl', 'distinguishedName'))
        $result = $searcher.FindOne()

        if ($null -eq $result) {
            Add-Finding -Scope 'Delegation' -Target $sourceShort -Check 'Délégation Kerberos (AD)' -Status 'Warning' `
                -Details "Compte ordinateur '$sourceShort' introuvable via ADSI." `
                -Recommendation 'Vérifier le nom NetBIOS du nœud et que le compte d'exécution a les droits de lecture AD sur l'attribut msDS-AllowedToDelegateTo.'
            return
        }

        $uac = 0
        if ($result.Properties['userAccountControl'].Count -gt 0) {
            $uac = [int]$result.Properties['userAccountControl'][0]
        }
        $unConstrained = (($uac -band 0x00080000) -ne 0)

        if ($unConstrained) {
            Add-Finding -Scope 'Delegation' -Target $sourceShort -Check 'Délégation Kerberos (AD)' -Status 'Warning' `
                -Details "Délégation non contrainte (unconstrained) activée sur le compte ordinateur $sourceShort (bit TRUSTED_FOR_DELEGATION)." `
                -Recommendation 'La délégation non contrainte est une exposition de sécurité. Migrer vers la délégation contrainte (Kerberos Constrained Delegation) avec uniquement les SPNs requis.'
            return
        }

        $delegationList = @()
        if ($result.Properties['msDS-AllowedToDelegateTo'].Count -gt 0) {
            $delegationList = @($result.Properties['msDS-AllowedToDelegateTo'])
        }

        if ($delegationList.Count -eq 0) {
            Add-Finding -Scope 'Delegation' -Target $sourceShort -Check 'Délégation Kerberos (AD)' -Status 'Fail' `
                -Details "Aucun SPN de délégation contrainte (msDS-AllowedToDelegateTo) configuré sur le compte ordinateur $sourceShort." `
                -Recommendation 'Configurer la délégation contrainte dans ADUC (propriété Delegation) ou via Set-ADComputer -Add @{''msDS-AllowedToDelegateTo''=@(...)} avec les SPNs: "Microsoft Virtual System Migration Service/TargetNode[.FQDN]" et "cifs/TargetNode[.FQDN]" pour les migrations shared-nothing/SMB.'
            return
        }

        $missingRequired    = [System.Collections.Generic.List[string]]::new()
        $missingRecommended = [System.Collections.Generic.List[string]]::new()

        foreach ($targetFQDN in $TargetNodeFQDNs) {
            $targetShort = $targetFQDN.Split('.')[0]

            $spnMvsShort = "Microsoft Virtual System Migration Service/$targetShort"
            $spnMvsFqdn  = "Microsoft Virtual System Migration Service/$targetFQDN"
            if (-not (($delegationList -contains $spnMvsShort) -or ($delegationList -contains $spnMvsFqdn))) {
                $missingRequired.Add($spnMvsShort) | Out-Null
            }

            $spnCifsShort = "cifs/$targetShort"
            $spnCifsFqdn  = "cifs/$targetFQDN"
            if (-not (($delegationList -contains $spnCifsShort) -or ($delegationList -contains $spnCifsFqdn))) {
                $missingRecommended.Add($spnCifsShort) | Out-Null
            }
        }

        if ($missingRequired.Count -eq 0 -and $missingRecommended.Count -eq 0) {
            Add-Finding -Scope 'Delegation' -Target $sourceShort -Check 'Délégation Kerberos (AD)' -Status 'Pass' `
                -Details ("Délégation contrainte complète. SPNs autorisés: {0}" -f (Join-Value $delegationList))
        }
        elseif ($missingRequired.Count -eq 0) {
            Add-Finding -Scope 'Delegation' -Target $sourceShort -Check 'Délégation Kerberos (AD)' -Status 'Warning' `
                -Details ("SPNs 'Microsoft Virtual System Migration Service' OK. SPNs 'cifs' absents (requis pour migrations shared-nothing/SMB): {0}" -f (Join-Value $missingRecommended)) `
                -Recommendation 'Ajouter les SPNs cifs/TargetNode si vous réalisez des migrations shared-nothing avec transfert de stockage via SMB.'
        }
        else {
            Add-Finding -Scope 'Delegation' -Target $sourceShort -Check 'Délégation Kerberos (AD)' -Status 'Fail' `
                -Details ("SPNs 'Microsoft Virtual System Migration Service' manquants: {0} | SPNs 'cifs' manquants: {1} | SPNs configurés: {2}" -f (Join-Value $missingRequired), (Join-Value $missingRecommended), (Join-Value $delegationList)) `
                -Recommendation 'Ajouter les SPNs manquants dans Active Directory sur le compte ordinateur du nœud Hyper-V source via ADUC ou Set-ADComputer.'
        }
    }
    catch {
        Add-Finding -Scope 'Delegation' -Target $sourceShort -Check 'Délégation Kerberos (AD)' -Status 'Warning' `
            -Details $_.Exception.Message `
            -Recommendation 'Vérifier les droits de lecture Active Directory depuis le poste d'exécution (lecture de msDS-AllowedToDelegateTo sur les comptes ordinateurs Hyper-V).'
    }
}

function Export-Reports {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    $findingsPath = Join-Path -Path $Path -ChildPath 'HyperV-LiveMigrationReadiness-Findings.csv'
    $inventoryPath = Join-Path -Path $Path -ChildPath 'HyperV-LiveMigrationReadiness-NodeInventory.csv'
    $connectivityPath = Join-Path -Path $Path -ChildPath 'HyperV-LiveMigrationReadiness-Connectivity.csv'
    $jsonPath = Join-Path -Path $Path -ChildPath 'HyperV-LiveMigrationReadiness.json'

    $findings | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter

    $inventoryRows = foreach ($inventory in $nodeInventories) {
        [pscustomobject]@{
            ClusterName                               = $inventory.ClusterName
            NodeName                                  = $inventory.NodeName
            FullyQualifiedDomainName                  = $inventory.FullyQualifiedDomainName
            VirtualMachineMigrationEnabled            = $inventory.VirtualMachineMigrationEnabled
            VirtualMachineMigrationAuthenticationType = $inventory.VirtualMachineMigrationAuthenticationType
            VirtualMachineMigrationPerformanceOption  = $inventory.VirtualMachineMigrationPerformanceOption
            MaximumVirtualMachineMigrations           = $inventory.MaximumVirtualMachineMigrations
            VirtualMachineMigrationNetworks           = Join-Value $inventory.VirtualMachineMigrationNetworks
            NumaSpanningEnabled                       = $inventory.NumaSpanningEnabled
            VMSwitches                                = Join-Value (@($inventory.VMSwitches) | ForEach-Object { "$($_.Name)[$($_.SwitchType)]" })
            IPv4Addresses                             = Join-Value (@($inventory.IPv4Addresses) | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)[$($_.InterfaceAlias)]" })
            ClusterNetworks                           = Join-Value (@($inventory.ClusterNetworks) | ForEach-Object { "$($_.Name)[Role=$($_.Role);$($_.Address)/$($_.AddressMask)]" })
            NtpSource                                 = $inventory.NtpSource
            NtpType                                   = $inventory.NtpType
            FirewallRules                             = Join-Value (@($inventory.FirewallRules) | Where-Object { [string]$_.Direction -eq 'Inbound' } | ForEach-Object { "$($_.DisplayName)[Enabled=$($_.Enabled)]" })
        }
    }
    @($inventoryRows) | Export-Csv -Path $inventoryPath -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter
    $connectivityRows | Export-Csv -Path $connectivityPath -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter

    [pscustomobject]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        VMMServer = $VMMServer
        SourceClusterName = $SourceClusterName
        DestinationClusterName = $DestinationClusterName
        Findings = @($findings)
        NodeInventory = @($inventoryRows)
        Connectivity = @($connectivityRows)
    } | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

    Write-Host "Rapports générés:" -ForegroundColor Cyan
    Write-Host "- $findingsPath"
    Write-Host "- $inventoryPath"
    Write-Host "- $connectivityPath"
    Write-Host "- $jsonPath"
}

Write-Host 'Diagnostic Hyper-V Live Migration' -ForegroundColor Cyan
if (-not [string]::IsNullOrWhiteSpace($VMMServer)) {
    Write-Host "SCVMM: $VMMServer"
}
Write-Host "Cluster source: $SourceClusterName"
if (-not [string]::IsNullOrWhiteSpace($DestinationClusterName)) {
    Write-Host "Cluster destination/externe: $DestinationClusterName"
}

$localModulesToCheck = @('FailoverClusters', 'Hyper-V')
if (-not [string]::IsNullOrWhiteSpace($VMMServer)) {
    $localModulesToCheck = @('VirtualMachineManager') + $localModulesToCheck
}

foreach ($moduleName in $localModulesToCheck) {
    if (Get-Module -ListAvailable -Name $moduleName) {
        Add-Finding -Scope 'Local' -Target $env:COMPUTERNAME -Check "Module PowerShell $moduleName" -Status 'Pass' -Details 'Module disponible localement.'
        Import-Module $moduleName -ErrorAction SilentlyContinue
    }
    else {
        $status = switch ($moduleName) {
            'VirtualMachineManager' { 'Fail' }
            'FailoverClusters' {
                if ([string]::IsNullOrWhiteSpace($VMMServer)) { 'Fail' } else { 'Warning' }
            }
            default { 'Warning' }
        }
        $recommendation = switch ($moduleName) {
            'VirtualMachineManager' { 'Installer la console/module SCVMM ou exécuter le script depuis le serveur VMM.' }
            'FailoverClusters' { 'Installer les RSAT Failover Clustering si vous voulez utiliser le repli local Get-ClusterNode; la découverte principale peut passer par SCVMM avec -VMMServer.' }
            default { 'Installer les RSAT/Feature correspondants sur le poste d’exécution si vous souhaitez exécuter aussi des contrôles locaux.' }
        }
        Add-Finding -Scope 'Local' -Target $env:COMPUTERNAME -Check "Module PowerShell $moduleName" -Status $status -Details 'Module non trouvé localement.' -Recommendation $recommendation
    }
}

if (-not [string]::IsNullOrWhiteSpace($VMMServer)) {
    try {
        Write-Verbose "Connexion à SCVMM $VMMServer"
        $vmmConnection = Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop
        $scvmmHosts = @(Get-SCVMHost -VMMServer $vmmConnection -ErrorAction Stop)
        Add-Finding -Scope 'SCVMM' -Target $VMMServer -Check 'Connexion SCVMM' -Status 'Pass' -Details ("Connexion établie; {0} hôte(s) récupéré(s)." -f $scvmmHosts.Count)
    }
    catch {
        Add-Finding -Scope 'SCVMM' -Target $VMMServer -Check 'Connexion SCVMM' -Status 'Fail' -Details $_.Exception.Message -Recommendation 'Vérifier le module VirtualMachineManager, le nom du serveur VMM, la connectivité et les droits SCVMM.'
    }
}

if (-not (Test-CommandAvailable -Name Invoke-Command)) {
    Add-Finding -Scope 'Local' -Target $env:COMPUTERNAME -Check 'PowerShell Remoting' -Status 'Fail' -Details 'Invoke-Command est indisponible.' -Recommendation 'Exécuter le script depuis Windows PowerShell/PowerShell avec remoting disponible.'
    Export-Reports -Path $OutputDirectory
    throw 'Invoke-Command est requis.'
}

$sourceNodes = @(Get-ClusterNodeNamesSafe -ClusterName $SourceClusterName)
$destinationNodes = @()

if (-not [string]::IsNullOrWhiteSpace($DestinationClusterName)) {
    $destinationNodes = @(Get-ClusterNodeNamesSafe -ClusterName $DestinationClusterName)
}

$sourceInventories = @()
foreach ($node in $sourceNodes) {
    $inventory = Get-NodeInventory -ClusterName $SourceClusterName -NodeName $node
    if ($null -ne $inventory) {
        $sourceInventories += $inventory
        Test-NodeInventory -Inventory $inventory
    }
}

$destinationInventories = @()
foreach ($node in $destinationNodes) {
    $inventory = Get-NodeInventory -ClusterName $DestinationClusterName -NodeName $node
    if ($null -ne $inventory) {
        $destinationInventories += $inventory
        Test-NodeInventory -Inventory $inventory
    }
}

Compare-ClusterNodeSettings -ClusterName $SourceClusterName -Inventories $sourceInventories
if ($destinationInventories.Count -gt 0) {
    Compare-ClusterNodeSettings -ClusterName $DestinationClusterName -Inventories $destinationInventories
}

$allSourceFqdns = @($sourceInventories | Where-Object { -not [string]::IsNullOrWhiteSpace($_.FullyQualifiedDomainName) } | ForEach-Object { $_.FullyQualifiedDomainName })
$allDestFqdns   = @($destinationInventories | Where-Object { -not [string]::IsNullOrWhiteSpace($_.FullyQualifiedDomainName) } | ForEach-Object { $_.FullyQualifiedDomainName })

foreach ($srcInv in $sourceInventories) {
    if ($srcInv.VirtualMachineMigrationAuthenticationType -eq 'Kerberos' -and -not [string]::IsNullOrWhiteSpace($srcInv.FullyQualifiedDomainName)) {
        $targets = @($allSourceFqdns | Where-Object { $_ -ne $srcInv.FullyQualifiedDomainName })
        $targets += $allDestFqdns
        if ($targets.Count -gt 0) {
            Test-KerberosDelegation -SourceNodeFQDN $srcInv.FullyQualifiedDomainName -TargetNodeFQDNs $targets
        }
    }
}

foreach ($dstInv in $destinationInventories) {
    if ($dstInv.VirtualMachineMigrationAuthenticationType -eq 'Kerberos' -and -not [string]::IsNullOrWhiteSpace($dstInv.FullyQualifiedDomainName)) {
        $targets = @($allSourceFqdns)
        $targets += @($allDestFqdns | Where-Object { $_ -ne $dstInv.FullyQualifiedDomainName })
        if ($targets.Count -gt 0) {
            Test-KerberosDelegation -SourceNodeFQDN $dstInv.FullyQualifiedDomainName -TargetNodeFQDNs $targets
        }
    }
}

if ($destinationInventories.Count -gt 0) {
    $sourceSwitches = @($sourceInventories | ForEach-Object { $_.VMSwitches } | Where-Object { $_.SwitchType -eq 'External' } | ForEach-Object { $_.Name } | Sort-Object -Unique)
    $destinationSwitches = @($destinationInventories | ForEach-Object { $_.VMSwitches } | Where-Object { $_.SwitchType -eq 'External' } | ForEach-Object { $_.Name } | Sort-Object -Unique)
    $missingOnDestination = @($sourceSwitches | Where-Object { $destinationSwitches -notcontains $_ })

    if ($missingOnDestination.Count -eq 0) {
        Add-Finding -Scope 'InterCluster' -Target "$SourceClusterName -> $DestinationClusterName" -Check 'Noms de vSwitch compatibles' -Status 'Pass' -Details 'Tous les vSwitches externes source sont présents côté destination.'
    }
    else {
        Add-Finding -Scope 'InterCluster' -Target "$SourceClusterName -> $DestinationClusterName" -Check 'Noms de vSwitch compatibles' -Status 'Warning' -Details ("vSwitches absents côté destination: {0}" -f (Join-Value $missingOnDestination)) -Recommendation 'Créer des vSwitches de même nom ou prévoir le remapping réseau avant migration.'
    }

    $sourceDomains = @($sourceInventories | ForEach-Object { $_.Domain } | Sort-Object -Unique)
    $destinationDomains = @($destinationInventories | ForEach-Object { $_.Domain } | Sort-Object -Unique)
    if ((Join-Value $sourceDomains) -eq (Join-Value $destinationDomains)) {
        Add-Finding -Scope 'InterCluster' -Target "$SourceClusterName -> $DestinationClusterName" -Check 'Domaine Active Directory' -Status 'Pass' -Details ("Domaine commun: {0}" -f (Join-Value $sourceDomains))
    }
    else {
        Add-Finding -Scope 'InterCluster' -Target "$SourceClusterName -> $DestinationClusterName" -Check 'Domaine Active Directory' -Status 'Warning' -Details ("Source: {0}; Destination: {1}" -f (Join-Value $sourceDomains), (Join-Value $destinationDomains)) -Recommendation 'Les migrations Kerberos inter-clusters nécessitent une relation AD/DNS/Kerberos cohérente et la délégation appropriée.'
    }

    Add-Finding -Scope 'InterCluster' -Target "$SourceClusterName -> $DestinationClusterName" -Check 'Délégation Kerberos / Active Directory' -Status 'Info' -Details 'Contrôle manuel recommandé.' -Recommendation 'Si VirtualMachineMigrationAuthenticationType = Kerberos, configurer la délégation contrainte des comptes ordinateurs Hyper-V vers Microsoft Virtual System Migration Service et CIFS selon le scénario de stockage.'
}

if ($SkipNetworkConnectivity) {
    Add-Finding -Scope 'Network' -Target 'Tous' -Check 'Tests de connectivité' -Status 'Info' -Details 'Tests ignorés par le paramètre -SkipNetworkConnectivity.'
}
else {
    $portsToTest = @($LiveMigrationPort, 445, 5985) | Sort-Object -Unique
    if ($sourceNodes.Count -gt 1) {
        Test-ConnectivityMatrix -Scope 'IntraCluster' -SourceNodes $sourceNodes -TargetNodes $sourceNodes -Ports $portsToTest
    }

    if ($destinationNodes.Count -gt 0) {
        Test-ConnectivityMatrix -Scope 'InterCluster' -SourceNodes $sourceNodes -TargetNodes $destinationNodes -Ports $portsToTest
        Test-ConnectivityMatrix -Scope 'InterCluster' -SourceNodes $destinationNodes -TargetNodes $sourceNodes -Ports $portsToTest
    }
}

$failCount = @($findings | Where-Object { $_.Status -eq 'Fail' }).Count
$warningCount = @($findings | Where-Object { $_.Status -eq 'Warning' }).Count
$passCount = @($findings | Where-Object { $_.Status -eq 'Pass' }).Count
$infoCount = @($findings | Where-Object { $_.Status -eq 'Info' }).Count

Write-Host ''
Write-Host "Synthèse: Pass=$passCount; Warning=$warningCount; Fail=$failCount; Info=$infoCount" -ForegroundColor Cyan
$findings |
    Sort-Object @{ Expression = { switch ($_.Status) { 'Fail' { 0 } 'Warning' { 1 } 'Info' { 2 } default { 3 } } } }, Scope, Target, Check |
    Format-Table -AutoSize Scope, Target, Check, Status, Details

Export-Reports -Path $OutputDirectory

if ($failCount -gt 0) {
    Write-Warning "Diagnostic terminé avec $failCount échec(s). Consultez le rapport Findings pour le détail."
    exit 2
}
elseif ($warningCount -gt 0) {
    Write-Warning "Diagnostic terminé avec $warningCount avertissement(s). Consultez le rapport Findings pour le détail."
    exit 1
}
else {
    Write-Host 'Diagnostic terminé sans échec ni avertissement.' -ForegroundColor Green
    exit 0
}
