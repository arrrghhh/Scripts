# Revoke all permissions granted to application
Connect-MgGraph

# Get Service Principal using objectId
$sp = Get-MgServicePrincipal -ServicePrincipalId 3ae3b889-a031-411b-9ac2-8074e0249830

# Get all delegated permissions for the service principal
$spOAuth2PermissionsGrants = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id -All

# Remove all delegated permissions
$spOAuth2PermissionsGrants | ForEach-Object {
    #Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId $_.Id
}

# Remove only 'Principal' (individual user) permissions
$spOAuth2PermissionsGrants | Where-Object ConsentType -ne 'AllPrincipals' | ForEach-Object {
    #Write-Host "$($_.ConsentType)"
    Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId $_.Id
}

# Get all application permissions for the service principal
$spApplicationPermissions = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id

# Remove all app role assignments
$spApplicationPermissions | ForEach-Object {
    Write-Host "$($_.PrincipalId)"
    #Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $_.PrincipalId -AppRoleAssignmentId $_.Id
}