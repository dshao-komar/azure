param(
  [string]$WorkbookPath = "Coats Mexico Shipment Report 04.17.26 - Trailer TM672.xlsx",
  [string]$SharePointFolderPath = "Coats Mexico Shipment Reports",
  [switch]$UseAzLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$envPath = Join-Path $repoRoot ".env"
if (-not (Test-Path $envPath)) {
  throw "Missing .env file at $envPath"
}

$config = @{}
Get-Content $envPath | ForEach-Object {
  $line = $_.Trim()
  if (-not $line -or $line.StartsWith("#")) {
    return
  }

  $parts = $line.Split("=", 2)
  if ($parts.Count -eq 2) {
    $config[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'")
  }
}

foreach ($requiredName in @("AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET", "SHAREPOINT_SITE_URL", "SHAREPOINT_LIBRARY")) {
  if (-not $config.ContainsKey($requiredName) -or [string]::IsNullOrWhiteSpace($config[$requiredName])) {
    throw "Missing required .env value: $requiredName"
  }
}

$resolvedWorkbookPath = Resolve-Path $WorkbookPath
$fileName = Split-Path $resolvedWorkbookPath -Leaf

if ($UseAzLogin) {
  $azTokenJson = & az account get-access-token --resource-type ms-graph --output json
  if ($LASTEXITCODE -ne 0) {
    throw "Could not get Microsoft Graph token from Azure CLI login."
  }
  $accessToken = ($azTokenJson | ConvertFrom-Json).accessToken
} else {
  $token = Invoke-RestMethod `
    -Method Post `
    -Uri "https://login.microsoftonline.com/$($config["AZURE_TENANT_ID"])/oauth2/v2.0/token" `
    -ContentType "application/x-www-form-urlencoded" `
    -Body @{
      client_id = $config["AZURE_CLIENT_ID"]
      client_secret = $config["AZURE_CLIENT_SECRET"]
      scope = "https://graph.microsoft.com/.default"
      grant_type = "client_credentials"
    }
  $accessToken = $token.access_token
}

$headers = @{
  Authorization = "Bearer $accessToken"
}

$siteUri = [Uri]$config["SHAREPOINT_SITE_URL"]
$siteGraphPath = "$($siteUri.Host):$($siteUri.AbsolutePath)"
$site = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/sites/$siteGraphPath"
$drives = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/drives"

$library = $config["SHAREPOINT_LIBRARY"]
$drive = $drives.value |
  Where-Object {
    $_.name -eq $library -or
    $_.webUrl -like "*/$($library.Replace(" ", "%20"))" -or
    $_.webUrl -like "*/$library" -or
    ($library -eq "Shared Documents" -and $_.name -eq "Documents")
  } |
  Select-Object -First 1

if (-not $drive) {
  throw "Could not resolve SharePoint drive for library '$library'."
}

$encodedFolder = ($SharePointFolderPath.Trim("/") -split "/" | ForEach-Object { [Uri]::EscapeDataString($_) }) -join "/"
$encodedFile = [Uri]::EscapeDataString($fileName)
$uploadUri = "https://graph.microsoft.com/v1.0/drives/$($drive.id)/root:/$encodedFolder/$encodedFile`:/content"

$result = Invoke-RestMethod `
  -Method Put `
  -Uri $uploadUri `
  -Headers $headers `
  -InFile $resolvedWorkbookPath `
  -ContentType "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

$result |
  Select-Object id, name, webUrl, size, createdDateTime, lastModifiedDateTime |
  ConvertTo-Json -Depth 5
