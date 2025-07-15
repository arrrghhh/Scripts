# A PowerShell script using the Az PowerShell module to remove a specific extension WindowsPatchExtension from all Azure Arc enabled machines in a specific resource group.
# The script will remove the extension from all machines in the resource group, regardless of the extension status.

# Parameters
[CmdletBinding()]
param (
    [Parameter()]
    [string] $ResourceGroupName = "RG-name",
    [Parameter()]
    [string] $ExtensionName = "AzureMonitorWindowsAgent"
)

# Connect to Azure
#Connect-AzAccount

# Get all Azure Arc enabled servers in the resource group
$arcMachines = Get-AzResource -ResourceGroupName $ResourceGroupName | Where-Object { $_.Type -eq "Microsoft.HybridCompute/machines" }

# Remove the extension from all machines
foreach ($arcMachine in $arcMachines) {
    $machineName = $arcMachine.Name
    Write-Output "Removing extension $ExtensionName from machine $machineName"
    Remove-AzResource -ResourceId "$($arcMachine.ResourceId)/extensions/$ExtensionName" -Force -WhatIf:$false
}