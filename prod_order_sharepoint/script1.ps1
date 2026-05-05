Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$envPath = Join-Path $PSScriptRoot ".env"
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
  if ($parts.Count -ne 2) {
    return
  }

  $name = $parts[0].Trim()
  $value = $parts[1].Trim().Trim('"').Trim("'")
  $config[$name] = $value
}

foreach ($requiredName in @("AZURE_TENANT_ID", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET")) {
  if (-not $config.ContainsKey($requiredName) -or [string]::IsNullOrWhiteSpace($config[$requiredName])) {
    throw "Missing required .env value: $requiredName"
  }
}

$body = @{
  client_id     = $config["AZURE_CLIENT_ID"]
  client_secret = $config["AZURE_CLIENT_SECRET"]
  scope         = "https://graph.microsoft.com/.default"
  grant_type    = "client_credentials"
}

$token = Invoke-RestMethod `
  -Method Post `
  -Uri "https://login.microsoftonline.com/$($config["AZURE_TENANT_ID"])/oauth2/v2.0/token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body $body

$headers = @{
  Authorization = "Bearer $($token.access_token)"
}

$global:AdfSharePointConfig = $config
$global:GraphToken = $token
$global:GraphHeaders = $headers

Write-Host "Graph token acquired."
Write-Host "Token type:" $token.token_type
Write-Host "Expires in:" $token.expires_in
