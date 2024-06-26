<# Variables:
{
    "FSLogixShareName": {
        "Description": "Share name in azure storage for the profles. or use secure variable FslShareName",
        "IsRequired": false
    },
    "FSLogixStorageAccount": {
        "Description": "Share name in azure storage account for the profles. or use secure variable FslStorageAccount",
        "IsRequired": false
    },
    "VNetName": {
        "Description": "VNet in which to create the temp VM. Must be able to access the fslogix fileshare. or use secure variable FslTempVmVnet",
        "IsRequired": false
    },
    "SubnetName": {
        "Description": "Subnet in which to create the temp VM. or use secure variable FslTempVmSubnet",
        "IsRequired": false
    },  
    "ResourceGroupName": {
        "Description": "Resource in which to create the temp VM. Leave blank to use the Vnet's ResourceGroup. or use secure variable FslTempVmResourceGroup",
        "IsRequired": false
    },
    "TempVmSize": {
        "Description": "Size of the temporary VM from which the repair script will be run.",
        "IsRequired": false,
        "DefaultValue": "Standard_D16s_v4"
    },
    "TempVmName": {
        "Description": "Name of the temporary VM from which the repair script will be run.",
        "IsRequired": false,
        "DefaultValue": "fslrepair-temp"
    },
    "ThrottleLimit": {
        "Description": "Throttle limit for vhdx processing simultaniously. Use in future, Not currently functional",
        "IsRequired": false,
        "DefaultValue": "10"
    }
}
#>
<#
    #####################
    #       Notes       #
    ##################### 
    Creates new server
    Gets storage account information
    Mounts storage share
    Gets all vhdx's from share
    runs repair on all vhdx's that are not currently mounted
    Removes new server

    Variables can be defined from running the script or secure variables
    FslShareName
        Example: "fslogix"
    FslStorageAccount
        Exmpale: "stg2093g90sd"
    FslTempVmVnet
        Example: VNET_PROD_WEST3
    FslTempVmSubnet
        Example: SN_PROD_WEST3_Infr
    FslTempVmResourceGroup
        Example: PROD_WEST3
    #####################
    #       TODO        #
    ##################### 
    Better logging  into nerdio output

#>

$ErrorActionPreference = 'Stop'

#Set base variables
$azureVmPublisherName = "MicrosoftWindowsServer"
$azureVmOffer = "WindowsServer"
$azureVmSkus = "2019-datacenter-core-g2"
$AzureVMName = "fslrepair-temp"
$AzureVmSize = 'Standard_D16s_v4'
$vmAdminUsername = "LocalAdminUser"
$TaskThrottleLimit = 5
$Guid = (new-guid).Guid
$vmAdminPassword = ConvertTo-SecureString "$Guid" -AsPlainText -Force
#Retrieve secure variables
$AzureVnetName = $SecureVars.FslTempVmVnet
$AzureVnetSubnetName = $SecureVars.FslTempVmSubnet
$AzureFSLogixShareName = $SecureVars.FslShareName
$AzureFSLogixStorageAccount = $SecureVars.FslStorageAccount
$AzureResourceGroup = $SecureVars.FslTempVmResourceGroup
# Override values with parameters supplied at runtime if specified
if ($VNetName) {$azureVnetName = $VNetName}
if ($SubnetName) {$azureVnetSubnetName = $SubnetName}
if ($TempVmSize) {$azureVmSize = $TempVmSize}
if ($TempVmName) {$AzureVMName = $TempVmName}
if ($FSLogixShareName) {$AzureFSLogixShareName = $FSLogixShareName}
if ($FSLogixStorageAccount) {$AzureFSLogixStorageAccount = $FSLogixStorageAccount}
if ($ThrottleLimit) {$TaskThrottleLimit = $ThrottleLimit}
if ($ResourceGroupName) {$AzureResourceGroup = $ResourceGroupName}

#Define the parameters for the Azure resources.
$azureVmOsDiskName = "$AzureVMName-os"
$azureNicName = "$AzureVMName-NIC"

# Check for essential variables
if ([string]::IsNullOrEmpty($azureVnetName)){
    Throw "Missing vnet name. Either provide the VNetName parameter at runtime, or create the FslTempVmVnet secure variable in Nerdio Settings"
}
if ([string]::IsNullOrEmpty($azureVnetSubnetName)) {
    Throw "Missing subnet name. Either provide the SubnetName parameter at runtime, or create the FslTempVmSubnet secure variable in Nerdio Settings."
}
if ([string]::IsNullOrEmpty($AzureFSLogixStorageAccount)) {
    Throw "Missing the FSLogix account name. Either provie account name paramater at runtime, or create FslStorageAccount secure variable in Nerdio Manager"
}
if ([string]::IsNullOrEmpty($AzureFSLogixShareName)) {
    Throw "Missing the FSLogix share name. Either provie share name paramater at runtime, or create FslShareName secure variable in Nerdio Manager"
}

#Correct potential bad formatting. Capitalization matters...
$AzureFSLogixShareName = $AzureFSLogixShareName.ToLower()
$AzureFSLogixStorageAccount = $AzureFSLogixStorageAccount.ToLower()

#Get the subnet details for the specified virtual network + subnet combination.
Write-Output "Getting vnet details"
$Vnet = Get-AzVirtualNetwork -Name $azureVnetName 
if (-not($vnet)) {
    Throw "Unable to get virtual network $azureVnetName. Please check the name."
}
$AzureRegionName = $vnet.Location
$azureVnetSubnet = $Vnet.Subnets | Where-Object {$_.Name -eq $azureVnetSubnetName}
if (-not($AzureResourceGroup)) {$AzureResourceGroup = $Vnet.ResourceGroupName}
if (-not($AzureResourceGroup)) {
    Throw "Unable to use $AzureResourceGroup. Please check the settings."
}

#Obtain storage account information
$StorageAccount = Get-AzStorageAccount | Where-Object {$_.StorageAccountName -eq $AzureFSLogixStorageAccount}
if (-not($StorageAccount)) {
    Throw "Unable to get storage account $AzureFSLogixStorageAccount. Please check the name."
}
$StorageAccountKeys = Get-AzStorageAccountKey -ResourceGroupName $StorageAccount.ResourceGroupName -Name $StorageAccount.StorageAccountName
$StorageAccountShare = Get-AzRmStorageShare -ResourceGroupName $StorageAccount.ResourceGroupName -StorageAccountName $StorageAccount.StorageAccountName -Name $AzureFSLogixShareName
if (-not($StorageAccountShare)) {
    Throw "Unable to get share $AzureFSLogixShareName. Please check the name."
}
$StorageAccountUser = $StorageAccountShare.StorageAccountName
$FSLogixFileShare = "\\$($StorageAccountShare.StorageAccountName).file.core.windows.net\$($StorageAccountShare.Name)"
$StorageAccountKey = $StorageAccountKeys[0].Value

$FSLogixConnectionCommand = "net use $($FSLogixFileShare) /user:$($StorageAccountUser) $($StorageAccountKey)"

Write-Output "Variables set: 
VNet for temp vm is $azureVnetName
Subnet is $azureVnetSubnetName
Path to fslogix share is $FSLogixFileShare
User account to access share is $StorageAccountUser
Resource Group for temp vm is $azureResourceGroup
Temp VM size is $azureVmSize
Region is $AzureRegionName"

Try { #Try Create Resources
    #Create the NIC.
    Write-Output "Creating NIC"
    $azureNIC = New-AzNetworkInterface -Name $azureNicName -ResourceGroupName $azureResourceGroup -Location $AzureRegionName -SubnetId $azureVnetSubnet.Id -Force
    
    #Store the credentials for the local admin account.
    Write-Output "Creating VM credentials"
    $vmCredential = New-Object System.Management.Automation.PSCredential ($vmAdminUsername, $vmAdminPassword)
    
    #Define the parameters for the new virtual machine.
    Write-Output "Creating VM config"
    $VirtualMachine = New-AzVMConfig -VMName $AzureVMName -VMSize $azureVmSize
    $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $AzureVMName -Credential $vmCredential -ProvisionVMAgent -EnableAutoUpdate
    $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $azureNIC.Id
    $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $azureVmPublisherName -Offer $azureVmOffer -Skus $azureVmSkus -Version "latest"
    $VirtualMachine = Set-AzVMBootDiagnostic -VM $VirtualMachine -Disable
    $VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -StorageAccountType "Premium_LRS" -Caching ReadWrite -Name $azureVmOsDiskName -CreateOption FromImage

    #Create the virtual machine.
    Write-Output "Creating new VM"
    $VM = New-AzVM -ResourceGroupName $azureResourceGroup -Location $AzureRegionName -VM $VirtualMachine -Verbose -ErrorAction stop
    Start-sleep 30
    if($VM) {
        Write-Output "$($AzureVMName) Created"
    }

#Script to run. Must remove leading tabs
$ScriptBlock = @"
Remove-Item -Path "$FSLogixFileShare\FslRepairDiskMaster.log" -Force
Start-Transcript -Path "$FSLogixFileShare\FslRepairDiskMaster.log" -Force

#authenticate connection
Invoke-Expression "$FSLogixConnectionCommand"

If (-not(Test-Path "$FSLogixFileShare")) {
    Throw "cannot access $FSLogixFileShare"
    break
}

`$ErrorActionPreference = 'SilentlyContinue'
#Get all vhdx's in path
`$vhdxs = Get-Childitem "$FSLogixFileShare" -recurse -include *.vhdx
#Throttle limit not currently working as expected
`$vhdxs | ForEach-Object { #-ThrottleLimit $TaskThrottleLimit -Parallel {
    `$VHDX = `$_
    `$VHDXPath = `$VHDX.Directory.FullName
    Remove-Item -Path "`$(`$VHDXPath)\FslRepairDisk.log" -Force
    Start-Transcript -Path "`$(`$VHDXPath)\FslRepairDisk.log" -Force
    Write-Output "Processing `$(`$VHDX.name)"
    `$IsMounted = `$null
    try {
        #Check if metadata file exists. Determines if mounted or not.
        `$IsMounted = Get-ChildItem `$VHDXPath -Recurse -Depth 0 -Include *.vhdx.metadata
        if(-not(`$IsMounted)) {
            #Mount Drive and gather information
            `$Disk = Mount-DiskImage -ImagePath `$VHDX.FullName -Verbose
            `$Mount = Get-DiskImage -ImagePath `$Disk.ImagePath -Verbose | Get-Disk | Get-Partition | Get-Volume
        } else {
            throw "`$(`$VHDX.name) Currently Mounted"
        }
    } catch {
        Write-Output "Error on mounting drive `$(`$VHDX.name)"
    }
    if(-not(`$IsMounted)) {
        try {
            #Run repair using system label
            Write-Output "Attempting repair on `$(`$VHDX.name)"
            `$Repair = Repair-Volume -Path `$Mount.Path -OfflineScanAndFix -Verbose
            `$Dismount = Dismount-DiskImage -ImagePath `$VHDX.FullName -Verbose
            Write-Output "Scan and Repair finished on `$(`$VHDX.name)"
            Write-Output "`$(`$VHDX.Name): `$(`$Repair)"
        } catch {
            Write-Output "An error occured on scan or repair of `$(`$VHDX.name)"
            try {
                #Run repair using system label
                Write-Output "Attempting Alternate repair on `$(`$VHDX.name)"
                cmd /c "chkdsk `$(`$Mount.Path) /f /r /b" | Out-Null
                `$Repair = Repair-Volume -Path `$Mount.Path -OfflineScanAndFix -Verbose
                `$Dismount = Dismount-DiskImage -ImagePath `$VHDX.FullName
                Write-Output "Scan and Repair finished on `$(`$VHDX.name)"
                Write-Output "`$(`$VHDX.Name): `$(`$Repair)"
            } catch {
                Write-Output "An error occured on alternate repair of `$(`$VHDX.name)"
                Write-Output "Unable to repair `$(`$VHDX.name)"
            }
        }
    }
    Stop-Transcript
}
Stop-Transcript
"@
$scriptblock > .\scriptblock.ps1

    try { #Run Script
        Write-Output "Running script on temp vm"
        $Time = get-date
        $job = Invoke-AzVmRunCommand -ResourceGroupName $azureResourceGroup -VMName $azureVmName -ScriptPath .\scriptblock.ps1 -CommandId 'RunPowershellScript' -AsJob -Verbose
        While ((get-job $job.id).state -eq 'Running') {
            if ((get-date) -gt $time.AddMinutes(86)){
                get-job $job.id | Stop-Job -Force
                Write-Output "Unable to finish processing profiles before 90 minute timeout elapsed"
                Throw "Unable to finish processing profiles before 90 minute timeout elapsed"
            } else {
                Start-Sleep 60
            }
        }
    } catch { #Run Script
        Write-Output "Error during execution of script on temp VM"
        Throw $_ 
    }

} Catch { #Try Create Resources
    Write-Output "Error during execution of script on temp VM"
    Throw $_ 
} Finally { #Try Create Resources
    Write-Output "Removing temporary VM"
    Start-Sleep 180
    Remove-AzVM -Name $azureVmName -ResourceGroupName $AzureResourceGroup -Force -ErrorAction Continue
    Remove-AzDisk -ResourceGroupName $AzureResourceGroup -DiskName $azureVmOsDiskName -Force -ErrorAction Continue
    Remove-AzNetworkInterface -Name $azureNicName -ResourceGroupName $AzureResourceGroup -Force -ErrorAction Continue
}
