# Remove old files from a local directory

# Specify the path of the root directory where you want to delete old items
$targetDirectory = "D:\path"
$ISEbackup = "D:\path\ISE_backup"

# Set the number of days to consider items as old
$daysToKeep = 60

# Date format
$dateFormatFile = Get-Date -Format 'yyyy-MM-dd'

function Get-TimeStamp {
    return Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
}

# All Log folder to remove all old logs
$alllogDir = "D:\Scripts\Logs"

# Create Folder for logs
$logDir = "D:\Scripts\Logs\Remove-oc1reactorfiles"
If (!(Test-Path $logDir)) {
    New-Item -Path "$logDir" -ItemType Directory
}

# Log file for recording deleted items
Start-Transcript -Path "$logDir\Remove-oc1reactorfiles_$($dateFormatFile).log" -Append
Write-Host "###### New Run ######"
$filesRemoved = 0
$foldersRemoved = 0

Get-ChildItem -Path $targetDirectory -Recurse | Where-Object {
	($_.PSIsContainer -eq $true -and $_.CreationTime -lt (Get-Date).AddDays(-1 * $daysToKeep)) -or
	($_.PSIsContainer -eq $false -and $_.LastWriteTime -lt (Get-Date).AddDays(-1 * $daysToKeep))
} | ForEach-Object {
	if ($_.PSIsContainer) {
        if ($_.FullName -like '*Scans*') {
            return
        }
        else {
		    Remove-Item $_.FullName -Recurse -Force
            $foldersRemoved++
            Write-Host "$(Get-TimeStamp) - Delete folder '$($_.FullName)' based on '$($_.CreationTime)' CreationTime"
        }
	} else {
        if ($_.FullName -like '*ReadMe.txt*') {
            return
        }
        else {
		    Remove-Item $_.FullName -Force
            $filesRemoved++
		    Write-Host "$(Get-TimeStamp) - Delete file '$($_.FullName)' based on '$($_.LastWriteTime)' LastWriteTime"
        }
	}
}

# Delete Empty Directories
Get-ChildItem -Path $targetDirectory -Recurse -Directory | Where-Object { (Get-ChildItem $_.FullName).Count -eq 0 } | ForEach-Object {
	Remove-Item $_.FullName -Recurse -Force
    $foldersRemoved++
	Write-Host "$(Get-TimeStamp) - Delete empty folder '$($_.FullName)'"
}
Write-Host "$(Get-TimeStamp) - Run complete, '$($foldersRemoved)' folder(s) removed, '$($filesRemoved)' file(s) removed."

# Delete old log files
Get-ChildItem -Path $alllogDir -Recurse | Where-Object {
	($_.PSIsContainer -eq $false -and $_.LastWriteTime -lt (Get-Date).AddDays(-1 * $daysToKeep))
} | ForEach-Object {
		Remove-Item $_.FullName -Force
		Write-Host "$(Get-TimeStamp) - Delete logfile '$($_.FullName)' based on '$($_.LastWriteTime)' LastWriteTime"
}

# Delete old Cisco ISE backups
Get-ChildItem -Path $ISEbackup -Recurse | Where-Object {
	($_.PSIsContainer -eq $false -and $_.LastWriteTime -lt (Get-Date).AddDays(-1 * $daysToKeep))
} | ForEach-Object {
		Remove-Item $_.FullName -Force
		Write-Host "$(Get-TimeStamp) - Delete Cisco ISE backup file '$($_.FullName)' based on '$($_.LastWriteTime)' LastWriteTime"
}