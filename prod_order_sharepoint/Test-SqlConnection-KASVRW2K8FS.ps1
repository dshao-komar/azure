param(
  [string]$Server = "KASVRW2K12P21",
  [string]$Database = "P21",
  [string]$UserName = "crystal",
  [int]$Port = 1433,
  [int]$TimeoutSeconds = 15,
  [switch]$UseIntegratedSecurity,
  [switch]$SkipTcpCheck
)

$ErrorActionPreference = "Stop"

function ConvertTo-PlainText {
  param([System.Security.SecureString]$SecureString)

  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
  try {
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Test-TcpPort {
  param(
    [string]$ComputerName,
    [int]$PortNumber,
    [int]$TimeoutMilliseconds
  )

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect($ComputerName, $PortNumber, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
      throw "TCP connection timed out after $TimeoutMilliseconds ms."
    }

    $client.EndConnect($async)
    $true
  } finally {
    $client.Close()
  }
}

Write-Host "SQL connection test"
Write-Host "Machine:" $env:COMPUTERNAME
Write-Host "Server:" $Server
Write-Host "Database:" $Database
Write-Host "Port:" $Port

try {
  $addresses = [System.Net.Dns]::GetHostAddresses($Server)
  Write-Host "DNS resolved:" (($addresses | ForEach-Object { $_.IPAddressToString }) -join ", ")
} catch {
  Write-Warning "DNS resolution failed for '$Server': $($_.Exception.Message)"
}

if (-not $SkipTcpCheck) {
  Write-Host "Testing TCP $Server`:$Port ..."
  [void](Test-TcpPort -ComputerName $Server -PortNumber $Port -TimeoutMilliseconds ($TimeoutSeconds * 1000))
  Write-Host "TCP check succeeded."
}

$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$builder["Data Source"] = $Server
$builder["Initial Catalog"] = $Database
$builder["Connect Timeout"] = $TimeoutSeconds
$builder["Encrypt"] = $true
$builder["TrustServerCertificate"] = $true
$builder["Application Name"] = "ADF SHIR SQL connectivity test"

if ($UseIntegratedSecurity) {
  $builder["Integrated Security"] = $true
  Write-Host "Authentication: Windows integrated"
} else {
  $securePassword = Read-Host "Password for SQL user '$UserName'" -AsSecureString
  $plainPassword = ConvertTo-PlainText -SecureString $securePassword
  $builder["User ID"] = $UserName
  $builder["Password"] = $plainPassword
  Write-Host "Authentication: SQL user $UserName"
}

$connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
try {
  Write-Host "Opening SQL connection ..."
  $connection.Open()
  Write-Host "SQL connection succeeded."

  $command = $connection.CreateCommand()
  $command.CommandTimeout = $TimeoutSeconds
  $command.CommandText = @"
select
  @@SERVERNAME as server_name,
  db_name() as database_name,
  suser_sname() as login_name,
  original_login() as original_login_name,
  getdate() as sql_server_time;
"@

  $reader = $command.ExecuteReader()
  try {
    if ($reader.Read()) {
      Write-Host "Server name:" $reader["server_name"]
      Write-Host "Database:" $reader["database_name"]
      Write-Host "Login:" $reader["login_name"]
      Write-Host "Original login:" $reader["original_login_name"]
      Write-Host "SQL server time:" $reader["sql_server_time"]
    }
  } finally {
    $reader.Close()
  }

  exit 0
} catch {
  Write-Error "SQL connection test failed: $($_.Exception.Message)"
  exit 1
} finally {
  if ($connection.State -ne "Closed") {
    $connection.Close()
  }

  if (Get-Variable -Name plainPassword -Scope Local -ErrorAction SilentlyContinue) {
    $plainPassword = $null
  }
}
