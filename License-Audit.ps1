# The function of this script is to return all users that have licences and have been inactive in AzureAD sigin logs for x amount of days.
# For customers who have Azure AD Premium P2 subscriptions, the sign-in logs are retained for 30 days.
# By default, Azure AD retains sign-in logs for 30 days, but the retention period can be increased up to two years by using Azure Monitor and Storage accounts

# Install the required PowerShell modules
Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module -Name Microsoft.Graph.Users -Scope CurrentUser
Install-Module -Name Microsoft.Graph.Reports -Scope CurrentUser

# Import the required modules
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Reports

# Connect to Microsoft Graph using delegated permissions
Connect-MgGraph -Scopes "User.Read.All, AuditLog.Read.All"

# Download the CSV file containing the product name and SkuPartNumber mappings
Invoke-WebRequest -Uri "https://download.microsoft.com/download/e/3/e/e3e9faf2-f28b-490a-9ada-c6089a1fc5b0/Product%20names%20and%20service%20plan%20identifiers%20for%20licensing.csv" -OutFile "c:\temp\product_names.csv"

# Import the CSV file into a variable and create a dictionary using the SkuPartNumber as key and Product_Display_Name as value
$productNames = Import-Csv "c:\temp\product_names.csv"
$skuDict = @{}
foreach($product in $productNames)
{
    $skuDict[$product.GUID] = $product.Product_Display_Name
}

# Set the number of days of inactivity to consider
$DaysInactive = 30
$InactiveDate = (Get-Date).AddDays(-$DaysInactive)

# Retrieve all users using the Microsoft Graph API
$AllUsers = Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, AccountEnabled

# Initialize an empty array to store inactive users
$InactiveUsers = @()

# Iterate through each user and check for inactivity in Azure AD sign-in logs
foreach ($User in $AllUsers) {
    $LicenseDetail = Get-MgUserLicenseDetail -UserId $User.Id
    if ($LicenseDetail -ne $null) {
        $License = ($LicenseDetail | ForEach-Object { $skuDict[$_.SkuId] }) -join ", "

        Write-Output "Checking $($User.userPrincipalName) with License: $License"

        Write-Output "Getting sign-in logs for $($User.displayName)"
        $AllSignInLogs = Get-MgAuditLogSignIn -Filter "userDisplayName eq '$($User.displayName)'"
        #Write-Output "All sign-in logs:"
        #Write-Output $AllSignInLogs

        $SignIn = $AllSignInLogs | Sort-Object -Property createdDateTime -Descending | Select-Object -First 1
        Write-Output "Most recent sign-in log entry:"
        Write-Output $SignIn.createdDateTime

        if (!$SignIn -or $SignIn.createdDateTime -lt $InactiveDate) {
            $InactiveUsers += [PSCustomObject]@{
                DisplayName = $User.displayName
                UserPrincipalName = $User.userPrincipalName
                LastSignin = $Signin
                Enabled = $User.accountEnabled
                License = $License
            }
            write-output 'InactiveUser! '$User.displayName $License
        }
    }
}

$InactiveUsers | Export-Csv -Path "c:\temp\InactiveUsers.csv" -NoTypeInformation

Disconnect-MgGraph 