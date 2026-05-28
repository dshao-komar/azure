param(
  [switch]$Live,
  [string]$ReceiptDatabase,
  [switch]$BypassMissingPoLine
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$envPath = Join-Path $repoRoot ".env"
if (-not (Test-Path $envPath)) {
  throw "Missing .env file at $envPath"
}

function Read-DotEnv {
  param([Parameter(Mandatory = $true)][string]$Path)

  $config = @{}
  Get-Content $Path | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith("#")) {
      return
    }

    $parts = $line.Split("=", 2)
    if ($parts.Count -ne 2) {
      return
    }

    $config[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'")
  }
  return $config
}

function Require-Config {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Config,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  foreach ($name in $Names) {
    if (-not $Config.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($Config[$name])) {
      throw "Missing required .env value: $name"
    }
  }
}

function Invoke-AzJson {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  $output = & az @Arguments --output json
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI failed: az $($Arguments -join ' ')"
  }
  if ([string]::IsNullOrWhiteSpace($output)) {
    return $null
  }
  return $output | ConvertFrom-Json
}

function Ensure-AzureProvider {
  param([Parameter(Mandatory = $true)][string]$Namespace)

  $provider = Invoke-AzJson -Arguments @("provider", "show", "--namespace", $Namespace)
  if ($provider.registrationState -eq "Registered") {
    return
  }

  Write-Host "Registering Azure provider $Namespace..."
  & az provider register --namespace $Namespace | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to start provider registration for $Namespace."
  }

  for ($attempt = 1; $attempt -le 30; $attempt++) {
    Start-Sleep -Seconds 10
    $provider = Invoke-AzJson -Arguments @("provider", "show", "--namespace", $Namespace)
    Write-Host "$Namespace registration state:" $provider.registrationState
    if ($provider.registrationState -eq "Registered") {
      return
    }
  }

  throw "Provider registration for $Namespace did not complete."
}

function Invoke-Graph {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body = $null
  )

  $headers = @{
    Authorization = "Bearer $script:GraphAccessToken"
  }

  if ($null -eq $Body) {
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
  }

  return Invoke-RestMethod `
    -Method $Method `
    -Uri $Uri `
    -Headers $headers `
    -ContentType "application/json" `
    -Body ($Body | ConvertTo-Json -Depth 20)
}

function Get-GraphToken {
  param([Parameter(Mandatory = $true)][hashtable]$Config)

  $body = @{
    client_id = $Config["AZURE_CLIENT_ID"]
    client_secret = $Config["AZURE_CLIENT_SECRET"]
    scope = "https://graph.microsoft.com/.default"
    grant_type = "client_credentials"
  }

  $token = Invoke-RestMethod `
    -Method Post `
    -Uri "https://login.microsoftonline.com/$($Config["AZURE_TENANT_ID"])/oauth2/v2.0/token" `
    -ContentType "application/x-www-form-urlencoded" `
    -Body $body

  return $token.access_token
}

function ConvertTo-GraphPath {
  param([Parameter(Mandatory = $true)][string]$SiteUrl)

  $uri = [Uri]$SiteUrl
  return "$($uri.Host):$($uri.AbsolutePath)"
}

function Find-SharePointDrive {
  param(
    [Parameter(Mandatory = $true)][string]$SiteUrl,
    [Parameter(Mandatory = $true)][string]$Library
  )

  $siteGraphPath = ConvertTo-GraphPath -SiteUrl $SiteUrl
  $site = Invoke-Graph -Method Get -Uri "https://graph.microsoft.com/v1.0/sites/$siteGraphPath"
  $drives = Invoke-Graph -Method Get -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/drives"
  $drive = $drives.value |
    Where-Object {
      $_.name -eq $Library -or
      $_.webUrl -like "*/$($Library.Replace(" ", "%20"))" -or
      $_.webUrl -like "*/$Library" -or
      ($Library -eq "Shared Documents" -and $_.name -eq "Documents")
    } |
    Select-Object -First 1

  if (-not $drive) {
    $drives.value | ForEach-Object { Write-Host "- $($_.name): $($_.webUrl)" }
    throw "Could not find SharePoint document library '$Library'."
  }

  return $drive
}

function Resolve-DriveFolder {
  param(
    [Parameter(Mandatory = $true)][string]$DriveId,
    [Parameter(Mandatory = $true)][string]$FolderPath
  )

  $encodedPath = ($FolderPath.Trim("/") -split "/" | ForEach-Object { [Uri]::EscapeDataString($_) }) -join "/"
  return Invoke-Graph -Method Get -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/$encodedPath"
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

function Set-AdfResource {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Config,
    [Parameter(Mandatory = $true)][string]$ResourcePath,
    [Parameter(Mandatory = $true)][hashtable]$Body
  )

  $uri = "https://management.azure.com/subscriptions/$($Config["AZURE_SUBSCRIPTION_ID"])/resourceGroups/$($Config["AZURE_RESOURCE_GROUP"])/providers/Microsoft.DataFactory/factories/$($Config["ADF_FACTORY_NAME"])/$ResourcePath`?api-version=2018-06-01"
  Invoke-RestMethod `
    -Method Put `
    -Uri $uri `
    -Headers (Get-ArmHeaders) `
    -ContentType "application/json" `
    -Body ($Body | ConvertTo-Json -Depth 100) | Out-Null
}

function Set-FunctionAppSettings {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Config,
    [Parameter(Mandatory = $true)][string]$FunctionAppName,
    [Parameter(Mandatory = $true)][hashtable]$Settings
  )

  $baseUri = "https://management.azure.com/subscriptions/$($Config["AZURE_SUBSCRIPTION_ID"])/resourceGroups/$($Config["AZURE_RESOURCE_GROUP"])/providers/Microsoft.Web/sites/$FunctionAppName"
  $listUri = "$baseUri/config/appsettings/list?api-version=2023-12-01"
  $putUri = "$baseUri/config/appsettings?api-version=2023-12-01"

  $current = Invoke-RestMethod `
    -Method Post `
    -Uri $listUri `
    -Headers (Get-ArmHeaders) `
    -ContentType "application/json"

  $properties = @{}
  if ($current.properties) {
    $current.properties.PSObject.Properties | ForEach-Object {
      $properties[$_.Name] = $_.Value
    }
  }

  foreach ($key in $Settings.Keys) {
    $properties[$key] = $Settings[$key]
  }

  Invoke-RestMethod `
    -Method Put `
    -Uri $putUri `
    -Headers (Get-ArmHeaders) `
    -ContentType "application/json" `
    -Body (@{ properties = $properties } | ConvertTo-Json -Depth 20) | Out-Null
}

function Get-FunctionHostKey {
  param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$FunctionAppName
  )

  $keys = Invoke-AzJson -Arguments @("functionapp", "keys", "list", "--resource-group", $ResourceGroup, "--name", $FunctionAppName)
  if ($keys.functionKeys.default) {
    return $keys.functionKeys.default
  }
  if ($keys.masterKey) {
    return $keys.masterKey
  }
  throw "Could not retrieve a function host key for $FunctionAppName."
}

function ConvertTo-AzCliPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  $wslPath = Get-Command wslpath -ErrorAction SilentlyContinue
  if ($wslPath) {
    $converted = & wslpath -w $Path
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($converted)) {
      return $converted.Trim()
    }
  }

  return $Path
}

$config = Read-DotEnv -Path $envPath
if (-not $Live) {
  $config["COATS_VALIDATION_EMAIL_TO"] = "dshao@komar.com"
  $config["COATS_VALIDATION_EMAIL_CC"] = ""
}
Require-Config -Config $config -Names @(
  "AZURE_TENANT_ID",
  "AZURE_CLIENT_ID",
  "AZURE_CLIENT_SECRET",
  "AZURE_SUBSCRIPTION_ID",
  "AZURE_RESOURCE_GROUP",
  "ADF_FACTORY_NAME",
  "SHAREPOINT_SITE_URL",
  "SHAREPOINT_LIBRARY",
  "STORAGE_ACCOUNT_NAME",
  "STORAGE_CONTAINER",
  "SQL_LINKED_SERVICE_NAME",
  "COATS_VALIDATION_EMAIL_FROM",
  "COATS_VALIDATION_EMAIL_TO"
)

$script:GraphAccessToken = Get-GraphToken -Config $config

Ensure-AzureProvider -Namespace "Microsoft.Web"

$location = if ($config.ContainsKey("AZURE_LOCATION")) { $config["AZURE_LOCATION"] } else { "westus" }
$functionAppName = if ($config.ContainsKey("COATS_FUNCTION_APP_NAME")) { $config["COATS_FUNCTION_APP_NAME"] } else { "func-coats-mexico-$($config["STORAGE_ACCOUNT_NAME"])" }
$pipelineName = if ($config.ContainsKey("COATS_ADF_PIPELINE_NAME")) { $config["COATS_ADF_PIPELINE_NAME"] } else { "Coats_Mexico_Shipment_Stage_And_Validate" }
$pipelineDisplayPrefix = ""
$targetDatabase = "P21Import"
$stagingDatabase = "P21Import"
if ($Live) {
  $pipelineName = "LIVE_Coats_Mexico_Shipment_Stage_And_Validate"
  $pipelineDisplayPrefix = "[LIVE] "
  $targetDatabase = "P21"
}
if (-not [string]::IsNullOrWhiteSpace($ReceiptDatabase)) {
  $targetDatabase = $ReceiptDatabase.Trim()
  if (-not $Live -and $targetDatabase -ne "P21Import") {
    $pipelineDisplayPrefix = "[TEST $targetDatabase] "
  }
}
$receiptActivityName = if ($Live) { "CreateP21Receipts" } else { "CreateP21ImportReceipts" }
$watchFolderPath = if ($config.ContainsKey("COATS_SHAREPOINT_FOLDER_PATH")) { $config["COATS_SHAREPOINT_FOLDER_PATH"] } else { "Coats Mexico Shipment Reports" }
$p21CreatedBy = if ($config.ContainsKey("COATS_P21_CREATED_BY")) { $config["COATS_P21_CREATED_BY"] } else { "ADF" }
$library = $config["SHAREPOINT_LIBRARY"]

Write-Host "Resolving SharePoint drive and folder..."
$drive = Find-SharePointDrive -SiteUrl $config["SHAREPOINT_SITE_URL"] -Library $library
$folder = Resolve-DriveFolder -DriveId $drive.id -FolderPath $watchFolderPath

Write-Host "Preparing storage connection string..."
$storageKey = Invoke-AzJson -Arguments @(
  "storage", "account", "keys", "list",
  "--resource-group", $config["AZURE_RESOURCE_GROUP"],
  "--account-name", $config["STORAGE_ACCOUNT_NAME"]
) | Select-Object -First 1

$rawStorageConnectionString = "DefaultEndpointsProtocol=https;AccountName=$($config["STORAGE_ACCOUNT_NAME"]);AccountKey=$($storageKey.value);EndpointSuffix=core.windows.net"

Write-Host "Ensuring Function App $functionAppName..."
try {
  Invoke-AzJson -Arguments @("functionapp", "show", "--resource-group", $config["AZURE_RESOURCE_GROUP"], "--name", $functionAppName) | Out-Null
} catch {
  Invoke-AzJson -Arguments @(
    "functionapp", "create",
    "--resource-group", $config["AZURE_RESOURCE_GROUP"],
    "--name", $functionAppName,
    "--storage-account", $config["STORAGE_ACCOUNT_NAME"],
    "--consumption-plan-location", $location,
    "--runtime", "python",
    "--runtime-version", "3.12",
    "--functions-version", "4",
    "--os-type", "Linux"
  ) | Out-Null
}

Invoke-AzJson -Arguments @("functionapp", "identity", "assign", "--resource-group", $config["AZURE_RESOURCE_GROUP"], "--name", $functionAppName) | Out-Null
$functionApp = Invoke-AzJson -Arguments @("functionapp", "show", "--resource-group", $config["AZURE_RESOURCE_GROUP"], "--name", $functionAppName)
$factoryScope = "/subscriptions/$($config["AZURE_SUBSCRIPTION_ID"])/resourceGroups/$($config["AZURE_RESOURCE_GROUP"])/providers/Microsoft.DataFactory/factories/$($config["ADF_FACTORY_NAME"])"

Write-Host "Ensuring Function App can start ADF pipeline..."
try {
  Invoke-AzJson -Arguments @(
    "role", "assignment", "create",
    "--assignee-object-id", $functionApp.identity.principalId,
    "--assignee-principal-type", "ServicePrincipal",
    "--role", "b24988ac-6180-42a0-ab88-20f7382dd24c",
    "--scope", $factoryScope
  ) | Out-Null
} catch {
  Write-Host "Role assignment may already exist; continuing."
}

Write-Host "Configuring Function App settings..."
Set-FunctionAppSettings -Config $config -FunctionAppName $functionAppName -Settings @{
  ADF_SUBSCRIPTION_ID = $config["AZURE_SUBSCRIPTION_ID"]
  ADF_RESOURCE_GROUP = $config["AZURE_RESOURCE_GROUP"]
  ADF_FACTORY_NAME = $config["ADF_FACTORY_NAME"]
  ADF_PIPELINE_NAME = $pipelineName
  GRAPH_TENANT_ID = $config["AZURE_TENANT_ID"]
  GRAPH_CLIENT_ID = $config["AZURE_CLIENT_ID"]
  GRAPH_CLIENT_SECRET = $config["AZURE_CLIENT_SECRET"]
  GRAPH_DRIVE_ID = $drive.id
  GRAPH_WATCH_FOLDER_ITEM_ID = $folder.id
  SHAREPOINT_WATCH_FOLDER_PATH = $watchFolderPath
  RAW_STORAGE_CONNECTION_STRING = $rawStorageConnectionString
  RAW_STORAGE_CONTAINER = $config["STORAGE_CONTAINER"]
  COATS_VALIDATION_EMAIL_FROM = $config["COATS_VALIDATION_EMAIL_FROM"]
  COATS_VALIDATION_EMAIL_TO = $config["COATS_VALIDATION_EMAIL_TO"]
  COATS_VALIDATION_EMAIL_CC = if ($config.ContainsKey("COATS_VALIDATION_EMAIL_CC")) { $config["COATS_VALIDATION_EMAIL_CC"] } else { "" }
  COATS_PIPELINE_DISPLAY_PREFIX = $pipelineDisplayPrefix
  COATS_TARGET_DATABASE = $targetDatabase
  COATS_STAGING_DATABASE = $stagingDatabase
  AzureWebJobsFeatureFlags = "EnableWorkerIndexing"
  SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
  ENABLE_ORYX_BUILD = "true"
}

Write-Host "Packaging Function App..."
$packageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "coats_mexico_function_package"
$packageZip = Join-Path ([System.IO.Path]::GetTempPath()) "coats_mexico_function_package.zip"
if (Test-Path $packageRoot) { Remove-Item -Recurse -Force $packageRoot }
if (Test-Path $packageZip) { Remove-Item -Force $packageZip }
New-Item -ItemType Directory -Path $packageRoot | Out-Null
Copy-Item (Join-Path $PSScriptRoot "azure_function/host.json") $packageRoot
Copy-Item (Join-Path $PSScriptRoot "azure_function/requirements.txt") $packageRoot
Copy-Item (Join-Path $PSScriptRoot "azure_function/function_app.py") $packageRoot
Copy-Item (Join-Path $PSScriptRoot "azure_function/coats_function_common.py") $packageRoot
Copy-Item (Join-Path $PSScriptRoot "azure_function/GraphSharePointNotification") $packageRoot -Recurse
Copy-Item (Join-Path $PSScriptRoot "azure_function/ProcessCoatsWorkbook") $packageRoot -Recurse
Copy-Item (Join-Path $PSScriptRoot "azure_function/SendCoatsValidationEmail") $packageRoot -Recurse
Copy-Item (Join-Path $PSScriptRoot "azure_function/SendCoatsSuccessEmail") $packageRoot -Recurse
Copy-Item (Join-Path $PSScriptRoot "src/extract_coats_mexico_workbook.py") (Join-Path $packageRoot "extract_coats_mexico_workbook.py")

Write-Host "Installing Python dependencies into package..."
$sitePackagesPath = Join-Path $packageRoot ".python_packages/lib/site-packages"
New-Item -ItemType Directory -Path $sitePackagesPath -Force | Out-Null
$pythonCommand = Get-Command python3, python -ErrorAction SilentlyContinue |
  Where-Object { $_.Source -notlike "*\WindowsApps\*" } |
  Select-Object -First 1
$pythonArgs = @()
if (-not $pythonCommand) {
  $pythonCommand = Get-Command py -ErrorAction SilentlyContinue | Select-Object -First 1
  $pythonArgs = @("-3")
}
if (-not $pythonCommand) {
  throw "Python was not found. Install Python or add it to PATH before deploying."
}

$pipPlatformArgs = @(
  "--platform", "manylinux2014_x86_64",
  "--implementation", "cp",
  "--python-version", "3.12",
  "--only-binary=:all:"
)

& $pythonCommand.Source @pythonArgs -m pip install `
  --disable-pip-version-check `
  --no-input `
  @pipPlatformArgs `
  --target $sitePackagesPath `
  -r (Join-Path $PSScriptRoot "azure_function/requirements.txt") | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Python dependency installation failed."
}

$env:PACKAGE_ROOT = $packageRoot
$env:PACKAGE_ZIP = $packageZip
@'
import os
import zipfile

root = os.environ["PACKAGE_ROOT"]
zip_path = os.environ["PACKAGE_ZIP"]

with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
    for dirpath, _, filenames in os.walk(root):
        for filename in filenames:
            path = os.path.join(dirpath, filename)
            arcname = os.path.relpath(path, root).replace(os.sep, "/")
            archive.write(path, arcname)
'@ | & $pythonCommand.Source @pythonArgs -
if ($LASTEXITCODE -ne 0) {
  throw "Function package zip creation failed."
}

Write-Host "Deploying Function App package..."
$packageZipForAz = ConvertTo-AzCliPath -Path $packageZip
Invoke-AzJson -Arguments @(
  "functionapp", "deployment", "source", "config-zip",
  "--resource-group", $config["AZURE_RESOURCE_GROUP"],
  "--name", $functionAppName,
  "--src", $packageZipForAz
) | Out-Null

$functionKey = Get-FunctionHostKey -ResourceGroup $config["AZURE_RESOURCE_GROUP"] -FunctionAppName $functionAppName
$processUrl = "https://$functionAppName.azurewebsites.net/api/process-coats-workbook?code=$functionKey"
$validationEmailUrl = "https://$functionAppName.azurewebsites.net/api/send-coats-validation-email?code=$functionKey"
$successEmailUrl = "https://$functionAppName.azurewebsites.net/api/send-coats-success-email?code=$functionKey"
$notificationUrl = "https://$functionAppName.azurewebsites.net/api/graph-sharepoint-notification?code=$functionKey"

Write-Host "Creating/updating ADF pipeline $pipelineName..."
$stagingSqlPath = Join-Path $PSScriptRoot "sql/main/001_create_coats_mexico_staging.sql"
$stagingSqlText = Get-Content -Raw -Path $stagingSqlPath
$stagingBatches = [regex]::Split($stagingSqlText, "(?im)^\s*GO\s*$")
$stagingDdlText = $stagingBatches[0]
$stagingProcText = $stagingBatches[1]
$procBeginMatch = [regex]::Match($stagingProcText, "(?is)\bAS\s*BEGIN\s*")
if (-not $procBeginMatch.Success) {
  throw "Could not find procedure body in $stagingSqlPath."
}
$stageBody = $stagingProcText.Substring($procBeginMatch.Index + $procBeginMatch.Length)
$lastEndIndex = $stageBody.LastIndexOf("END;")
if ($lastEndIndex -lt 0) {
  throw "Could not find final END in staging procedure body."
}
$stageBody = $stageBody.Substring(0, $lastEndIndex)
$stageScript = @"
USE P21Import;

$stagingDdlText

DECLARE @payload nvarchar(max) = @extraction_payload;

$stageBody
"@

$validationSqlPath = Join-Path $PSScriptRoot "sql/main/002_validate_coats_mexico_staging_from_p21.sql"
$validationSqlText = Get-Content -Raw -Path $validationSqlPath
$validationSqlText = [regex]::Replace($validationSqlText, "(?im)^\s*USE\s+P21Import\s*;\s*$", "")
$validationSqlText = [regex]::Replace($validationSqlText, "(?im)^\s*GO\s*$", "")
$validationSqlText = [regex]::Replace(
  $validationSqlText,
  "(?im)^\s*DECLARE\s+@ShipmentFileId\s+uniqueidentifier\s*=\s*'00000000-0000-0000-0000-000000000000'\s*;\s*$",
  "SET @ShipmentFileId = TRY_CONVERT(uniqueidentifier, JSON_VALUE(@extractionPayload, '$.metadata.shipment_file_id'));"
)
$validationSqlText = [regex]::Replace(
  $validationSqlText,
  "(?is)IF\s+@ShipmentFileId\s*=\s*'00000000-0000-0000-0000-000000000000'\s*BEGIN\s*THROW\s+50000,\s*'Set @ShipmentFileId before running validation\.',\s*1;\s*END;",
  "IF @ShipmentFileId IS NULL`nBEGIN`n    THROW 50000, 'Extractor payload metadata.shipment_file_id is missing or invalid.', 1;`nEND;"
)
if ($BypassMissingPoLine) {
  $validationSqlText = [regex]::Replace(
    $validationSqlText,
    "(?im)^\s*DECLARE\s+@BypassMissingPoLine\s+bit\s*=\s*0\s*;\s*$",
    "DECLARE @BypassMissingPoLine bit = 1;"
  )
}
if ($targetDatabase -ne "P21Import") {
  $validationSqlText = [regex]::Replace($validationSqlText, "(?i)(\bFROM\s+)dbo\.(document_line_bin|inventory_supplier|inv_mast|po_line)\b", "`${1}$targetDatabase.dbo.`$2")
  $validationSqlText = [regex]::Replace($validationSqlText, "(?i)(\bJOIN\s+)dbo\.(document_line_bin|inventory_supplier|inv_mast|po_line)\b", "`${1}$targetDatabase.dbo.`$2")
}
$validationScript = @"
USE P21Import;

DECLARE @extractionPayload nvarchar(max) = @extraction_payload;
DECLARE @ShipmentFileId uniqueidentifier = TRY_CONVERT(uniqueidentifier, JSON_VALUE(@extractionPayload, '$.metadata.shipment_file_id'));

$validationSqlText
"@

$receiptSqlPath = Join-Path $PSScriptRoot "sql/main/004_create_coats_mexico_p21import_receipts.sql"
$receiptSqlText = Get-Content -Raw -Path $receiptSqlPath
$receiptBatches = [regex]::Split($receiptSqlText, "(?im)^\s*GO\s*$")
$receiptDdlText = ($receiptBatches | Where-Object {
  $_ -notmatch "(?is)CREATE\s+OR\s+ALTER\s+PROCEDURE\s+dbo\.usp_create_coats_mexico_p21import_receipts"
} | ForEach-Object {
  [regex]::Replace($_, "(?im)^\s*USE\s+P21Import\s*;\s*$", "")
}) -join "`n"
$receiptProcText = ($receiptBatches | Where-Object {
  $_ -match "(?is)CREATE\s+OR\s+ALTER\s+PROCEDURE\s+dbo\.usp_create_coats_mexico_p21import_receipts"
}) | Select-Object -First 1
$receiptProcBeginMatch = [regex]::Match($receiptProcText, "(?is)\bAS\s*BEGIN\s*")
if (-not $receiptProcBeginMatch.Success) {
  throw "Could not find receipt procedure body in $receiptSqlPath."
}
$receiptBody = $receiptProcText.Substring($receiptProcBeginMatch.Index + $receiptProcBeginMatch.Length)
$receiptLastEndIndex = $receiptBody.LastIndexOf("END;")
if ($receiptLastEndIndex -lt 0) {
  throw "Could not find final END in receipt procedure body."
}
$receiptBody = $receiptBody.Substring(0, $receiptLastEndIndex)
if ($Live) {
  $receiptDdlText = $receiptDdlText `
    -replace "Create Coats Mexico P21Import receipt records from validated staging rows\.", "Create Coats Mexico P21 receipt records from validated P21Import staging rows." `
    -replace "Run in P21Import\. This script intentionally does not use the P21 database and\s+does not insert document_line_bin rows\.", "Stage audit DDL runs in P21Import; receipt inserts run in P21. This script does not insert document_line_bin rows."
  $receiptBody = $receiptBody `
    -replace "DB_NAME\(\) <> 'P21Import'", "DB_NAME() <> 'P21'" `
    -replace "This procedure must run in the P21Import database\.", "This receipt script must run in the P21 database." `
    -replace "Missing required P21Import column", "Missing required P21 column" `
    -replace "required P21Import target columns", "required P21 target columns" `
    -replace "P21Import receipt records", "P21 receipt records" `
    -replace "\bdbo\.(coats_mexico_shipment_receipt_build|coats_mexico_shipment_file|coats_mexico_shipment_validation_issue|coats_mexico_shipment_pallet_line|coats_mexico_shipment_raw_line)\b", "P21Import.dbo.`$1"
}
elseif ($targetDatabase -ne "P21Import") {
  $receiptDdlText = $receiptDdlText `
    -replace "Create Coats Mexico P21Import receipt records from validated staging rows\.", "Create Coats Mexico $targetDatabase receipt records from validated P21Import staging rows." `
    -replace "Run in P21Import\. This script intentionally does not use the P21 database and\s+does not insert document_line_bin rows\.", "Stage audit DDL runs in P21Import; receipt inserts run in $targetDatabase. This script does not insert document_line_bin rows."
  $receiptBody = $receiptBody `
    -replace "DB_NAME\(\) <> 'P21Import'", "DB_NAME() <> '$targetDatabase'" `
    -replace "This procedure must run in the P21Import database\.", "This receipt script must run in the $targetDatabase database." `
    -replace "Missing required P21Import column", "Missing required $targetDatabase column" `
    -replace "required P21Import target columns", "required $targetDatabase target columns" `
    -replace "P21Import receipt records", "$targetDatabase receipt records" `
    -replace "\bdbo\.(coats_mexico_shipment_receipt_build|coats_mexico_shipment_file|coats_mexico_shipment_validation_issue|coats_mexico_shipment_pallet_line|coats_mexico_shipment_raw_line)\b", "P21Import.dbo.`$1"
}
$receiptDatabase = $targetDatabase
$receiptScript = @"
USE P21Import;

$receiptDdlText

USE $receiptDatabase;

DECLARE @extractionPayload nvarchar(max) = @extraction_payload;
DECLARE @ShipmentFileId uniqueidentifier = TRY_CONVERT(uniqueidentifier, JSON_VALUE(@extractionPayload, '$.metadata.shipment_file_id'));
DECLARE @CreatedBy nvarchar(30) = @created_by;
DECLARE @ReceiptDate date = NULL;
DECLARE @AllowExisting bit = 1;

$receiptBody
"@

$extractRawScript = $null
$successEmailDependencyName = $receiptActivityName
if ($Live) {
  $extractRawSqlPath = Join-Path $PSScriptRoot "sql/main/005_extract_raw_file.sql"
  $extractRawSqlText = Get-Content -Raw -Path $extractRawSqlPath
  $extractRawSqlText = [regex]::Replace(
    $extractRawSqlText,
    "(?im)^\s*DECLARE\s+@ShipmentFileId\s+uniqueidentifier\s*=\s*'00000000-0000-0000-0000-000000000000'\s*;\s*$",
    "DECLARE @ShipmentFileId uniqueidentifier = TRY_CONVERT(uniqueidentifier, JSON_VALUE(@extractionPayload, '$.metadata.shipment_file_id'));"
  )
  $extractRawSqlText = [regex]::Replace(
    $extractRawSqlText,
    "(?is)IF\s+@ShipmentFileId\s*=\s*'00000000-0000-0000-0000-000000000000'\s*BEGIN\s*THROW\s+53000,\s*'Set @ShipmentFileId before running the raw file extract\.',\s*1;\s*END;",
    "IF @ShipmentFileId IS NULL`nBEGIN`n    THROW 53000, 'Extractor payload metadata.shipment_file_id is missing or invalid.', 1;`nEND;"
  )
  $extractRawScript = @"
USE P21;

DECLARE @extractionPayload nvarchar(max) = @extraction_payload;

$extractRawSqlText
"@
  $successEmailDependencyName = "ExtractRawFileForEmail"
}

Set-AdfResource -Config $config -ResourcePath "pipelines/$pipelineName" -Body @{
  properties = @{
    parameters = @{
      sharePointDriveId = @{ type = "String" }
      sharePointDriveItemId = @{ type = "String" }
      sourceFileName = @{ type = "String" }
      sourceWebUrl = @{ type = "String" }
      sourceFolderPath = @{ type = "String" }
      graphSubscriptionId = @{ type = "String" }
      notificationReceivedUtc = @{ type = "String" }
    }
    activities = @(
      @{
        name = "ProcessCoatsWorkbook"
        type = "WebActivity"
        dependsOn = @()
        policy = @{
          timeout = "0.00:10:00"
          retry = 1
          retryIntervalInSeconds = 30
          secureInput = $true
          secureOutput = $false
        }
        typeProperties = @{
          method = "POST"
          url = $processUrl
          headers = @{
            "Content-Type" = "application/json"
          }
          body = @{
            value = "@json(concat('{', '""sharePointDriveId"":""', pipeline().parameters.sharePointDriveId, '"",', '""sharePointDriveItemId"":""', pipeline().parameters.sharePointDriveItemId, '"",', '""sourceFileName"":""', replace(pipeline().parameters.sourceFileName, '""', '\""'), '"",', '""sourceWebUrl"":""', replace(pipeline().parameters.sourceWebUrl, '""', '\""'), '"",', '""sourceFolderPath"":""', replace(pipeline().parameters.sourceFolderPath, '""', '\""'), '"",', '""pipelineRunId"":""', pipeline().RunId, '""', '}'))"
            type = "Expression"
          }
        }
      },
      @{
        name = "StageCoatsShipmentJson"
        type = "Script"
        dependsOn = @(
          @{
            activity = "ProcessCoatsWorkbook"
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
              text = $stageScript
              parameters = @(
                @{
                  name = "extraction_payload"
                  value = @{
                    value = "@string(activity('ProcessCoatsWorkbook').output.extraction)"
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
        name = "ValidateCoatsShipment"
        type = "Script"
        dependsOn = @(
          @{
            activity = "StageCoatsShipmentJson"
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
              text = $validationScript
              parameters = @(
                @{
                  name = "extraction_payload"
                  value = @{
                    value = "@string(activity('ProcessCoatsWorkbook').output.extraction)"
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
        name = "IfBlockingValidationIssues"
        type = "IfCondition"
        dependsOn = @(
          @{
            activity = "ValidateCoatsShipment"
            dependencyConditions = @("Succeeded")
          }
        )
        typeProperties = @{
          expression = @{
            type = "Expression"
            value = "@greater(int(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].blocking_issue_count), 0)"
          }
          ifTrueActivities = @(
            @{
              name = "SendBlockingValidationEmail"
              type = "WebActivity"
              dependsOn = @()
              policy = @{
                timeout = "0.00:05:00"
                retry = 1
                retryIntervalInSeconds = 30
                secureInput = $true
                secureOutput = $false
              }
              typeProperties = @{
                method = "POST"
                url = $validationEmailUrl
                headers = @{
                  "Content-Type" = "application/json"
                }
                body = @{
                  type = "Expression"
                  value = "@json(concat('{', '""sourceFileName"":""', replace(coalesce(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].source_file_name, ''), '""', '\""'), '"",', '""sourceWebUrl"":""', replace(coalesce(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].source_web_url, ''), '""', '\""'), '"",', '""shipmentFileId"":""', string(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].shipment_file_id), '"",', '""shipmentDate"":""', string(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].shipment_date), '"",', '""trailerName"":""', replace(coalesce(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].trailer_name, ''), '""', '\""'), '"",', '""pipelineRunId"":""', pipeline().RunId, '"",', '""pipelineDisplayPrefix"":""$pipelineDisplayPrefix"",', '""targetDatabase"":""$targetDatabase"",', '""stagingDatabase"":""$stagingDatabase"",', '""blockingIssueCount"":', string(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].blocking_issue_count), ',', '""issues"":', activity('ValidateCoatsShipment').output.resultSets[2].rows[0].issue_json, '}'))"
                }
              }
            },
            @{
              name = "FailBlockingValidation"
              type = "Fail"
              dependsOn = @(
                @{
                  activity = "SendBlockingValidationEmail"
                  dependencyConditions = @("Succeeded")
                }
              )
              typeProperties = @{
                errorCode = "COATS_BLOCKING_VALIDATION"
                message = @{
                  type = "Expression"
                  value = "@concat('$pipelineDisplayPrefix', 'Coats Mexico shipment has ', string(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].blocking_issue_count), ' blocking validation issue(s). Email notification sent; $targetDatabase receipts were not created.')"
                }
              }
            }
          )
          ifFalseActivities = @(
            @{
              name = $receiptActivityName
              type = "Script"
              dependsOn = @()
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
                    text = $receiptScript
                    parameters = @(
                      @{
                        name = "extraction_payload"
                        value = @{
                          value = "@string(activity('ProcessCoatsWorkbook').output.extraction)"
                          type = "Expression"
                        }
                        type = "String"
                        direction = "Input"
                      },
                      @{
                        name = "created_by"
                        value = $p21CreatedBy
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
              name = "SendSuccessEmail"
              type = "WebActivity"
              dependsOn = @(
                @{
                  activity = $successEmailDependencyName
                  dependencyConditions = @("Succeeded")
                }
              )
              policy = @{
                timeout = "0.00:05:00"
                retry = 1
                retryIntervalInSeconds = 30
                secureInput = $true
                secureOutput = $false
              }
              typeProperties = @{
                method = "POST"
                url = $successEmailUrl
                headers = @{
                  "Content-Type" = "application/json"
                }
                body = @{
                  type = "Expression"
                  value = if ($Live) {
                    "@json(concat('{', '""sourceFileName"":""', replace(coalesce(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].source_file_name, ''), '""', '\""'), '"",', '""sourceWebUrl"":""', replace(coalesce(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].source_web_url, ''), '""', '\""'), '"",', '""shipmentFileId"":""', string(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].shipment_file_id), '"",', '""shipmentDate"":""', string(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].shipment_date), '"",', '""trailerName"":""', replace(coalesce(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].trailer_name, ''), '""', '\""'), '"",', '""pipelineRunId"":""', pipeline().RunId, '"",', '""pipelineDisplayPrefix"":""$pipelineDisplayPrefix"",', '""targetDatabase"":""$targetDatabase"",', '""stagingDatabase"":""$stagingDatabase"",', '""receipt"":', string(activity('$receiptActivityName').output.resultSets[0].rows[0]), ',', '""rawFileAttachmentName"":""', replace(concat('coats-mexico-raw-extract-', coalesce(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].trailer_name, 'shipment'), '-', string(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].shipment_date), '.csv'), '""', '\""'), '"",', '""rawFileRows"":', if(equals(activity('ExtractRawFileForEmail').output.resultSetCount, 0), '[]', string(activity('ExtractRawFileForEmail').output.resultSets[0].rows)), '}'))"
                  } else {
                    "@json(concat('{', '""sourceFileName"":""', replace(coalesce(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].source_file_name, ''), '""', '\""'), '"",', '""sourceWebUrl"":""', replace(coalesce(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].source_web_url, ''), '""', '\""'), '"",', '""shipmentFileId"":""', string(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].shipment_file_id), '"",', '""shipmentDate"":""', string(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].shipment_date), '"",', '""trailerName"":""', replace(coalesce(activity('ValidateCoatsShipment').output.resultSets[0].rows[0].trailer_name, ''), '""', '\""'), '"",', '""pipelineRunId"":""', pipeline().RunId, '"",', '""pipelineDisplayPrefix"":""$pipelineDisplayPrefix"",', '""targetDatabase"":""$targetDatabase"",', '""stagingDatabase"":""$stagingDatabase"",', '""receipt"":', string(activity('$receiptActivityName').output.resultSets[0].rows[0]), '}'))"
                  }
                }
              }
            }
          )
        }
      }
    )
  }
}

Write-Host "Registering Microsoft Graph subscription..."
$existingSubscriptions = Invoke-Graph -Method Get -Uri "https://graph.microsoft.com/v1.0/subscriptions"
foreach ($existing in $existingSubscriptions.value) {
  if ($existing.resource -eq "drives/$($drive.id)/root" -and $existing.notificationUrl -like "https://$functionAppName.azurewebsites.net/*") {
    Write-Host "Deleting existing Graph subscription $($existing.id)..."
    Invoke-Graph -Method Delete -Uri "https://graph.microsoft.com/v1.0/subscriptions/$($existing.id)" | Out-Null
  }
}

$expiration = (Get-Date).ToUniversalTime().AddDays(25).ToString("yyyy-MM-ddTHH:mm:ssZ")
$subscription = Invoke-Graph -Method Post -Uri "https://graph.microsoft.com/v1.0/subscriptions" -Body @{
  changeType = "updated"
  notificationUrl = $notificationUrl
  resource = "drives/$($drive.id)/root"
  expirationDateTime = $expiration
  clientState = [Guid]::NewGuid().ToString()
}

$subscriptionOutputPath = Join-Path $PSScriptRoot "graph_subscription.json"
$subscription | ConvertTo-Json -Depth 20 | Set-Content -Path $subscriptionOutputPath -Encoding UTF8

Write-Host "Deployment complete."
Write-Host "Function App: $functionAppName"
Write-Host "ADF pipeline: $pipelineName"
Write-Host "SharePoint drive: $($drive.name) / $($drive.id)"
Write-Host "Watch folder: $watchFolderPath / $($folder.id)"
Write-Host "Graph subscription id: $($subscription.id)"
Write-Host "Graph subscription saved to: $subscriptionOutputPath"
