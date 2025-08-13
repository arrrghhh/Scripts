# Define variables
$siteUrl = "https://contoso.sharepoint.com/sites/testsite/" # Base URL to Sharepoint site
$SharePointFolderPath = "Shared Documents\SP Path" # NO trailing slash here... remaining path to location in Sharepoint
$localPath = 'C:\temp\path' # Path where you want the files downloaded to
# Will download recusrively, traversing all folders within the particular SharePoint path provided in $SharePointFolderPath
$Recurse = $false

# Only define these if you want to download a single file...
$OneFile = $false
#$SharePointFileName = "10th Anniversary Slide Show.mp4"

# Ensure local path exists, if not, create it.
if (!(Test-Path -LiteralPath $localPath)) {
	New-Item -ItemType Directory -Path $localPath
}

# Connect to SharePoint Online
Connect-PnPOnline -Url $siteUrl -Interactive -ClientId 'GUID for AppReg' # PnP requires an app registration in your tenant

function Download-SPFiles {
    param (
        [string]$SharePointFolder,
        [string]$LocalFolder
    )

    # Ensure local folder exists
    if (!(Test-Path -LiteralPath $LocalFolder)) {
        New-Item -ItemType Directory -Path $LocalFolder -Force
    }
	
	if ($OneFile) {
		$files = Get-PnPFolderItem -FolderSiteRelativeUrl $SharePointFolder -ItemType File
		$file = $files | Where-Object Name -eq $SharePointFileName
		$localFilePath = Join-Path -Path $LocalFolder -ChildPath $file.Name
        if (Test-Path -LiteralPath $localFilePath) {
            $localFileSize = (Get-Item -LiteralPath $localFilePath).Length
            if ($localFileSize -eq $file.Length) {
                Write-Host "Skipping $($file.Name) (already exists)"
				break
            }
        }
		Write-Host "Downloading '$($file.Name)'..."
        Get-PnPFile -Url $file.ServerRelativeUrl -Path $LocalFolder -FileName $file.Name -AsFile -Force
	}

    # Get files in current folder
    $files = Get-PnPFolderItem -FolderSiteRelativeUrl $SharePointFolder -ItemType File
    $totalFiles = $files.Count
    $currentFile = 0

    foreach ($file in $files) {
        $currentFile++
        $percentComplete = ($currentFile / $totalFiles) * 100
        Write-Progress -Activity "Downloading files $([Math]::Round($percentComplete, 2))%" -Status "Downloading $($file.Name)" -PercentComplete $percentComplete
        $localFilePath = Join-Path -Path $LocalFolder -ChildPath $file.Name
        if (Test-Path -LiteralPath $localFilePath) {
            $localFileSize = (Get-Item -LiteralPath $localFilePath).Length
            if ($localFileSize -eq $file.Length) {
                Write-Host "Skipping $($file.Name) (already exists)"
                continue
            }
        }
        Get-PnPFile -Url $file.ServerRelativeUrl -Path $LocalFolder -FileName $file.Name -AsFile -Force
    }
	# Recurse into subfolders
	if ($Recurse) {
		$subFolders = Get-PnPFolderInFolder -FolderSiteRelativeUrl $SharePointFolder -ExcludeSystemFolders
		foreach ($subFolder in $subFolders) {
			$subFolderPath = $subFolder.ServerRelativeUrl

			# Normalize and decode both paths
			$decodedBasePath = [System.Web.HttpUtility]::HtmlDecode($SharePointFolderPath).Replace('\', '/')
			$decodedSubFolderPath = [System.Web.HttpUtility]::HtmlDecode($subFolderPath)

			# Get relative path
			$relativeSubPath = $decodedSubFolderPath.Substring($decodedSubFolderPath.IndexOf($decodedBasePath) + $decodedBasePath.Length).TrimStart('/')

			# Build local and SharePoint paths
			$localSubFolder = Join-Path -Path $localPath -ChildPath $relativeSubPath
			$SharePointSubFolderPath = Join-Path -Path $SharePointFolderPath -ChildPath $relativeSubPath

			# Recurse
			Download-SPFiles -SharePointFolder $SharePointSubFolderPath -LocalFolder $localSubFolder
		}
	}

}

# Start download
Download-SPFiles -SharePointFolder $SharePointFolderPath -LocalFolder $localPath

# Complete progress bar
Write-Progress -Activity "Downloading files" -Status "Complete" -PercentComplete 100