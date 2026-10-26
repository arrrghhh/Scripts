# Install the Microsoft.Graph module if not already installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module -Name Microsoft.Graph -Force -Scope CurrentUser
}

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Device.Read.All", "BitLockerKey.Read.All"

# Get all devices
$devices = Get-MgDevice -All

# Filter for Windows OS devices
$windowsDevices = $devices | Where-Object { $_.operatingSystem -like "Windows*" }

# Group devices by display name to find duplicates
$duplicateDevices = $windowsDevices | Group-Object -Property displayName | Where-Object { $_.Count -gt 1 }

if ($duplicateDevices.Count -eq 0) {
    Write-Output "No duplicate devices found."
} else {
    foreach ($group in $duplicateDevices) {
        Write-Output "Duplicate devices found for DisplayName: $($group.Name)"
        #Write-Output "OnPremisesLastSyncDateTime: '$($group.Group.OnPremisesLastSyncDateTime)'"
        <#foreach ($device in $group.Group) {
            Write-Output "Device ID: $($device.Id)"
            
            # Get Bitlocker recovery key (assuming Bitlocker keys are stored in Microsoft Graph)
            $bitlockerKeys = Get-MgInformationProtectionBitlockerRecoveryKey -Filter "deviceId eq '$($device.Id)'"
            foreach ($key in $bitlockerKeys) {
                Write-Output "Bitlocker Key ID: $($key.Id)"
                Write-Output "Recovery Key: $($key.RecoveryKey)"
            }
        }#>
    }
}

# Disconnect from Microsoft Graph
#Disconnect-MgGraph