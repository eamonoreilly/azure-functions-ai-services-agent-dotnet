$ErrorActionPreference = "Stop"

$output = azd env get-values

# Parse the output to get the resource names and the resource group
foreach ($line in $output) {
    if ($line -match "STORAGE_ACCOUNT_NAME"){
        $StorageAccount = ($line -split "=")[1] -replace '"',''
    }
    if ($line -match "RESOURCE_GROUP"){
        $ResourceGroup = ($line -split "=")[1] -replace '"',''
    }
}

# Read the config.json file to see if vnet is enabled
$ConfigFolder = ($ResourceGroup -split '-' | Select-Object -Skip 1) -join '-'
$jsonContent = Get-Content -Path ".azure\$ConfigFolder\config.json" -Raw | ConvertFrom-Json
if ($jsonContent.infra.parameters.skipVnet -eq $true) {
    Write-Output "VNet is not enabled. Skipping adding the client IP to the network rule of the storage account"
}
else {
    Write-Output "VNet is enabled. Adding the client IP to the network rule of the Azure Functions storage account"
    # Get the client IP
    $ClientIP = Invoke-RestMethod -Uri 'https://api.ipify.org'

    az storage account network-rule add --resource-group $ResourceGroup --account-name $StorageAccount --ip-address $ClientIP | Out-Null
    Write-Output "Client IP $ClientIP added to the network rule of the Azure Functions storage account"
}