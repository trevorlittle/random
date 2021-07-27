# Random
shrinkManagedDisk.ps1 - Helps shrink data disks for Azure managed disks.

This script will help with the process of shrinking a managed disk in Azure.
It's a modification of the OS disk shink script located here: https://jrudlin.github.io/2019-08-27-shrink-azure-vm-osdisk/

The steps are in the link above but the basic steps are:
1. Shrink the disk in Windows using the Disk Management Tool (diskmgmt.msc) to something smaller than you're shrinking to
2. Fill out the variables
3. Run the script
4. After VM is back online use the Disk Management Tool to expand the disk to reclaim the new size
5. Delete storage account sashrinkddisk* and old managed disk after everything checks out
