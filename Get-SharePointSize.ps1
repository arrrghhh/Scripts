# SharePoint file size report, found it's actually better to use https://contoso.sharepoint.com/sites/<sitename>/_layouts/storman.aspx
# Stolen partially from https://www.sharepointdiary.com/2020/10/powershell-get-file-size.html, partially from https://www.sharepointdiary.com/2018/08/sharepoint-online-powershell-to-get-all-files-in-document-library.html
#Set Variables
$SiteSpecific = "MTC_Process_Engineering"
$LibraryName = "Documents"
$ReportOutput = "C:\Temp\getAllFiles_$SiteSpecific.csv"

$SiteURLBase = "https://contoso.sharepoint.com/sites/"

#Please note that on my case, the modules: 
#Microsoft.Online.SharePoint.Powershell and
#Microsoft.Online.SharePoint.Powershell didn't get loaded
#automatically, so have to manually import them

#This doesn't seems to work with Powershell 7.4 because it seems
#that this module is not yet compatible. You will get some warnings
#Import-Module Microsoft.Online.SharePoint.Powershell

#This will work with Powershell 7.4, I guess it is using version
#5.1 for the import
Import-Module Microsoft.Online.SharePoint.Powershell -UseWindowsPowerShell

Import-Module PnP.PowerShell

#Connect to SharePoint Online site. Please note that since I'm
#using two factor authentication, Get-Credential won't work, so,
#I used the "Connect-PnPOnline" with the "-Interactive" option,
#then a Window will popup
$SiteURL = $SiteURLBase + $SiteSpecific
Connect-PnPOnline -Url $SiteURL -Interactive -ClientId 6fb25488-b491-48cb-9274-2f640f4efa37

$FileData = @()
#Iterate through all files
$ItemCounter = 0 
Write-Host "Getting all items in '$LibraryName' for site '$SiteSpecific'..."
$ListItems = Get-PnPListItem -List $LibraryName -PageSize 500 -Fields Author, Editor, Created, File_x0020_Type, File_x0020_Size, Versions

Foreach ($Item in $ListItems)
{
    $FileSizeBytes = $Item.FieldValues.File_x0020_Size
    $FileSizeKB = [Math]::Round($FileSizeBytes / 1024)

    if ($FileSizeKB -ge 1024) {
        $FileSizeMB = $FileSizeBytes / (1024 * 1024)
        if ($FileSizeMB -ge 1024) {
            $FileSizeGB = [Math]::Round($FileSizeMB / 1024, 2)
            $FileSize = "$FileSizeGB GB"
        } else {
            $FileSizeMB = [Math]::Round($FileSizeMB, 2)
            $FileSize = "$FileSizeMB MB"
        }
    } else {
        $FileSize = "$FileSizeKB KB"
    }
    $FileData += New-Object PSObject -Property ([ordered]@{
    Name              = $Item["FileLeafRef"]
    Type              = $Item.FileSystemObjectType
    FileType          = $Item["File_x0020_Type"]
    FileSizeKB        = "$FileSizeKB"
    FileSizeReadable  = $FileSize
    RelativeURL       = $Item["FileRef"]
    CreatedByEmail    = $Item["Author"].Email
    CreatedOn         = $Item["Created"]
    Modified          = $Item["Modified"]
    ModifiedByEmail   = $Item["Editor"].Email
  })
  $ItemCounter++
  Write-Progress -PercentComplete ($ItemCounter / ($ListItems.Count) * 100) -Activity "Exporting data from Documents $ItemCounter of $($ListItems.Count)" -Status "Exporting Data from Document '$($Item['FileLeafRef'])"
}

$FileData | Export-Csv -Path $ReportOutput -NoTypeInformation -Delimiter ","