#!/bin/bash
set -e

output=$(azd env get-values)

# Parse the output to get the resource names and the resource group
while IFS= read -r line; do
    if [[ $line == STORAGE_ACCOUNT_NAME* ]]; then
        StorageAccount=$(echo "$line" | cut -d'=' -f2 | tr -d '"')
    elif [[ $line == RESOURCE_GROUP* ]]; then
        ResourceGroup=$(echo "$line" | cut -d'=' -f2 | tr -d '"')
    fi
done <<< "$output"

# Read the config.json file to see if vnet is enabled
ConfigFolder=$(echo "$ResourceGroup" | cut -d'-' -f2-)
configFile=".azure/$ConfigFolder/config.json"

if [[ -f "$configFile" ]]; then
    jsonContent=$(cat "$configFile")
    skipVnet=$(echo "$jsonContent" | grep '"skipVnet"' | sed 's/.*"skipVnet":\s*"\([^"]*\)".*/\1/')
else
    echo "Config file $configFile not found. Assuming VNet is enabled."
    skipVnet="false"
fi

# skipVnet is in the form "skipVnet": false
if echo "$skipVnet" | grep -iq "true"; then
    echo "VNet is not enabled. Skipping adding the client IP to the network rule of the Azure Functions storage account"
else
    echo "VNet is enabled. Adding the client IP to the network rule of the Azure Functions storage account"
    
    # Get the client IP
    ClientIP=$(curl -s https://api.ipify.org)

    az storage account network-rule add --resource-group "$ResourceGroup" --account-name "$StorageAccount" --ip-address "$ClientIP" > /dev/null
fi