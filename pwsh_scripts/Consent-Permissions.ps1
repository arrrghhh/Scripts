# Admin consent to specific permissions - https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent?pivots=ms-powershell
Connect-MgGraph
$clientapp = Get-MgServicePrincipal -Filter "displayName eq 'Lever'"

$params = @{

    "ClientId" = $Clientapp.Id
    "ConsentType" = "AllPrincipals"
    "ResourceId" = "6b6aae28-44fa-4e52-842a-112090b6aa6e" # This GUID should be for the 'Microsoft Graph' permissions
    "Scope" = "User.Read openid offline_access Contacts.Read Calendars.ReadWrite.Shared Calendars.ReadWrite User.ReadBasic.All Mail.Read Mail.Send Mail.ReadWrite"
    }
    
New-MgOauth2PermissionGrant -BodyParameter $params | 
Format-List Id, ClientId, ConsentType, ResourceId, Scope

Get-MgOauth2PermissionGrant -Filter "clientId eq '$($clientApp.Id)' and consentType eq 'AllPrincipals'"