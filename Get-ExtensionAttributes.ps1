# Get all extension attribute values for every enabled user
$attributes = 1..15 | %{ "extensionAttribute$_" }
$orBlock = $attributes -join ' -like "*" -or '
$filter = 'Enabled -eq "true" -and ({0} -like "*")' -f $orBlock
Get-ADUser -fil $filter -prop $attributes | Select (@('Name') + $attributes) | Export-Csv C:\temp\attributes.csv