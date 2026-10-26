# Intune AutoPatch Device Enrollment Status - currently just gets the status, does not reset it

# Device name(s) to search for
$devices = @("WIN10TO11","WIN10TO11-02","INTUNETEST01","INTUNETEST02")

# Location for exported CSV
$CSVPath = "C:\temp"

<#
# Auth with a clientId/Token for non-interactive
$clientId = "YOUR_CLIENT_ID"
$tenantId = "common"  # or your specific tenant ID
$scope = "https://graph.microsoft.com/.default"

$tokenResponse = Get-MsalToken -ClientId $clientId -TenantId $tenantId -Interactive
$accessToken = $tokenResponse.AccessToken


# Define the access token (replace with your actual token)
$accessToken = "YOUR_ACCESS_TOKEN"
#>

$clientId = "00000000-0000-0000-0000-000000000000" # Azure App Registration with appropriate permissions to query Graph
$tenantId = "00000000-0000-0000-0000-000000000000" # Your tenant ID
#$scope = "https://graph.microsoft.com/.default"

# No access token exists
if (!$accessToken) {
    $tokenResponse = Get-MsalToken -ClientId $clientId -TenantId $tenantId -Interactive
    $accessToken = $tokenResponse.AccessToken
}
# Token exists, check if it is expired...
else {
    # Split the token into parts
    $tokenParts = $accessToken -split '\.'
    $payload = $tokenParts[1]

    # Pad the base64 string if needed
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { $payload += '===' }
    }

    # Decode and convert from JSON
    $decodedPayload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
    $tokenData = $decodedPayload | ConvertFrom-Json
    
    # Convert expiration time to local time
    $epoch = [datetime]"1970-01-01 00:00:00Z"
    $expirationTime = $epoch.AddSeconds($tokenData.exp).ToLocalTime()
    $currentTime = (Get-Date).ToLocalTime()
    
    # Display token expiration info
    Write-Host "Token expires at: $expirationTime"
    Write-Host "Current time is:  $currentTime"

    if ($currentTime -ge $expirationTime) {
        Write-Host "❌ Token has expired" -ForegroundColor Yellow
        $tokenResponse = Get-MsalToken -ClientId $clientId -TenantId $tenantId -Interactive
        $accessToken = $tokenResponse.AccessToken
    }
    else {
        Write-Host "✅ The token is still valid." -ForegroundColor Green
    }
}

# Ensure headers are set correctly
$headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type"  = "application/json"
}

$reportData = @()
foreach ($deviceName in $devices) {
    $lookupUri = "https://graph.microsoft.com/beta/devices?`$filter=displayName eq '$deviceName'"
    # Make the request
    try {
        $responseLookup = Invoke-RestMethod -Uri $lookupUri -Headers $headers -Method GET
        if ($responseLookup.value.Count -gt 0) {
            $deviceId = $responseLookup.value[0].deviceId
            Write-Host "Device ID: $deviceId"
        }
        else {
            Write-Warning "No device found with name '$deviceName'"
        }
    } catch {
        Write-Error "Request failed: $($_.Exception.Message)"
        continue
    }

    # GET - Retrieve a specific asset
    $getUri = "https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets/$deviceId"
    try {
        $responseGet = Invoke-RestMethod -Uri $getUri -Method GET -Headers $headers
    }
    catch {
        Write-Error "Request failed: $($_.Exception.Message)"
        continue
    }
    # Uncomment if you want to dump the data to a CSV (also uncomment the last line)
    $obj = [PSCustomObject]@{}
    $obj | Add-Member -MemberType NoteProperty -Name "Device Name" -Value $deviceName
    #$obj | Add-Member -MemberType NoteProperty -Name "Device Id" -Value $deviceId
    $obj | Add-Member -MemberType NoteProperty -Name "Feature Update" -Value $responseGet.enrollment.feature.enrollmentState
    $obj | Add-Member -MemberType NoteProperty -Name "Quality Update" -Value $responseGet.enrollment.quality.enrollmentState
    $obj | Add-Member -MemberType NoteProperty -Name "Driver Update" -Value $responseGet.enrollment.driver.enrollmentState
    $reportData+=$obj
    
    <# Write-Output "Feature Update: $($responseGet.enrollment.feature.enrollmentState)"
    Write-Output "Quality Update: $($responseGet.enrollment.quality.enrollmentState)"
    Write-Output "Driver Update: $($responseGet.enrollment.driver.enrollmentState)" #>
}
$reportData | Export-CSV -Path "$CSVPath\IntuneAutoPatchReport.csv" -Encoding UTF8 -NoTypeInformation