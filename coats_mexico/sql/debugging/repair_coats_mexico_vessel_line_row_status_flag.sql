/*
Repair Coats Mexico live P21 vessel_receipts_line.row_status_flag values.

The vessel receipt header should use row_status_flag 972, but the vessel
receipt lines should be created with row_status_flag 702.

Default target is the known ADF-created live P21 header 762. Review the preview
result sets, then set @ApplyRepair = 1 to apply. Set
@TargetVesselReceiptsHdrUid = NULL only if you intentionally want to repair all
matching Coats ADF receipt builds with vessel line row_status_flag 972.
*/

USE P21;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @TargetVesselReceiptsHdrUid int = 762;
DECLARE @ApplyRepair bit = 0;
DECLARE @RepairRowStatusFlag int = 702;

;WITH repair_target AS
(
    SELECT
          vl.vessel_receipts_line_uid
        , vl.vessel_receipts_hdr_uid
        , vl.line_no
        , vl.po_line_uid
        , current_row_status_flag = vl.row_status_flag
        , repair_row_status_flag = @RepairRowStatusFlag
        , vl.created_by
        , vl.date_created
    FROM P21.dbo.vessel_receipts_line AS vl
    INNER JOIN P21.dbo.vessel_receipts_hdr AS vh
      ON vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
    WHERE vl.row_status_flag = 972
      AND vh.row_status_flag = 972
      AND vl.created_by = 'ADF'
      AND vh.created_by = 'ADF'
      AND EXISTS
      (
          SELECT 1
          FROM P21Import.dbo.coats_mexico_shipment_receipt_build AS rb
          WHERE rb.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
            AND rb.created_by = 'ADF'
      )
      AND (@TargetVesselReceiptsHdrUid IS NULL OR vl.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
)
SELECT
      action_to_take = CASE WHEN @ApplyRepair = 1 THEN 'APPLY' ELSE 'PREVIEW_ONLY' END
    , vessel_receipts_hdr_uid
    , repair_line_count = CONVERT(int, COUNT(*))
    , current_row_status_flag = MIN(current_row_status_flag)
    , repair_row_status_flag = MIN(repair_row_status_flag)
    , first_vessel_receipts_line_uid = MIN(vessel_receipts_line_uid)
    , last_vessel_receipts_line_uid = MAX(vessel_receipts_line_uid)
FROM repair_target
GROUP BY
      vessel_receipts_hdr_uid
ORDER BY
      vessel_receipts_hdr_uid;

;WITH repair_target AS
(
    SELECT
          vl.vessel_receipts_line_uid
        , vl.vessel_receipts_hdr_uid
        , vl.line_no
        , vl.po_line_uid
        , current_row_status_flag = vl.row_status_flag
        , repair_row_status_flag = @RepairRowStatusFlag
    FROM P21.dbo.vessel_receipts_line AS vl
    INNER JOIN P21.dbo.vessel_receipts_hdr AS vh
      ON vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
    WHERE vl.row_status_flag = 972
      AND vh.row_status_flag = 972
      AND vl.created_by = 'ADF'
      AND vh.created_by = 'ADF'
      AND EXISTS
      (
          SELECT 1
          FROM P21Import.dbo.coats_mexico_shipment_receipt_build AS rb
          WHERE rb.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
            AND rb.created_by = 'ADF'
      )
      AND (@TargetVesselReceiptsHdrUid IS NULL OR vl.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
)
SELECT
      vessel_receipts_hdr_uid
    , vessel_receipts_line_uid
    , line_no
    , po_line_uid
    , current_row_status_flag
    , repair_row_status_flag
FROM repair_target
ORDER BY
      vessel_receipts_hdr_uid
    , line_no
    , vessel_receipts_line_uid;

IF @ApplyRepair = 1
BEGIN
    ;WITH repair_target AS
    (
        SELECT
              vl.vessel_receipts_line_uid
        FROM P21.dbo.vessel_receipts_line AS vl
        INNER JOIN P21.dbo.vessel_receipts_hdr AS vh
          ON vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
        WHERE vl.row_status_flag = 972
          AND vh.row_status_flag = 972
          AND vl.created_by = 'ADF'
          AND vh.created_by = 'ADF'
          AND EXISTS
          (
              SELECT 1
              FROM P21Import.dbo.coats_mexico_shipment_receipt_build AS rb
              WHERE rb.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
                AND rb.created_by = 'ADF'
          )
          AND (@TargetVesselReceiptsHdrUid IS NULL OR vl.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
    )
    UPDATE vl
    SET
          vl.row_status_flag = @RepairRowStatusFlag
        , vl.date_last_modified = dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL)
        , vl.last_maintained_by = 'ADF'
    FROM P21.dbo.vessel_receipts_line AS vl
    INNER JOIN repair_target AS rt
      ON rt.vessel_receipts_line_uid = vl.vessel_receipts_line_uid;

    SELECT repaired_line_count = @@ROWCOUNT;
END;

SELECT
      vh.vessel_receipts_hdr_uid
    , header_row_status_flag = vh.row_status_flag
    , vessel_line_count = CONVERT(int, COUNT(vl.vessel_receipts_line_uid))
    , line_status_702_count = CONVERT(int, SUM(CASE WHEN vl.row_status_flag = 702 THEN 1 ELSE 0 END))
    , line_status_972_count = CONVERT(int, SUM(CASE WHEN vl.row_status_flag = 972 THEN 1 ELSE 0 END))
    , min_line_row_status_flag = MIN(vl.row_status_flag)
    , max_line_row_status_flag = MAX(vl.row_status_flag)
FROM P21.dbo.vessel_receipts_hdr AS vh
INNER JOIN P21.dbo.vessel_receipts_line AS vl
  ON vl.vessel_receipts_hdr_uid = vh.vessel_receipts_hdr_uid
WHERE (@TargetVesselReceiptsHdrUid IS NULL OR vh.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
  AND vh.created_by = 'ADF'
  AND EXISTS
  (
      SELECT 1
      FROM P21Import.dbo.coats_mexico_shipment_receipt_build AS rb
      WHERE rb.vessel_receipts_hdr_uid = vh.vessel_receipts_hdr_uid
        AND rb.created_by = 'ADF'
  )
GROUP BY
      vh.vessel_receipts_hdr_uid
    , vh.row_status_flag
ORDER BY
      vh.vessel_receipts_hdr_uid;
GO
