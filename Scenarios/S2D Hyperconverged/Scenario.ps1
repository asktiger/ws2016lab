﻿################################
# Run from DC or Management VM #
################################

Start-Transcript -Path '.\S2DHydration.log'

$StartDateTime = get-date
Write-host "Script started at $StartDateTime"

#region LAB Config

    # 2,3,4,8, or 16 nodes
        $numberofnodes=4
        $ServersNamePrefix="S2D"
    #generate servernames (based number of nodes and serversnameprefix)
        $Servers=@()
        1..$numberofnodes | ForEach-Object {$Servers+="$($ServersNamePrefix)$_"}
    #Cluster Name
        $ClusterName="S2D-Cluster"

    ## Networking ##
        $Networking=$True
        $StorNet="172.16.1."
        $StorVLAN=1
    #start IP
        $IP=1

    #Real hardware?
        $RealHW=$False #will configure VMQ not to use CPU 0 if $True

    #PFC?
        $DCB=$False #$true for ROCE, $false for iWARP

    #iWARP?
        $iWARP=$False

    #Number of Disks Created. If >4 nodes, then x Mirror-Accelerated Parity and x Mirror disks are created
        $NumberOfDisks=$numberofnodes

    #Nano server?
        $NanoServer=$False

#endregion

#install features for management
    $WindowsInstallationType=(Get-ComputerInfo).WindowsInstallationType
    if ($WindowsInstallationType -eq "Server"){
        Install-WindowsFeature -Name RSAT-Clustering,RSAT-Clustering-Mgmt,RSAT-Clustering-PowerShell,RSAT-Hyper-V-Tools
    }elseif ($WindowsInstallationType -eq "Server Core"){
        Install-WindowsFeature -Name RSAT-Clustering,RSAT-Clustering-PowerShell,RSAT-Hyper-V-Tools
    }elseif ($WindowsInstallationType -eq "Client"){
        #Validate RSAT Installed
            if (!((Get-HotFix).hotfixid -contains "KB2693643") ){
                Write-Host "Please install RSAT, Exitting in 5s"
                Start-Sleep 5
                Exit
            }
        #Install Hyper-V Management features
            if ((Get-WindowsOptionalFeature -online -FeatureName Microsoft-Hyper-V-Management-PowerShell).state -ne "Enabled"){
                #Install all features and then remove all except Management (fails when installing just management)
                Enable-WindowsOptionalFeature -online -FeatureName Microsoft-Hyper-V-All -NoRestart
                Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -NoRestart
                $Q=Read-Host -Prompt "Restart is needed. Do you want to restart now? Y/N"
                If ($Q -eq "Y"){
                    Write-Host "Restarting Computer"
                    Start-Sleep 3
                    Restart-Computer
                }else{
                    Write-Host "You did not type Y, please restart Computer. Exitting"
                    Start-Sleep 3
                    Exit
                }
            }elseif((get-command -Module Hyper-V) -eq $null){
                $Q=Read-Host -Prompt "Restart is needed to load Hyper-V Management. Do you want to restart now? Y/N"
                If ($Q -eq "Y"){
                    Write-Host "Restarting Computer"
                    Start-Sleep 3
                    Restart-Computer
                }else{
                    Write-Host "You did not type Y, please restart Computer. Exitting"
                    Start-Sleep 3
                    Exit
                }
            }
    }

#Region configure servers
    #install roles and features
        if (!$NanoServer){
            #install Hyper-V using DISM (if nested virtualization is not enabled install-windowsfeature would fail)
            Invoke-Command -ComputerName $servers -ScriptBlock {Enable-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V -Online -NoRestart}
            foreach ($server in $servers) {Install-WindowsFeature -Name "Failover-Clustering","Hyper-V-PowerShell" -ComputerName $server} 
            #restart and wait for computers
            Restart-Computer $servers -Protocol WSMan -Wait -For PowerShell
            Start-Sleep 10 #Failsafe
        }

    ###Configure networking###
        if ($Networking){

            Invoke-Command -ComputerName $servers -ScriptBlock {New-VMSwitch -Name SETSwitch -EnableEmbeddedTeaming $TRUE -MinimumBandwidthMode Weight -NetAdapterName (Get-NetIPAddress -IPAddress 10.* ).InterfaceAlias}
            $Servers | ForEach-Object {
                    #Configure vNICs
                    Rename-VMNetworkAdapter -ManagementOS -Name SETSwitch -NewName Management -ComputerName $_
                    Set-VMNetworkAdapter -ManagementOS -Name Management -MinimumBandwidthWeight 5 -CimSession $_
                    Set-VMSwitch SETSwitch -DefaultFlowMinimumBandwidthWeight 3 -CimSession $_
                    Add-VMNetworkAdapter -ManagementOS -Name SMB_1 -SwitchName SETSwitch -CimSession $_
                    Add-VMNetworkAdapter -ManagementOS -Name SMB_2 -SwitchName SETSwitch -Cimsession $_
                    #configure IP Addresses
                    New-NetIPAddress -IPAddress ($StorNet+$IP.ToString()) -InterfaceAlias "vEthernet (SMB_1)" -CimSession $_ -PrefixLength 24
                    $IP++
                    New-NetIPAddress -IPAddress ($StorNet+$IP.ToString()) -InterfaceAlias "vEthernet (SMB_2)" -CimSession $_ -PrefixLength 24
                    $IP++         
            }

            Start-Sleep 5
            Clear-DnsClientCache

            #Configure the host vNIC to use a Vlan.  They can be on the same or different VLans 
            Set-VMNetworkAdapterVlan -VMNetworkAdapterName SMB_1 -VlanId $StorVLAN -Access -ManagementOS -CimSession $Servers
            Set-VMNetworkAdapterVlan -VMNetworkAdapterName SMB_2 -VlanId $StorVLAN -Access -ManagementOS -CimSession $Servers

            #Restart each host vNIC adapter so that the Vlan is active.
            Restart-NetAdapter "vEthernet (SMB_1)" -CimSession $Servers 
            Restart-NetAdapter "vEthernet (SMB_2)" -CimSession $Servers

            #Enable RDMA on the host vNIC adapters
            Enable-NetAdapterRDMA "vEthernet (SMB_1)","vEthernet (SMB_2)" -CimSession $Servers

            #Associate each of the vNICs configured for RDMA to a physical adapter that is up and is not virtual (to be sure that each vRDMA NIC is mapped to separate pRDMA NIC)
            Invoke-Command -ComputerName $servers -ScriptBlock {
                $physicaladapters=(get-vmswitch SETSwitch).NetAdapterInterfaceDescriptions | Sort-Object
                Set-VMNetworkAdapterTeamMapping –VMNetworkAdapterName "SMB_1" –ManagementOS –PhysicalNetAdapterName (get-netadapter -InterfaceDescription $physicaladapters[0]).name
                Set-VMNetworkAdapterTeamMapping –VMNetworkAdapterName "SMB_2" –ManagementOS –PhysicalNetAdapterName (get-netadapter -InterfaceDescription $physicaladapters[1]).name
            }
        }
    
    #Verify Networking
        if ($Networking){
            #verify mapping
                Get-VMNetworkAdapterTeamMapping -CimSession $servers -ManagementOS | ft ComputerName,NetAdapterName,ParentAdapter 
            #Verify that the VlanID is set
                Get-VMNetworkAdapterVlan –ManagementOS -CimSession $servers |Sort-Object -Property Computername | ft ComputerName,AccessVlanID,ParentAdapter -AutoSize -GroupBy ComputerName
            #verify RDMA
                Get-NetAdapterRdma -CimSession $servers | Sort-Object -Property Systemname | ft systemname,interfacedescription,name,enabled -AutoSize -GroupBy Systemname
            #verify ip config 
                Get-NetIPAddress -CimSession $servers -InterfaceAlias vEthernet* -AddressFamily IPv4 | Sort-Object -Property PSComputername | ft pscomputername,interfacealias,ipaddress -AutoSize -GroupBy pscomputername

        }

    #configure DCB if requested
        if ($DCB -eq $True){
            #Install DCB
                if (!$NanoServer){
                    foreach ($server in $servers) {Install-WindowsFeature -Name "Data-Center-Bridging" -ComputerName $server} 
                }
            ##Configure QoS
                New-NetQosPolicy "SMB" –NetDirectPortMatchCondition 445 –PriorityValue8021Action 3 -CimSession $servers

            #Turn on Flow Control for SMB
                Invoke-Command -ComputerName $servers -ScriptBlock {Enable-NetQosFlowControl –Priority 3}

            #Disable flow control for other traffic
                Invoke-Command -ComputerName $servers -ScriptBlock {Disable-NetQosFlowControl –Priority 0,1,2,4,5,6,7}

            #validate flow control setting
                Invoke-Command -ComputerName $servers -ScriptBlock { Get-NetQosFlowControl} | Sort-Object  -Property PSComputername | ft PSComputerName,Priority,Enabled -GroupBy PSComputerNa

            #Apply policy to the target adapters.  The target adapters are adapters connected to vSwitch
                Invoke-Command -ComputerName $servers -ScriptBlock {Enable-NetAdapterQos -InterfaceDescription (Get-VMSwitch).NetAdapterInterfaceDescriptions}

            #validate policy
                Invoke-Command -ComputerName $servers -ScriptBlock {Get-NetAdapterQos | where enabled -eq true} | Sort-Object PSComputerName

            #Create a Traffic class and give SMB Direct 30% of the bandwidth minimum.  The name of the class will be "SMB"
                Invoke-Command -ComputerName $servers -ScriptBlock {New-NetQosTrafficClass "SMB" –Priority 3 –BandwidthPercentage 30 –Algorithm ETS}
        }

    #enable iWARP firewall rule if requested
        if ($iWARP -eq $True){
            Enable-NetFirewallRule -Name "FPSSMBD-iWARP-In-TCP" -CimSession $servers
        }

#endregion

#Region test and create new cluster 
    Test-Cluster –Node $servers –Include "Storage Spaces Direct",Inventory,Network,"System Configuration"
    New-Cluster –Name $ClusterName –Node $servers
    Start-Sleep 5
    Clear-DnsClientCache

#endregion

#region Create Fault Domains https://technet.microsoft.com/en-us/library/mt703153.aspx
#just some examples for Rack/Chassis fault domains.
if ($numberofnodes -eq 4){
$xml =  @"
<Topology>
    <Site Name="SEA" Location="Contoso HQ, 123 Example St, Room 4010, Seattle">
        <Rack Name="Rack01" Location="Contoso HQ, Room 4010, Aisle A, Rack 01">
                <Node Name="$($ServersNamePrefix)1"/>
                <Node Name="$($ServersNamePrefix)2"/>
                <Node Name="$($ServersNamePrefix)3"/>
                <Node Name="$($ServersNamePrefix)4"/>
        </Rack>
    </Site>
</Topology>
"@

Set-ClusterFaultDomainXML -XML $xml -CimSession $ClusterName
}

if ($numberofnodes -eq 8){
$xml =  @"
<Topology>
    <Site Name="SEA" Location="Contoso HQ, 123 Example St, Room 4010, Seattle">
        <Rack Name="Rack01" Location="Contoso HQ, Room 4010, Aisle A, Rack 01">
            <Node Name="$($ServersNamePrefix)1"/>
            <Node Name="$($ServersNamePrefix)2"/>
        </Rack>
        <Rack Name="Rack02" Location="Contoso HQ, Room 4010, Aisle A, Rack 02">
            <Node Name="$($ServersNamePrefix)3"/>
            <Node Name="$($ServersNamePrefix)4"/>
        </Rack>
        <Rack Name="Rack03" Location="Contoso HQ, Room 4010, Aisle A, Rack 03">
            <Node Name="$($ServersNamePrefix)5"/>
            <Node Name="$($ServersNamePrefix)6"/>
        </Rack>
        <Rack Name="Rack04" Location="Contoso HQ, Room 4010, Aisle A, Rack 04">
            <Node Name="$($ServersNamePrefix)7"/>
            <Node Name="$($ServersNamePrefix)8"/>
        </Rack>
    </Site>
</Topology>
"@

Set-ClusterFaultDomainXML -XML $xml -CimSession $ClusterName
    
}


if ($numberofnodes -eq 16){
$xml =  @"
<Topology>
    <Site Name="SEA" Location="Contoso HQ, 123 Example St, Room 4010, Seattle">
        <Rack Name="Rack01" Location="Contoso HQ, Room 4010, Aisle A, Rack 01">
            <Chassis Name="Chassis01" Location="Rack Unit 1 (Upper)" >
                <Node Name="$($ServersNamePrefix)1"/>
                <Node Name="$($ServersNamePrefix)2"/>
                <Node Name="$($ServersNamePrefix)3"/>
                <Node Name="$($ServersNamePrefix)4"/>
            </Chassis>
            <Chassis Name="Chassis02" Location="Rack Unit 1 (Upper)" >
                <Node Name="$($ServersNamePrefix)5"/>
                <Node Name="$($ServersNamePrefix)6"/>
                <Node Name="$($ServersNamePrefix)7"/>
                <Node Name="$($ServersNamePrefix)8"/>
            </Chassis>
            <Chassis Name="Chassis03" Location="Rack Unit 1 (Lower)" >
                <Node Name="$($ServersNamePrefix)9"/>
                <Node Name="$($ServersNamePrefix)10"/>
                <Node Name="$($ServersNamePrefix)11"/>
                <Node Name="$($ServersNamePrefix)12"/>
            </Chassis>
            <Chassis Name="Chassis04" Location="Rack Unit 1 (Lower)" >
                <Node Name="$($ServersNamePrefix)13"/>
                <Node Name="$($ServersNamePrefix)14"/>
                <Node Name="$($ServersNamePrefix)15"/>
                <Node Name="$($ServersNamePrefix)16"/>
            </Chassis>
        </Rack>
    </Site>
</Topology>
"@

Set-ClusterFaultDomainXML -XML $xml -CimSession $ClusterName

}

    #show fault domain configuration
        Get-ClusterFaultDomainxml -CimSession $ClusterName

#endregion

#region configure S2D and create vDisks

    #Enable-ClusterS2D
        Enable-ClusterS2D -CimSession $ClusterName -confirm:0 -Verbose

    #Create vDisks
        if ($numberofnodes -le 3){
            1..$NumberOfDisks | ForEach-Object {
                New-Volume -StoragePoolFriendlyName "S2D on $ClusterName" -FriendlyName Mirror$_ -FileSystem CSVFS_ReFS -StorageTierFriendlyNames Capacity -StorageTierSizes 2TB -CimSession $ClusterName
            }
        }else{
            1..$NumberOfDisks | ForEach-Object {
                New-Volume -StoragePoolFriendlyName "S2D on $ClusterName" -FriendlyName MirrorAcceleratedParity$_ -FileSystem CSVFS_ReFS -StorageTierFriendlyNames performance,capacity -StorageTierSizes 2TB,8TB -CimSession $ClusterName
                New-Volume -StoragePoolFriendlyName "S2D on $ClusterName" -FriendlyName Mirror$_                  -FileSystem CSVFS_ReFS -StorageTierFriendlyNames performance          -StorageTierSizes 2TB     -CimSession $ClusterName
            }
        }

    start-sleep 10

    #rename CSV(s) to match name
        Get-ClusterSharedVolume -Cluster $ClusterName | % {
            $volumepath=$_.sharedvolumeinfo.friendlyvolumename
            $newname=$_.name.Substring(22,$_.name.Length-23)
            Invoke-Command -ComputerName (Get-ClusterSharedVolume -Cluster $ClusterName -Name $_.Name).ownernode -ScriptBlock {param($volumepath,$newname); Rename-Item -Path $volumepath -NewName $newname} -ArgumentList $volumepath,$newname -ErrorAction SilentlyContinue
        } 

#endregion

#region configure Witness and other cluster settings
    #ConfigureWitness on DC
        #Create new directory
            $WitnessName=$Clustername+"Witness"
            Invoke-Command -ComputerName DC -ScriptBlock {param($WitnessName);new-item -Path c:\Shares -Name $WitnessName -ItemType Directory} -ArgumentList $WitnessName
            $accounts=@()
            $accounts+="corp\$ClusterName$"
            $accounts+="corp\Domain Admins"
            New-SmbShare -Name $WitnessName -Path "c:\Shares\$WitnessName" -FullAccess $accounts -CimSession DC
        # Set NTFS permissions 
            Invoke-Command -ComputerName DC -ScriptBlock {param($WitnessName);(Get-SmbShare "$WitnessName").PresetPathAcl | Set-Acl} -ArgumentList $WitnessName
        #Set Quorum
            Set-ClusterQuorum -Cluster $ClusterName -FileShareWitness "\\DC\$WitnessName"

    #configure other cluster settings
        #set CSV Cache 
            #(Get-Cluster $ClusterName).BlockCacheSize = 10240 

        #rename networks
            (Get-ClusterNetwork -Cluster $clustername | where Address -eq $StorNet"0").Name="SMB"
            (Get-ClusterNetwork -Cluster $clustername | where Address -eq "10.0.0.0").Name="Management"

        #configure Live Migration 
            Get-ClusterResourceType -Cluster $clustername -Name "Virtual Machine" | Set-ClusterParameter -Name MigrationExcludeNetworks -Value ([String]::Join(";",(Get-ClusterNetwork -Cluster $clustername | Where-Object {$_.Name -ne "SMB"}).ID))
            Set-VMHost –VirtualMachineMigrationPerformanceOption SMB -cimsession $servers
#endregion

#region create some VMs and optimize pNICs and activate High Perf Power Plan

    #create some fake VMs
        Start-Sleep -Seconds 30 #just to a bit wait as I saw sometimes that first VM fails to create
        $CSVs=(Get-ClusterSharedVolume -Cluster $ClusterName).Name
        foreach ($CSV in $CSVs){
            $CSV=$CSV.Substring(22)
            $CSV=$CSV.TrimEnd(")")
            1..3 | ForEach-Object {
                $VMName="TestVM$($CSV)_$_"
                Invoke-Command -ComputerName (Get-ClusterNode -Cluster $ClusterName).name[0] -ArgumentList $CSV,$VMName -ScriptBlock {
                    param($CSV,$VMName);
                    New-VM -Name $VMName -NewVHDPath "c:\ClusterStorage\$CSV\$VMName\Virtual Hard Disks\$VMName.vhdx" -NewVHDSizeBytes 32GB -SwitchName SETSwitch -Generation 2 -Path "c:\ClusterStorage\$CSV\"
                }
                Add-ClusterVirtualMachineRole -VMName $VMName -Cluster $ClusterName
            }
        }

    #move NICs out of CPU 0 (not much tested)
        if ($RealHW){
            $Switches=Get-VMSwitch -CimSession $servers -SwitchType External

            foreach ($switch in $switches){
                $processor=Get-WmiObject win32_processor -ComputerName $switch.ComputerName | Select -First 1
                if ($processor.NumberOfCores -eq $processor.NumberOfLogicalProcessors/2){
                    $HT=$True
                }
                $adapters=@()
                $switch.NetAdapterInterfaceDescriptions | ForEach-Object {$adapters+=Get-NetAdapterHardwareInfo -InterfaceDescription $_ -CimSession $switch.computername}

                foreach ($adapter in $adapters){
                    if($HT){
                        $BaseProcessorNumber=$adapter.NumaNode*$processor.NumberOfLogicalProcessors+2
                    }else{
                        $BaseProcessorNumber=$adapter.NumaNode*$processor.NumberOfLogicalProcessors+1
                    }
                    $adapter=Get-NetAdapter -InterfaceDescription $adapter.InterfaceDescription -CimSession $adapter.PSComputerName  
                    $adapter | Set-NetAdapterVmq -BaseProcessorNumber $BaseProcessorNumber -MaxProcessors ($processor.NumberOfCores-1)
                    $adapter | Set-NetAdapterRss -Profile Closest
                }
            }
        }

    #activate High Performance Power plan
        #show enabled power plan
            Get-CimInstance -Name root\cimv2\power -Class win32_PowerPlan -CimSession (Get-ClusterNode -Cluster $ClusterName).Name | where isactive -eq $true | ft PSComputerName,ElementName
        #Grab instances of power plans
            $instances=Get-CimInstance -Name root\cimv2\power -Class win32_PowerPlan -CimSession (Get-ClusterNode -Cluster $ClusterName).Name | where Elementname -eq "High performance"
        #activate plan
            foreach ($instance in $instances) {Invoke-CimMethod -InputObject $instance -MethodName Activate}
        #show enabled power plan
            Get-CimInstance -Name root\cimv2\power -Class win32_PowerPlan -CimSession (Get-ClusterNode -Cluster $ClusterName).Name | where isactive -eq $true | ft PSComputerName,ElementName

#endregion
#finishing
Write-Host "Script finished at $(Get-date) and took $(((get-date) - $StartDateTime).TotalMinutes) Minutes"
Stop-Transcript