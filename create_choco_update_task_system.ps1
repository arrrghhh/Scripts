# Setup scheduled task to automatically update chocolatey packages

# Check if old chocoUpdater user exists, remove it if so
$user = "chocoUpdater"

$chocoUser = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
if ($chocoUser) {
    $chocoUser | Remove-LocalUser
}

# Check choco.exe exists
$localprograms = Get-Command -Name choco.exe -ErrorAction SilentlyContinue 
if ($localprograms){
    Write-Host "Chocolatey installed"
} else {
    Write-Error "Chocolatey not Found!"
    break
}

#Create scheduled task
$taskName = "chocoUpdate"
Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false

$hours = @("1am", "2am", "3am", "4am", "5am", "6am", "7am", "8am", "9am", "10am", "11am", "1pm", "2pm", "3pm", "4pm", "5pm", "6pm", "7pm", "8pm","9pm", "10pm", "11pm")
$rand_hour = (Get-Random -InputObject $hours -Count 1)

$schtaskDescription = "Daily checks for software updates."
$trigger1 = New-ScheduledTaskTrigger -AtStartup
$trigger2 = New-ScheduledTaskTrigger -Daily -At $rand_hour
$User='Nt Authority\System'
$action = New-ScheduledTaskAction -Execute "C:\ProgramData\chocolatey\choco.exe" -Argument 'upgrade all -y'
$settings= New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $taskName -Trigger $trigger1,$trigger2 -Action $action -Settings $settings -Description $schtaskDescription -User $User -RunLevel Highest -Force