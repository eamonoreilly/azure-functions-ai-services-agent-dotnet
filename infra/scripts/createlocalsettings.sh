#!/bin/bash

set -e

if [ ! -f "./app/local.settings.json" ]; then

    output=$(azd env get-values)

    # Initialize variables
    AIProjectConnectionString=""
    StorageConnectionQueue=""

    # Parse the output to get the endpoint URLs
    while IFS= read -r line; do
        if [[ $line == *"PROJECT_CONNECTION_STRING"* ]]; then
            AIProjectConnectionString=$(echo "$line" | cut -d '=' -f 2 | tr -d '"')
        fi
        if [[ $line == *"STORAGE_CONNECTION__queueServiceUri"* ]]; then
            StorageConnectionQueue=$(echo "$line" | cut -d '=' -f 2 | tr -d '"')
        fi
    done <<< "$output"

    cat <<EOF > ./app/local.settings.json
{
    "IsEncrypted": "false",
    "Values": {
        "AzureWebJobsStorage": "UseDevelopmentStorage=true",
        "FUNCTIONS_WORKER_RUNTIME": "python",
        "PROJECT_CONNECTION_STRING": "$AIProjectConnectionString",
        "STORAGE_CONNECTION__queueServiceUri": "$StorageConnectionQueue"
    }
}
EOF

fi