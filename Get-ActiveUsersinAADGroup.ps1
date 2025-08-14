# Get only active users in an AzureAD group

$AzureADGroup = 'SS_SiriusAAD'
try {
    $AADGroupDetail = Get-AzureADGroup -All:$true -SearchString $AzureADGroup -ErrorAction Stop | Where-Object DisplayName -eq $AzureADGroup
}
catch {
    if ($_.Exception.Message -like "*You must call the Connect-AzureAD*") {
        Connect-AzureAD
        $AADGroupDetail = Get-AzureADGroup -All:$true -SearchString $AzureADGroup | Where-Object DisplayName -eq $AzureADGroup
    }
    else {
        $_ | Write-Error
    }
}
if (!$AADGroupDetail) {
    Write-Host "AAD Group does not exist... exiting."
    break
}
$GroupUsers = $AADGroupDetail | Get-AzureADGroupMember -All:$true
$EnabledUser = @()
foreach ($User in $GroupUsers) {
    $AADUser = $User | Get-AzureADUser
    if ($AADUser.AccountEnabled) {
        $EnabledUser += $AADUser.UserPrincipalName
    }
    else {
        continue
    }
}
Write-Host "Enabled Users:"
Write-Host $EnabledUsers