# Define the target file or program for which you want to create a shortcut 
$targetPath = "C:\Windows\System32\shutdown.exe"
$Args = "/s /f /t 0"
$workingDir = "C:\Windows\System32"

# Define the name of the shortcut (without the .lnk extension)
$shortcutName = "Full shutdown"

# Define the path to the public desktop directory
$publicDesktopPath = [System.Environment]::GetFolderPath("CommonDesktopDirectory")

# Create a WScript Shell object to create the shortcut
$shell = New-Object -ComObject WScript.Shell

# Create a shortcut object
$shortcut = $shell.CreateShortcut("$publicDesktopPath\$shortcutName.lnk")

# Set the target path for the shortcut
$shortcut.TargetPath = $targetPath

# Set the 'working directory' (aka 'start in')
$shortcut.WorkingDirectory = $workingDir

# Set the icon to the shutdown icon
$shortcut.IconLocation = "shell32.dll,27"

# Set the arguments
$shortcut.Arguments = $Args

# Save the shortcut
$shortcut.Save()

# Clean up the objects
$shell = $null
$shortcut = $null