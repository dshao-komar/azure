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
DECLARE @BypassMissingPoLine bit = 0;

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
      , 'COMPLETED_PO_LINE'
      , 'INVALID_BIN_ID'
      , 'MISSING_REQUIRED_VALUE_SQL'
  );

;WITH cte_last_color_bin AS (
    SELECT TOP (1)
          dlb.bin_cd
        , dlb.date_created
        , CASE
              WHEN p.prefix = 'BL' THEN 'Y'
              WHEN p.prefix = 'Y' THEN 'BL'
              ELSE 'unknown'
          END AS next_bin_start
    FROM dbo.document_line_bin AS dlb
    CROSS APPLY (
        SELECT prefix =
            CASE
                WHEN PATINDEX('%[0-9]%', dlb.bin_cd) > 0
                    THEN LEFT(dlb.bin_cd, PATINDEX('%[0-9]%', dlb.bin_cd) - 1)
                ELSE dlb.bin_cd
            END
    ) AS p
    WHERE dlb.document_type = 'CR'
      AND p.prefix IN ('BL', 'Y')
    ORDER BY
          dlb.date_created DESC
        , dlb.bin_cd DESC
)
UPDATE p
SET P21_Bin_ID =
    CASE
        WHEN CHARINDEX('-', p.Bin_ID) > 0 THEN
            (SELECT next_bin_start FROM cte_last_color_bin)
            + SUBSTRING(p.Bin_ID, CHARINDEX('-', p.Bin_ID) + 1, LEN(p.Bin_ID))
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
              ORDER BY
                    CASE WHEN ISNULL(pol.cancel_flag, 'N') = 'Y' THEN 1 ELSE 0 END
                  , pol.po_line_uid
          )
        , match_count = COUNT(*) OVER (
              PARTITION BY p.shipment_pallet_line_id
          )
    FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
    JOIN dbo.po_line AS pol
      ON pol.po_no = p.PO_No
     AND (pol.complete <> 'Y' OR ISNULL(pol.cancel_flag, 'N') = 'Y')
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

;WITH po_line_status AS (
    SELECT
          p.shipment_pallet_line_id
        , any_po_line_count = COUNT(DISTINCT pol.po_line_uid)
        , open_or_canceled_po_line_count = COUNT(DISTINCT CASE
              WHEN pol.complete <> 'Y'
                OR ISNULL(pol.cancel_flag, 'N') = 'Y'
                  THEN pol.po_line_uid
          END)
        , completed_non_canceled_po_line_count = COUNT(DISTINCT CASE
              WHEN pol.complete = 'Y'
                AND ISNULL(pol.cancel_flag, 'N') <> 'Y'
                  THEN pol.po_line_uid
          END)
    FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
    JOIN dbo.inventory_supplier AS ivs
      ON ivs.supplier_id = @SupplierID
     AND ivs.supplier_part_no = p.Item_ID
    JOIN dbo.inv_mast AS ivm
      ON ivm.inv_mast_uid = ivs.inv_mast_uid
     AND ISNULL(ivm.delete_flag, 'N') <> 'Y'
    JOIN dbo.po_line AS pol
      ON pol.po_no = p.PO_No
     AND pol.inv_mast_uid = ivm.inv_mast_uid
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
    , v.severity
    , v.issue_code
    , v.message
    , p.source_sheet
    , p.source_row_number
    , p.Bin_ID
    , p.Item_ID
    , p.PO_No
    , p.raw_pallet_comment
FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
LEFT JOIN po_line_status AS pls
  ON pls.shipment_pallet_line_id = p.shipment_pallet_line_id
CROSS APPLY (
    VALUES
          (
              CASE
                  WHEN NULLIF(LTRIM(RTRIM(ISNULL(p.Item_ID, ''))), '') IS NULL
                    OR NULLIF(LTRIM(RTRIM(ISNULL(p.PO_No, ''))), '') IS NULL
                    OR p.Invoiced_Qty IS NULL
                      THEN 'MISSING_REQUIRED_VALUE_SQL'
              END,
              'BLOCKING',
              'Required item, purchase order, or quantity value is missing from the workbook.'
          )
        , (
              CASE WHEN p.missing_supplier_part_flag = 1 THEN 'MISSING_SUPPLIER_PART' END,
              'BLOCKING',
              CONCAT('Item ', ISNULL(NULLIF(p.Item_ID, ''), '[blank]'), ' has a supplier part number mismatch. Please check Item Maintenance.')
          )
        , (
              CASE WHEN p.has_duplicate_supplier_part = 1 THEN 'DUPLICATE_SUPPLIER_PART' END,
              'BLOCKING',
              CONCAT('Item ', ISNULL(NULLIF(p.Item_ID, ''), '[blank]'), ' has duplicate supplier parts. Please check Item Maintenance.')
          )
        , (
              CASE
                  WHEN p.po_line_uid IS NULL
                    AND ISNULL(p.missing_supplier_part_flag, 0) = 0
                    AND ISNULL(pls.any_po_line_count, 0) = 0
                      THEN 'MISSING_PO_LINE'
              END,
              CASE WHEN @BypassMissingPoLine = 1 THEN 'INTERNAL' ELSE 'BLOCKING' END,
              CASE
                  WHEN @BypassMissingPoLine = 1
                      THEN CONCAT('Item ', ISNULL(NULLIF(p.Item_ID, ''), '[blank]'), ' is missing from the Purchase Order and will be skipped for this test run.')
                  ELSE CONCAT('Item ', ISNULL(NULLIF(p.Item_ID, ''), '[blank]'), ' is missing from the Purchase Order.')
              END
          )
        , (
              CASE
                  WHEN p.po_line_uid IS NULL
                    AND ISNULL(p.missing_supplier_part_flag, 0) = 0
                    AND ISNULL(pls.completed_non_canceled_po_line_count, 0) > 0
                    AND ISNULL(pls.open_or_canceled_po_line_count, 0) = 0
                      THEN 'COMPLETED_PO_LINE'
              END,
              'BLOCKING',
              CONCAT('Item ', ISNULL(NULLIF(p.Item_ID, ''), '[blank]'), ' is on the Purchase Order but the matching PO line is complete. Please review the PO line.')
          )
        , (
              CASE WHEN p.cancel_flag = 'Y' THEN 'CANCELED_PO_LINE' END,
              'BLOCKING',
              CONCAT('Item ', ISNULL(NULLIF(p.Item_ID, ''), '[blank]'), ' is on the Purchase Order but the line is cancelled. Please un-cancel the PO line.')
          )
        , (
              CASE
                  WHEN p.P21_Bin_ID IS NULL
                    OR (p.P21_Bin_ID NOT LIKE 'BL%' AND p.P21_Bin_ID NOT LIKE 'Y%')
                      THEN 'INVALID_BIN_ID'
              END,
              'INTERNAL',
              'Bin ID requires pipeline review; no purchaser action is required.'
          )
) AS v(issue_code, severity, message)
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
    , CONCAT('Item ', ISNULL(NULLIF(p.Item_ID, ''), '[blank]'), ' matches more than one open Purchase Order line. Please review the Purchase Order.')
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
      i.issue_code
    , i.severity
    , i.message
    , i.source_sheet
    , i.source_row_number
    , i.Bin_ID
    , i.Item_ID
    , i.PO_No
    , Invoiced_Qty = (
          SELECT TOP (1) p.Invoiced_Qty
          FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
          WHERE p.shipment_file_id = i.shipment_file_id
            AND p.source_sheet = i.source_sheet
            AND p.source_row_number = i.source_row_number
            AND ISNULL(p.Bin_ID, '') = ISNULL(i.Bin_ID, '')
            AND ISNULL(p.Item_ID, '') = ISNULL(i.Item_ID, '')
            AND ISNULL(p.PO_No, '') = ISNULL(i.PO_No, '')
          ORDER BY p.shipment_pallet_line_id
      )
    , i.raw_pallet_comment
FROM P21Import.dbo.coats_mexico_shipment_validation_issue AS i
WHERE i.shipment_file_id = @ShipmentFileId
ORDER BY
      i.severity
    , i.issue_code
    , i.source_row_number;

SELECT issue_json =
    COALESCE(
        (
            SELECT
                  i.issue_code
                , i.severity
                , i.message
                , i.source_sheet
                , i.source_row_number
                , i.Bin_ID
                , i.Item_ID
                , i.PO_No
                , Invoiced_Qty = (
                      SELECT TOP (1) p.Invoiced_Qty
                      FROM P21Import.dbo.coats_mexico_shipment_pallet_line AS p
                      WHERE p.shipment_file_id = i.shipment_file_id
                        AND p.source_sheet = i.source_sheet
                        AND p.source_row_number = i.source_row_number
                        AND ISNULL(p.Bin_ID, '') = ISNULL(i.Bin_ID, '')
                        AND ISNULL(p.Item_ID, '') = ISNULL(i.Item_ID, '')
                        AND ISNULL(p.PO_No, '') = ISNULL(i.PO_No, '')
                      ORDER BY p.shipment_pallet_line_id
                  )
                , i.raw_pallet_comment
            FROM P21Import.dbo.coats_mexico_shipment_validation_issue AS i
            WHERE i.shipment_file_id = @ShipmentFileId
            ORDER BY
                  i.severity
                , i.issue_code
                , i.source_row_number
            FOR JSON PATH
        ),
        '[]'
    );
