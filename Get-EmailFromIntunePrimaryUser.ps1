# Get email address of primary user of a device
# Useful for finding email addresses of a group based on who owns the device (device-based groups)
#Install-Module Microsoft.Graph

# Define the group name
$groupName = 'Intune - Windows - Win10 Dynamic - Devices'

try {
    Write-Output "Finding group '$($groupName)'..."
    $group = Get-MgGroup -Filter "DisplayName eq '$groupName'" -ErrorAction Stop
}
catch {
    if ($_.Exception.Message -like "*Authentication needed*") {
        Write-Output "Need to connect to graph first..."
        Connect-MgGraph -Scopes "User.Read.All", "Device.Read.All" -NoWelcome
        Write-Output "Finding group '$($groupName)'..."
        $group = Get-MgGroup -Filter "DisplayName eq '$groupName'"
    }
    else {
        $_ | Write-Error
    }
}

if (!$group) {
    Write-Error "Could not find group.  See above errors."
    break
}

# Fetch the list of devices in the group
Write-Output "Finding group members..."
$devices = Get-MgGroupMember -GroupId $group.Id -All -ConsistencyLevel eventual | Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.device' }

# Initialize an array to store the results
$results = @()
$resultsDisabled = @()
$resultsNoPrimaryUser = @()

# Loop through each device and fetch the primary user
Write-Output "Finding devices / primary users..."
foreach ($device in $devices) {
    Write-Output "Finding primary user..."
    $primaryUser = Get-MgDeviceRegisteredOwner -DeviceId $device.Id | Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user' }
    
    if ($primaryUser) {
        Write-Output "Primary user '$($primaryUser.AdditionalProperties.displayName)' found!"
        # Fetch user details to check if the account is enabled
        $userDetails = Get-MgUser -UserId $primaryUser.Id -Property "accountEnabled,displayName,mail"
        
        if ($userDetails.AccountEnabled) {
            $results += [PSCustomObject]@{
                DeviceName = $device.AdditionalProperties.displayName
                PrimaryUser = $primaryUser.AdditionalProperties.displayName
                PrimaryUserEmail = $primaryUser.AdditionalProperties.mail
            }
        }
        if (!($userDetails.AccountEnabled)) {
            $resultsDisabled += [PSCustomObject]@{
                DeviceName = $device.AdditionalProperties.displayName
                PrimaryUser = $primaryUser.AdditionalProperties.displayName
                PrimaryUserEmail = $primaryUser.AdditionalProperties.mail
            }
        }
    }
    else {
        Write-Output "No primary user for '$($device.AdditionalProperties.displayName)'"
        # No primary user listed
        $resultsNoPrimaryUser += [PSCustomObject]@{
            DeviceName = $device.AdditionalProperties.displayName
            Model = $device.AdditionalProperties.model
        }
    }
}

# Output the results
Write-Output "Enabled user list:"
$results | Format-Table -AutoSize
Write-Output "Disabled user list:"
$resultsDisabled | Format-Table -AutoSize
Write-Output "No primary user list:"
$resultsNoPrimaryUser | Format-Table -AutoSize