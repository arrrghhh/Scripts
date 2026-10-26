# Get all users NOT a member of AzureAD Group
$filepath = 'C:\tempNotInGroup.csv'
$AzureADGroup = 'Intune - Mobile Application Management - Users'

if (-not (Get-Module Microsoft.Graph -ListAvailable)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

try {
    $group = Get-MgGroup -Filter "displayName eq '$AzureADGroup'" -ErrorAction Stop
}
catch {
    if ($_.Exception.Message -like '*You must call the Connect-MgGraph cmdlet before calling any other cmdlets.*') {
        Connect-MgGraph -Scopes "Group.Read.All"
        $group = Get-MgGroup -Filter "displayName eq '$AzureADGroup'"
    }
    else {
        $_ | Write-Error
    }
}

$userht = @{} # create hashtable that will contain users
Get-MgUser -Filter "userType eq 'Member' and accountEnabled eq true" -All | ForEach-Object { $userht.Add($_.Id, $_) } # add all AzureAD users to hashtable with ObjectID as unique key
Get-MgGroupMember -GroupId $group.Id -All | ForEach-Object { $userht.Remove($_.Id) } # if user is member of group, remove them from hashtable
$userht.Values | Select-Object DisplayName, UserPrincipalName, JobTitle | Sort-Object DisplayName | Export-Csv -Path $filepath -NoTypeInformation # return remaining users that are not in specified groups