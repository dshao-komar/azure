/*
Repair Coats Mexico vessel_receipts_line rows that were created with a matching
vessel_receipts_container row but a NULL line-level vessel_receipts_container_uid.

Default target is the known ADF-created header 762. Review the preview result set,
then set @ApplyRepair = 1 to apply. Set @TargetVesselReceiptsHdrUid = NULL only if
you intentionally want to repair all matching Coats ADF receipt builds.
*/

USE P21Import;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @TargetVesselReceiptsHdrUid int = 762;
DECLARE @ApplyRepair bit = 0;

;WITH one_container_header AS
(
    SELECT
          vc.vessel_receipts_hdr_uid
        , vessel_receipts_container_uid = MIN(vc.vessel_receipts_container_uid)
        , container_count = COUNT(*)
    FROM dbo.vessel_receipts_container AS vc
    GROUP BY
          vc.vessel_receipts_hdr_uid
    HAVING COUNT(*) = 1
),
repair_target AS
(
    SELECT
          vl.vessel_receipts_line_uid
        , vl.vessel_receipts_hdr_uid
        , current_vessel_receipts_container_uid = vl.vessel_receipts_container_uid
        , repair_vessel_receipts_container_uid = och.vessel_receipts_container_uid
        , vl.line_no
        , vl.po_line_uid
        , vl.created_by
        , vl.date_created
    FROM dbo.vessel_receipts_line AS vl
    INNER JOIN one_container_header AS och
      ON och.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
    INNER JOIN dbo.vessel_receipts_hdr AS vh
      ON vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
    INNER JOIN dbo.vessel_receipts_container AS vc
      ON vc.vessel_receipts_container_uid = och.vessel_receipts_container_uid
    INNER JOIN dbo.coats_mexico_shipment_receipt_build AS rb
      ON rb.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
     AND rb.vessel_receipts_container_uid = och.vessel_receipts_container_uid
    WHERE vl.vessel_receipts_container_uid IS NULL
      AND vl.created_by = 'ADF'
      AND vh.created_by = 'ADF'
      AND vc.created_by = 'ADF'
      AND rb.created_by = 'ADF'
      AND (@TargetVesselReceiptsHdrUid IS NULL OR vl.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
)
SELECT
      action_to_take = CASE WHEN @ApplyRepair = 1 THEN 'APPLY' ELSE 'PREVIEW_ONLY' END
    , vessel_receipts_hdr_uid
    , repair_vessel_receipts_container_uid
    , line_count = COUNT(*)
    , first_vessel_receipts_line_uid = MIN(vessel_receipts_line_uid)
    , last_vessel_receipts_line_uid = MAX(vessel_receipts_line_uid)
FROM repair_target
GROUP BY
      vessel_receipts_hdr_uid
    , repair_vessel_receipts_container_uid
ORDER BY
      vessel_receipts_hdr_uid;

IF @ApplyRepair = 1
BEGIN
    ;WITH one_container_header AS
    (
        SELECT
              vc.vessel_receipts_hdr_uid
            , vessel_receipts_container_uid = MIN(vc.vessel_receipts_container_uid)
            , container_count = COUNT(*)
        FROM dbo.vessel_receipts_container AS vc
        GROUP BY
              vc.vessel_receipts_hdr_uid
        HAVING COUNT(*) = 1
    ),
    repair_target AS
    (
        SELECT
              vl.vessel_receipts_line_uid
            , repair_vessel_receipts_container_uid = och.vessel_receipts_container_uid
        FROM dbo.vessel_receipts_line AS vl
        INNER JOIN one_container_header AS och
          ON och.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
        INNER JOIN dbo.vessel_receipts_hdr AS vh
          ON vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
        INNER JOIN dbo.vessel_receipts_container AS vc
          ON vc.vessel_receipts_container_uid = och.vessel_receipts_container_uid
        INNER JOIN dbo.coats_mexico_shipment_receipt_build AS rb
          ON rb.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
         AND rb.vessel_receipts_container_uid = och.vessel_receipts_container_uid
        WHERE vl.vessel_receipts_container_uid IS NULL
          AND vl.created_by = 'ADF'
          AND vh.created_by = 'ADF'
          AND vc.created_by = 'ADF'
          AND rb.created_by = 'ADF'
          AND (@TargetVesselReceiptsHdrUid IS NULL OR vl.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
    )
    UPDATE vl
    SET
          vl.vessel_receipts_container_uid = rt.repair_vessel_receipts_container_uid
        , vl.date_last_modified = dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL)
        , vl.last_maintained_by = 'ADF'
    FROM dbo.vessel_receipts_line AS vl
    INNER JOIN repair_target AS rt
      ON rt.vessel_receipts_line_uid = vl.vessel_receipts_line_uid;

    SELECT repaired_line_count = @@ROWCOUNT;
END;
GO
