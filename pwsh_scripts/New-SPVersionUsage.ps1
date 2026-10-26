# Generate version usage report - https://learn.microsoft.com/en-us/sharepoint/tutorial-generate-version-usage-report
$SiteSpecific = "collab_marketing"
$ReportOutput = "Shared Documents/VersionReport.csv"
# Shouldn't need to modify this...
$SiteURLBase = "https://contoso.sharepoint.com/sites/"
$SiteURLFull = $SiteURLBase + $SiteSpecific

#Connect-SPOService -url https://contoso-admin.sharepoint.com

New-SPOSiteFileVersionExpirationReportJob -Identity $SiteURLFull -ReportUrl "$SiteURLFull/$ReportOutput"

$SiteSpecific = "EngineeringRD2"
$ReportOutput = "Shared Documents/VersionReport.csv"
# Shouldn't need to modify this...
$SiteURLBase = "https://contoso.sharepoint.com/sites/"
$SiteURLFull = $SiteURLBase + $SiteSpecific