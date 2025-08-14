# List of computer names provided by the user

$computers = @(
    "computer1", "computer2", "computer3", "computer4",
    "computer5", "computer6"
)


#$computers = "computer1"

$results = @()

foreach ($computer in $computers) {
    try {
        Write-Host "Checking '$computer'..."
        $status = Invoke-Command -ComputerName $computer -ScriptBlock {
            Get-MpComputerStatus | Select-Object -Property PSComputerName, AMRunningMode
        }
        $results += $status
    } catch {
        Write-Host "Could not connect to $computer"
    }
}

$results | Export-Csv -Path "C:\DefenderAntivirusModeReport.csv" -NoTypeInformation
