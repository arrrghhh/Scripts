# Create app registration with 99 year expiration
$startDate = Get-Date
$endDate = $startDate.AddYears(99)
$aadAppsecret01 = New-AzureADApplicationPasswordCredential -ObjectId '948dc371-e3f7-4350-a5a1-c27c80c9606d' -StartDate $startDate -EndDate $endDate -CustomKeyIdentifier 'ADP Mobile SSO'