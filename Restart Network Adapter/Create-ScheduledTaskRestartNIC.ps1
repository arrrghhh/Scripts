$Version = "1.1"
$TaskName = "Restart Network Adapter $Version"

if (!(Test-Path C:\Intellicom\Scripts\)) {
    New-Item -Path C:\Intellicom\Scripts\ -ItemType Directory
}
Copy-Item "\\monooc1fs01\Scripts\Restart-NetworkAdapter\Restart-NetworkAdapter.ps1" C:\Intellicom\Scripts

$taskExists = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {$_.TaskName -like "Restart Network Adapter*"}
if (!$taskExists) {
    Write-Host "Register new scheduled task Restart Network Adapter v$Version..."
    Register-ScheduledTask -xml (Get-Content \\monooc1fs01\Scripts\Restart-NetworkAdapter\RestartNetworkAdapterTask.xml | Out-String) -TaskName $TaskName -Force
}
else {
    $previousTaskExists = ($taskExists.TaskName).Split(' ')[3]
    if ($previousTaskExists -eq $Version) {
        Write-Host "No action taken, already running latest."
    }
    else {
        Write-Host "Unregister old scheduled task Restart Network Adapter v$previousTaskExists..."
        $taskExists | Unregister-ScheduledTask -Confirm:$false
        Write-Host "Register new scheduled task Restart Network Adapter v$Version..."
        Register-ScheduledTask -xml (Get-Content \\monooc1fs01\Scripts\Restart-NetworkAdapter\RestartNetworkAdapterTask.xml | Out-String) -TaskName $TaskName -Force
    }
}