# This script will help with the process of shrinking a managed disk in Azure.
# It's a modification of the OS disk shink script located here: https://jrudlin.github.io/2019-08-27-shrink-azure-vm-osdisk/
# The steps are in the link above but the basic steps are:
# 1. Shrink the disk in Windows using the Disk Management Tool (diskmgmt.msc) to something smaller than you're shrinking to
# 2. Fill out the variables below
# 3. Run the script
# 4. After VM is back online use the Disk Management Tool to expand the disk to reclaim the new size
# 4. Delete storage account sashrinkddisk* and old managed disk after everything checks out


# Variables
$DiskID = ""# "/subscriptions/203bdbf0-69bd-1a12-a894-a826cf0a34c8/resourcegroups/rg-server1-prod-1/providers/Microsoft.Compute/disks/Server1-Server1"
$VMName = "" # "VM name"
$DiskSizeGB = 128 # size you're shinking to
$AzSubscription = "" # "subscription name"
# Provide the storage type for the Managed Disk. 
# Available values are Standard_LRS (HDD), StandardSSD_LRS (SSD) Premium_LRS (Premium SSD)
$SKUType = "StandardSSD_LRS"
# End Variables

# Provide your Azure admin credentials
Connect-AzAccount

#Provide the subscription Id of the subscription where snapshot is created
Select-AzSubscription -Subscription $AzSubscription

# Get VM
$VM = Get-AzVm | ? Name -eq $VMName

# Shutdown the VM
Write-Host "Shutting down VM" -ForegroundColor DarkBlue -BackgroundColor White
$VM | Stop-AzVM -Force

# Get resource group name
$resourceGroupName = $VM.ResourceGroupName

# Get Disk ID
Write-Host "Getting Disk ID" -ForegroundColor DarkBlue -BackgroundColor White
$Disk = Get-AzDisk | ? Id -eq $DiskID

# Get VM/Disk generation from Disk
$HyperVGen = $Disk.HyperVGeneration

# Get Disk Name from Disk
$DiskName = $Disk.Name

Write-Host "Getting SAS URI for the managed disk" -ForegroundColor DarkBlue -BackgroundColor White
# Get SAS URI for the Managed disk
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName -Access 'Read' -DurationInSecond 600000;

# Storage account name where you want to copy the disk - the script will create a new one temporarily
$storageAccountName = "sashrinkddisk" #+ ($($VMName -replace '[^a-zA-Z0-9]', '')).ToLower()
Write-Host "Storage account name" $storageAccountName -ForegroundColor DarkBlue -BackgroundColor White

# Name of the storage container where the disk will be stored
$storageContainerName = $storageAccountName
Write-Host "Storage container name" $storageContainerName -ForegroundColor DarkBlue -BackgroundColor White

# Name of the VHD file to which disk will be copied.
$destinationVHDFileName = "$($DiskName).vhd"
Write-Host "VHD name is " $destinationVHDFileName -ForegroundColor DarkBlue -BackgroundColor White

# Create the context for the storage account which will be used to copy disk to the storage account 
Write-Host "Creating storage account..." $storageAccountName -ForegroundColor DarkBlue -BackgroundColor White
$StorageAccount = New-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName -SkuName Standard_LRS -Location $VM.Location
$destinationContext = $StorageAccount.Context
Write-Host "Creating storage container..." $storageContainerName -ForegroundColor DarkBlue -BackgroundColor White
$container = New-AzStorageContainer -Name $storageContainerName -Permission Off -Context $destinationContext

# Copy the disk to the storage account and wait for it to complete
Write-Host "Begin copying disk snapshot to storage container" -ForegroundColor DarkBlue -BackgroundColor White
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $destinationVHDFileName -DestContext $destinationContext
while(($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $destinationVHDFileName -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 20 }
$state

# Revoke SAS token
Write-Host "Revoke SAS URI" -ForegroundColor DarkBlue -BackgroundColor White
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName

# Emtpy disk to get footer from
$emptydiskforfootername = "$($DiskName)-empty.vhd"

# Disk config
 $diskConfig = New-AzDiskConfig `
     -Location $VM.Location `
     -CreateOption Empty `
     -DiskSizeGB $DiskSizeGB `
     -HyperVGeneration $HyperVGen

     Write-Host "Create new vhd disk" -ForegroundColor DarkBlue -BackgroundColor White
 $dataDisk = New-AzDisk `
     -ResourceGroupName $resourceGroupName `
     -DiskName $emptydiskforfootername `
     -Disk $diskConfig

# Get SAS token for the empty disk
Write-Host "Getting SAS token for empty disk" -ForegroundColor DarkBlue -BackgroundColor White
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername -Access 'Read' -DurationInSecond 600000;

# Copy the empty disk to blob storage
Write-Host "Copying to destination blob" -ForegroundColor DarkBlue -BackgroundColor White
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $emptydiskforfootername -DestContext $destinationContext
while(($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $emptydiskforfootername -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 20 }
$state

# Revoke SAS token
Write-Host "Revoke SAS URI" -ForegroundColor DarkBlue -BackgroundColor White
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername

# Delete temp disk
Write-Host "Deleting temp disk" -ForegroundColor DarkBlue -BackgroundColor White
Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername -Force;

# Get the blobs
Write-Host "Getting blobs" -ForegroundColor DarkBlue -BackgroundColor White
$emptyDiskblob = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $emptydiskforfootername
$diskToResize = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $destinationVHDFileName

$footer = New-Object -TypeName byte[] -ArgumentList 512
Write-Host "Get footer of empty disk" -ForegroundColor DarkBlue -BackgroundColor White

$downloaded = $emptyDiskblob.ICloudBlob.DownloadRangeToByteArray($footer, 0, $emptyDiskblob.Length - 512, 512)

$diskToResize.ICloudBlob.Resize($emptyDiskblob.Length)
$footerStream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (,$footer)
Write-Host "Writing footer of empty disk to disk" -ForegroundColor DarkBlue -BackgroundColor White
$diskToResize.ICloudBlob.WritePages($footerStream, $emptyDiskblob.Length - 512)

Write-Host "Removing empty disk blobs" -ForegroundColor DarkBlue -BackgroundColor White
$emptyDiskblob | Remove-AzStorageBlob -Force

# Name of the new Managed Disk
$NewDiskName = "$DiskName" + "-new"

# Get the new disk URI
$vhdUri = $diskToResize.ICloudBlob.Uri.AbsoluteUri

# Specify the disk options
$diskConfig = New-AzDiskConfig -AccountType $SKUType -Location $VM.location -DiskSizeGB $DiskSizeGB -SourceUri $vhdUri -CreateOption Import -StorageAccountId $StorageAccount.Id -HyperVGeneration $HyperVGen

# Create the new Managed Disk
Write-Host "Creating new managed disk" -ForegroundColor DarkBlue -BackgroundColor White
$NewManagedDisk = New-AzDisk -DiskName $NewDiskName -Disk $diskConfig -ResourceGroupName $resourceGroupName

# Get updated VM context
$VM = Get-AzVm | ? Name -eq $VMName

# Get the LUN number and Caching info
foreach ($attachedDisk in $VM.StorageProfile.DataDisks) { 
    if ($attachedDisk.Name -eq $DiskName) {
        $Lun = $attachedDisk.Lun
        $Caching = $attachedDisk.Caching
    }
}
Write-Host "LUN id is" $Lun -ForegroundColor DarkBlue -BackgroundColor White
Write-Host "Caching is" $caching -ForegroundColor DarkBlue -BackgroundColor White
# Remove old disk
Write-Host "Removing old disk" -ForegroundColor DarkBlue -BackgroundColor White
Remove-AzVMDataDisk -VM $VM -Name $DiskName
# Update the VM with the new disk
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

# Set the VM configuration to point to the new disk  
Write-Host "Adding new disk" $NewManagedDisk.Name -ForegroundColor DarkBlue -BackgroundColor White
$VM = Add-AzVMDataDisk -CreateOption Attach -Lun $Lun -Caching $Caching -VM $VM -ManagedDiskId $NewManagedDisk.Id -Name $NewManagedDisk.Name

# Update the VM with the new Managed Disk
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

Write-Host "Starting up" $VMName "..."-ForegroundColor DarkBlue -BackgroundColor White
$VM | Start-AzVM
Write-Host $VMName "has started" -ForegroundColor DarkBlue -BackgroundColor White

# # Check everything is running normally before removing old disks and storage

# # Delete old Managed Disk
# Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $DiskName -Force

# # Delete old blob storage
# $diskToResize | Remove-AzStorageBlob -Force

# # Delete temp storage account
# $StorageAccount | Remove-AzStorageAccount -Force
