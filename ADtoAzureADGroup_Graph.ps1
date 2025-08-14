$ADGroup = 'Accounting Dashboard Users'
$AzureADGroup = 'Accounting Dashboard Users AAD'

try {
    $AADGroupDetail = Get-MgGroup -Filter "displayName eq '$AzureADGroup'" -ErrorAction Stop
}
catch {
    if ($_.Exception.Message -like "*You must call the Connect-MgGraph*") {
        Connect-MgGraph -Scopes "Group.ReadWrite.All"
        $AADGroupDetail = Get-MgGroup -Filter "displayName eq '$AzureADGroup'"
    }
    elseif ($_.Exception.Message -like "*is not recognized as a name of a cmdlet*") {
        Install-Module Microsoft.Graph -Scope CurrentUser
        Import-Module Microsoft.Graph
        try {
            $AADGroupDetail = Get-MgGroup -Filter "displayName eq '$AzureADGroup'" -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Message -like "*You must call the Connect-MgGraph*") {
                Connect-MgGraph -Scopes "Group.ReadWrite.All"
                $AADGroupDetail = Get-MgGroup -Filter "displayName eq '$AzureADGroup'"
            }
            else {
                $_ 
                Write-Error
            }
        }
    }
    else {
        $_ 
        Write-Error
    }
}

if (!$AADGroupDetail) {
    Write-Error "AAD Group Detail Missing"
    $answer = Read-Host "Create group '$($AzureADGroup)' Y/N?"
    if ($answer -eq 'Y' -or $answer -eq 'y') { 
        New-MgGroup -DisplayName $AzureADGroup -MailEnabled $false -SecurityEnabled $true -MailNickname "NotSet"
        $AADGroupDetail = Get-MgGroup -Filter "displayName eq '$AzureADGroup'" -ErrorAction Stop
        if (!$AADGroupDetail) {
            Start-Sleep -Seconds 30
            $AADGroupDetail = Get-MgGroup -Filter "displayName eq '$AzureADGroup'" -ErrorAction Stop
        }
    }
    else {
        Write-Host "AAD Group does not exist, user indicated they do not want it created... exiting."
        break
    }
}

$GroupUsers = Get-ADGroupMember -Identity $ADGroup
$FailedUsers = @()
foreach ($User in $GroupUsers) {
    Write-Host "Adding $($User.Name)"
    $AADUser = Get-MgUser -Filter "userPrincipalName eq '$($User.SamAccountName)@monolith-corp.com'"
    if ($AADUser) {
        try {
            Add-MgGroupMember -GroupId $AADGroupDetail.Id -DirectoryObjectId $AADUser.Id -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Message -like "*One or more added object references already exist for the following modified properties*") {
                Write-Host 'User already added to group.'
            }
            else {
                $_ 
                Write-Error
                $FailedUsers += $User.Name
            }
        }
    }
    else {
        Write-Error "User '$($User.Name)' not found in AAD"
        $FailedUsers += $User.Name
    }
}
Write-Host "Failed Users:"
Write-Host $FailedUsers