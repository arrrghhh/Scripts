# Create Folder for logs
$Logs = "C:\Intellicom\Scripts\Logs"
If (!(Test-Path $Logs)) {
    New-Item -Path "$Logs" -ItemType Directory
}

# Set the number of days to consider logs as old
$daysToKeep = 180

function Get-TimeStamp {
    return Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
}

# Date format
$dateFormatFile = Get-Date -Format 'yyyy-MM-dd'

Start-Transcript -Path "$Logs\Restart-NetworkAdapter_$($dateFormatFile).log" -Append

$profiles = Get-NetConnectionProfile

foreach ($profile in $profiles) {
    if ($profile.NetworkCategory -ne "DomainAuthenticated") {
        $interfaceAlias = $profile.InterfaceAlias
        Write-Host "$(Get-TimeStamp) - Restarting adapter: $interfaceAlias ($($profile.NetworkCategory) network)"
        Restart-NetAdapter -Name $interfaceAlias -Confirm:$false
    }
}

# Delete old log files
Get-ChildItem -Path $Logs -Recurse | Where-Object {
	($_.PSIsContainer -eq $false -and $_.LastWriteTime -lt (Get-Date).AddDays(-1 * $daysToKeep))
} | ForEach-Object {
		Remove-Item $_.FullName -Force
		Write-Host "$(Get-TimeStamp) - Delete logfile '$($_.FullName)' based on '$($_.LastWriteTime)' LastWriteTime"
}

Stop-Transcript