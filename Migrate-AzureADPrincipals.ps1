Import-Module Microsoft.Graph.Beta.Identity.DirectoryManagement
Import-Module Microsoft.Graph.Beta.Applications

Connect-MgGraph -Scopes "Application.Read.All", "User.Read.All", "DirectoryRecommendations.Read.All"
$appsRecommendationType = "aadGraphDeprecationApplication"
$spRecommendationType  = "aadGraphDeprecationServicePrincipal"

function getImpactedResources($recommendationType){
    $recommendation = Get-MgBetaDirectoryRecommendation -Filter "recommendationType eq `'$recommendationType`'"
    $resources =""
    if($recommendation){
        $resources = Get-MgBetaDirectoryRecommendationImpactedResource -RecommendationId $recommendation.id -Filter "Status eq 'active'" | select DisplayName, Id, Status
    }
    $resources | ft
}

Write-Output "Applications to migrate from Azure AD Graph to Microsoft Graph"
getImpactedResources $appsRecommendationType
Write-Output "Service Principals to migrate from Azure AD Graph to Microsoft Graph"
getImpactedResources $spRecommendationType