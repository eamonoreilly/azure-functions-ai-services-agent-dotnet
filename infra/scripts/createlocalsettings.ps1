$ErrorActionPreference = "Stop"

if (-not (Test-Path ".\app\local.settings.json")) {

    $output = azd env get-values

    # Parse the output to get the endpoint values
    foreach ($line in $output) {
        if ($line -match "PROJECT_CONNECTION_STRING"){
            $AIProjectConnectionString = ($line -split "=")[1] -replace '"',''
        }
        if ($line -match "STORAGE_CONNECTION__queueServiceUri"){
            $StorageConnectionQueue = ($line -split "=")[1] -replace '"',''
        }
    }

    @{
        "IsEncrypted" = "false";
        "Values" = @{
            "AzureWebJobsStorage" = "UseDevelopmentStorage=true";
            "FUNCTIONS_WORKER_RUNTIME" = "python";
            "PROJECT_CONNECTION_STRING" = "$AIProjectConnectionString";
            "STORAGE_CONNECTION__queueServiceUri" = "$StorageConnectionQueue";
        }
    } | ConvertTo-Json | Out-File -FilePath ".\app\local.settings.json" -Encoding ascii
}