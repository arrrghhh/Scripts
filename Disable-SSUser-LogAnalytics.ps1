<#PSScriptInfo
.VERSION        1.5.0
.GUID           5c94b55a-0b1a-4302-8f5e-9b5d9c6f6f1f
.AUTHOR         Scott Brescia
.COMPANYNAME    Monolith
.COPYRIGHT      (c) Monolith. All rights reserved.
.TAGS           Delinea;SecretServer;Identity;Cleanup;Inactivity;MicrosoftGraph;Mail;Automation;ScheduledTask;Azure;KeyVault;ManagedIdentity
.EXTERNALMODULEDEPENDENCIES Microsoft.Graph.Mail, ActiveDirectory, Az.Accounts, Az.KeyVault
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
1.5.0  - Moved SSC API credentials to Azure Key Vault accessed via Managed Identity; added #requires Az.KeyVault; updated docs for KV usage and config.
1.4.0  - Added immediate SS disable if AD account is disabled; exponential backoff when disabling SS users; safer Bcc handling.
1.3.0  - Added per-domain inactivity window (e.g., *@cdw.com 30 days vs others 90 days) and notification period (14 days).
1.2.0  - Implemented paging for SS user listing; CSV ledger for emailed users; transcript logging and log retention.
1.1.0  - Migrated email sender to Microsoft Graph (app + cert auth).
1.0.0  - Initial version to warn and disable inactive Secret Server users.
#>

<#
.SYNOPSIS
Disables inactive Delinea Secret Server Cloud (SSC) user accounts, with pre‑disable notifications via Microsoft Graph and CSV-based tracking.

.DESCRIPTION
This script:
1) Retrieves SSC API credentials from **Azure Key Vault** using **Managed Identity** and authenticates to SSC via OAuth2.
2) Enumerates all SSC users (paged).
3) Filters users by inactivity threshold (default 90 days; 30 days for *@cdw.com).
4) Immediately disables SSC accounts if the corresponding AD account is disabled (for *@monolith-corp.com users).
5) Emails a 14‑day inactivity warning via **Microsoft Graph** to users who haven’t been previously notified (tracked in CSV).
6) After the notification period passes without login, disables the SSC account (Delinea “Delete” API disables users).
7) Maintains a CSV ledger of emailed users and a transcript log; prunes logs older than the retention window.

The script supports:
- HTML email bodies with optional Bcc.
- Exponential backoff/retry when disabling SSC users.
- Transcript logging and simple auditability via CSV.

.PARAMETER (Script Configuration Variables)
These are defined in the body of the script; adjust as needed:
- $apiUrl                 : SSC API base (e.g., "https://monolith-corp.secretservercloud.com/api/v1")
- $baseUrl                : SSC OAuth base (e.g., "https://monolith-corp.secretservercloud.com")
- $LoginDaysAgo           : Inactivity threshold for most domains (default: (Get-Date).AddDays(-90))
- $LoginDaysAgoCDW        : Inactivity threshold for *@cdw.com (default: (Get-Date).AddDays(-30))
- $notificationPeriod     : Days between notification and disable (default: 14)
- $logDir / $logFile      : Transcript log directory/file
- $daysToKeepLogs         : Log retention in days (default: 120)
- $emaileduserlogFile     : CSV ledger of emailed users
- $BccEmails              : Bcc address(es) for notifications (default: "scott.brescia@monolith-corp.com")

.PARAMETER (Azure Key Vault Settings)
- $kvName                 : Key Vault name (e.g., "MonolithKeyVaultProd")
- $kvUserSecretName       : Secret name for SSC API username (e.g., "ssc-api-username")
- $kvPassSecretName       : Secret name for SSC API password (e.g., "ssc-api-password")
- Authentication          : Uses `Connect-AzAccount -Identity` (Managed Identity) to access Key Vault

.PARAMETER (Graph Mail Settings)
App + certificate auth:
- $tenantId               : Azure AD tenant ID (GUID)
- $clientId               : App registration (client) ID (GUID)
- $thumbprint             : Cert thumbprint in LocalMachine\My for the Graph app
- From                    : Sender user UPN (must be allowed to send as this mailbox)

.REQUIREMENTS
- PowerShell 5.1+ (or PowerShell 7 with compatible modules).
- Modules: Microsoft.Graph.Mail, ActiveDirectory, Az.Accounts, Az.KeyVault.
- Network access to:
  - https://graph.microsoft.com
  - Your SSC tenant (e.g., https://monolith-corp.secretservercloud.com)
- Permissions:
  - **Graph App Role**: Mail.Send (Application). Admin consent required; app configured with certificate.
  - **Key Vault**: Managed Identity with Secret Get permissions to the named secrets.
  - **SSC API**: User account with rights to list and disable users.
- Environment:
  - For AD lookups: run where the RSAT AD module is available and you can query user objects.
  - Certificate installed in the machine store for Graph auth (thumbprint matches).

.INPUTS
None. (All configuration is set within the script.)

.OUTPUTS
- Transcript log file with timestamped actions and errors.
- CSV ledger of users who were emailed and the date emailed.
- Side effects: Emails are sent; SSC users may be disabled per policy; stale logs deleted.

.EXAMPLE
PS> .\Disable-SSUser-Inactivity.ps1
Runs the workflow end-to-end:
- Auth to SSC (creds from Azure Key Vault)
- Evaluate inactivity and AD state
- Notify new candidates
- Disable those past the notification window
- Update ledger and logs, prune old logs

.EXAMPLE
# Run as a Scheduled Task (recommended)
# Trigger: Daily @ 06:00
# Action: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "F:\Scripts\Disable-SSUser-Inactivity.ps1"

.NOTES
- Security:
  * Credentials come from Azure Key Vault via Managed Identity—avoid storing secrets in source.
  * Graph certificate in LocalMachine\My; protect private key; restrict app permissions to minimum.
  * Consider replacing OAuth “password” grant if SSC supports a more secure flow for service auth.
- AD UPN to sAMAccountName: The script trims *@monolith-corp.com and truncates to 20 chars for Get-ADUser.
- Paging: `$take` defaults to 10—adjust to match SSC API limits.
- Retention: Logs older than `$daysToKeepLogs` are removed.
- Known Limitations:
  * `$baseUrl` must be set; keep it consistent with `$apiUrl` (token endpoint is `$baseUrl/oauth2/token`).
  * Ensure email body strings are valid HTML (the script sends as HTML).
  * The “Delete” SSC API is used as per Delinea guidance to disable users; verify org policy before enabling in production.

.LINK
- Microsoft Graph PowerShell SDK: https://learn.microsoft.com/graph/powershell/get-started
- Microsoft Graph Mail.Send:     https://learn.microsoft.com/graph/api/user-sendmail
- Az.Accounts (Managed Identity): https://learn.microsoft.com/azure/developer/azure-developer-cli/azd-auth/managed-identity
- Az.KeyVault Secrets:           https://learn.microsoft.com/azure/key-vault/secrets/quick-create-powershell
- Delinea Secret Server API:     https://docs.delinea.com/online-help/secret-server/
#>

#requires -Modules Az.Accounts, Az.KeyVault, ActiveDirectory

$dateFormatFile = Get-Date -Format 'yyyy-MM-dd'
$logDir = "F:\Scripts\Logs"
$logFile = "$logDir\Disable-SSUserJSON_$($dateFormatFile).log"
$daysToKeepLogs = 120
$emaileduserlogFile = "F:\Scripts\emailed_users.csv"

# Inactivity thresholds
$LoginDaysAgo = (Get-Date).AddDays(-90)
$LoginDaysAgoCDW = (Get-Date).AddDays(-30)

# Bcc email addresses
$BccEmails = "scott.brescia@monolith-corp.com"
$BccEmailsCDW = "scott.brescia@monolith-corp.com;Nicki.Morse@cdw.com"


# --- Log Analytics Compatible Logging ---
function Write-LogAnalyticsLog {
    param(
        [string]$Level = "Info",
        [string]$Message,
        [hashtable]$Properties = @{}
    )
    $logObj = [ordered]@{
        TimeGenerated = (Get-Date).ToUniversalTime().ToString("o")
        Level         = $Level
        Message       = $Message
    }
    foreach ($key in $Properties.Keys) {
        $logObj[$key] = $Properties[$key]
    }
    $json = $logObj | ConvertTo-Json -Compress
    Add-Content -Path $logFile -Value $json
}

function Send-EmailviaGraph {
    param (
        [Parameter(Mandatory = $true)]
        [string]$To,
        [string]$Bcc,
        [Parameter(Mandatory = $true)]
        [string]$From,
        [Parameter(Mandatory = $true)]
        [string]$Body,
        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    $message = @{
        subject = $Subject
        body    = @{
            contentType = "HTML"
            content     = $Body
        }
        toRecipients = @(
            @{ emailAddress = @{ address = $To } }
        )
    }

    if ($Bcc) {
        # Allow multiple Bcc values separated by , ; or space
        $bccArray = $Bcc -split '[;, ]+' | Where-Object { $_ -and $_.Trim() -ne "" }
        if ($bccArray) {
            $message.bccRecipients = @()
            foreach ($addr in $bccArray) {
                $message.bccRecipients += @{ emailAddress = @{ address = $addr.Trim() } }
            }
        }
    }

    $payload = @{ message = $message } | ConvertTo-Json -Depth 10

    Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/users/$From/sendMail" `
        -Body $payload `
        -ContentType "application/json"
}

Write-LogAnalyticsLog -Level "Info" -Message "###### New Run ######"

$baseUrl = "https://monolith-corp.secretservercloud.com"
$apiUrl = "https://monolith-corp.secretservercloud.com/api/v1"

# --- Azure & Key Vault bootstrap --------------------------------------------
$kvName = "MonolithKeyVaultProd" 
$kvUserSecretName = "ssc-api-username"
$kvPassSecretName = "ssc-api-password"

# Use managed identity on Azure VM to access KeyVault
$null = Connect-AzAccount -Identity
Write-Output "$(Get-TimeStamp) - Connection to Azure successful."

# Retrieve the SS API username/password from Key Vault
try {
    # Prefer -AsPlainText (Az.KeyVault supports this parameter)
    $username = Get-AzKeyVaultSecret -VaultName $kvName -Name $kvUserSecretName -AsPlainText
    $password = Get-AzKeyVaultSecret -VaultName $kvName -Name $kvPassSecretName -AsPlainText
}
catch {
    Write-LogAnalyticsLog -Level "Error" -Message "Failed to retrieve secrets from Key Vault: $($_.Exception.Message)"
    throw
}
# -----------------------------------------------------------------------------

# --- Graph connection (establish once) ---
# Reuse your existing values here
$GraphTenantId       = "f35b2478-3a8b-4430-9f23-28cff73c416d"
$GraphClientId       = "cf25da74-550b-485d-882c-1c4989757e3c"
$GraphCertThumbprint = "29C1BEC4FBC9FF8009579AEE54F3C615CF3659CE"

if (-not (Get-Module -Name Microsoft.Graph.Mail)) {
    try { Import-Module Microsoft.Graph.Mail -ErrorAction Stop }
    catch {
        Install-Module Microsoft.Graph.Mail -Scope CurrentUser -Force
        Import-Module Microsoft.Graph.Mail
    }
}

# Connect once; reuse the context for all subsequent sends
$mgCtx = $null
try { $mgCtx = Get-MgContext -ErrorAction Stop } catch {}

if (-not $mgCtx -or $mgCtx.TenantId -ne $GraphTenantId) {
    Connect-MgGraph -ClientId $GraphClientId `
                    -TenantId $GraphTenantId `
                    -CertificateThumbprint $GraphCertThumbprint `
                    -NoWelcome
}

Write-LogAnalyticsLog -Level "Info" -Message "Connection to Graph successful."

$grantType = "password"
$headers = $null
$body = @{
    username = $username
    password = $password
    grant_type = $grantType
};

# Get auth token
try {
    $response = Invoke-WebRequest -Uri "$baseUrl/oauth2/token" -Method Post -Body $body -Headers $headers
    $token = ($response.Content | ConvertFrom-Json).access_token
    Write-LogAnalyticsLog -Level "Info" -Message "Authentication to SecretServer Cloud successful."
} catch {
    Write-LogAnalyticsLog -Level "Error" -Message "Failed to authenticate: '$($_.Exception.Message)'"
	exit
}

# Use auth token for SS user query
$headers = @{
    Authorization = "Bearer $token"
}

# Query users
$allUsers = @()
$skip = 0
$take = 10  # Adjust this value based on the API's page size limit
do {
    $filters = "?skip=$skip&take=$take&filter.includeInactive=true"
    try {
        $response = Invoke-WebRequest -Uri "$apiUrl/users$filters" -Headers $headers
        $allusers += ($response.Content | ConvertFrom-Json).records
        $skip += $take
    }
    catch {
        Write-LogAnalyticsLog -Level "Error" -Message "Failed to retrieve users: $($_.Exception.Message)"
        exit
    }
} while (($response.Content | ConvertFrom-Json).hasNext)

# Filter users who haven't logged in for the last 90 days
$filteredUsers = $allUsers | Where-Object { 
    $lastLogin = $null
    try {
        $lastLogin = Get-Date $_.lastLogin
        ($lastLogin -lt $LoginDaysAgo -and $_.userName -ne "DelineaWorkloadService" -and $_.userName -ne "Primarily1677" -and $_.userName -ne "APIUser" -and $_.userName -ne "cloudadmin@monolith-corp" -and $_.enabled -eq $true) -or ($lastLogin -lt $LoginDaysAgoCDW -and $_.emailAddress -like "*@cdw.com" -and $_.enabled -eq $true)
    } catch {
        Write-LogAnalyticsLog -Level "Error" -Message "Failed to parse last login date for user '$($_.userName)': $_"
        $false
    }
}

# Disable SS accounts immediately if AD account is disabled
foreach ($user in $allUsers) {
	if ($user.Enabled -eq $false) {
		# If the SS user is already disabled, no need to do anything
		continue
	}
	# Only match users in AD
    if ($user.userName -like "*@monolith-corp.com") {
		try {
			# Remove the domain name, ignore case
			$ShortUser = ($user.userName -ireplace '@monolith-corp.com','')
			# Some usernames are longer than 20char, causing the Get-ADUser cmdlet to fail
			if ($ShortUser.Length -gt 20) {
				$ShortUser = $ShortUser.Substring(0, 20)
			}
			$adUser = Get-ADUser -Identity $ShortUser
			if ($adUser.Enabled -eq $false) {
				Write-LogAnalyticsLog -Level "Info" -Message "'$($user.userName)' is disabled in AD. Disabling Secret Server account and skipping notification." -Properties @{ UserName = $user.userName }
				# Disable SS account immediately if they are disabled in AD
				$disableUser = Invoke-WebRequest -Uri "$apiUrl/users/$($user.Id)" -Method Delete -Headers $headers -ContentType "application/json" -ErrorAction Stop
				# Remove from filteredUsers to skip further processing
				$filteredUsers = $filteredUsers | Where-Object { $_.userName -ne $user.userName }
				continue
			}
		} catch {
			Write-LogAnalyticsLog -Level "Error" -Message "Failed AD lookup for '$($user.userName)': $($_.Exception.Message)" -Properties @{ UserName = $user.userName }
		}
	}
}

Write-LogAnalyticsLog -Level "Info" -Message "$($filteredUsers.Count) filtered users retrieved successfully." -Properties @{ FilteredUserCount = $filteredUsers.Count }

$notificationPeriod = 14  # Number of days before disabling the account

# Load existing emaileduser CSV file if it exists
if (Test-Path $emaileduserlogFile) {
    [array]$emailedUsers = Import-Csv $emaileduserlogFile
} else {
    $emailedUsers = @()
}

# Send email notification to each filtered user
foreach ($user in $filteredUsers) {
    $emailedUser = $emailedUsers | Where-Object { $_.userName -eq $user.userName }
    if (-not $emailedUser) {
        $lastLogin = $null
        $userCreated = $null
        $lastLogin = Get-Date $user.lastLogin
        $userCreated = Get-Date $user.created
        # If the account was never logged in and has existed for longer than $LoginDaysAgo, send a nastygram.
        if ($lastLogin.ToString("MM/dd/yyyy HH:mm:ss") -eq '01/01/0001 00:00:00' -and ($userCreated -lt $LoginDaysAgo -or ($userCreated -lt $LoginDaysAgoCDW -and $user.emailAddress -like "*@cdw.com"))) {
			$dateEmailed = Get-Date
            $emailBody = @"
<p>Dear $($user.displayName),</p>
<p>You have never logged into Secret Server, and your account was created on $($userCreated.ToString("MM/dd/yyyy")). Your account will be disabled if you do not log in within the next 14 days.</p>
<p>Please contact the Monolith IT Team (itteam@monolith-corp.com) if you feel this was sent in error.  If you do nothing, the Secret Server account will be disabled on $($dateEmailed.AddDays($notificationPeriod).ToString("MM/dd/yyyy")).</p>
<p>Best Regards,<br>Monolith IT Team</p>
"@
            # Log the emailed user
            $emailedUsers += [PSCustomObject]@{ UserName = $user.userName; EmailAddress = $user.emailAddress; DateEmailed = ($dateEmailed.ToString("MM/dd/yyyy HH:mm:ss")) }
			Write-LogAnalyticsLog -Level "Info" -Message "'$($user.emailAddress)' has been emailed, they never logged in." -Properties @{
                UserName = $user.userName
                EmailAddress = $user.emailAddress
                UserCreated = $userCreated
                DisableAfter = $dateEmailed.AddDays($notificationPeriod)
            }
			if ($user.emailAddress) {
                # Decide Bcc based on domain
                $BccEmails = if ($user.emailAddress -like "*@cdw.com") {
                    $BccEmailsCDW
                }
                else {
                    $BccEmails
                }
                Send-EmailviaGraph -To $user.emailAddress `
                                -Bcc $BccEmails `
                                -From "SecretServer@monolith-corp.com" `
                                -Subject "Secret Server Account Inactivity Notice" `
                                -Body $emailBody
				# Debug, send mail only to me...
				#Send-EmailviaGraph -To 'scott.brescia@monolith-corp.com' -From "SecretServer@monolith-corp.com" -Subject "Secret Server Account Inactivity Notice" -Body $emailBody
			}
			else {
				Write-LogAnalyticsLog -Level "Error" -Message "'$($user.userName)' is missing an email address. Please investigate." -Properties @{ UserName = $user.userName }
			}
        }
        # If the account has been logged into at some point, but has not logged in for $LoginDaysAgo, send a nastygram.
        elseif ($lastLogin.ToString("MM/dd/yyyy HH:mm:ss") -ne '01/01/0001 00:00:00') {
			$dateEmailed = Get-Date
            $emailBody = @"
<p>Dear $($user.displayName),</p>
<p>You have not logged into Secret Server recently. The last time you logged in was $($lastLogin.ToString("MM/dd/yyyy HH:mm")). Your account will be disabled if you do not log in within the next 14 days.</p>
<p>Please contact the Monolith IT Team (itteam@monolith-corp.com) if you feel this was sent in error.  If you do nothing, the Secret Server account will be disabled on $($dateEmailed.AddDays($notificationPeriod).ToString("MM/dd/yyyy")).</p>
<p>Best Regards,<br>Monolith IT Team</p>
"@
            # Log the emailed user
            $emailedUsers += [PSCustomObject]@{ UserName = $user.userName; EmailAddress = $user.emailAddress; DateEmailed = ($dateEmailed.ToString("MM/dd/yyyy HH:mm:ss")) }
			Write-LogAnalyticsLog -Level "Info" -Message "'$($user.emailAddress)' has been emailed, they last logged in '$($lastLogin.ToString("MM/dd/yyyy HH:mm:ss"))'." -Properties @{
                UserName = $user.userName
                EmailAddress = $user.emailAddress
                LastLogin = $lastLogin
                DisableAfter = $dateEmailed.AddDays($notificationPeriod)
            }
            if ($user.emailAddress) {
				# Decide Bcc based on domain
                $BccEmails = if ($user.emailAddress -like "*@cdw.com") {
                    $BccEmailsCDW
                }
                else {
                    $BccEmails
                }
                Send-EmailviaGraph -To $user.emailAddress `
                                -Bcc $BccEmails `
                                -From "SecretServer@monolith-corp.com" `
                                -Subject "Secret Server Account Inactivity Notice" `
                                -Body $emailBody				
				# Debug, send mail only to me...
				#Send-EmailviaGraph -To 'scott.brescia@monolith-corp.com' -From "SecretServer@monolith-corp.com" -Subject "Secret Server Account Inactivity Notice" -Body $emailBody
			}
			else {
				Write-LogAnalyticsLog -Level "Error" -Message "'$($user.userName)' is missing an email address. Please investigate." -Properties @{ UserName = $user.userName }
			}
        }
        else {
            # Enable if you need to debug leftovers, should only be users that never logged in but the account creation was less than $LoginDaysAgo days ago.
            #Write-LogAnalyticsLog -Level "Debug" -Message "'$($user.userName)' not contacted - account creation was on '$($userCreated.ToString("MM/dd/yyyy HH:mm:ss"))' and last login was '$($lastLogin.ToString("MM/dd/yyyy HH:mm:ss"))'."
        }
    }
    else {
        # Enable if you need to debug, should only be users that have already been emailed (are in the $emaileduserlogFile)
        #Write-LogAnalyticsLog -Level "Debug" -Message "'$($user.userName)' is in the list of users that have not logged in recently, but has already been emailed."
    }
}

Write-LogAnalyticsLog -Level "Info" -Message "Emailed users count: $($emailedUsers.Count)" -Properties @{ Count = $emailedUsers.Count }

# Log users without a username
$blankUsers = $emailedUsers | Where-Object { $_.UserName -eq $null -or $_.UserName -eq "" }
$blankUsers | ForEach-Object { Write-LogAnalyticsLog -Level "Warning" -Message "User is missing a username." -Properties @{ EmailAddress = $_.EmailAddress } }

# Save the log file
$emailedUsers | Where-Object { $_.UserName -and $_.UserName.Trim() -ne "" } |
    Sort-Object UserName -Unique |
    Export-Csv -Path $emaileduserlogFile -NoTypeInformation

# Disable users who have been notified and the notification period has passed
foreach ($emailedUser in $emailedUsers) {
    $user = $allUsers | Where-Object { $_.userName -eq $emailedUser.UserName }
    if ($user) {
        $lastLogin = $null
        $lastLogin = Get-Date $user.lastLogin
        if (($lastLogin -gt $LoginDaysAgoCDW -and $user.emailAddress -like "*@cdw.com") -or ($user.emailAddress -notlike "*@cdw.com" -and $lastLogin -gt $LoginDaysAgo)) {
            Write-LogAnalyticsLog -Level "Info" -Message "User $($user.emailAddress) has recently logged in - removing from CSV." -Properties @{
                UserName = $user.userName
                EmailAddress = $user.emailAddress
                LastLogin = $lastLogin
            }
            $emailedUsers = $emailedUsers | Where-Object { $_.UserName -ne $user.userName }
            continue
        }
        if ($user.Enabled -eq $false) {
            Write-LogAnalyticsLog -Level "Info" -Message "User $($user.emailAddress) has already been disabled outside of this script - removing from CSV." -Properties @{
                UserName = $user.userName
                EmailAddress = $user.emailAddress
            }
            $emailedUsers = $emailedUsers | Where-Object { $_.UserName -ne $user.userName }
            continue
        }
        $dateEmailed = [datetime]::Parse($emailedUser.DateEmailed)
        if ((Get-Date) -gt $dateEmailed.AddDays($notificationPeriod)) {
            Write-LogAnalyticsLog -Level "Info" -Message "Attempting disable of SS userID '$($user.Id)', displayName '$($user.displayName)', with email '$($user.emailAddress)'." -Properties @{
                UserId = $user.Id
                DisplayName = $user.displayName
                EmailAddress = $user.emailAddress
            }
            $retryCount = 0
            $InitialDelaySeconds = 2
            $delay = $InitialDelaySeconds
            $MaxRetries = 10
            while ($retryCount -lt $MaxRetries) {
                try {
                    # Per Delinea, use the 'Delete' API call - it will actually disable the user...
                    $disableUser = Invoke-WebRequest -Uri "$apiUrl/users/$($user.Id)" -Method Delete -Headers $headers -ContentType "application/json" -ErrorAction Stop
                    $userStatus = Invoke-WebRequest -Uri "$apiUrl/users/$($user.Id)" -Method Get -Headers $headers -ContentType "application/json" -ErrorAction Stop
                    if (($userStatus.Content | ConvertFrom-Json).Enabled -eq $false) {
                        Write-LogAnalyticsLog -Level "Info" -Message "User '$($user.displayName)' successfully disabled." -Properties @{
                            UserId = $user.Id
                            DisplayName = $user.displayName
                            EmailAddress = $user.emailAddress
                        }
                        # Remove the user from the emaileduser CSV file
                        $emailedUsers = $emailedUsers | Where-Object { $_.UserName -ne $user.userName }
                        # Break the disable 'while' loop, but will continue the initial ForEach loop
                        break
                    }
                    else {
                        throw "User not disabled."
                    }
			    }
			    catch {
				    Write-LogAnalyticsLog -Level "Error" -Message "Disable attempt failed: $($_.Exception.Message)" -Properties @{
                        UserId = $user.Id
                        DisplayName = $user.displayName
                        EmailAddress = $user.emailAddress
                        RetryCount = $retryCount
                    }
                    $status = $null
                    try { $status = $_.Exception.Response.StatusCode.value__ } catch {}
                    if ($status) { Write-LogAnalyticsLog -Level "Info" -Message "Response code: '$status'" }
                    $retryCount++
                    if ($retryCount -lt $MaxRetries) {
                        Write-LogAnalyticsLog -Level "Info" -Message "Retrying in '$delay' seconds..." -Properties @{ Delay = $delay }
                        Start-Sleep -Seconds $delay
                        $delay = [math]::Pow(2, $retryCount) * $InitialDelaySeconds
                    }
                    else {
                        Write-LogAnalyticsLog -Level "Error" -Message "Operation failed after '$MaxRetries' attempts." -Properties @{
                            UserId = $user.Id
                            DisplayName = $user.displayName
                            EmailAddress = $user.emailAddress
                        }
                        throw
                    }
			    }
            }
        }
        else {
			# Enable if you need to debug, should only be users that have already been emailed but are not to be disabled (yet)
            #Write-LogAnalyticsLog -Level "Debug" -Message "User $($user.emailAddress) was emailed '$($emailedUser.DateEmailed)', do not disable until '$notificationPeriod' days has passed (disable on '$($dateEmailed.AddDays($notificationPeriod))'). Last Login '$lastLogin'"
        }
    }
}

# Save the updated emaileduser CSV file
$emailedUsers | Where-Object { $_.UserName -and $_.UserName.Trim() -ne "" } |
    Sort-Object UserName -Unique |
    Export-Csv -Path $emaileduserlogFile -NoTypeInformation

# Delete old log files
Get-ChildItem -Path $logDir -Recurse | Where-Object {
	($_.PSIsContainer -eq $false -and $_.LastWriteTime -lt (Get-Date).AddDays(-1 * $daysToKeepLogs))
} | ForEach-Object {
		Remove-Item $_.FullName -Force
		Write-LogAnalyticsLog -Level "Info" -Message "Delete logfile '$($_.FullName)' based on '$($_.LastWriteTime)' LastWriteTime" -Properties @{ File = $_.FullName; LastWriteTime = $_.LastWriteTime }
}

Write-LogAnalyticsLog -Level "Info" -Message "Run Complete."
