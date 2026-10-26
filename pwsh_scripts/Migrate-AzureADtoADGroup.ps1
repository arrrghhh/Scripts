##
# Copy all users from an AzureAD group to an on-prem AD group - script assumes that the on-prem and AzureAD groups both exist!
##
if(-not (Get-Module Microsoft.Graph -ListAvailable)){
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}
$ADGroup = 'OnPrem Group'
$AzureADGroup = 'Cloud Group'
try {
    $AADGroupDetail = Get-MgGroup -Filter "displayName eq '$AzureADGroup'" -ErrorAction Stop
}
catch {
    if ($_.Exception.Message -like "*You must call the Connect-MgGraph*") {
        Connect-MgGraph -Scopes "Group.ReadWrite.All"
        $AADGroupDetail = Get-MgGroup -Filter "displayName eq '$AzureADGroup'"
    }
    else {
        $_ | Write-Error
    }
}
try {
    $GroupUsers = Get-ADGroupMember -Identity $ADGroup -ErrorAction Stop
}
catch {
    $_ | Write-Error
}
$FailedUsers = @()
$AADGroupUsers = Get-MgGroupMember -GroupId $AADGroupDetail.Id -All
foreach ($User in $AADGroupUsers) {
    Write-Host "Adding $($User.AdditionalProperties.displayName)"
    $upn = $User.AdditionalProperties.userPrincipalName
    $ADUser = Get-ADUser -Filter { UserPrincipalName -eq $upn }
    if ($ADUser) {
        try {
            Add-ADGroupMember -Identity $ADGroup -Members $ADUser -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Message -like "*One or more added object references already exist for the following modified properties*") {
                Write-Host 'User already added to group.'
            }
            else {
                $_ | Write-Error
                $FailedUsers += $($User.AdditionalProperties.displayName)
            }
        }
    }
    else {
        Write-Error "User '$($User.AdditionalProperties.displayName)' not found in AD"
        $FailedUsers += $($User.AdditionalProperties.displayName)
    }
}