# Install required PS modules
Install-Module Az, DBATools, SqlServer

# Login on Azure Subscription
Add-AzAccount

# Deploy a SQL optimized VM in the Azure location
$RgName = "DR-Demo-RG"
$Rg = Get-AzResourceGroup -Name $RgName -Location "westeurope" -ErrorAction SilentlyContinue
if(!$Rg) {
    $Rg = New-AzResourceGroup -Name $RgName -Location "westeurope"
}

New-AzResourceGroupDeployment -ResourceGroupName $Rg.ResourceGroupName `
    -TemplateUri "https://raw.githubusercontent.com/OmegaMadLab/OptimizedSqlVm/master/azuredeploy.json" `
    -TemplateParameterFile ".\template_param.json" `
    -Name "DRSQL" 

# Check initial configuration
# Onprem
Get-Cluster 
Get-Cluster | Get-ClusterNode
Get-Cluster | Get-ClusterGroup | ? Name -like '*SQL*' | Get-ClusterResource

Connect-DbaInstance -SqlInstance SQLONPREM.omegamadlab.local |
    Select ComputerName, Version, EngineEdition, isClustered

Get-DbaAgHadr -SqlInstance SQLONPREM.omegamadlab.local

Get-DbaDatabase -SqlInstance SQLONPREM.omegamadlab.local -ExcludeAllSystemDb | Select Name

# Azure
Connect-DbaInstance -SqlInstance SQLDR.omegamadlab.local |
    Select ComputerName, Version, EngineEdition, isClustered

Get-DbaAgHadr -SqlInstance SQLDR.omegamadlab.local

Get-DbaDatabase -SqlInstance SQLDR.omegamadlab.local -ExcludeAllSystemDb | Select Name

# Create Azure Internal Load Balancer for DR Node
# Needed to maintain cluster IPs for AGs listeners and Cluster VNN
.\demo_ILB.ps1

# Add DR node to cluster
Install-WindowsFeature -Name Failover-Clustering `
    -IncludeAllSubFeature `
    -IncludeManagementTools `
    -ComputerName SQLDR.omegamadlab.local

Get-Cluster | Add-ClusterNode -Name SQLDR.omegamadlab.local -NoStorage

# Add DR node IP to Cluster Name
$drIp = Add-ClusterResource -Name "IP Address 10.1.0.25" `
            -Group "Cluster Group" `
            -ResourceType "Ip Address"
$drIp | Set-ClusterParameter -Multiple @{"Address"="10.1.0.25";`
                                         "ProbePort"="58880";`
                                         "SubnetMask"="255.255.255.255";`
                                         "Network"="Cluster Network 2";`
                                         "EnableDhcp"=0}
Set-ClusterResourceDependency -Resource "Cluster Name" `
    -Dependency "[Cluster IP Address] OR [$($drIp.Name)]"

# Remove quorum vote from DR node
Get-ClusterNode | Format-Table -property NodeName, State, NodeWeight
(Get-ClusterNode -Name SQLDR.omegamadlab.local).NodeWeight = 0
Get-ClusterNode | Format-Table -property NodeName, State, NodeWeight

# Remove SQLDR as possible owner for on-prem FCI
Get-ClusterGroup | 
    ? Name -like '*SQL*' | 
    Get-ClusterResource 

Get-ClusterGroup | 
    ? Name -like '*SQL*' | 
    Get-ClusterResource |
    Set-ClusterOwnerNode -Owners SQL01, SQL02, SQLDR

Get-ClusterGroup | 
    ? Name -like '*SQL*' | 
    Get-ClusterResource |
    Get-ClusterOwnerNode

# Enable HADR feature on both instances, update service account on DR instance
Enable-DbaAgHaDr -SqlInstance SQLONPREM.omegamadlab.local -force
$group = Get-ClusterGroup | ? Name -like '*MSSQLSERVER*'
$group | Stop-ClusterGroup
$group | Start-ClusterGroup

Enable-DbaAgHaDr -SqlInstance SQLDR.omegamadlab.local -force
$cred = Get-Credential
Get-DbaService -ComputerName SQLDR.omegamadlab.local `
                -Type Engine,Agent | Update-DbaServiceAccount -ServiceCredential $cred
Restart-DbaService -ComputerName SQLDR.omegamadlab.local -Type Engine,Agent -Force

# Create a shared folder to hosts DB backups
New-Item F:\SqlBck -ItemType Directory -Force
New-SmbShare -Name "SqlBck" `
    -Path "F:\SqlBck" `
    -FullAccess "OMEGAMADLAB\SqlSvc" `
    -ContinuouslyAvailable $true

# Create mirroring endpoints
$endpoint = New-DbaEndpoint -SqlInstance SQLONPREM.omegamadlab.local `
    -Port 5022 `
    -Name "hadr_endpoint"
New-DbaLogin -SqlInstance SQLONPREM.omegamadlab.local `
    -Login OMEGAMADLAB\SqlSvc
Grant-DbaAgPermission -SqlInstance SQLONPREM.omegamadlab.local `
    -Type endpoint `
    -Login omegamadlab\sqlsvc
$endpoint | Start-DbaEndpoint

$endpoint = New-DbaEndpoint -SqlInstance SQLDR.omegamadlab.local `
    -Port 5022 `
    -Name "hadr_endpoint"
New-DbaLogin -SqlInstance SQLDR.omegamadlab.local `
    -Login OMEGAMADLAB\SqlSvc
Grant-DbaAgPermission -SqlInstance SQLDR.omegamadlab.local `
    -Type endpoint `
    -Login omegamadlab\sqlsvc
$endpoint | Start-DbaEndpoint

# Create two BAGs for on-prem databases
New-DbaAvailabilityGroup -Primary SQLONPREM.omegamadlab.local `
    -Secondary SQLDR.omegamadlab.local `
    -Name "AG1" `
    -Basic `
    -ClusterType Wsfc `
    -AvailabilityMode AsynchronousCommit `
    -FailoverMode Manual `
    -SeedingMode Manual `
    -SharedPath "\\SQLONPREM\SqlBck" `
    -Database "AdventureWorksLT1" `
    -Force

New-DbaAvailabilityGroup -Primary SQLONPREM.omegamadlab.local `
    -Secondary SQLDR.omegamadlab.local `
    -Name "AG2" `
    -Basic `
    -ClusterType Wsfc `
    -AvailabilityMode AsynchronousCommit `
    -FailoverMode Manual `
    -SeedingMode Manual `
    -SharedPath "\\SQLONPREM\SqlBck" `
    -Database "AdventureWorksLT2017" `
    -Force

# Create listeners for BAGs and add IPs and probe ports for DR site
$agListener = New-SqlAvailabilityGroupListener -Name "AG1vip" `
                -Path "SqlServer:\SQL\SQLONPREM\DEFAULT\AvailabilityGroups\AG1" `
                -StaticIp 192.168.1.20/255.255.255.0,10.1.0.20/255.255.255.0 `
                -Port 1433

$AgListenerDrIp = Get-ClusterGroup -Name "AG1" | `
                    Get-ClusterResource | ? {$_.ResourceType -eq "IP Address" -and $_.Name -like '*10.1.0.20*'}
$AgListenerDrIp | Set-ClusterParameter -Multiple @{"Address"="10.1.0.20";`
                                                   "ProbePort"="59990";`
                                                   "SubnetMask"="255.255.255.255";`
                                                   "Network"="Cluster Network 2";`
                                                   "EnableDhcp"=0} 

$agListener = New-SqlAvailabilityGroupListener -Name "AG2vip" `
                -Path "SqlServer:\SQL\SQLONPREM\DEFAULT\AvailabilityGroups\AG2" `
                -StaticIp 192.168.1.21/255.255.255.0,10.1.0.21/255.255.255.0 `
                -Port 1433

$AgListenerDrIp = Get-ClusterGroup -Name "AG2" |`
                    Get-ClusterResource | ? {$_.ResourceType -eq "IP Address" -and $_.Name -like '*10.1.0.21*'}
$AgListenerDrIp | Set-ClusterParameter -Multiple @{"Address"="10.1.0.21";`
                                                   "ProbePort"="59991";`
                                                   "SubnetMask"="255.255.255.255";`
                                                   "Network"="Cluster Network 2";`
                                                   "EnableDhcp"=0} 

# Setting RegisterAllProvidersIP and TTL = 10 sec (for demo purposes) for both ag listeners network name
$ClientAccessPoint = Get-ClusterGroup -Name AG1, AG2 | `
                        Get-ClusterResource | ? ResourceType -eq "Network Name"
$ClientAccessPoint | Set-ClusterParameter -Multiple @{"HostRecordTTL"=10;`
                                                      "RegisterAllProvidersIP"=0}
$ClientAccessPoint | Stop-ClusterResource
$ClientAccessPoint | Start-ClusterResource

# To copy Login, Jobs, etc. use DBATools

