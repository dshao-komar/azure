# Coats Mexico Shipment Pipeline

This folder contains the Coats Mexico shipment pipeline build through
P21Import container, vessel receipt, and container receipt creation.

Current implemented pieces:

```text
azure_function/  Graph notification endpoint that starts ADF
src/             dependency-free .xlsx extractor and pallet comment parser
sql/             SQL staging, validation, and P21Import receipt scripts
```

## Local Extraction Test

The sample workbook does not include the future required trailer/date filename
pattern, so pass overrides when testing locally:

```bash
python3 src/extract_coats_mexico_workbook.py \
  "Detalle Expo Komar 04.17.26.xlsx" \
  --shipment-date 2026-04-17 \
  --trailer-name TM672 \
  --output /tmp/coats_mexico_extract.json
```

Expected sample behavior:

```text
raw_lines: 116
pallet_lines: 120
A10 comment splits O-8, O-9, O-10, O-11
A17 comment splits O-12, O-13
```

## SQL Staging

Run this in `P21Import`:

```sql
:r sql/001_create_coats_mexico_staging.sql
```

Then stage extractor JSON with:

```sql
DECLARE @payload nvarchar(max) = N'<extractor json>';
EXEC dbo.usp_stage_coats_mexico_shipment_json @payload = @payload;
```

Run validation from `P21Import` after replacing `@ShipmentFileId`:

```sql
:r sql/002_validate_coats_mexico_staging_from_p21.sql
```

The validation script updates staged pallet lines with P21 lookup values and
adds blocking validation issues. It does not create container-building, vessel
receipt, container receipt, or `document_line_bin` rows.

## P21Import Receipt Creation

The deployment script adds validation gating to the
`Coats_Mexico_Shipment_Stage_And_Validate` ADF pipeline after
`StageCoatsShipmentJson`. `ValidateCoatsShipment` runs first. If it finds any
`BLOCKING` issues, ADF calls `send-coats-validation-email` and then fails the
run without creating receipt records. If there are no blocking issues,
`CreateP21ImportReceipts` creates the P21Import receipt chain.

Required `.env` settings for blocking validation email:

```text
COATS_VALIDATION_EMAIL_FROM=<sender mailbox or shared mailbox>
COATS_VALIDATION_EMAIL_TO=<comma-separated recipients>
COATS_VALIDATION_EMAIL_CC=<optional comma-separated recipients>
```

The Graph app must have application `Mail.Send` permission and admin consent
for `/users/{COATS_VALIDATION_EMAIL_FROM}/sendMail`.

For manual execution, install the receipt procedure in `P21Import`:

```sql
:r sql/004_create_coats_mexico_p21import_receipts.sql
```

Then create the P21Import receipt chain for a staged shipment:

```sql
EXEC dbo.usp_create_coats_mexico_p21import_receipts
      @ShipmentFileId = '<shipment_file_id>'
    , @CreatedBy = 'DSHAO';
```

The procedure creates `container_building`, `container_building_po`,
`vessel_receipts_hdr`, `vessel_receipts_container`, `vessel_receipts_line`,
`container_receipts_hdr`, and `container_receipts_line` rows in `P21Import`.
It records generated IDs in `dbo.coats_mexico_shipment_receipt_build` and skips
`document_line_bin` insertion.

The ADF receipt activity uses `.env` key `COATS_P21_CREATED_BY` when present;
otherwise it uses `ADF` for created/maintained-by fields.
