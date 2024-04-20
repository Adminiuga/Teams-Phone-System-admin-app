Param (
    [parameter(mandatory = $false)] $displayName = "Teams Telephony Manager",   # Display name for your application registered in Azure AD 
    [parameter(mandatory = $false)] $rgName = "Teams-Telephony-Manager",        # Name of the resource group for Azure
    [parameter(mandatory = $false)] $resourcePrefix = "Teams",                  # Prefix for the resources deployed on your Azure subscription
    [parameter(mandatory = $false)] $location = 'westeurope',                   # Location (region) where the Azure resource are deployed
    [parameter(mandatory = $false, HelpMessage="Keyvault Certificate name")]
    [string]$kvCertificateName = "TeamsAdminAppRole",                           # Certificate Name in KeyVault for the Teams Admin Role app auth
    [parameter(mandatory = $false, HelpMessage="Teams Certificate Subject name")]
    [string]$CertificateSubjectName = "Teams-Admin-App-Role"                    # Certificate Subject Name for the Teams Admin Role app auth
)

$base = $PSScriptRoot
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

# Import required PowerShell modules for the deployment
If($PSVersionTable.PSVersion.Major -ne 7) { 
    Write-Error "Please install and use PowerShell v7.2.1 to run this script"
    Write-Error "Follow the instruction to install PowerShell on Windows here"
    Write-Error "https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows?view=powershell-7.2"
    return
}
Import-Module Az.Accounts, Az.Resources, Az.KeyVault   # Required to deploy the Azure resource

# Connect to AzureAD and Azure using modern authentication
write-host -ForegroundColor blue "Azure sign-in request - Please check the sign-in window opened in your web browser"
Try
{
    Connect-AzAccount -WarningAction Ignore -ErrorAction Stop |Out-Null
}
Catch
{
    Write-Error "An error occured connecting to Azure using the Azure PowerShell module"
    $_.Exception.Message
}

# Validating if multiple Azure Subscriptions are active
If($subscriptionID -eq $null)
{
    [array]$AzSubscriptions = Get-AzSubscription |Where-Object {$_.State -eq "Enabled"}
    $menu = @{}
    If($(Get-AzSubscription |Where-Object {$_.State -eq "Enabled"}).Count -gt 1)
    {
        Write-Host "Multiple active Azure Subscriptions found, please select a subscription from the list below:"
        for ($i=1;$i -le $AzSubscriptions.count; $i++) 
        { 
                Write-Host "$i. $($AzSubscriptions[$i-1].Id)" 
                $menu.Add($i,($AzSubScriptions[$i-1].Id))
        }
        [int]$AZSelectedSubscription = Read-Host 'Enter selection'
        $selection = $menu.Item($AZSelectedSubscription) ; 
        Select-AzSubscription -Subscription $selection | Out-Null
    }
}
else
{
    Select-AzSubscription -Subscription $subscriptionID | Out-Null
}

write-host -ForegroundColor blue "Checking if app '$displayName' is already registered"
$AAdapp = Get-AzADApplication -Filter "DisplayName eq '$displayName'"
If ($AAdapp.Count -gt 1) {
    Write-Error "Multiple Azure AD app registered under the name '$displayName' - Please use another name and retry"
    return
}

If([string]::IsNullOrEmpty($AAdapp)){
    write-host -ForegroundColor blue "Register a new app in Azure AD using Azure Function app name"
    $GraphAppPermissions = @{
        ResourceAppId = "00000003-0000-0000-c000-000000000000"
        ResourceAccess = @(
            @{Type = "Role"; Id = "dc149144-f292-421e-b185-5953f2e98d7f"}
            @{Type = "Role"; Id = "6a118a39-1227-45d4-af0c-ea7b40d210bc"}
            @{Type = "Role"; Id = "35930dcf-aceb-4bd1-b99a-8ffed403c974"}
            @{Type = "Role"; Id = "243cded2-bd16-4fd6-a953-ff8177894c3d"}
            @{Type = "Role"; Id = "62a82d76-70ea-41e2-9197-370581804d09"}
            @{Type = "Role"; Id = "498476ce-e0fe-48b0-b801-37ba7e2685c6"}
            @{Type = "Role"; Id = "bdd80a03-d9bc-451d-b7c4-ce7c63fe3c8f"}
            @{Type = "Role"; Id = "df021288-bdef-4463-88db-98f22de89214"}
        )
    }
    $AADapp = New-AzADApplication -DisplayName $displayName -AvailableToOtherTenants $false -RequiredResourceAccess $GraphAppPermissions
    $AppIdURI = "api://azfunc-" + $AADapp.AppId
    # Expose an API and create an Application ID URI
    Try {
        Update-AzADApplication -ObjectId $AADapp.Id -IdentifierUri $AppIdURI
    }    
    Catch {
        Write-Error "Azure AD application registration error - Please check your permissions in Azure AD and review detailed error description below"
        $_.Exception.Message
        return
    }
    # Create a new app secret with a default validaty period of 1 year - Get the generated secret
    $secret   = (New-AzADAppCredential -ObjectId $AADapp.Id -EndDate (Get-Date).date.AddYears(1)).SecretText
    # Get the AppID from the newly registered App
    $clientID = $AADapp.AppId
    # Get theenantID based on App's publisher domain
    $tenantID = $(Get-AzTenant | Where-Object {$_.Domains -contains $AADapp.PublisherDomain})[0].id
    write-host -ForegroundColor blue "New app '$displayName' registered into AzureAD"
}
Else {
    write-host -ForegroundColor blue "Generating a new secret for app '$displayName'"
    $secret   = (New-AzAdAppCredential -ObjectId $AADapp.Id -EndDate (Get-Date).date.AddYears(1)).SecretText
    # Get the AppID from the newly registered App
    $clientID = $AADapp.AppId
    # Get the tenantID based on App's publisher domain
    $tenantID = $(Get-AzTenant | Where-Object {$_.Domains -contains $AADapp.PublisherDomain})[0].id
}

write-host -ForegroundColor blue "Deploy resource to Azure subscription"
Try {
    New-AzResourceGroup -Name $rgName -Location $location -Force
}    
Catch {
    Write-Error "Azure Ressource Group creation failed - Please verify your permissions on the subscription and review detailed error description below"
    $_.Exception.Message
    return
}
write-host -ForegroundColor blue "Resource Group $rgName created in location $location - Now initiating Azure resource deployments..."
$deploymentName = 'deploy-' + (Get-Date -Format "yyyyMMdd-hhmm")
$parameters = @{
    resourcePrefix          = $resourcePrefix
    clientID                = $clientID
    appSecret               = $secret
}

$outputs = New-AzResourceGroupDeployment -ResourceGroupName $rgName -TemplateFile $base\ZipDeploy\azuredeploy.json -TemplateParameterObject $parameters -Name $deploymentName -ErrorAction SilentlyContinue
If ($outputs.provisioningState -ne 'Succeeded') {
    Write-Error "ARM deployment failed with error"
    Write-Error "Please retry deployment"
    $outputs
    return
}
write-host -ForegroundColor blue "ARM template deployed successfully"

# Getting UPN from connected user
$CurrentUserId = Get-AzContext | ForEach-Object account | ForEach-Object Id

# Assign current user with the permissions to list and read Azure KeyVault secrets (to enable the connection with the Power Automate flow)
Write-Host -ForegroundColor blue "Assigning 'Secrets List & Get' policy on Azure KeyVault for user $CurrentUserId"
Try {
    Set-AzKeyVaultAccessPolicy -VaultName $outputs.Outputs.azKeyVaultName.Value -ResourceGroupName $rgName -UserPrincipalName $CurrentUserId -PermissionsToSecrets list,get `
                               -PermissionsToCertificates "get", "list", "update", "create"
}
Catch {
    Write-Error "Error - Couldn't assign user permissions to get,list the KeyVault secrets - Please review detailed error message below"
    $_.Exception.Message
}

write-host -ForegroundColor blue "Checking if Certificate exists and is not expired"
$kvCert = Get-AzKeyVaultCertificate -VaultName $outputs.Outputs.azKeyVaultName.Value -Name $kvCertificateName
if (($null -eq $kvCert) -or ($(get-date -AsUTC) -ge $($kvCert.Expires.AddDays(-21)))) {
    write-host -ForegroundColor blue "Creating a self-signed certificate for Teams admin access"
    $KVCertPolicyParams = @{
        SecretContentType = "application/x-pkcs12"
        SubjectName       = "CN=$CertificateSubjectName"
        IssuerName        = "Self"
        ValidityInMonths  = 6
    }
    Try {
        $Policy = New-AzKeyVaultCertificatePolicy @KVCertPolicyParams
        Add-AzKeyVaultCertificate -VaultName $outputs.Outputs.azKeyVaultName.Value -Name $kvCertificateName -CertificatePolicy $Policy
    }
    Catch {
        Write-Error "Couldn't issue a self-signed certificate"
        $_.Exception.Message
    }

    $retries = 0
    do {
        write-host -ForegroundColor yellow "Checking certificate request status"
        $certOp = Get-AzKeyVaultCertificateOperation -VaultName $outputs.Outputs.azKeyVaultName.Value -Name $kvCertificateName
        $certReqIsCompleted = ($certOp.Status -eq "completed")
        if ( !$certReqIsCompleted ) {
            $delay = 2 + $retries * 2
            $retries += 1
            write-host "Sleeping for $delay seconds before retrying"
            Sleep-Seconds $delay
        }
    }
    until (($certReqIsCompleted -eq $true) -and ($retries -le 5))
}

# Add Certificate to the App credentials if needed
Try {
    $kvCert = Get-AzKeyVaultCertificate -VaultName $outputs.Outputs.azKeyVaultName.Value -Name $kvCertificateName
    $AppCertsCred = $AADApp.KeyCredentials  | ForEach-Object {
        [Convert]::ToBase64String($_.CustomKeyIdentifier)
    }
    if ( !($AppCertsCred -contains $kvCert.Thumbprint) ) {
        write-host -ForegroundColor blue "Adding certificate to the App credentials"
        $pemCert = [Convert]::ToBase64String($kvCert.Certificate.Export(1))
        New-AzADAppCredential -CertValue $pemCert -ApplicationId $AAdApp.AppId
    }
}
Catch {
    Write-Error "Couldn't add certificate to the application secrets"
    $_.Exception.Message
}

# Link certificate in KeyVault to WebApp's "bring your own certificate"
Try {
    $importCertParams = @{
        ResourceGroupName = $rgName
        KeyVaultName      = $outputs.Outputs.azKeyVaultName.Value
        CertName          = $kvCertificateName
        WebAppName        = $outputs.Outputs.azFuncAppName.Value
    }
    Import-AzWebAppKeyVaultCertificate @importCertParams | Out-Null
}
Catch {
    Write-Error "Couldn't import KeyVault certificate to Web Function App"
    $_.Exception.Message
}

write-host -ForegroundColor blue "Updating Web App Settings"
Try {
    $WebApp = Get-AzWebApp -ResourceGroupName $rgName -Name $outputs.Outputs.azFuncAppName.Value
    $UpdatedWebAppSettings = @{WEBSITE_LOAD_CERTIFICATES = $kvCert.Thumbprint}
    $WebApp.SiteConfig.AppSettings | ForEach-Object {
        $UpdatedWebAppSettings[$_.Name] = $_.Value
    }
    $azWebAppParams = @{
        ResourceGroupName = $rgName
        Name              = $outputs.Outputs.azFuncAppName.Value
        AppSettings       = $UpdatedWebAppSettings
    }
    Set-AzWebApp @azWebAppParams | Out-Null
}
Catch {
    Write-Error "Couldn't update web app settings"
    $_.Exception.Message
}

write-host -ForegroundColor blue "Getting the Azure Function App key for warm-up test"
## lookup the resource id for your Azure Function App ##
$azFuncResourceId = (Get-AzResource -ResourceGroupName $rgName -ResourceName $outputs.Outputs.azFuncAppName.Value -ResourceType "Microsoft.Web/sites").ResourceId

## compose the operation path for listing keys ##
$path = "$azFuncResourceId/host/default/listkeys?api-version=2021-02-01"
$result = Invoke-AzRestMethod -Path $path -Method POST

if($result -and $result.StatusCode -eq 200)
{
   ## Retrieve result from Content body as a JSON object ##
   $contentBody = $result.Content | ConvertFrom-Json
   $code = $contentBody.masterKey
}
else {
    Write-Error "Couldn't retrive the Azure Function app master key - Warm-up tests not executed"
    return
}

write-host -ForegroundColor blue "Waiting 2 min to let the Azure function app to start"
Start-Sleep -Seconds 120

write-host -ForegroundColor blue "Warming-up Azure Function apps - This will take a few minutes"
& $base\warmup.ps1 -hostname $outputs.Outputs.azFuncHostName.Value -code $code -tenantID $tenantID -clientID $clientID -secret $secret

write-host -ForegroundColor blue "Deployment script terminated"

# Generating outputs
$outputsData = [ordered]@{
    API_URL       = 'https://'+ $outputs.Outputs.azFuncHostName.Value
    API_Code      = $outputs.Outputs.AzFuncAppCode.Value
    TenantID      = $tenantID
    ClientID      = $clientID
    Audience      = 'api://azfunc-' + $clientID
    KeyVault_Name = $outputs.Outputs.AzKeyVaultName.Value
    AzFunctionIPs = $outputs.Outputs.outboundIpAddresses.Value
}

#Disconnecting from Azure
Disconnect-AzAccount

write-host -ForegroundColor magenta "Here are the information you'll need to deploy and configure the Power Application"
$outputsData
