# Clear specific extensionAttribute in AD for all enabled users
$Users = Get-ADUser -fil 'Enabled -eq "true"' -Properties extensionAttribute5
foreach ($user in $users) {
    Set-ADUser -Identity $User -Clear "extensionattribute5"
}