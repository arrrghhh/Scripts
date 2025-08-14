$OUpath = 'OU=OUdeep,OU=OUroot,DC=dc,DC=dc1,DC=dc2' # Distinguished Name of OU
$users = (Get-ADUser -Filter * -SearchBase $OUpath).samaccountname
$userlist = @()
foreach ($user in $users) {
    $userlist += Get-ADUser -Identity $user -Properties * | select UserPrincipalName,Mail,Enabled #| where Enabled -eq 'True' | where Mail -ne $null | 
}
$userlist | ft -a
#$userlist | Export-Csv -Path c:\temp\Users.csv