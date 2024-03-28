<#
    #####################
    #       Notes       #
    ##################### 
    Gets storage account information
    Mounts storage share if not already mounted. Can use better detection here
    Gets all vhdx's from share
    runs repair on all vhdx's that are not currently mounted

    Server being run against must have enough resources and line of site to the file share

    Variables not selectable when running against server so much be added here or use secure variables
    FslShareName
        Example: "FSlogix"
    FslStorageAccount
        Exmpale: "stg2093g90sd"
    #####################
    #       TODO        #
    ##################### 
    Better logging  into nerdio output
    Detect net use needed or not before run to avoid unnecesary error output
    Add logic for network share with ad account instead of azure files and storage key
#>

#Set base variables
#Not currently functional
$TaskThrottleLimit = 10
$FSLogixShareName = ""
$FSLogixStorageAccount = ""

#Retrieve secure variables
$AzureFSLogixShareName = $SecureVars.FslShareName
$AzureFSLogixStorageAccount = $SecureVars.FslStorageAccount

# Override values with parameters supplied at runtime if specified
if (-not($AzureFSLogixShareName)) {$AzureFSLogixShareName = $FSLogixShareName}
if (-not($AzureFSLogixStorageAccount)) {$AzureFSLogixStorageAccount = $FSLogixStorageAccount}

if ([string]::IsNullOrEmpty($AzureFSLogixStorageAccount)) {
    Throw "Missing the FSLogix account name. Either provie account name paramater at runtime, or create FslStorageUser and FslStorageAccount secure variables in Nerdio Manager"
}
if ([string]::IsNullOrEmpty($AzureFSLogixShareName)) {
    Throw "Missing the FSLogix share name. Either provie share name paramater at runtime, or create FslStorageUser and FslShare secure variables in Nerdio Manager"
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

Try {
#Script to run
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
        $job = Invoke-AzVmRunCommand -ResourceGroupName $azureResourceGroupName -VMName $azureVmName -ScriptPath .\scriptblock.ps1 -CommandId 'RunPowershellScript' -AsJob
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
        Write-Output "Error during execution of script on VM"
        Throw $_ 
    }
    #Receive Job
    $job = Receive-Job -id $job.id 
    if ($job.value.Message -like '*No files to process*') {  
        Write-Output "SUCCESS: No files to process" 
    } elseif ($job.value.Message -like '*error*') {  
        Write-Output "Failed. An error occurred: `n $($job.value.Message)" 
        throw $($job.value.Message)        
    } else {
        $job | out-string | Write-Output
    } 
} Catch { #Try Create Resources
    Write-Output "Error during execution of script on VM"
    Throw $_ 
}
