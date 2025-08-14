<#
$GroupNames = @('Ammonia',
'Capital Build',
'Capital Markets Security',
'CFO',
'Clean Energy',
'Communication',
'Controls & Automation',
'COO',
'Corporate Accounting',
'Decarbonized Solutions General',
'Development General',
'Government Relations',
'Head Office',
'Human Resources General',
'Information Technology and Security',
'Intellectual Property',
'Manufacturing Corporate',
'Manufacturing Operations General',
'Market Strategy & Sustainability',
'Mechanical Design',
'Outbound Shipping',
'Power Electronics',
'Product Application',
'Project Development',
'Quality',
'Research & Development',
'Safety',
'Sales',
'Strategic Initiatives',
'Supply Chain',
'Systems & Processes',
'Talent Acquisition',
'Technology Fellows',
'Treasury',
'Product Management',
'Hydrogen Development')
#>
$GroupNames = @('HR')
$AADGroups = @()
$usermailsall = @()
$SpecificGroups = @()
$usermail = $null

if (!(Get-Module Microsoft.Graph)) {
    try {
        Write-Host "Importing Microsoft.Graph module..."
        Import-Module Microsoft.Graph -ErrorAction Stop
    }
    catch {
        Write-Host "Import failed, try installing Microsoft.Graph module..."
        Install-Module Microsoft.Graph
    }
}

try {
    $AADGroups = Get-MgGroup -Filter "securityEnabled eq true" -All -ErrorAction Stop
}
catch {
    if ($_.Exception.Message -like '*You must call the Connect-MgGraph cmdlet*') {
        Write-Host "Must connect to Microsoft Graph first..."
        Connect-MgGraph -Scopes "Group.Read.All"
        $AADGroups = Get-MgGroup -Filter "securityEnabled eq true" -All
    }
    else {
        $_ | Write-Error
    }
}

foreach ($AADGroup in $AADGroups) {
    $SpecificGroups += $AADGroup | Where-Object { $_.DisplayName -in $GroupNames }
}

foreach ($Group in $SpecificGroups) {
    Write-Host "Getting members of group '$($Group.DisplayName)'"
    $usermails = Get-MgGroupMember -GroupId $Group.Id -All | Where-Object { $_.AccountEnabled -eq $true } | Select-Object Mail
    foreach ($usermail in $usermails) {
        $hash = [ordered] @{
            Mail = $usermail.Mail
            Group = $Group.DisplayName
        }
        $usermailsall += [pscustomobject]$hash
    }
}

#usermailsall | ft -Property Mail, Group -AutoSize
$usermailsall | Export-Csv "C:\temp\userlist.csv" -NoTypeInformation