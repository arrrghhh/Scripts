$TaskName = "Logoff IntellicDA Disconnected Users"

if (!(Test-Path C:\Intellicom\Scripts\)) {
    New-Item -Path C:\Intellicom\Scripts\ -ItemType Directory
}
Copy-Item "\\monooc1fs01\Scripts\Logoff-DisconnectedUser\Logoff-DisconnectedUser.ps1" C:\Intellicom\Scripts

# Register a new Scheduled Task using the XML
Register-ScheduledTask -xml (Get-Content \\monooc1fs01\Scripts\Logoff-DisconnectedUser\LogoffDiscUsersTask.xml | Out-String) -TaskName $TaskName -Force