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
    "FSLogixAgeThreshold": {
        "Description": "Threshold for change a vhdx to .old. or use secure variable FslModifedThreshold",
        "IsRequired": false,
        "Default": "90"
    },
    "FSLogixOldThreshold": {
        "Description": "Threshold for removal of .old files. or use secure variable FslOldThreshold",
        "IsRequired": false,
        "Default": "90"
    }
}
#>

#Retrieve secure variables
$AzureFSLogixShareName = $SecureVars.FslShareName
$AzureFSLogixStorageAccount = $SecureVars.FslStorageAccount
$AzureFSLogixAgeThreshold = $SecureVars.FslModifedThreshold
$AzureFSLogixOldThreshold = $SecureVars.FslOldThreshold

# Override values with parameters supplied at runtime if specified
if (-not($AzureFSLogixShareName)) {$AzureFSLogixShareName = $FSLogixShareName}
if (-not($AzureFSLogixStorageAccount)) {$AzureFSLogixStorageAccount = $FSLogixStorageAccount}
if (-not($AzureFSLogixAgeThreshold)) {$AzureFSLogixAgeThreshold= $FSLogixAgeThreshold}
if (-not($AzureFSLogixOldThreshold)) {$AzureFSLogixOldThreshold = $FSLogixOldThreshold}

<#
    #####################
    #       Notes       #
    ##################### 
    Variables can be defined from running the script or secure variables
    FslShareName
        Example: "fslogix"
    FslStorageAccount
        Exmpale: "stg2093g90sd"
    FslModifedThreshold
        Example: "90"
    FSLogixOldThreshold
        Example: "90"

    #####################
    #       TODO        #
    ##################### 
    Better logging  into nerdio output
    Check if file is in use before removal. It will error either way but...
#>

if ([string]::IsNullOrEmpty($AzureFSLogixStorageAccount)) {
    Throw "Missing the FSLogix account name. Either provie account name paramater at runtime, or create FslStorageAccount secure variable in Nerdio Manager"
}
if ([string]::IsNullOrEmpty($AzureFSLogixShareName)) {
    Throw "Missing the FSLogix share name. Either provie share name paramater at runtime, or create FslShareName secure variable in Nerdio Manager"
}
if ([string]::IsNullOrEmpty($AzureFSLogixAgeThreshold)) {
    Throw "Missing the VHDX age threshold. Either provie threshold paramater at runtime, or create FslModifedThreshold secure variable in Nerdio Manager"
}
if ([string]::IsNullOrEmpty($AzureFSLogixOldThreshold)) {
    Throw "Missing the .old age threshold. Either provie thresholdparamater at runtime, or create FSLogixOldThreshold secure variable in Nerdio Manager"
}

#Correct potential bad formatting. Capitalization matters...
$AzureFSLogixShareName = $AzureFSLogixShareName.ToLower()
$AzureFSLogixStorageAccount = $AzureFSLogixStorageAccount.ToLower()

#Obtain storage account information
$StorageAccount = Get-AzStorageAccount | Where-Object {$_.StorageAccountName -eq $AzureFSLogixStorageAccount}
if (-not($StorageAccount)) {
    Throw "Unable to get storage account $AzureFSLogixStorageAccount. Please check the name."
}

$Date = Get-Date
$OldFileCutoff = $Date.AddDays(-$AzureFSLogixOldThreshold)
$VHDXFileCutoff = $Date.AddDays(-$FSLogixAgeThreshold)
$OldFileFormat = ".vhdx.old"
$CurFileFormat = ".vhdx"

Write-Output "Cutoff for old file removal: $($OldFileCutoff)"
Write-Output "Cutoff for vhdx to .old: $($VHDXFileCutoff)"
#Get .old files for removal
$OldFiles = Get-AzStorageFile -Context $StorageAccount.Context -ShareName $AzureFSLogixShareName | Get-AzStorageFile | Where-Object {$_.Name -Like "*$($OldFileFormat)"}
$AgedOutOldFiles = $OldFiles | Where-Object {$_.LastModified -lt $OldFileCutoff}
$AgedOutOldFiles | ForEach-Object { 
    $AgedOutOldFile = $_
    Write-Output "$($AgedOutOldFile.Name) last modified: $($AgedOutOldFile.LastModified)"
    Write-Output "Removing: $($AgedOutOldFile.Name)"
    Remove-AzStorageFile -File $AgedOutOldFile.CloudFile
}

#Get .vhdx files to flag for .old
$VHDXFiles = Get-AzStorageFile -Context $StorageAccount.Context -ShareName $AzureFSLogixShareName | Get-AzStorageFile | Where-Object {$_.Name -Like "*$($CurFileFormat)"}
$AgedOutVHDXFiles = $VHDXFiles | Where-Object {$_.LastModified -lt $VHDXFileCutoff}
$AgedOutVHDXFiles | ForEach-Object {
    $AgedOutVHDXFile = $_
    Write-Output "$($AgedOutVHDXFile.Name) last modified: $($AgedOutVHDXFile.LastModified)"
    Write-Output "Renaming VHDX to .old: $($AgedOutVHDXFile.Name)"
    $Path = $AgedOutVHDXFile.CloudFile.Parent.Uri.LocalPath
    $OldName = $AgedOutVHDXFile.name
    $NewName = $AgedOutVHDXFile.name.Replace("$($CurFileFormat)", "$($OldFileFormat)")
    $SourcePath = ($Path+"/"+$OldName).Replace("/"+$AzureFSLogixShareName+"/", "")
    $DestinationPath = ($Path+"/"+$NewName).Replace("/"+$AzureFSLogixShareName+"/", "")
    Rename-AzStorageFile -SourcePath $SourcePath -DestinationPath $DestinationPath -Context $StorageAccount.Context -ShareName $AzureFSLogixShareName
}
