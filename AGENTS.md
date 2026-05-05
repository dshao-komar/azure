# ADF SharePoint Pipeline Runbook

This folder contains two PowerShell scripts that are intended to be run sequentially:

```powershell
. ./script1.ps1
./script2.ps1
```

Run them in the same `pwsh` session. `script1.ps1` loads `.env`, requests a Microsoft Graph app-only token, and exposes the token/config as global PowerShell variables. `script2.ps1` uses those variables to validate the Komar SharePoint file and create/update the Azure Data Factory assets.

## Goal

Create an Azure Data Factory pipeline that copies this SharePoint file:

```text
https://komaralliance.sharepoint.com/sites/KomarPublic/Shared%20Documents/PRODUCTION%20ORDERS.xlsx
```

To this Blob destination:

```text
20260401dshao/raw/sharepoint/PRODUCTION ORDERS.xlsx
```

## Environment

Working directory:

```text
/mnt/c/users/danshao/projects/azure
```

Required tools:

```bash
pwsh
az
```

Verified versions/environment during setup:

```text
pwsh: /usr/bin/pwsh
PowerShell: 7.6.1
az: /home/dsshao/.local/bin/az
```

Azure CLI was already logged in to:

```text
Tenant: Komar Alliance
Tenant ID: eff39737-e722-4258-93dd-f457dbb008d5
Subscription: Azure subscription 1
Subscription ID: 6624ec13-3826-43b2-8e45-077f9051b88f
User: dshao@komar.com
```

## Configuration

The `.env` file was normalized into `KEY=VALUE` format because the original file used human-readable Azure portal labels such as `Application (client) ID:` and `Value:`. That format was not reliable for script loading.

Required `.env` keys:

```text
AZURE_TENANT_ID
AZURE_CLIENT_ID
AZURE_CLIENT_SECRET
SHAREPOINT_SITE_URL
SHAREPOINT_LIBRARY
SHAREPOINT_FILE_PATH
AZURE_SUBSCRIPTION_ID
AZURE_RESOURCE_GROUP
ADF_FACTORY_NAME
STORAGE_ACCOUNT_NAME
STORAGE_CONTAINER
STORAGE_DESTINATION_PATH
ADF_PIPELINE_NAME
```

Discovered Azure resources:

```text
Resource group: RG1
Data Factory: 2026-04-01-DF1
Storage account: 20260401dshao
Blob container: raw
```

SharePoint resolution:

```text
Site: https://komaralliance.sharepoint.com/sites/KomarPublic
Document library requested: Shared Documents
Document library resolved by Graph: Documents
File: PRODUCTION ORDERS.xlsx
Graph-reported file size: 545421 bytes
```

## Script Flow

`script1.ps1`:

1. Loads `.env` from the script folder.
2. Validates Graph app credentials are present.
3. Requests a token from:

```text
https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token
```

4. Uses the client credentials scope:

```text
https://graph.microsoft.com/.default
```

5. Exposes:

```powershell
$global:AdfSharePointConfig
$global:GraphToken
$global:GraphHeaders
```

`script2.ps1`:

1. Dot-sources `script1.ps1` if the Graph token/config are not already loaded.
2. Validates all required `.env` values.
3. Resolves the SharePoint site through Microsoft Graph.
4. Lists site drives and finds the target document library.
5. Converts the SharePoint URL into a drive-relative path.
6. Confirms the target file exists through Graph.
7. Gets the storage account key through Azure CLI.
8. Gets an Azure Resource Manager token with `az account get-access-token`.
9. Uses direct ARM `Invoke-RestMethod` calls to create/update ADF resources.
10. Creates/updates:

```text
Linked service: LS_Graph_Http_Anonymous
Linked service: LS_Blob_20260401dshao
Dataset: DS_Graph_Komar_Production_Orders
Dataset: DS_Blob_Komar_Production_Orders
Pipeline: Copy_Komar_Production_Orders_From_SharePoint
```

## Barriers Overcome

PowerShell was initially unavailable in WSL. After `pwsh` was installed, the scripts could be run in the intended shell.

The original `script1.ps1` used placeholders:

```powershell
[EXTRACT_FROM_ENV_CONFIG_FILE]
```

It was changed to load real values from `.env`.

The original `.env` format was not parseable as environment config. It was converted to `KEY=VALUE` format so scripts can load values deterministically.

The original `script2.ps1` assumed `$token` existed from a previous script. That is fragile unless both scripts run in the same session. The scripts now use explicit global variables, and `script2.ps1` can dot-source `script1.ps1` if needed.

The Azure CLI in WSL is a wrapper around Windows PowerShell:

```bash
#!/usr/bin/env bash
exec powershell.exe -NoProfile -Command "& 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' @args" "$@"
```

This caused parsing failures with JMESPath queries and JSON bodies containing braces or `@file` references. Workarounds:

```text
Use plain JSON output instead of JMESPath queries when needed.
Use direct ARM Invoke-RestMethod calls from PowerShell instead of `az rest --body`.
```

The first deployed ADF pipeline used `RestSource` and a binary Blob sink. The manual run failed with:

```text
ErrorCode=UserErrorFormatIsRequired
Format setting is required for file based store(s) in this scenario.
```

The fix was to use ADF's HTTP binary copy pattern:

```text
Linked service type: HttpServer
Source dataset type: Binary
Source location type: HttpServerLocation
Copy source type: BinarySource
Copy source storeSettings type: HttpReadSettings
Copy source formatSettings type: BinaryReadSettings
Sink dataset type: Binary
Sink type: BinarySink
```

This matches Azure Data Factory guidance that binary copy should be binary-to-binary, and that the HTTP connector is appropriate for downloading files as-is.

Blob verification with Azure AD auth failed because the signed-in user did not have Blob data-plane RBAC:

```text
You do not have the required permissions needed to perform this operation.
```

The workaround was:

```bash
az storage blob list --account-name 20260401dshao --container-name raw --prefix sharepoint --auth-mode key --output json
```

That succeeded because the Azure login could retrieve the storage account key.

## Successful Run Evidence

Scripts completed successfully:

```text
Graph token acquired.
Token type: Bearer
Expires in: 3599
SharePoint site: https://komaralliance.sharepoint.com/sites/KomarPublic
Document library: Documents
Source file size: 545421
ADF factory: 2026-04-01-DF1
ADF pipeline: Copy_Komar_Production_Orders_From_SharePoint
Blob destination: 20260401dshao/raw/sharepoint/PRODUCTION ORDERS.xlsx
```

Manual ADF run:

```text
Run ID: 189bfa10-47fc-11f1-9e79-9cb150a3acae
Status: Succeeded
Duration: 38184 ms
```

Activity results:

```text
GetGraphToken: Succeeded
CopySharePointFileToBlob: Succeeded
Files read: 1
Files written: 1
Data read: 545421
Data written: 545421
Source: HttpServer
Sink: AzureBlobStorage
```

Blob verification:

```text
Container: raw
Blob: sharepoint/PRODUCTION ORDERS.xlsx
Content length: 545421
Blob type: BlockBlob
Created: 2026-05-04T20:59:44+00:00
Last modified: 2026-05-04T20:59:44+00:00
Content type: application/octet-stream
```

## Current Nightly SQL Load

The pipeline has been extended beyond the original Blob landing step. The current production flow is:

```text
Key Vault -> Graph token -> SharePoint workbook -> Blob landing -> DQ range check -> Graph workbook range -> SQL Script activity -> dbo.usp_load_sharepoint_prod_orders_batch
```

The ADF pipeline is still named:

```text
Copy_Komar_Production_Orders_From_SharePoint
```

The scheduled trigger is:

```text
tr_koprodorders_1130pm_pacific
Runtime state: Started
Schedule: daily at 23:30 Pacific Standard Time
```

Key Vault was added:

```text
Vault: kv-komar-adf-p21
Secrets:
- adf-graph-client-secret
- adf-blob-connection-string
```

ADF managed identity with object ID `0af32c1c-3833-4e5c-bd45-b5d7223d4d08` was granted Key Vault `get` and `list` permissions for secrets.

The SQL load does not create or alter SQL objects. The `SqlServer1` linked service user does not have `CREATE PROCEDURE` permission in `P21`, so wrapper logic is executed inline in the ADF Script activity and then calls the existing stored procedure:

```text
dbo.usp_load_sharepoint_prod_orders_batch
```

The inline SQL used by ADF is stored here:

```text
current_process_power_automate/load_sharepoint_prod_orders_batch_adf_inline.sql
```

Manual validation run:

```text
Run ID: 4bd13231-4806-11f1-ab49-9cb150a3acae
Status: Succeeded
Duration: 93155 ms
```

SQL result set from `LoadProductionOrdersToSql`:

```text
batch_id: 3b213345-5df3-4b6e-8724-8b0e49d4ebb0
source_file: sharepoint/PRODUCTION ORDERS.xlsx
cutoff_date: 2026-03-04
total_rows_received: 2312
rows_missing_key_parts: 7
rows_skipped_non_unique_key: 0
rows_skipped_by_date_filter: 1663
rows_inserted_to_staging: 649
```

Additional barriers overcome while implementing the SQL load:

```text
SQL DDL denied:
CREATE PROCEDURE permission denied in database 'P21'.
Resolution: Do not create a wrapper proc from ADF; run normalization inline and call the existing proc.

ADF Excel connector invalid header:
Invalid excel header with empty value at column 11.
Resolution: Avoid ADF Excel connector for this workbook.

ADF Excel connector date parsing:
Not a legal OleAut date.
Resolution: Use Microsoft Graph workbook range API instead of ADF Excel parsing.
```

The Graph workbook range endpoint currently reads:

```text
Sheet: PRODUCTION ORDER RECENT
Range: A1:H5000
```

This preserves `DATE COMPLETED` while bypassing ADF's Excel parser.

## Current Data Quality Control

The first data quality rule is:

```text
If column D / ORDER # is blank, do not load that row.
```

ADF now runs `FindBlankOrderRows` before `GetWorkbookRange`. The detection SQL is stored here:

```text
current_process_power_automate/find_blank_order_rows.sql
```

The query parses the Graph workbook `values` array for `A1:H5000`, skips the header row, ignores completely blank rows, and returns row numbers where column D is blank. It orders row numbers descending so the result can be used safely for row deletion later if SharePoint edit permissions are granted.

The initial implementation attempted to delete those rows from the source workbook through Microsoft Graph before `GetWorkbookRange`. Graph rejected that write with:

```text
EditModeAccessDenied: Contact the workbook owner to request edit access.
```

Resolution:

```text
Do not mutate the SharePoint workbook from ADF with the current app permissions.
Keep the pre-GetWorkbookRange DQ detection step for observability.
Filter blank ORDER # rows out of the normalized SQL payload before calling dbo.usp_load_sharepoint_prod_orders_batch.
```

The inline SQL filter is in:

```text
current_process_power_automate/load_sharepoint_prod_orders_batch_adf_inline.sql
```

Validation run after this control was added:

```text
Run ID: 6e0c1fdd-4809-11f1-a3c6-9cb150a3acae
Status: Succeeded
Duration: 136224 ms
```

`FindBlankOrderRows` found 5 rows with blank `ORDER #`:

```text
2239
1253
398
378
270
```

SQL result set from `LoadProductionOrdersToSql` after filtering:

```text
batch_id: d549b4f1-9a7a-4383-ae8a-70935990c191
source_file: sharepoint/PRODUCTION ORDERS.xlsx
cutoff_date: 2026-03-04
total_rows_received: 2307
rows_missing_key_parts: 2
rows_skipped_non_unique_key: 0
rows_skipped_by_date_filter: 1658
rows_inserted_to_staging: 649
```

Compared with the prior SQL validation run, `total_rows_received` dropped from `2312` to `2307`, matching the 5 blank-order rows that were excluded.

## Date Received Incremental Filter Fix

On 2026-05-05, order `8053475` was missing from `dbo.prod_orders_sharepoint` after ADF incremental runs, but appeared after the Power Automate manual full refresh.

Evidence from the current SharePoint workbook:

```text
Worksheet row: 2314
ITEM PRODUCED DESCRIPTION: 36X60/40 WHT BUTCHER 200
RUN DATE: blank
MACHINE: CUTTER
ORDER #: 8053475
DATE RCVD: 46143 / 2026-05-01
DATE COMPLETED: blank
```

Root cause:

```text
The stored proc incremental filter only used coalesce(actual_start_date, actual_end_date).
ADF mapped actual_start_date from RUN DATE and actual_end_date from DATE COMPLETED.
For 8053475, both were blank, so the incremental load skipped it.
The Power Automate full refresh passed @full_load = 1, bypassing the incremental date filter.
```

Resolution:

```text
ADF inline SQL now parses column E / DATE RCVD.
The incremental load filter uses coalesce(RUN DATE, DATE COMPLETED, DATE RCVD).
DATE RCVD is not stored into actual_start_date or actual_end_date; it is only used to decide whether the row is recent enough to load.
The ADF Script activity now performs the staging insert and merge inline rather than calling dbo.usp_load_sharepoint_prod_orders_batch, because the existing proc cannot accept a separate DATE RCVD filter column.
```

Validation run:

```text
Run ID: 113e2683-48b2-11f1-abe5-9cb150a3acae
Status: Succeeded
Duration: 160469 ms
```

SQL result set from `LoadProductionOrdersToSql`:

```text
batch_id: 4bac6058-9857-4cf5-aa4c-c8f62f3ef729
source_file: sharepoint/PRODUCTION ORDERS.xlsx
cutoff_date: 2026-03-05
total_rows_received: 2335
rows_missing_key_parts: 2
rows_skipped_non_unique_key: 0
rows_skipped_by_date_filter: 1590
rows_inserted_to_staging: 745
rows_loaded_by_date_received_only: 90
```

## Useful Commands

Run scripts sequentially:

```bash
pwsh -NoProfile -Command '. ./script1.ps1; ./script2.ps1'
```

Trigger the ADF pipeline:

```bash
az datafactory pipeline create-run \
  --resource-group RG1 \
  --factory-name 2026-04-01-DF1 \
  --name Copy_Komar_Production_Orders_From_SharePoint \
  --output json
```

Check a pipeline run:

```bash
az datafactory pipeline-run show \
  --resource-group RG1 \
  --factory-name 2026-04-01-DF1 \
  --run-id <run-id> \
  --output json
```

Check activity runs:

```bash
az datafactory activity-run query-by-pipeline-run \
  --resource-group RG1 \
  --factory-name 2026-04-01-DF1 \
  --run-id <run-id> \
  --last-updated-after 2026-05-04T20:59:00Z \
  --last-updated-before 2026-05-04T21:40:00Z \
  --output json
```

Verify Blob output:

```bash
az storage blob list \
  --account-name 20260401dshao \
  --container-name raw \
  --prefix sharepoint \
  --auth-mode key \
  --output json
```

## References

Azure Data Factory HTTP connector:

```text
https://learn.microsoft.com/en-us/azure/data-factory/connector-http
```

Azure Data Factory Binary format:

```text
https://learn.microsoft.com/en-us/azure/data-factory/format-binary
```
