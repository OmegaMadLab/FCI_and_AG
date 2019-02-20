# On-prem disaster simulation
Stop-Computer -ComputerName SQL01.omegamadlab.local -Force
Stop-Computer -ComputerName SQL02.omegamadlab.local -Force
Invoke-Command -ComputerName RRAS.omegamadlab.local -ScriptBlock {
    Remove-SmbShare -Name Witness
}
    
# Stop cluster service if it's alive
$clusSvc = Get-Service -Name ClusSvc
If($clusSvc.Status -ne "Stopped") {
    $clusSvc | Stop-Service -Force
}

# Force cluster start
Start-ClusterNode –Name SQLDR.omegamadlab.local -FixQuorum

Get-ClusterNode

# Force AG1 failover with AllowDataLoss
$AgPath = "SQLSERVER:\SQL\SQLDR\DEFAULT\AvailabilityGroups\AG1"
Switch-SqlAvailabilityGroup -Path $AgPath -AllowDataLoss -Force

$AgPath = "SQLSERVER:\SQL\SQLDR\DEFAULT\AvailabilityGroups\AG2"
Switch-SqlAvailabilityGroup -Path $AgPath -AllowDataLoss -Force