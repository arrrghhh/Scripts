# Resets Intune AutoPatch Device Enrollment Status - inspired by https://patchmypc.com/blog/troubleshooting-windows-feature-updates-enrollment/

# Device name(s) to search for
$devices = @("WIN10TO11","INTUNETEST01","INTUNETEST02")

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

$clientId = "00000000-0000-0000-0000-000000000000" # Use a public client ID like Azure CLI: "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
$tenantId = "00000000-0000-0000-0000-000000000000" # or your tenant ID
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
    Write-Host "Current time is: $currentTime"

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
            continue
        }
    } catch {
        Write-Error "Request failed: $($_.Exception.Message)"
        continue
    }

    # - Section commented, at the moment this script will just retrieve the status and dump to a CSV
    # 1. Unenroll Asset
    $postUri = "https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets/unenrollassets"
    $postBody = @{
        updateCategory = "feature"
        assets = @(
            @{
                "@odata.type" = "#microsoft.graph.windowsUpdates.azureADDevice"
                id = "$deviceId"
            }
        )
    } | ConvertTo-Json -Depth 3
    $responsePost = Invoke-RestMethod -Uri $postUri -Method POST -Headers $headers -Body $postBody

    # 2. DELETE - Remove a specific updatable asset
    $deleteUri = "https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets/$deviceId"
    $responseDelete = Invoke-RestMethod -Uri $deleteUri -Method DELETE -Headers $headers

    # 3a. POST - Enroll asset, feature update
    $postUri = "https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets/enrollassets"
    $postBody = @{
        updateCategory = "feature"
        assets = @(
            @{
                "@odata.type" = "#microsoft.graph.windowsUpdates.azureADDevice"
                id = "$deviceId"
            }
        )
    } | ConvertTo-Json -Depth 3
    $responsePost = Invoke-RestMethod -Uri $postUri -Method POST -Headers $headers -Body $postBody

    # 3b. POST - Enroll asset, quality update
    $postUri = "https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets/enrollassets"
    $postBody = @{
        updateCategory = "quality"
        assets = @(
            @{
                "@odata.type" = "#microsoft.graph.windowsUpdates.azureADDevice"
                id = "$deviceId"
            }
        )
    } | ConvertTo-Json -Depth 3
    $responsePost = Invoke-RestMethod -Uri $postUri -Method POST -Headers $headers -Body $postBody

    # 3c. POST - Enroll asset, driver update
    $postUri = "https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets/enrollassets"
    $postBody = @{
        updateCategory = "driver"
        assets = @(
            @{
                "@odata.type" = "#microsoft.graph.windowsUpdates.azureADDevice"
                id = "$deviceId"
            }
        )
    } | ConvertTo-Json -Depth 3
    $responsePost = Invoke-RestMethod -Uri $postUri -Method POST -Headers $headers -Body $postBody

    # 4. GET - Retrieve a specific asset
    $getUri = "https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets/$deviceId"
    try {
        $responseGet = Invoke-RestMethod -Uri $getUri -Method GET -Headers $headers
    }
    catch {
        Write-Error "Request failed: $($_.Exception.Message)"
        continue
    }
    <#
    $obj = [PSCustomObject]@{}
    $obj | Add-Member -MemberType NoteProperty -Name "Device Name" -Value $deviceName
    #$obj | Add-Member -MemberType NoteProperty -Name "Device Id" -Value $deviceId
    $obj | Add-Member -MemberType NoteProperty -Name "Feature Update" -Value $responseGet.enrollment.feature.enrollmentState
    $obj | Add-Member -MemberType NoteProperty -Name "Quality Update" -Value $responseGet.enrollment.quality.enrollmentState
    $obj | Add-Member -MemberType NoteProperty -Name "Driver Update" -Value $responseGet.enrollment.driver.enrollmentState
    $reportData+=$obj
    #>
    Write-Output "Feature Update: $($responseGet.enrollment.feature.enrollmentState)"
    Write-Output "Quality Update: $($responseGet.enrollment.quality.enrollmentState)"
    Write-Output "Driver Update: $($responseGet.enrollment.driver.enrollmentState)"
    
}
#$reportData | Export-CSV -Path "$CSVPath\IntuneAutoPatchReport.csv" -Encoding UTF8 -NoTypeInformation