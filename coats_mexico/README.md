# Coats Mexico Shipment Pipeline

This folder contains the first build slice for the `AGENTS.md` plan up to
`## P21 Container Building`.

Current implemented pieces:

```text
azure_function/  Graph notification endpoint that starts ADF
src/             dependency-free .xlsx extractor and pallet comment parser
sql/             SQL staging DDL and P21 validation script
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

Run P21 validation from the P21 database after replacing `@ShipmentFileId`:

```sql
:r sql/002_validate_coats_mexico_staging_from_p21.sql
```

The validation script updates staged pallet lines with P21 lookup values and
adds blocking validation issues. It does not create container-building, vessel
receipt, container receipt, or `document_line_bin` rows.
