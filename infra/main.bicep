
@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
@allowed(['eastus', 'westus2'])
@metadata({
  azd: {
    type: 'location'
  }
})
param location string = 'eastus'

@description('Skip the creation of the virtual network and private endpoint')
param skipVnet bool

@description('Name of the API service')
param apiServiceName string = ''

@description('Name of the user assigned identity')
param apiUserAssignedIdentityName string = ''

@description('Name of the application insights resource')
param applicationInsightsName string = ''

@description('Name of the app service plan')
param appServicePlanName string = ''

@description('Name of the log analytics workspace')
param logAnalyticsName string = ''

@description('Name of the resource group')
param resourceGroupName string = ''

@description('Name of the storage account')
param storageAccountName string = ''

@description('Name of the virtual network')
param vNetName string = ''

@description('Disable local authentication for Azure Monitor')
param disableLocalAuth bool = true

@description('Id of the user or app to assign application roles')
param principalId string = ''

@description('Name for the AI resource and used to derive name of dependent resources.')
param aiHubName string = 'hub-demo'

@description('Friendly name for your Hub resource')
param aiHubFriendlyName string = 'Agents Hub resource'

@description('Description of your Azure AI resource displayed in AI studio')
param aiHubDescription string = 'This is an example AI resource for use in Azure AI Studio.'

@description('Name for the AI project resources.')
param aiProjectName string = 'project-demo'

@description('Friendly name for your Azure AI resource')
param aiProjectFriendlyName string = 'Agents Project resource'

@description('Description of your Azure AI resource displayed in AI studio')
param aiProjectDescription string = 'This is an example AI Project resource for use in Azure AI Studio.'

@description('Name of the Azure AI Search account')
param aiSearchName string = 'agentaisearch'

@description('Name for capabilityHost.')
param capabilityHostName string = 'caphost1'

@description('Name of the Azure AI Services account')
param aiServicesName string = 'agentaiservices'

@description('Model name for deployment')
param modelName string = 'gpt-4o-mini'

@description('Model format for deployment')
param modelFormat string = 'OpenAI'

@description('Model version for deployment')
param modelVersion string = '2024-07-18'

@description('Model deployment SKU name')
param modelSkuName string = 'GlobalStandard'

@description('Model deployment capacity')
param modelCapacity int = 50

@description('Model deployment location. If you want to deploy an Azure AI resource/model in different location than the rest of the resources created.')
param modelLocation string = 'eastus'

@description('The AI Service Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param aiServiceAccountResourceId string = ''

@description('The Ai Search Service full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param aiSearchServiceResourceId string = ''

@description('The Ai Storage Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param aiStorageAccountResourceId string = ''

// Variables
var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id ,environmentName, location))
var tags = { 'azd-env-name': environmentName }
var functionAppName = !empty(apiServiceName) ? apiServiceName : '${abbrs.webSitesFunctions}api-${resourceToken}'
var deploymentStorageContainerName = 'app-package-${take(functionAppName, 32)}-${take(toLower(uniqueString(functionAppName, resourceToken)), 7)}'
var name = toLower('${aiHubName}')
var projectName = toLower('${aiProjectName}')

// Create a short, unique suffix, that will be unique to each resource group
var uniqueSuffix = toLower(uniqueString(subscription().id, resourceGroup().id, location))

// User assigned managed identity to be used by the function app to reach storage and service bus
module apiUserAssignedIdentity './core/identity/userAssignedIdentity.bicep' = {
  name: 'apiUserAssignedIdentity'
  params: {
    location: location
    tags: tags
    identityName: !empty(apiUserAssignedIdentityName) ? apiUserAssignedIdentityName : '${abbrs.managedIdentityUserAssignedIdentities}api-${resourceToken}'
  }
}

// The application backend is a function app
module appServicePlan './core/host/appserviceplan.bicep' = {
  name: 'appserviceplan'
  params: {
    name: !empty(appServicePlanName) ? appServicePlanName : '${abbrs.webServerFarms}${resourceToken}'
    location: location
    tags: tags
    sku: {
      name: 'FC1'
      tier: 'FlexConsumption'
    }
  }
}

module api './app/api.bicep' = {
  name: 'api'
  params: {
    name: functionAppName
    location: location
    tags: tags
    applicationInsightsName: monitoring.outputs.applicationInsightsName
    appServicePlanId: appServicePlan.outputs.id
    runtimeName: 'dotnet-isolated'
    runtimeVersion: '8.0'
    storageAccountName: storage.outputs.name
    deploymentStorageContainerName: deploymentStorageContainerName
    identityId: apiUserAssignedIdentity.outputs.identityId
    identityClientId: apiUserAssignedIdentity.outputs.identityClientId
    appSettings: {
      PROJECT_CONNECTION_STRING: aiProject.outputs.projectConnectionString
      STORAGE_CONNECTION__queueServiceUri: 'https://${storage.outputs.name}.queue.${environment().suffixes.storage}'
    }
    virtualNetworkSubnetId: skipVnet ? '' : serviceVirtualNetwork.outputs.appSubnetID
  }
}

// Dependent resources for the Azure Machine Learning workspace
module aiDependencies './agent/standard-dependent-resources.bicep' = {
  name: 'dependencies${name}${uniqueSuffix}deployment'
  params: {
    location: location
    storageName: 'st${uniqueSuffix}'
    keyvaultName: 'kv${name}${uniqueSuffix}'
    aiServicesName: '${aiServicesName}${uniqueSuffix}'
    aiSearchName: '${aiSearchName}${uniqueSuffix}'
    tags: tags

     // Model deployment parameters
     modelName: modelName
     modelFormat: modelFormat
     modelVersion: modelVersion
     modelSkuName: modelSkuName
     modelCapacity: modelCapacity  
     modelLocation: modelLocation

     aiServiceAccountResourceId: aiServiceAccountResourceId
     aiSearchServiceResourceId: aiSearchServiceResourceId
     aiStorageAccountResourceId: aiStorageAccountResourceId
    }
}

module aiHub './agent/standard-ai-hub.bicep' = {
  name: '${name}${uniqueSuffix}deployment'
  params: {
    // workspace organization
    aiHubName: '${name}${uniqueSuffix}'
    aiHubFriendlyName: aiHubFriendlyName
    aiHubDescription: aiHubDescription
    location: location
    tags: tags
    capabilityHostName: '${name}${uniqueSuffix}${capabilityHostName}'

    aiSearchName: aiDependencies.outputs.aiSearchName
    aiSearchId: aiDependencies.outputs.aisearchID

    aiServicesName: aiDependencies.outputs.aiServicesName
    aiServicesId: aiDependencies.outputs.aiservicesID
    aiServicesTarget: aiDependencies.outputs.aiservicesTarget
    
    keyVaultId: aiDependencies.outputs.keyvaultId
    storageAccountId: aiDependencies.outputs.storageId
  }
}


module aiProject './agent/standard-ai-project.bicep' = {
  name: '${projectName}${uniqueSuffix}deployment'
  params: {
    // workspace organization
    aiProjectName: '${projectName}${uniqueSuffix}'
    aiProjectFriendlyName: aiProjectFriendlyName
    aiProjectDescription: aiProjectDescription
    location: location
    tags: tags
    
    // dependent resources
    capabilityHostName: '${projectName}${uniqueSuffix}${capabilityHostName}'

    aiHubId: aiHub.outputs.aiHubID
    acsConnectionName: aiHub.outputs.acsConnectionName
    aoaiConnectionName: aiHub.outputs.aoaiConnectionName
  }
}

// Backing storage for Azure functions backend processor
module storage 'core/storage/storage-account.bicep' = {
  name: 'storage'
  params: {
    name: !empty(storageAccountName) ? storageAccountName : '${abbrs.storageStorageAccounts}${resourceToken}'
    location: location
    tags: tags
    containers: [
      {name: deploymentStorageContainerName}
    ]
    networkAcls: skipVnet ? {} : {
      bypass: 'None'
      virtualNetworkRules: [
        {
          id: serviceVirtualNetwork.outputs.appSubnetID
          action: 'Allow'
          state: 'Succeeded'
        }
      ]
      resourceAccessRules: [
        {
          tenantId: tenant().tenantId
          resourceId: aiProject.outputs.aiProjectResourceId
        }
      ]
      defaultAction: 'Deny'
    }
  }
}

module aiServiceRoleAssignments './agent/ai-service-role-assignments.bicep' = {
  name: 'aiserviceroleassignments${projectName}${uniqueSuffix}deployment'
  params: {
    aiServicesName: aiDependencies.outputs.aiServicesName
    aiProjectPrincipalId: aiProject.outputs.aiProjectPrincipalId
    aiProjectId: aiProject.outputs.aiProjectResourceId
  }
}

module aiSearchRoleAssignments './agent/ai-search-role-assignments.bicep' = {
  name: 'aisearchroleassignments${projectName}${uniqueSuffix}deployment'
  params: {
    aiSearchName: aiDependencies.outputs.aiSearchName
    aiProjectPrincipalId: aiProject.outputs.aiProjectPrincipalId
    aiProjectId: aiProject.outputs.aiProjectResourceId
  }
}

var storageRoleDefinitionId  = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner role

// Allow access from api to storage account using a managed identity
module storageRoleAssignmentApi 'app/storage-Access.bicep' = {
  name: 'storageRoleAssignmentapi'
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageRoleDefinitionId
    principalID: apiUserAssignedIdentity.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

var storageQueueDataContributorRoleDefinitionId  = '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor

module storageQueueDataContributorRoleAssignmentprocessor 'app/storage-Access.bicep' = {
  name: 'storageQueueDataContributorRoleAssignmentprocessor'
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageQueueDataContributorRoleDefinitionId
    principalID: apiUserAssignedIdentity.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Allow access from AI project to storage account using a managed identity
module storageQueueDataContributorRoleAssignmentAIProject 'app/storage-Access.bicep' = {
  name: 'storageQueueDataContributorRoleAssignmentAIProject'
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageQueueDataContributorRoleDefinitionId
    principalID: aiProject.outputs.aiProjectPrincipalId
    principalType: 'ServicePrincipal'
  }
}

module storageQueueDataContributorRoleAssignmentUserIdentityprocessor 'app/storage-Access.bicep' = {
  name: 'storageQueueDataContributorRoleAssignmentUserIdentityprocessor'
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageQueueDataContributorRoleDefinitionId
    principalID: principalId
    principalType: 'User'
  }
}

var storageTableDataContributorRoleDefinitionId  = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor

module storageTableDataContributorRoleAssignmentprocessor 'app/storage-Access.bicep' = {
  name: 'storageTableDataContributorRoleAssignmentprocessor'
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageTableDataContributorRoleDefinitionId
    principalID: apiUserAssignedIdentity.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Virtual Network & private endpoint to blob storage
module serviceVirtualNetwork 'app/vnet.bicep' =  if (!skipVnet) {
  name: 'serviceVirtualNetwork'
  params: {
    location: location
    tags: tags
    vNetName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
  }
}

module storagePrivateEndpoint 'app/storage-PrivateEndpoint.bicep' = if (!skipVnet) {
  name: 'servicePrivateEndpoint'
  params: {
    location: location
    tags: tags
    virtualNetworkName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
    subnetName: skipVnet ? '' : serviceVirtualNetwork.outputs.peSubnetName
    resourceName: storage.outputs.name
  }
}

// Monitor application with Azure Monitor
module monitoring './core/monitor/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    tags: tags
    logAnalyticsName: !empty(logAnalyticsName) ? logAnalyticsName : '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: !empty(applicationInsightsName) ? applicationInsightsName : '${abbrs.insightsComponents}${resourceToken}'
    disableLocalAuth: disableLocalAuth  
  }
}

var monitoringRoleDefinitionId = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher role ID

// Allow access from api to application insights using a managed identity
module appInsightsRoleAssignmentApi './core/monitor/appinsights-access.bicep' = {
  name: 'appInsightsRoleAssignmentapi'
  params: {
    appInsightsName: monitoring.outputs.applicationInsightsName
    roleDefinitionID: monitoringRoleDefinitionId
    principalID: apiUserAssignedIdentity.outputs.identityPrincipalId
  }
}

var AzureAIAdministratorRoleDefinitionId = 'b78c5d69-af96-48a3-bf8d-a8b4d589de94' // Azure AI Administrator role ID
// Enable access to AI Project from the Azure Function user assigned identity
resource AIProjectRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(AzureAIAdministratorRoleDefinitionId, aiProjectName, resourceId('Microsoft.MachineLearningServices/workspaces', aiProjectName))
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', AzureAIAdministratorRoleDefinitionId)
    principalId: apiUserAssignedIdentity.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// App outputs
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.applicationInsightsConnectionString
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output SERVICE_API_NAME string = api.outputs.SERVICE_API_NAME
output SERVICE_API_URI string = api.outputs.SERVICE_API_URI
output AZURE_FUNCTION_APP_NAME string = api.outputs.SERVICE_API_NAME
output RESOURCE_GROUP string = resourceGroupName
output STORAGE_ACCOUNT_NAME string = storage.outputs.name
output PROJECT_CONNECTION_STRING string = aiProject.outputs.projectConnectionString
output STORAGE_CONNECTION__queueServiceUri string = 'https://${storage.outputs.name}.queue.${environment().suffixes.storage}'
