# Push files to SharePoint site

# Specify the path of the logs directory where you want to delete old items
$logDir = "C:\DCS Logs\Script\Logs"

# Set the number of days to consider items as old
$daysToKeep = 60

$dateFormatFile = Get-Date -Format 'yyyy-MM-dd'
Start-Transcript -Path "$logDir\Put-DCSLogs_$($dateFormatFile).log" -Append

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
$FilePathAlarmSummaryReports = "C:\DCS Logs\Alarm Summary Reports"
$FilePathEventLogs = "C:\DCS Logs\Event Logs"
$SiteURL = "https://contoso.sharepoint.com/sites/SiteName"
$FolderServerRelativeURLEventLogs = "/Shared Documents/DCS Reports/Event Logs"
$FolderServerRelativeURLAlarmSummaryReports = "/Shared Documents/DCS Reports/Alarm Summary Reports"

# Vars for the connection to SharePoint
$tenantID = "AzureTenantGUID"
$applicationID = "AppID"
$thumbprint = "CertThumb"
Connect-PnPOnline -Url $SiteURL -ClientId $applicationID -Tenant $tenantID -Thumbprint $thumbprint

# Get All files from the local disk
$FilesAlarmSummaryReports = Get-ChildItem -Path $FilePathAlarmSummaryReports -File
$FilesEventLogs = Get-ChildItem -Path $FilePathEventLogs -File

# Ensure target exists
try {
    $ResolveRemoteFolderEventLogs = Resolve-PnPFolder -SiteRelativePath $FolderServerRelativeURLEventLogs -ErrorAction Stop
    $ResolveRemoteFolderAlarmSummaryReports = Resolve-PnPFolder -SiteRelativePath $FolderServerRelativeURLAlarmSummaryReports -ErrorAction Stop
}
catch {
    $_ | Write-Error
    Stop-Transcript
    exit
}

# Iterate through each file for AlarmSummaryReports and upload
ForEach($File in $FilesAlarmSummaryReports) {
    $uploadedfile = @()
    $uploadedfile = Get-PnPFile -Url "$($ResolveRemoteFolderAlarmSummaryReports.ServerRelativeUrl)/$($file.Name)" -AsListItem -ErrorAction SilentlyContinue
    if ($uploadedfile -and $uploadedfile.FieldValues['SMTotalFileStreamSize'] -gt 100) {
        Write-Host "$(Get-TimeStamp) - File has already been uploaded.  Deleting '$($File.FullName)'"
        $file | Remove-Item
    }
    else {
        $null = Add-PnPFile -Path "$($File.Directory)\$($File.Name)" -Folder $ResolveRemoteFolderAlarmSummaryReports.ServerRelativeUrl -Values @{"Title" = $($File.Name)}
        Write-Host "$(Get-TimeStamp) - Uploaded File: $($File.FullName)"
        $uploadedfile = Get-PnPFile -Url "$($ResolveRemoteFolderAlarmSummaryReports.ServerRelativeUrl)/$($file.Name)" -AsListItem -ErrorAction SilentlyContinue
        if ($uploadedfile -and $uploadedfile.FieldValues['SMTotalFileStreamSize'] -gt 100) {
            Write-Host "$(Get-TimeStamp) - File uploaded, deleting '$($File.FullName)'"
            $file | Remove-Item
        }
        else {
            Write-Error "$(Get-TimeStamp) - Issue uploading file '$($File.FullName)', will save file for another attempt."
        }
    }
}

# Iterate through each file for EventLogs and upload
ForEach($File in $FilesEventLogs) {
    $uploadedfile = @()
    $uploadedfile = Get-PnPFile -Url "$($ResolveRemoteFolderEventLogs.ServerRelativeUrl)/$($file.Name)" -AsListItem -ErrorAction SilentlyContinue
    if ($uploadedfile -and $uploadedfile.FieldValues['SMTotalFileStreamSize'] -gt 100) {
        Write-Host "$(Get-TimeStamp) - File has already been uploaded.  Deleting '$($File.FullName)'"
        $file | Remove-Item
    }
    else {
        $null = Add-PnPFile -Path "$($File.Directory)\$($File.Name)" -Folder $ResolveRemoteFolderEventLogs.ServerRelativeUrl -Values @{"Title" = $($File.Name)}
        Write-Host "$(Get-TimeStamp) - Uploaded File: '$($File.FullName)'"
        $uploadedfile = Get-PnPFile -Url "$($ResolveRemoteFolderEventLogs.ServerRelativeUrl)/$($file.Name)" -AsListItem -ErrorAction SilentlyContinue
        if ($uploadedfile -and $uploadedfile.FieldValues['SMTotalFileStreamSize'] -gt 100) {
            Write-Host "$(Get-TimeStamp) - File uploaded, deleting '$($File.FullName)'"
            $file | Remove-Item
        }
        else {
            Write-Error "$(Get-TimeStamp) - Issue uploading file '$($File.FullName)', will save file for another attempt."
        }
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