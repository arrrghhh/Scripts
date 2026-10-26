# Push files to SharePoint site

# Specify the path of the logs directory where you want to logs sent / old items deleted
$logDir = "F:\scripts\SharePoint\Logs"

# Set the number of days to consider items as old
$daysToKeep = 60

$dateFormatFile = Get-Date -Format 'yyyy-MM-dd'
Start-Transcript -Path "$logDir\Put-XRFCSV_$($dateFormatFile).log" -Append

function Get-TimeStamp {
    return Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
}

if (!(Get-Module PnP.Powershell)) {
    try {
        Import-Module PnP.PowerShell -ErrorAction Stop
    }
    catch {
        $_ | Write-Error
        Install-Module PnP.Powershell
    }
}

# Vars for the local paths + SharePoint
$FilePathXRF = "F:\data\airtable\xrfAllFiles"
$SiteURL = "https://contoso.sharepoint.com/sites/SiteName"

# Vars for the connection to SharePoint
$tenantID = "AzureTenantGUID"
$applicationID = "AppRegGUID"
$thumbprint = "CertThumbprint"
Connect-PnPOnline -Url $SiteURL -ClientId $applicationID -Tenant $tenantID -Thumbprint $thumbprint

# Get All files from the local disk
$FilesXRF = Get-ChildItem -Path $FilePathXRF -File

# Location in SharePoint
$FolderServerRelativeURL = "/Shared Documents/Databases/XRF"

# Ensure target exists
try {
    $ResolveRemoteFolder = Resolve-PnPFolder -SiteRelativePath $FolderServerRelativeURL -ErrorAction Stop
}
catch {
    Write-Error "$(Get-TimeStamp) - $($_.Exception.Message)"
    Stop-Transcript
    exit
}

# Iterate through each file locally and upload
ForEach($File in $FilesXRF) {
    #$uploadedfile = @()
    $uploadedfilecheck = @()
    #$uploadedfile = Get-PnPFile -Url "$($ResolveRemoteFolder.ServerRelativeUrl)/$($File.Name)" -AsListItem -ErrorAction SilentlyContinue
    $null = Add-PnPFile -Path "$($File.Directory)\$($File.Name)" -Folder $ResolveRemoteFolder.ServerRelativeUrl -Values @{"Title" = $($File.Name)}
    Write-Host "$(Get-TimeStamp) - Uploaded File: $($File.FullName)"
    $uploadedfilecheck = Get-PnPFile -Url "$($ResolveRemoteFolder.ServerRelativeUrl)/$($file.Name)" -AsListItem -ErrorAction SilentlyContinue
    if ($uploadedfilecheck -and $uploadedfilecheck.FieldValues['SMTotalFileStreamSize'] -gt 100) {
        Write-Host "$(Get-TimeStamp) - confirmed file uploaded successfully '$($File.FullName)'"
    }
    else {
        Write-Error "$(Get-TimeStamp) - Issue uploading file '$($File.FullName)' will retry on next cycle."
    }
}

# Delete old log files
Get-ChildItem -Path $logDir -Recurse | Where-Object {
	($_.PSIsContainer -eq $false -and $_.LastWriteTime -lt (Get-Date).AddDays(-1 * $daysToKeep))
} | ForEach-Object {
		Remove-Item $_.FullName -Force
		Write-Host "$(Get-TimeStamp) - Delete logfile '$($_.FullName)' based on '$($_.LastWriteTime)' LastWriteTime"
}

Stop-Transcript