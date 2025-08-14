# Generate CSV report of all OneDrive URLs
$TenantUrl = "https://contoso-admin.sharepoint.com"
$LogFile = "c:\temp\OneDriveSites.log"
Connect-SPOService -Url $TenantUrl
Get-SPOSite -IncludePersonalSite $true -Limit all -Filter "Url -like '-my.sharepoint.com/personal/'" | Select -ExpandProperty Url | Out-File $LogFile -Force
Write-Host "Done! File saved as $($LogFile)."
