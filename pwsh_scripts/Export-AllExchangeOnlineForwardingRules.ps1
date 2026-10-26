# Report on mail forward rules

#Connect-ExchangeOnline
$Rules = @()

foreach ($i in (Get-Mailbox -ResultSize unlimited)) { 
    $Rules += Get-InboxRule -Mailbox $i.DistinguishedName | where {$_.ForwardTo} | select MailboxOwnerID,Name,@{Name='ForwardTo';Expression={$_.ForwardTo -replace '\[EX:.*?\]',''}}
}

#Get-Mailbox -ResultSize unlimited | select UserPrincipalName,ForwardingSmtpAddress,DeliverToMailboxAndForward | where DeliverToMailboxAndForward -eq $true | Export-csv .\forwarders.csv -NoTypeInformation 

#Get-InboxRule -Mailbox Daniela.Venegas@monolith-corp.com | fl -p *

$Rules | Export-Csv -path c:\temp\All_Mailbox_Forward_Rules.csv -NoTypeInformation