/*
Validate one staged Coats Mexico shipment against P21Import.

Run from the P21Import database. This keeps the Coats Mexico staging,
validation, and receipt-write path scoped to P21Import instead of P21.

Set @ShipmentFileId before running. This script does not create container,
vessel receipt, container receipt, or document_line_bin records.
*/

USE P21Import;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ShipmentFileId uniqueidentifier = '00000000-0000-0000-0000-000000000000';
DECLARE @SupplierID int = 40408;

IF @ShipmentFileId = '00000000-0000-0000-0000-000000000000'
BEGIN
    THROW 50000, 'Set @ShipmentFileId before running validation.', 1;
END;

IF NOT EXISTS (
    SELECT 1
    FROM P21Import.dbo.coats_mexico_shipment_file
    WHERE shipment_file_id = @ShipmentFileId
)
BEGIN
    THROW 50001, 'Shipment file was not found in P21Import staging.', 1;
END;

BEGIN TRAN;

DELETE FROM P21Import.dbo.coats_mexico_shipment_validation_issue
WHERE shipment_file_id = @ShipmentFileId
  AND issue_code IN
  (
        'MISSING_SUPPLIER_PART'
      , 'DUPLICATE_SUPPLIER_PART'
      , 'MISSING_PO_LINE'
      , 'DUPLICATE_PO_LINE'
      , 'CANCELED_PO_LINE'
      , 'INVALID_BIN_ID'
      , 'MISSING_REQUIRED_VALUE_SQL'
  );

;WITH cte_last_color_bin AS (
    SELECT
          dlb.bin_cd
        , CASE
              WHEN p.prefix = 'BL' THEN 'Y'
              WHEN p.prefix = 'Y' THEN 'BL'
              ELSE 'unknown'
          END AS next_bin_start
    FROM (
        SELECT
              dlb.bin_cd
            , ROW_NUMBER() OVER (ORDER BY dlb.date_created DESC) AS rn
        FROM dbo.document_line_bin AS dlb
        WHERE dlb.document_type = 'CR'
    ) AS dlb
    CROSS APPLY (
        SELECT prefix =
            CASE
                WHEN PATINDEX('%[0-9]%', dlb.bin_cd) > 0
                    THEN LEFT(dlb.bin_cd, PATINDEX('%[0-9]%', dlb.bin_cd) - 1)
                ELSE dlb.bin_cd
            END
    ) AS p
    WHERE dlb.rn = 1
)
UPDATE p
SET P21_Bin_ID =
    CASE
        WHEN CHARINDEX('-', p.Bin_ID) > 0 THEN
            (SELECT next_bin_start FROM cte_last_color_bin)
            + SUBSTRING(p.Bin_ID, CHARINDEX('-', p.Bin_ID), LEN(p.Bin_ID))
        ELSE p.Bin_ID
    END
FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
WHERE p.shipment_file_id = @ShipmentFileId;

;WITH supplier_part AS (
    SELECT
          ivs.supplier_part_no
        , active_part_count = COUNT(DISTINCT ivs.inv_mast_uid)
        , komar_item_id = MAX(ivm.item_id)
    FROM dbo.inventory_supplier AS ivs
    JOIN dbo.inv_mast AS ivm
      ON ivm.inv_mast_uid = ivs.inv_mast_uid
    WHERE ivs.supplier_id = @SupplierID
      AND ISNULL(ivm.delete_flag, 'N') <> 'Y'
    GROUP BY
          ivs.supplier_part_no
),
po_candidates AS (
    SELECT
          p.shipment_pallet_line_id
        , pol.po_line_uid
        , pol.cancel_flag
        , container_uom =
            CASE
                WHEN ivm.default_purchasing_unit = pol.unit_of_measure
                    THEN pol.unit_of_measure
                ELSE ivm.default_purchasing_unit
            END
        , rn = ROW_NUMBER() OVER (
              PARTITION BY p.shipment_pallet_line_id
              ORDER BY pol.po_line_uid
          )
        , match_count = COUNT(*) OVER (
              PARTITION BY p.shipment_pallet_line_id
          )
    FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
    JOIN dbo.po_line AS pol
      ON pol.po_no = p.PO_No
     AND pol.complete <> 'Y'
    JOIN dbo.inv_mast AS ivm
      ON ivm.inv_mast_uid = pol.inv_mast_uid
     AND ISNULL(ivm.delete_flag, 'N') <> 'Y'
    JOIN dbo.inventory_supplier AS ivs
      ON ivs.inv_mast_uid = ivm.inv_mast_uid
     AND ivs.supplier_id = @SupplierID
     AND ivs.supplier_part_no = p.Item_ID
    WHERE p.shipment_file_id = @ShipmentFileId
),
chosen_po AS (
    SELECT
          shipment_pallet_line_id
        , po_line_uid
        , cancel_flag
        , container_uom
        , match_count
    FROM po_candidates
    WHERE rn = 1
)
UPDATE p
SET
      p.po_line_uid = c.po_line_uid
    , p.cancel_flag = c.cancel_flag
    , p.container_uom = c.container_uom
    , p.has_duplicate_supplier_part =
        CASE WHEN ISNULL(sp.active_part_count, 0) > 1 THEN 1 ELSE 0 END
    , p.missing_supplier_part_flag =
        CASE WHEN ISNULL(sp.active_part_count, 0) = 0 THEN 1 ELSE 0 END
    , p.komar_item_id = sp.komar_item_id
FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
LEFT JOIN supplier_part AS sp
  ON sp.supplier_part_no = p.Item_ID
LEFT JOIN chosen_po AS c
  ON c.shipment_pallet_line_id = p.shipment_pallet_line_id
WHERE p.shipment_file_id = @ShipmentFileId;

INSERT INTO P21Import.dbo.coats_mexico_shipment_validation_issue
(
      shipment_file_id
    , severity
    , issue_code
    , message
    , source_sheet
    , source_row_number
    , Bin_ID
    , Item_ID
    , PO_No
    , raw_pallet_comment
)
SELECT
      p.shipment_file_id
    , 'BLOCKING'
    , v.issue_code
    , v.message
    , p.source_sheet
    , p.source_row_number
    , p.Bin_ID
    , p.Item_ID
    , p.PO_No
    , p.raw_pallet_comment
FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
CROSS APPLY (
    VALUES
          (
              CASE
                  WHEN NULLIF(LTRIM(RTRIM(ISNULL(p.Bin_ID, ''))), '') IS NULL
                    OR NULLIF(LTRIM(RTRIM(ISNULL(p.Item_ID, ''))), '') IS NULL
                    OR NULLIF(LTRIM(RTRIM(ISNULL(p.PO_No, ''))), '') IS NULL
                    OR p.Invoiced_Qty IS NULL
                      THEN 'MISSING_REQUIRED_VALUE_SQL'
              END,
              'Required staged pallet value is missing.'
          )
        , (
              CASE WHEN p.missing_supplier_part_flag = 1 THEN 'MISSING_SUPPLIER_PART' END,
              'Supplier part does not map to an active Komar item for supplier 40408.'
          )
        , (
              CASE WHEN p.has_duplicate_supplier_part = 1 THEN 'DUPLICATE_SUPPLIER_PART' END,
              'Supplier part maps to more than one active Komar item for supplier 40408.'
          )
        , (
              CASE WHEN p.po_line_uid IS NULL THEN 'MISSING_PO_LINE' END,
              'No open PO line matched this PO and supplier part.'
          )
        , (
              CASE WHEN p.cancel_flag = 'Y' THEN 'CANCELED_PO_LINE' END,
              'Matched PO line is canceled.'
          )
        , (
              CASE
                  WHEN p.P21_Bin_ID IS NULL
                    OR (p.P21_Bin_ID NOT LIKE 'BL%' AND p.P21_Bin_ID NOT LIKE 'Y%')
                      THEN 'INVALID_BIN_ID'
              END,
              'Translated P21 bin is missing or does not use the expected BL/Y prefix.'
          )
) AS v(issue_code, message)
WHERE p.shipment_file_id = @ShipmentFileId
  AND v.issue_code IS NOT NULL;

;WITH po_match_counts AS (
    SELECT
          p.shipment_pallet_line_id
        , match_count = COUNT(*)
    FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
    JOIN dbo.po_line AS pol
      ON pol.po_no = p.PO_No
     AND pol.complete <> 'Y'
    JOIN dbo.inv_mast AS ivm
      ON ivm.inv_mast_uid = pol.inv_mast_uid
     AND ISNULL(ivm.delete_flag, 'N') <> 'Y'
    JOIN dbo.inventory_supplier AS ivs
      ON ivs.inv_mast_uid = ivm.inv_mast_uid
     AND ivs.supplier_id = @SupplierID
     AND ivs.supplier_part_no = p.Item_ID
    WHERE p.shipment_file_id = @ShipmentFileId
    GROUP BY
          p.shipment_pallet_line_id
)
INSERT INTO P21Import.dbo.coats_mexico_shipment_validation_issue
(
      shipment_file_id
    , severity
    , issue_code
    , message
    , source_sheet
    , source_row_number
    , Bin_ID
    , Item_ID
    , PO_No
    , raw_pallet_comment
)
SELECT
      p.shipment_file_id
    , 'BLOCKING'
    , 'DUPLICATE_PO_LINE'
    , 'More than one open PO line matched this PO and supplier part.'
    , p.source_sheet
    , p.source_row_number
    , p.Bin_ID
    , p.Item_ID
    , p.PO_No
    , p.raw_pallet_comment
FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
JOIN po_match_counts AS c
  ON c.shipment_pallet_line_id = p.shipment_pallet_line_id
WHERE c.match_count > 1;

COMMIT;

SELECT
      shipment_file_id = @ShipmentFileId
    , f.source_file_name
    , f.source_web_url
    , f.shipment_date
    , f.trailer_name
    , f.estimated_arrival_date
    , pallet_line_count = (
          SELECT COUNT(*)
          FROM P21Import.dbo.coats_mexico_shipment_pallet_line
          WHERE shipment_file_id = @ShipmentFileId
      )
    , blocking_issue_count = (
          SELECT COUNT(*)
          FROM P21Import.dbo.coats_mexico_shipment_validation_issue
          WHERE shipment_file_id = @ShipmentFileId
                AND severity = 'BLOCKING'
      )
FROM P21Import.dbo.coats_mexico_shipment_file AS f
WHERE f.shipment_file_id = @ShipmentFileId;

SELECT
      issue_code
    , severity
    , message
    , source_sheet
    , source_row_number
    , Bin_ID
    , Item_ID
    , PO_No
    , raw_pallet_comment
FROM P21Import.dbo.coats_mexico_shipment_validation_issue
WHERE shipment_file_id = @ShipmentFileId
ORDER BY
      severity
    , issue_code
    , source_row_number;

SELECT issue_json =
    COALESCE(
        (
            SELECT
                  issue_code
                , severity
                , message
                , source_sheet
                , source_row_number
                , Bin_ID
                , Item_ID
                , PO_No
                , raw_pallet_comment
            FROM P21Import.dbo.coats_mexico_shipment_validation_issue
            WHERE shipment_file_id = @ShipmentFileId
            ORDER BY
                  severity
                , issue_code
                , source_row_number
            FOR JSON PATH
        ),
        '[]'
    );
