# Create the Azure Internal Load Balancer for DR listeners' IP
$rgName = 'DR-Demo-RG'
$VNetName = 'DR-Vnet'          # Vnet name
$SubnetName = 'default'        # Subnet name
$ILBName = 'DR-ILB'            # ILB name
$Location = 'West Europe'      # Azure location
$VMName = 'SQLDR'              # Virtual machine names

$ILBIP = '10.1.0.20'                        # AG listener IP address
[int]$ListenerPort = '1433'                 # AG listener port
[int]$ProbePort = '59990'                   # AG listener Probe port

$LBProbeNamePrefix = "$ILBName-PROBE-0"        # The Load balancer Probe Object Name              
$LBConfigRuleNamePrefix = "$ILBName-RULE-0"    # The Load Balancer Rule Object Name

$FrontEndConfigurationPrefix = "$ILBName-FECONFIG-0"  # Object name for the front-end configuration 
$BackEndConfigurationPrefix = "$ILBName-BECONFIG-0"   # Object name for the back-end configuration

# Load balancer creation with initial configuration
$VNet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $RgName 

$Subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $VNet `
                                                -Name $SubnetName 

# Frontend configuration
$FEConfig = New-AzLoadBalancerFrontendIpConfig -Name "$($FrontEndConfigurationPrefix)0" `
                                                    -PrivateIpAddress $ILBIP `
                                                    -Subnet $Subnet

# Backend configuration
$BEConfig = New-AzLoadBalancerBackendAddressPoolConfig -Name "$($BackEndConfigurationPrefix)0"

# Probe
$SQLHealthProbe = New-AzLoadBalancerProbeConfig -Name "$($LBProbeNamePrefix)0" `
                                                        -Protocol tcp `
                                                        -Port $ProbePort `
                                                        -IntervalInSeconds 15 `
                                                        -ProbeCount 2

# Rule
$ILBRule = New-AzLoadBalancerRuleConfig -Name "$($LBConfigRuleNamePrefix)0" `
                                                -FrontendIpConfiguration $FEConfig `
                                                -BackendAddressPool $BEConfig `
                                                -Probe $SQLHealthProbe `
                                                -Protocol tcp `
                                                -FrontendPort $ListenerPort `
                                                -BackendPort $ListenerPort `
                                                -LoadDistribution Default `
                                                -EnableFloatingIP 

# Creating ILB
$ILB = New-AzLoadBalancer -Location $Location `
                                -Name $ILBName `
                                -ResourceGroupName $RgName `
                                -FrontendIpConfiguration $FEConfig `
                                -BackendAddressPool $BEConfig `
                                -LoadBalancingRule $ILBRule `
                                -Probe $SQLHealthProbe 

$ILBIP = '10.1.0.21'                        # AG listener IP address
[int]$ListenerPort = '1433'                 # AG listener port
[int]$ProbePort = '59991'                   # AG listener Probe port

# Frontend configuration
Add-AzLoadBalancerFrontendIpConfig -Name "$($FrontEndConfigurationPrefix)1" `
                                                -PrivateIpAddress $ILBIP `
                                                -Subnet $Subnet `
                                                -LoadBalancer $ILB

Add-AzLoadBalancerProbeConfig -Name "$($LBProbeNamePrefix)1" `
    -Protocol tcp `
    -Port $ProbePort `
    -IntervalInSeconds 15 `
    -ProbeCount 2 `
    -LoadBalancer $ILB

$FEConfig = get-AzLoadBalancerFrontendIpConfig -Name "$($FrontEndConfigurationPrefix)1" `
                -LoadBalancer $ILB

$SQLHealthProbe  = Get-AzLoadBalancerProbeConfig -Name "$($LBProbeNamePrefix)1" `
                        -LoadBalancer $ILB

Add-AzLoadBalancerRuleConfig -LoadBalancer $ILB `
    -Name "$($LBConfigRuleNamePrefix)1" `
    -FrontendIpConfiguration $FEConfig `
    -BackendAddressPool $BEConfig `
    -Probe $SQLHealthProbe `
    -Protocol tcp `
    -FrontendPort $ListenerPort `
    -BackendPort $ListenerPort `
    -LoadDistribution Default `
    -EnableFloatingIP

$ILBIP = '10.1.0.25'                        
[int]$ListenerPort = '58880'                
[int]$ProbePort = '58880'                   

# Frontend configuration
Add-AzLoadBalancerFrontendIpConfig -Name "$($FrontEndConfigurationPrefix)2" `
    -PrivateIpAddress $ILBIP `
    -Subnet $Subnet `
    -LoadBalancer $ILB

Add-AzLoadBalancerProbeConfig -Name "$($LBProbeNamePrefix)2" `
    -Protocol tcp `
    -Port $ProbePort `
    -IntervalInSeconds 15 `
    -ProbeCount 2 `
    -LoadBalancer $ILB


$FEConfig = get-AzLoadBalancerFrontendIpConfig -Name "$($FrontEndConfigurationPrefix)2" `
                -LoadBalancer $ILB

$SQLHealthProbe  = Get-AzLoadBalancerProbeConfig -Name "$($LBProbeNamePrefix)2" `
                -LoadBalancer $ILB

Add-AzLoadBalancerRuleConfig -LoadBalancer $ILB `
    -Name "$($LBConfigRuleNamePrefix)2" `
    -FrontendIpConfiguration $FEConfig `
    -BackendAddressPool $BEConfig `
    -Probe $SQLHealthProbe `
    -Protocol tcp `
    -FrontendPort $ListenerPort `
    -BackendPort $ListenerPort `
    -LoadDistribution Default `
    -EnableFloatingIP

$ILB | Set-AzLoadBalancer

# Backend pool
$bepool = Get-AzLoadBalancerBackendAddressPoolConfig -Name "$($BackEndConfigurationPrefix)0" `
                                                            -LoadBalancer $ILB 

# Assign VM NICs to backend pool
$VM = Get-AzVM -ResourceGroupName $RgName `
                    -Name $VMName 
$NICName = ($VM.NetworkProfile.NetworkInterfaces[0].Id.Split('/') | Select-Object -last 1)
$NIC = Get-AzNetworkInterface -name $NICName `
                                    -ResourceGroupName $RgName
$NIC.IpConfigurations[0].LoadBalancerBackendAddressPools = $BEPool
Set-AzNetworkInterface -NetworkInterface $NIC
