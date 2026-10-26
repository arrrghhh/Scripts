# Remove old files from the local directory oc1reactorfiles_short

# Specify the path (source and target) of the root directory where you want to move old items from/to
$sourceDirectory = "C:\Share\CFD_FlowSim"
$targetDirectory = "D:\Share\CFD_FlowSim"

# Set the number of days to consider items as old
$daysToKeep = 60

# Date format
$dateFormatFile = Get-Date -Format 'yyyy-MM-dd'
function Get-TimeStamp {
    return Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
}

# Log file for recording deleted items
$logDir = "C:\intellicom\MoveFiles\Logs"
$logFile = "$logDir\MoveFiles_$($dateFormatFile).log"
Start-Transcript -Path "$logFile" -Append
Write-Output "###### New Run ######"
$filesRemoved = 0
$foldersRemoved = 0

Get-ChildItem -Path $sourceDirectory | Where-Object {
	($_.PSIsContainer -eq $true -and $_.LastWriteTime -lt (Get-Date).AddDays(-1 * $daysToKeep))
} | ForEach-Object {
    # Only move folders that start with a number
    if ($_.Name -match '^\d') {
	    try { 
            Move-Item -Path $_.FullName -Destination $targetDirectory -ErrorAction Stop 
        }
        catch [System.IO.PathTooLongException] {
            Write-Output "$(Get-TimeStamp) -  ERROR: 'Path too long' - $($_.TargetObject.FullName)"
            Continue
        }
        catch {
            Write-Output "$(Get-TimeStamp) -  ERROR: '$($_.Exception.Message)' - $($_.TargetObject.FullName)"
            Continue
        }
        $foldersRemoved++
        Write-Output "$(Get-TimeStamp) -  Move folder '$($_.FullName)' based on '$($_.LastWriteTime)' LastWriteTime"
    }
}

# Delete Empty Directories
<# Get-ChildItem -Path $sourceDirectory -Recurse -Directory | Where-Object { (Get-ChildItem $_.FullName).Count -eq 0 } | ForEach-Object {
	Remove-Item $_.FullName -Recurse -Force -WhatIf
    $foldersRemoved++
	Write-Output "$(Get-TimeStamp) -  Delete empty folder '$($_.FullName)'"
} #>
Write-Output "$(Get-TimeStamp) -  Run complete, '$($foldersRemoved)' folder(s) moved."

# Delete old log files
Get-ChildItem -Path $logDir -Recurse | Where-Object {
	($_.PSIsContainer -eq $false -and $_.LastWriteTime -lt (Get-Date).AddDays(-1 * $daysToKeep))
} | ForEach-Object {
		Remove-Item $_.FullName -Force
		Write-Output "$(Get-TimeStamp) -  Delete logfile '$($_.FullName)' based on '$($_.LastWriteTime)' LastWriteTime"
}
Stop-Transcript