# Generates a list of email addresses from an on-prem AD group
$GroupName = 'OnPrem GroupName'
$users = (Get-ADGroupMember -Identity "$GroupName").samaccountname
$userlist = @()
foreach ($user in $users) {
    Write-Host "Fetching email for user '$user'..."
    $userlist += Get-ADUser -Identity $user -Properties mail | where Enabled -eq 'True' | where Mail -ne $null | select Mail
}
$userlist | ft -a
#$userlist | Export-Csv -Path c:\temp\$GroupName.csv