Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Variable -Name GraphToken -Scope Global -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot "script1.ps1")
}

$config = $global:AdfSharePointConfig
$headers = $global:GraphHeaders

foreach ($requiredName in @(
  "SHAREPOINT_SITE_URL",
  "SHAREPOINT_FILE_PATH",
  "AZURE_SUBSCRIPTION_ID",
  "AZURE_RESOURCE_GROUP",
  "ADF_FACTORY_NAME",
  "STORAGE_ACCOUNT_NAME",
  "STORAGE_CONTAINER",
  "STORAGE_DESTINATION_PATH",
  "ADF_PIPELINE_NAME",
  "KEYVAULT_NAME",
  "KEYVAULT_GRAPH_SECRET_NAME",
  "KEYVAULT_BLOB_CONNECTION_SECRET_NAME",
  "SQL_LINKED_SERVICE_NAME",
  "SQL_WRAPPER_PROC_NAME",
  "EXCEL_SHEET_NAME",
  "EXCEL_RANGE",
  "ADF_TRIGGER_NAME",
  "ADF_TRIGGER_TIME_ZONE",
  "ADF_TRIGGER_HOUR",
  "ADF_TRIGGER_MINUTE"
)) {
  if (-not $config.ContainsKey($requiredName) -or [string]::IsNullOrWhiteSpace($config[$requiredName])) {
    throw "Missing required .env value: $requiredName"
  }
}

function ConvertTo-GraphPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SiteUrl
  )

  $uri = [Uri]$SiteUrl
  return "$($uri.Host):$($uri.AbsolutePath)"
}

function ConvertTo-SharePointDrivePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SiteUrl,
    [Parameter(Mandatory = $true)]
    [string]$FilePathOrUrl,
    [Parameter(Mandatory = $true)]
    [string]$Library
  )

  if ($FilePathOrUrl -match "^https?://") {
    $siteUri = [Uri]$SiteUrl
    $fileUri = [Uri]$FilePathOrUrl
    $sitePath = [Uri]::UnescapeDataString($siteUri.AbsolutePath.TrimEnd("/"))
    $filePath = [Uri]::UnescapeDataString($fileUri.AbsolutePath)

    if (-not $filePath.StartsWith("$sitePath/", [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "SHAREPOINT_FILE_PATH is not under SHAREPOINT_SITE_URL."
    }

    $relativePath = $filePath.Substring($sitePath.Length).TrimStart("/")
  } else {
    $relativePath = [Uri]::UnescapeDataString($FilePathOrUrl.TrimStart("/"))
  }

  $libraryPrefix = $Library.Trim("/")
  if ($relativePath.StartsWith("$libraryPrefix/", [System.StringComparison]::OrdinalIgnoreCase)) {
    $relativePath = $relativePath.Substring($libraryPrefix.Length).TrimStart("/")
  }

  return $relativePath
}

function Invoke-GraphGet {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri
  )

  return Invoke-RestMethod -Headers $headers -Uri $Uri
}

function Invoke-AzJson {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & az @Arguments --output json
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI failed: az $($Arguments -join ' ')"
  }

  if ([string]::IsNullOrWhiteSpace($output)) {
    return $null
  }

  return $output | ConvertFrom-Json
}

function Get-ArmHeaders {
  if (-not (Get-Variable -Name ArmHeaders -Scope Script -ErrorAction SilentlyContinue)) {
    $armToken = Invoke-AzJson -Arguments @("account", "get-access-token", "--resource", "https://management.azure.com/")
    $script:ArmHeaders = @{
      Authorization = "Bearer $($armToken.accessToken)"
    }
  }

  return $script:ArmHeaders
}

function Get-KeyVaultHeaders {
  if (-not (Get-Variable -Name KeyVaultHeaders -Scope Script -ErrorAction SilentlyContinue)) {
    $vaultToken = Invoke-AzJson -Arguments @("account", "get-access-token", "--resource", "https://vault.azure.net")
    $script:KeyVaultHeaders = @{
      Authorization = "Bearer $($vaultToken.accessToken)"
    }
  }

  return $script:KeyVaultHeaders
}

function Set-KeyVaultSecret {
  param(
    [Parameter(Mandatory = $true)]
    [string]$VaultName,
    [Parameter(Mandatory = $true)]
    [string]$SecretName,
    [Parameter(Mandatory = $true)]
    [string]$SecretValue
  )

  $uri = "https://$VaultName.vault.azure.net/secrets/$SecretName`?api-version=7.4"
  $json = @{
    value = $SecretValue
  } | ConvertTo-Json -Depth 10

  Invoke-RestMethod `
    -Method Put `
    -Uri $uri `
    -Headers (Get-KeyVaultHeaders) `
    -ContentType "application/json" `
    -Body $json | Out-Null
}

function Set-AdfResource {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResourcePath,
    [Parameter(Mandatory = $true)]
    [hashtable]$Body
  )

  $uri = "https://management.azure.com/subscriptions/$($config["AZURE_SUBSCRIPTION_ID"])/resourceGroups/$($config["AZURE_RESOURCE_GROUP"])/providers/Microsoft.DataFactory/factories/$($config["ADF_FACTORY_NAME"])/$ResourcePath`?api-version=2018-06-01"
  $json = $Body | ConvertTo-Json -Depth 100
  Invoke-RestMethod `
    -Method Put `
    -Uri $uri `
    -Headers (Get-ArmHeaders) `
    -ContentType "application/json" `
    -Body $json | Out-Null
}

function Invoke-AdfAction {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResourcePath,
    [Parameter(Mandatory = $true)]
    [string]$Action
  )

  $uri = "https://management.azure.com/subscriptions/$($config["AZURE_SUBSCRIPTION_ID"])/resourceGroups/$($config["AZURE_RESOURCE_GROUP"])/providers/Microsoft.DataFactory/factories/$($config["ADF_FACTORY_NAME"])/$ResourcePath/$Action`?api-version=2018-06-01"
  Invoke-RestMethod -Method Post -Uri $uri -Headers (Get-ArmHeaders) | Out-Null
}

function Ensure-KeyVaultProvider {
  $provider = Invoke-AzJson -Arguments @("provider", "show", "--namespace", "Microsoft.KeyVault")
  if ($provider.registrationState -ne "Registered") {
    Write-Host "Registering Microsoft.KeyVault provider..."
    & az provider register --namespace Microsoft.KeyVault | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to start Microsoft.KeyVault provider registration."
    }

    $registered = $false
    for ($attempt = 1; $attempt -le 30; $attempt++) {
      Start-Sleep -Seconds 10
      $provider = Invoke-AzJson -Arguments @("provider", "show", "--namespace", "Microsoft.KeyVault")
      if ($provider.registrationState -eq "Registered") {
        $registered = $true
        break
      }
      Write-Host "Microsoft.KeyVault registration state:" $provider.registrationState
    }

    if (-not $registered) {
      throw "Microsoft.KeyVault provider registration did not complete."
    }
  }
}

function Ensure-KeyVault {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BlobConnectionString
  )

  Ensure-KeyVaultProvider

  $vaultName = $config["KEYVAULT_NAME"]
  $factory = Invoke-AzJson -Arguments @(
    "datafactory", "show",
    "--resource-group", $config["AZURE_RESOURCE_GROUP"],
    "--factory-name", $config["ADF_FACTORY_NAME"]
  )

  try {
    Invoke-AzJson -Arguments @("keyvault", "show", "--name", $vaultName) | Out-Null
  } catch {
    Write-Host "Creating Key Vault $vaultName..."
    Invoke-AzJson -Arguments @(
      "keyvault", "create",
      "--name", $vaultName,
      "--resource-group", $config["AZURE_RESOURCE_GROUP"],
      "--location", "westus",
      "--enable-rbac-authorization", "false"
    ) | Out-Null
  }

  Invoke-AzJson -Arguments @(
    "keyvault", "set-policy",
    "--name", $vaultName,
    "--object-id", $factory.identity.principalId,
    "--secret-permissions", "get", "list"
  ) | Out-Null

  Set-KeyVaultSecret `
    -VaultName $vaultName `
    -SecretName $config["KEYVAULT_GRAPH_SECRET_NAME"] `
    -SecretValue $config["AZURE_CLIENT_SECRET"]

  Set-KeyVaultSecret `
    -VaultName $vaultName `
    -SecretName $config["KEYVAULT_BLOB_CONNECTION_SECRET_NAME"] `
    -SecretValue $BlobConnectionString
}

$siteGraphPath = ConvertTo-GraphPath -SiteUrl $config["SHAREPOINT_SITE_URL"]
$site = Invoke-GraphGet -Uri "https://graph.microsoft.com/v1.0/sites/$siteGraphPath"
$drives = Invoke-GraphGet -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/drives"

$library = if ($config.ContainsKey("SHAREPOINT_LIBRARY") -and -not [string]::IsNullOrWhiteSpace($config["SHAREPOINT_LIBRARY"])) {
  $config["SHAREPOINT_LIBRARY"]
} else {
  "Shared Documents"
}

$drive = $drives.value |
  Where-Object {
    $_.name -eq $library -or
    $_.webUrl -like "*/$($library.Replace(" ", "%20"))" -or
    $_.webUrl -like "*/$library"
  } |
  Select-Object -First 1

if (-not $drive) {
  Write-Host "Available document libraries:"
  $drives.value | ForEach-Object { Write-Host "- $($_.name): $($_.webUrl)" }
  throw "Could not find SharePoint document library '$library'."
}

$driveRelativePath = ConvertTo-SharePointDrivePath `
  -SiteUrl $config["SHAREPOINT_SITE_URL"] `
  -FilePathOrUrl $config["SHAREPOINT_FILE_PATH"] `
  -Library $library

$encodedDrivePath = ($driveRelativePath -split "/" | ForEach-Object { [Uri]::EscapeDataString($_) }) -join "/"
$fileItem = Invoke-GraphGet -Uri "https://graph.microsoft.com/v1.0/drives/$($drive.id)/root:/$encodedDrivePath"

$storageKey = Invoke-AzJson -Arguments @(
  "storage", "account", "keys", "list",
  "--resource-group", $config["AZURE_RESOURCE_GROUP"],
  "--account-name", $config["STORAGE_ACCOUNT_NAME"]
) | Select-Object -First 1

if (-not $storageKey.value) {
  throw "Could not retrieve a storage account key for $($config["STORAGE_ACCOUNT_NAME"])."
}

$destination = $config["STORAGE_DESTINATION_PATH"].Trim("/")
$destinationFolder = Split-Path $destination -Parent
$destinationFile = Split-Path $destination -Leaf
if ([string]::IsNullOrWhiteSpace($destinationFolder)) {
  $destinationFolder = "."
}

$blobConnectionString = "DefaultEndpointsProtocol=https;AccountName=$($config["STORAGE_ACCOUNT_NAME"]);AccountKey=$($storageKey.value);EndpointSuffix=core.windows.net"
Ensure-KeyVault -BlobConnectionString $blobConnectionString

$keyVaultLinkedServiceName = "LS_KeyVault_Komar_ADF_P21"
$graphLinkedServiceName = "LS_Graph_Http_Anonymous"
$blobLinkedServiceName = "LS_Blob_$($config["STORAGE_ACCOUNT_NAME"])"
$sourceDatasetName = "DS_Graph_Komar_Production_Orders"
$sinkDatasetName = "DS_Blob_Komar_Production_Orders"
$excelDatasetName = "DS_Excel_Komar_Production_Order_Recent"
$sqlLoadPath = Join-Path $PSScriptRoot "current_process_power_automate/load_sharepoint_prod_orders_batch_adf_inline.sql"
$sqlLoadText = Get-Content -Raw -Path $sqlLoadPath
$findBlankOrderRowsPath = Join-Path $PSScriptRoot "current_process_power_automate/find_blank_order_rows.sql"
$findBlankOrderRowsText = Get-Content -Raw -Path $findBlankOrderRowsPath

Set-AdfResource -ResourcePath "linkedservices/$keyVaultLinkedServiceName" -Body @{
  properties = @{
    type = "AzureKeyVault"
    typeProperties = @{
      baseUrl = "https://$($config["KEYVAULT_NAME"]).vault.azure.net/"
    }
  }
}

Set-AdfResource -ResourcePath "linkedservices/$graphLinkedServiceName" -Body @{
  properties = @{
    type = "HttpServer"
    typeProperties = @{
      url = "https://graph.microsoft.com/v1.0/"
      enableServerCertificateValidation = $true
      authenticationType = "Anonymous"
    }
  }
}

Set-AdfResource -ResourcePath "linkedservices/$blobLinkedServiceName" -Body @{
  properties = @{
    type = "AzureBlobStorage"
    typeProperties = @{
      connectionString = @{
        type = "AzureKeyVaultSecret"
        store = @{
          referenceName = $keyVaultLinkedServiceName
          type = "LinkedServiceReference"
        }
        secretName = $config["KEYVAULT_BLOB_CONNECTION_SECRET_NAME"]
      }
    }
  }
}

Set-AdfResource -ResourcePath "datasets/$sourceDatasetName" -Body @{
  properties = @{
    linkedServiceName = @{
      referenceName = $graphLinkedServiceName
      type = "LinkedServiceReference"
    }
    type = "Binary"
    typeProperties = @{
      location = @{
        type = "HttpServerLocation"
        relativeUrl = "drives/$($drive.id)/items/$($fileItem.id)/content"
      }
    }
  }
}

Set-AdfResource -ResourcePath "datasets/$sinkDatasetName" -Body @{
  properties = @{
    linkedServiceName = @{
      referenceName = $blobLinkedServiceName
      type = "LinkedServiceReference"
    }
    type = "Binary"
    typeProperties = @{
      location = @{
        type = "AzureBlobStorageLocation"
        container = $config["STORAGE_CONTAINER"]
        folderPath = $destinationFolder
        fileName = $destinationFile
      }
    }
  }
}

Set-AdfResource -ResourcePath "datasets/$excelDatasetName" -Body @{
  properties = @{
    linkedServiceName = @{
      referenceName = $blobLinkedServiceName
      type = "LinkedServiceReference"
    }
    type = "Excel"
    typeProperties = @{
      location = @{
        type = "AzureBlobStorageLocation"
        container = $config["STORAGE_CONTAINER"]
        folderPath = $destinationFolder
        fileName = $destinationFile
      }
      sheetName = $config["EXCEL_SHEET_NAME"]
      range = $config["EXCEL_RANGE"]
      firstRowAsHeader = $true
    }
  }
}

$encodedClientId = [Uri]::EscapeDataString($config["AZURE_CLIENT_ID"])
$encodedScope = [Uri]::EscapeDataString("https://graph.microsoft.com/.default")
$secretUrl = "https://$($config["KEYVAULT_NAME"]).vault.azure.net/secrets/$($config["KEYVAULT_GRAPH_SECRET_NAME"])?api-version=7.4"
$encodedSheetName = [Uri]::EscapeDataString($config["EXCEL_SHEET_NAME"])
$encodedExcelRange = [Uri]::EscapeDataString($config["EXCEL_RANGE"]).Replace("%3A", ":")
$workbookRangeUrl = "https://graph.microsoft.com/v1.0/drives/$($drive.id)/items/$($fileItem.id)/workbook/worksheets/$encodedSheetName/range(address=%27$encodedExcelRange%27)"
$sourceFileForSql = $config["STORAGE_DESTINATION_PATH"]

Set-AdfResource -ResourcePath "pipelines/$($config["ADF_PIPELINE_NAME"])" -Body @{
  properties = @{
    activities = @(
      @{
        name = "GetGraphClientSecret"
        type = "WebActivity"
        dependsOn = @()
        policy = @{
          timeout = "0.00:10:00"
          retry = 1
          retryIntervalInSeconds = 30
          secureInput = $true
          secureOutput = $true
        }
        typeProperties = @{
          method = "GET"
          url = $secretUrl
          authentication = @{
            type = "MSI"
            resource = "https://vault.azure.net"
          }
        }
      },
      @{
        name = "GetGraphToken"
        type = "WebActivity"
        dependsOn = @(
          @{
            activity = "GetGraphClientSecret"
            dependencyConditions = @("Succeeded")
          }
        )
        policy = @{
          timeout = "0.00:10:00"
          retry = 1
          retryIntervalInSeconds = 30
          secureInput = $true
          secureOutput = $true
        }
        typeProperties = @{
          method = "POST"
          url = "https://login.microsoftonline.com/$($config["AZURE_TENANT_ID"])/oauth2/v2.0/token"
          headers = @{
            "Content-Type" = "application/x-www-form-urlencoded"
          }
          body = @{
            value = "@concat('client_id=$encodedClientId&client_secret=', uriComponent(activity('GetGraphClientSecret').output.value), '&scope=$encodedScope&grant_type=client_credentials')"
            type = "Expression"
          }
        }
      },
      @{
        name = "CopySharePointFileToBlob"
        type = "Copy"
        dependsOn = @(
          @{
            activity = "GetGraphToken"
            dependencyConditions = @("Succeeded")
          }
        )
        policy = @{
          timeout = "0.12:00:00"
          retry = 1
          retryIntervalInSeconds = 30
          secureInput = $true
          secureOutput = $false
        }
        inputs = @(
          @{
            referenceName = $sourceDatasetName
            type = "DatasetReference"
          }
        )
        outputs = @(
          @{
            referenceName = $sinkDatasetName
            type = "DatasetReference"
          }
        )
        typeProperties = @{
          source = @{
            type = "BinarySource"
            storeSettings = @{
              type = "HttpReadSettings"
              requestMethod = "GET"
              httpRequestTimeout = "00:01:40"
              additionalHeaders = @{
                value = "@concat('Authorization: Bearer ', activity('GetGraphToken').output.access_token)"
                type = "Expression"
              }
            }
            formatSettings = @{
              type = "BinaryReadSettings"
            }
          }
          sink = @{
            type = "BinarySink"
            storeSettings = @{
              type = "AzureBlobStorageWriteSettings"
            }
          }
          enableStaging = $false
        }
      },
      @{
        name = "GetDataQualityRange"
        type = "WebActivity"
        dependsOn = @(
          @{
            activity = "CopySharePointFileToBlob"
            dependencyConditions = @("Succeeded")
          }
        )
        policy = @{
          timeout = "0.00:10:00"
          retry = 0
          retryIntervalInSeconds = 30
          secureInput = $true
          secureOutput = $true
        }
        typeProperties = @{
          method = "GET"
          url = $workbookRangeUrl
          headers = @{
            Authorization = @{
              value = "@concat('Bearer ', activity('GetGraphToken').output.access_token)"
              type = "Expression"
            }
          }
        }
      },
      @{
        name = "FindBlankOrderRows"
        type = "Script"
        dependsOn = @(
          @{
            activity = "GetDataQualityRange"
            dependencyConditions = @("Succeeded")
          }
        )
        policy = @{
          timeout = "0.00:10:00"
          retry = 0
          retryIntervalInSeconds = 30
          secureInput = $true
          secureOutput = $false
        }
        linkedServiceName = @{
          referenceName = $config["SQL_LINKED_SERVICE_NAME"]
          type = "LinkedServiceReference"
        }
        typeProperties = @{
          scripts = @(
            @{
              type = "Query"
              text = $findBlankOrderRowsText
              parameters = @(
                @{
                  name = "payload"
                  value = @{
                    value = "@string(activity('GetDataQualityRange').output)"
                    type = "Expression"
                  }
                  type = "String"
                  direction = "Input"
                }
              )
            }
          )
          scriptBlockExecutionTimeout = "00:10:00"
          logSettings = @{
            logDestination = "ActivityOutput"
          }
        }
      },
      @{
        name = "GetWorkbookRange"
        type = "WebActivity"
        dependsOn = @(
          @{
            activity = "FindBlankOrderRows"
            dependencyConditions = @("Succeeded")
          }
        )
        policy = @{
          timeout = "0.00:10:00"
          retry = 0
          retryIntervalInSeconds = 30
          secureInput = $true
          secureOutput = $true
        }
        typeProperties = @{
          method = "GET"
          url = $workbookRangeUrl
          headers = @{
            Authorization = @{
              value = "@concat('Bearer ', activity('GetGraphToken').output.access_token)"
              type = "Expression"
            }
          }
        }
      },
      @{
        name = "LoadProductionOrdersToSql"
        type = "Script"
        dependsOn = @(
          @{
            activity = "GetWorkbookRange"
            dependencyConditions = @("Succeeded")
          }
        )
        policy = @{
          timeout = "0.00:30:00"
          retry = 0
          retryIntervalInSeconds = 30
          secureInput = $true
          secureOutput = $false
        }
        linkedServiceName = @{
          referenceName = $config["SQL_LINKED_SERVICE_NAME"]
          type = "LinkedServiceReference"
        }
        typeProperties = @{
          scripts = @(
            @{
              type = "Query"
              text = $sqlLoadText
              parameters = @(
                @{
                  name = "payload"
                  value = @{
                    value = "@string(activity('GetWorkbookRange').output)"
                    type = "Expression"
                  }
                  type = "String"
                  direction = "Input"
                },
                @{
                  name = "source_file"
                  value = $sourceFileForSql
                  type = "String"
                  direction = "Input"
                },
                @{
                  name = "full_load"
                  value = $false
                  type = "Boolean"
                  direction = "Input"
                }
              )
            }
          )
          scriptBlockExecutionTimeout = "00:30:00"
          logSettings = @{
            logDestination = "ActivityOutput"
          }
        }
      }
    )
  }
}

$triggerHour = [int]$config["ADF_TRIGGER_HOUR"]
$triggerMinute = [int]$config["ADF_TRIGGER_MINUTE"]
$triggerStartTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$triggerResourcePath = "triggers/$($config["ADF_TRIGGER_NAME"])"

try {
  Invoke-AdfAction -ResourcePath $triggerResourcePath -Action "stop"
  Start-Sleep -Seconds 5
} catch {
  Write-Host "Trigger was not stopped before update, likely because it does not exist yet."
}

Set-AdfResource -ResourcePath $triggerResourcePath -Body @{
  properties = @{
    type = "ScheduleTrigger"
    pipelines = @(
      @{
        pipelineReference = @{
          referenceName = $config["ADF_PIPELINE_NAME"]
          type = "PipelineReference"
        }
        parameters = @{}
      }
    )
    typeProperties = @{
      recurrence = @{
        frequency = "Day"
        interval = 1
        startTime = $triggerStartTime
        timeZone = $config["ADF_TRIGGER_TIME_ZONE"]
        schedule = @{
          hours = @($triggerHour)
          minutes = @($triggerMinute)
        }
      }
    }
  }
}

Invoke-AdfAction -ResourcePath $triggerResourcePath -Action "start"

Write-Host "SharePoint site:" $site.webUrl
Write-Host "Document library:" $drive.name
Write-Host "Source file:" $fileItem.webUrl
Write-Host "Source file size:" $fileItem.size
Write-Host "ADF factory:" $config["ADF_FACTORY_NAME"]
Write-Host "ADF pipeline:" $config["ADF_PIPELINE_NAME"]
Write-Host "Excel sheet:" $config["EXCEL_SHEET_NAME"]
Write-Host "Excel range:" $config["EXCEL_RANGE"]
Write-Host "SQL linked service:" $config["SQL_LINKED_SERVICE_NAME"]
Write-Host "SQL load mode: inline normalization, date-received incremental filter, staging merge"
Write-Host "Blob destination:" "$($config["STORAGE_ACCOUNT_NAME"])/$($config["STORAGE_CONTAINER"])/$destination"
Write-Host "Trigger started:" $config["ADF_TRIGGER_NAME"] "at $triggerHour`:$("{0:D2}" -f $triggerMinute)" $config["ADF_TRIGGER_TIME_ZONE"]
