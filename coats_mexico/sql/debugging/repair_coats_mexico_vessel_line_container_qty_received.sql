/*
Repair Coats Mexico live P21 vessel_receipts_line.container_qty_received values
from the already-created linked container_receipts_line.qty_received values.

Default target is the known ADF-created live P21 header 762. Review the preview
result sets, then set @ApplyRepair = 1 to apply. Set
@TargetVesselReceiptsHdrUid = NULL only if you intentionally want to repair all
matching Coats ADF receipt builds with missing/zero vessel line container qty.
*/

USE P21;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @TargetVesselReceiptsHdrUid int = 762;
DECLARE @ApplyRepair bit = 0;

;WITH container_line_qty AS
(
    SELECT
          crl.vessel_receipts_line_uid
        , repair_container_qty_received = SUM(CONVERT(decimal(19, 9), crl.qty_received))
        , container_receipts_line_count = COUNT(*)
    FROM P21.dbo.container_receipts_line AS crl
    GROUP BY
          crl.vessel_receipts_line_uid
),
repair_target AS
(
    SELECT
          vl.vessel_receipts_line_uid
        , vl.vessel_receipts_hdr_uid
        , vl.line_no
        , vl.po_line_uid
        , current_container_qty_received = vl.container_qty_received
        , clq.repair_container_qty_received
        , clq.container_receipts_line_count
        , vl.created_by
        , vl.date_created
    FROM P21.dbo.vessel_receipts_line AS vl
    INNER JOIN P21.dbo.vessel_receipts_hdr AS vh
      ON vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
    INNER JOIN container_line_qty AS clq
      ON clq.vessel_receipts_line_uid = vl.vessel_receipts_line_uid
    WHERE (vl.container_qty_received IS NULL OR vl.container_qty_received = 0)
      AND clq.repair_container_qty_received IS NOT NULL
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
    , current_container_qty_received_total = CONVERT(varchar(50), SUM(COALESCE(current_container_qty_received, 0)))
    , repair_container_qty_received_total = CONVERT(varchar(50), SUM(repair_container_qty_received))
    , first_vessel_receipts_line_uid = MIN(vessel_receipts_line_uid)
    , last_vessel_receipts_line_uid = MAX(vessel_receipts_line_uid)
FROM repair_target
GROUP BY
      vessel_receipts_hdr_uid
ORDER BY
      vessel_receipts_hdr_uid;

;WITH container_line_qty AS
(
    SELECT
          crl.vessel_receipts_line_uid
        , repair_container_qty_received = SUM(CONVERT(decimal(19, 9), crl.qty_received))
        , container_receipts_line_count = COUNT(*)
    FROM P21.dbo.container_receipts_line AS crl
    GROUP BY
          crl.vessel_receipts_line_uid
),
repair_target AS
(
    SELECT
          vl.vessel_receipts_line_uid
        , vl.vessel_receipts_hdr_uid
        , vl.line_no
        , vl.po_line_uid
        , current_container_qty_received = vl.container_qty_received
        , clq.repair_container_qty_received
        , clq.container_receipts_line_count
    FROM P21.dbo.vessel_receipts_line AS vl
    INNER JOIN P21.dbo.vessel_receipts_hdr AS vh
      ON vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
    INNER JOIN container_line_qty AS clq
      ON clq.vessel_receipts_line_uid = vl.vessel_receipts_line_uid
    WHERE (vl.container_qty_received IS NULL OR vl.container_qty_received = 0)
      AND clq.repair_container_qty_received IS NOT NULL
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
    , current_container_qty_received = CONVERT(varchar(50), current_container_qty_received)
    , repair_container_qty_received = CONVERT(varchar(50), repair_container_qty_received)
    , container_receipts_line_count = CONVERT(int, container_receipts_line_count)
FROM repair_target
ORDER BY
      vessel_receipts_hdr_uid
    , line_no
    , vessel_receipts_line_uid;

IF @ApplyRepair = 1
BEGIN
    ;WITH container_line_qty AS
    (
        SELECT
              crl.vessel_receipts_line_uid
            , repair_container_qty_received = SUM(CONVERT(decimal(19, 9), crl.qty_received))
        FROM P21.dbo.container_receipts_line AS crl
        GROUP BY
              crl.vessel_receipts_line_uid
    ),
    repair_target AS
    (
        SELECT
              vl.vessel_receipts_line_uid
            , clq.repair_container_qty_received
        FROM P21.dbo.vessel_receipts_line AS vl
        INNER JOIN P21.dbo.vessel_receipts_hdr AS vh
          ON vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
        INNER JOIN container_line_qty AS clq
          ON clq.vessel_receipts_line_uid = vl.vessel_receipts_line_uid
        WHERE (vl.container_qty_received IS NULL OR vl.container_qty_received = 0)
          AND clq.repair_container_qty_received IS NOT NULL
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
          vl.container_qty_received = rt.repair_container_qty_received
        , vl.date_last_modified = dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL)
        , vl.last_maintained_by = 'ADF'
    FROM P21.dbo.vessel_receipts_line AS vl
    INNER JOIN repair_target AS rt
      ON rt.vessel_receipts_line_uid = vl.vessel_receipts_line_uid;

    SELECT repaired_line_count = @@ROWCOUNT;
END;

;WITH receipt_build AS
(
    SELECT
          vessel_receipts_hdr_uid
        , total_qty = MAX(total_qty)
    FROM P21Import.dbo.coats_mexico_shipment_receipt_build
    WHERE created_by = 'ADF'
    GROUP BY
          vessel_receipts_hdr_uid
)
SELECT
      rb.vessel_receipts_hdr_uid
    , receipt_build_total_qty = CONVERT(varchar(50), rb.total_qty)
    , vessel_line_container_qty_total = CONVERT(varchar(50), SUM(CONVERT(decimal(19, 9), COALESCE(vl.container_qty_received, 0))))
    , container_receipts_line_qty_total = CONVERT(varchar(50), SUM(CONVERT(decimal(19, 9), COALESCE(crl.qty_received, 0))))
    , vessel_line_count = CONVERT(int, COUNT(DISTINCT vl.vessel_receipts_line_uid))
    , container_receipts_line_count = CONVERT(int, COUNT(crl.container_receipts_line_uid))
FROM receipt_build AS rb
INNER JOIN P21.dbo.vessel_receipts_line AS vl
  ON vl.vessel_receipts_hdr_uid = rb.vessel_receipts_hdr_uid
LEFT JOIN P21.dbo.container_receipts_line AS crl
  ON crl.vessel_receipts_line_uid = vl.vessel_receipts_line_uid
WHERE (@TargetVesselReceiptsHdrUid IS NULL OR rb.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
GROUP BY
      rb.vessel_receipts_hdr_uid
    , rb.total_qty
ORDER BY
      rb.vessel_receipts_hdr_uid;
GO
