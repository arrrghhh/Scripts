# Logoff all accounts (except first.last) if they are in a 'disconnected' state (IE the user forgot to logoff)

try {
    ## Find all sessions NOT matching the specified username
    $sessions = quser | Where-Object {$_ -notmatch '\bfirst\.last\b'}
    ## Initialize an array to hold session IDs
    $sessionIds = @()
    ## Parse the session IDs from the output
    foreach ($session in $sessions) {
        $sessiondisc = ($session -split ' +')[3]
        if ($sessiondisc -eq 'Disc') {
            $sessionId = ($session -split ' +')[2]
            $sessionIds += $sessionId
        }
    }
    Write-Host "Found $(@($sessionIds).Count) user login(s) on computer."
    ## Loop through each session ID and pass each to the logoff command
    $sessionIds | ForEach-Object {
        Write-Host "Logging off session id [$($_)]..."
        logoff $_
    }
} catch {
    if ($_.Exception.Message -match 'No user exists') {
        Write-Host "The user is not logged in."
    } else {
        throw $_.Exception.Message
    }
}