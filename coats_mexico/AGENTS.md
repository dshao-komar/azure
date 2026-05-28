# Coats Mexico Shipment Pipeline Plan

## Goal

Create an event-driven pipeline for Coats Mexico shipment workbooks. When Mary or the vendor drops a new shipment `.xlsx` file into the Komar Public SharePoint folder, the pipeline should land the raw workbook, extract and validate the shipment detail, parse pallet quantity comments, and stage normalized rows for P21 receipt creation.

The end-state business process is:

```text
Source vendor workbook -> Blob raw landing -> workbook extraction -> comment-based pallet split -> SQL staging/validation -> P21 container -> P21 vessel receipt -> P21 container receipt
```

For the first implementation, stop after SQL staging and validation. Do not automatically create P21 container, vessel receipt, or container receipt records until the staged data and rules are proven.

## SharePoint Source

The existing Komar Public SharePoint site resolves the library as `Documents`. This pipeline watches this folder:

```text
Documents/Coats Mexico Shipment Reports
```

Only new `.xlsx` files should trigger processing. Ignore Excel lock/temp files such as:

```text
~$*.xlsx
```

## Event Notification

Use Microsoft Graph change notifications for the SharePoint drive/folder and route notifications to an Azure Function.

Initial implementation scaffold:

```text
azure_function/function_app.py
azure_function/requirements.txt
azure_function/host.json
```

The Azure Function should:

1. Receive Graph change notifications.
2. Validate the notification.
3. Resolve changed drive items.
4. Filter to newly added `.xlsx` files in `Documents/Coats Mexico Shipment Reports`.
5. Ignore temp files such as `~$Detalle Expo Komar 04.17.26.xlsx`.
6. Start the ADF pipeline with the SharePoint drive item ID, file name, web URL, source folder, and received timestamp.

Do not use a time-based ADF trigger for this pipeline.

## File Naming and Shipment Metadata

Mary currently emails the shipment metadata. Example email subject:

```text
Coats Mexico Shipment Report 04/17/26 - Trailer TM672
```

Going forward, require the dropped workbook filename to include the shipment date and trailer name so the event-driven process can parse metadata without a separate email. Recommended filename format:

```text
Coats Mexico Shipment Report 04.17.26 - Trailer TM672.xlsx
```

Parse:

```text
shipment_date = 2026-04-17
trailer_name = TM672
```

Estimate arrival as the closest next Friday after the truck-left-Mexico shipment date.

If the filename does not contain a parseable shipment date and trailer name, fail validation before SQL staging/P21 writes and report the file as needing manual correction.

## Raw Landing

Download the `.xlsx` file from SharePoint using the existing app-only Microsoft Graph file download pattern.

Land the original workbook unchanged in Blob storage for audit/replay. Use a deterministic path that includes the received date and source file name, for example:

```text
raw/coats-mexico/YYYY/MM/DD/<original-file-name>
```

## Workbook Extraction

Sample workbook:

```text
Detalle Expo Komar 04.17.26.xlsx
```

Relevant worksheet:

```text
Material Detail
```

The column header row is not fixed. Usually headers start on row 8, but the sample file has headers on row 9 because a row was inserted.

Dynamically detect the header row by finding these required headers in the same row:

```text
PALLET
MATERIAL
INVOICED QTY
No. PEDIDO CLIENTE
```

Required mapping:

```text
PALLET             -> Bin_ID
MATERIAL           -> Item_ID
INVOICED QTY       -> Invoiced_Qty
No. PEDIDO CLIENTE -> PO_No
```

Normalize extracted rows with at least:

```text
source_file
source_sheet
source_row_number
trailer_name
shipment_date
estimated_arrival_date
Bin_ID
Item_ID
Invoiced_Qty
PO_No
raw_pallet_comment
pipeline_run_id
loaded_at_utc
```

Store normalized rows in SQL staging because the downstream P21 validation and receipt logic is SQL-heavy. Blob CSV/JSON output can be added as an audit artifact, but SQL staging is the primary integration surface.

Initial dependency-free extractor:

```text
src/extract_coats_mexico_workbook.py
```

## Workbook Comment Parsing Strategy

Do not use the Microsoft Graph workbook comments API. It is not needed, and it does not fit the current app-only auth pattern.

An `.xlsx` file is a zip package containing XML parts. The sample workbook stores pallet breakdown comments in:

```text
xl/threadedComments/threadedComment1.xml
xl/comments1.xml
```

Preferred extraction order:

1. Parse threaded comments from `xl/threadedComments/*.xml`.
2. Fall back to legacy comments from `xl/comments*.xml` if needed.

Each comment includes a cell reference, for example:

```xml
<threadedComment ref="A10">...</threadedComment>
```

Map the comment reference back to the worksheet row and join it to the pallet cell for that row.

Confirmed sample comments:

```text
A10 -> pallet value O-8, O-11
A17 -> pallet value O-12, O-13
```

For single-pallet rows, use the spreadsheet row quantity directly.

For multi-pallet rows such as:

```text
O-8, O-11
```

parse the attached comment text for pallet-level quantities. Example comment text from the sample:

```text
Pallet #8 with 44 box, 1386 cones
Pallet #9 with 44 box 1382 cones
Pallet #10 with 44 box 1374 cones
Pallet #11 with 26 box 826 cones
```

The parser should extract pallet identifiers and usable quantities into child rows. Preserve the raw comment text for audit.

If a multi-pallet row has no comment, or the comment cannot be parsed into pallet/quantity pairs, fail validation before any P21 write.

When the comment provides quantities in a unit compatible with `INVOICED QTY`, validate that parsed child quantities sum back to the source row quantity. If the comment quantity unit is not compatible, stage the parsed pallet detail and flag the row for review instead of guessing.

## Validation Rules

Validate before any P21 write:

1. Required worksheet exists: `Material Detail`.
2. Required headers are found dynamically.
3. Required row values are present for pallet, item, PO, and quantity.
4. Multi-pallet rows have parseable pallet breakdown comments.
5. Parsed pallet quantities reconcile to source row quantity when the units are compatible.
6. Supplier part maps to a valid Komar item for supplier `40408`.
7. PO line exists for the parsed PO and supplier part/item.
8. Duplicate supplier part mappings are flagged.
9. Missing supplier part mappings are flagged.
10. Canceled PO lines are flagged.
11. Invalid bin IDs are flagged.

Reuse the existing SQL logic in `Coats transfer truck Procedure.sql` as the starting point for supplier/PO validation and deduplication.

Rows needing review should be returned in a clear validation result set with source file, row number, item, PO, pallet value, comment text, and reason.

## SQL Staging and Transformation

Create stable staging tables instead of shipment-specific tables such as:

```text
P21Import.dbo.coats_mexico_truck_2026_04_17
P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24
```

Recommended staging layers:

```text
P21Import.dbo.coats_mexico_shipment_file
P21Import.dbo.coats_mexico_shipment_raw_line
P21Import.dbo.coats_mexico_shipment_pallet_line
P21Import.dbo.coats_mexico_shipment_validation_issue
```

The first implementation should insert staged rows and validation results only. It should not create or update production P21 receipt records.

Initial SQL implementation:

```text
sql/main/001_create_coats_mexico_staging.sql
sql/main/002_validate_coats_mexico_staging_from_p21.sql
```

## P21 Container Building

Later implementation should replace manual container-building steps with a parameterized stored procedure wrapper.

Inputs should include:

```text
shipment_file_id
trailer_name
shipment_date
estimated_arrival_date
created_by
```

The stored procedure should validate that the staged shipment has no blocking validation issues before creating P21 records.

When creating the row directly in `P21Import.dbo.container_building`, set the required business columns explicitly rather than relying on UI defaults. The live schema requires:

```text
container_building_uid
container_name
location_id
row_status_flag
date_created
created_by
date_last_modified
last_maintained_by
```

The unique key is:

```text
location_id, container_name
```

For the Coats flow, use:

```text
location_id = 210
container_name = trailer_name
row_status_flag = 702
created_by = last_maintained_by = operator login
date_created = date_last_modified = current system datetime
```

Use `dbo.p21_get_counter` or the existing P21 counter pattern to allocate `container_building_uid` if you are creating a real record, not a probe.

## P21 Vessel Receipts

Later implementation should create vessel receipt header and line records transactionally after container-building data is validated.

The manual SQL currently references hard-coded values such as container building UID and vessel receipts header UID. Replace those with generated IDs returned by the transactional stored procedure.

When creating the row directly in `P21Import.dbo.vessel_receipts_hdr`, set the required fields explicitly and keep the unique constraints in mind. The live schema requires:

```text
vessel_receipts_hdr_uid
vessel_receipt_number
company_id
location_id
vessel_name
departure_date
freight_terms_cd
documents_received_flag
apply_landed_costs_flag
period
year_for_period
row_status_flag
date_created
created_by
date_last_modified
last_maintained_by
```

The unique keys are:

```text
vessel_receipt_number
location_id, vessel_name, departure_date
```

For the Coats flow, use:

```text
vessel_name = trailer_name
location_id = 210
company_id = KA
departure_date = shipment_date
freight_terms_cd = 1773
documents_received_flag = N
apply_landed_costs_flag = N
period = period for the departure date
year_for_period = year for the departure date
row_status_flag = 972
created_by = last_maintained_by = operator login
date_created = date_last_modified = current system datetime
```

Use the existing counter pattern for `vessel_receipts_hdr_uid` and assign a unique `vessel_receipt_number` before insert.

## P21 Container Receipts And Automatic Allocation

The implemented pipeline creates container building, vessel receipt, and container receipt records transactionally after staging validation succeeds. In live mode, the receipt records are written to `P21`; in test mode, the receipt records can be written to `P21Play` while staging remains in `P21Import`.

Use the existing `Coats transfer truck container receipts line insert step.sql` as a reference for line creation and counter allocation.

When creating the row directly in `P21Import.dbo.container_receipts_hdr`, do not try to populate a `container_name` column. The live schema does not expose one.

Required columns to set explicitly:

```text
container_receipts_hdr_uid
vessel_receipts_container_uid
date_received
period
year_for_period
row_status_flag
date_created
created_by
date_last_modified
last_maintained_by
```

The only foreign-keyed business input in this header is `vessel_receipts_container_uid`, which must point at the vessel/container row created earlier in the same transaction.

For the Coats flow, use:

```text
row_status_flag = 971
created_by = last_maintained_by = operator login
date_created = date_last_modified = current system datetime
date_received = the receipt date used by the business flow
period = period for date_received
year_for_period = year for date_received
```

When simulating the full P21 insert chain in `P21Import`, create `vessel_receipts_container` in the same transaction as the other header rows. The live pattern uses:

```text
vessel_receipts_container_uid = vessel_receipts_hdr_uid
container_name = trailer_name
expected_arrival_date = estimated_arrival_date
row_status_flag = 704
container_building_uid = the inserted container_building_uid
container_packaging_weight = 0.0
```

Automatic sales order allocation depends on PO/SO linkage rows, not just the receipt rows. Manual GUI diagnostics showed this sequence:

```text
1. Before vessel receipt creation, sales order demand is linked to the original PO in oe_line_po with connection_type = P.
2. During vessel receipt creation, P21 reduces the original P-link quantity and creates new oe_line_po rows with connection_type = V.
3. The V-link rows use po_no = vessel_receipt_number and po_line_number = vessel_receipts_line.line_no.
4. Before container receipt approval, the V-link rows remain completed = N.
5. When purchasers approve/save the container receipt with Allocate Automatically and Mark Container Completely Received, P21 consumes the V-link rows, marks them completed = Y, and updates oe_line, oe_hdr, and inv_loc allocation quantities.
```

The ADF receipt procedure must therefore create the same pre-approval `oe_line_po` vessel links that the GUI creates:

```text
source rows: open oe_line_po rows for the original PO line
source connection_type: P
new connection_type: V
new po_no: vessel_receipts_hdr.vessel_receipt_number
new po_line_number: vessel_receipts_line.line_no
new quantity_on_po: quantity moved from the original P-link, capped by received vessel line quantity
new completed: N
new delete_flag: N
new cancel_flag: N
```

The procedure must also reduce the original `connection_type = P` rows by the moved quantity and set `completed = Y` when the remaining original linked quantity reaches zero.

Do not directly update `oe_line`, `oe_hdr`, `inv_loc`, inventory allocation tables, or sales order allocation tables from the pipeline. Those downstream allocation changes must remain P21 behavior triggered by purchaser approval/save.

Additional GUI-parity fields that were required for the working receipt path:

```text
vessel_receipts_hdr.est_avail_ship_date = estimated_arrival_date
vessel_receipts_line.container_qty_unloaded = 0
vessel_receipts_line.sku_vessel_line_lc_amt = 0
vessel_receipts_line.reduce_po_line_qty_flag = N
vessel_receipts_line.exclude_from_landed_cost_flag = N
vessel_receipts_container.row_status_flag = 704
```

Validation note for restored test databases:

```text
MISSING_PO_LINE can be downgraded to INTERNAL only for explicit P21Play tests when the test database is older than the workbook's POs.
Live validation should keep MISSING_PO_LINE blocking so missing PO demand is not silently skipped in production.
```

## Counter Verification

`dbo.p21_get_counter` advances SQL sequence-backed counters even when the surrounding insert transaction rolls back. The live procedure definition shows it calls `sp_sequence_get_range`, so counter advancement is not undone by the later `ROLLBACK`.

Observed after the insert simulation on 2026-05-06:

```text
container_building     -> 899
vessel_receipts_hdr    -> 760
container_receipts_hdr -> 681
```

The simulated rows were rolled back, but these counter values remained advanced in `P21Import`.

## Important Step To Skip

Inserting bin rows is not optimized for the live environment. Skip automated `document_line_bin` insertion for now.

Keep parsed pallet/bin detail in staging so it is available for review and future implementation.

## Test Plan

Test with:

```text
Detalle Expo Komar 04.17.26.xlsx
```

Required checks:

1. Event function ignores non-`.xlsx` and `~$*.xlsx` files.
2. Raw workbook lands unchanged in Blob.
3. Filename parser extracts shipment date and trailer name from the required pattern.
4. Header detection finds row 9 in the sample workbook.
5. Worksheet rows extract into the required column mapping.
6. Threaded comments from `A10` and `A17` are extracted from workbook XML.
7. Comments join back to the correct pallet rows.
8. Multi-pallet rows with usable comments split into pallet-level staged rows.
9. Multi-pallet rows without usable comments fail validation.
10. SQL validation flags missing supplier parts, duplicate supplier parts, missing PO lines, canceled PO lines, and invalid bins.
11. Test receipt creation inserts only non-blocking validated lines into container building, vessel receipt, and container receipt tables.
12. For lines with eligible open sales order demand, the procedure creates open `oe_line_po` V-link rows before approval.
13. After purchaser approval/save in P21 with Allocate Automatically and Mark Container Completely Received, P21 marks the V-link rows completed and updates sales order allocation quantities.
14. The pipeline does not directly write `oe_line`, `oe_hdr`, `inv_loc`, `document_line_bin`, or allocation tables.

## Assumptions

Mary will include shipment date and trailer name in the dropped filename.

Estimated arrival date is the closest next Friday after the truck-left-Mexico shipment date.

The first implementation originally staged and validated only; the current implementation can create P21 receipt records after validation succeeds.

Automatic allocation requires the `oe_line_po` V-link handoff described above. Creating transfers alone is not sufficient.
