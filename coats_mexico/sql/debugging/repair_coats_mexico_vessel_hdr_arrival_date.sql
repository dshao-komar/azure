/*
Repair Coats Mexico vessel_receipts_hdr arrival_date values from the staged
estimated_arrival_date. Default target is the known ADF-created header 762.

Review the preview result set, then set @ApplyRepair = 1 to apply. Set
@TargetVesselReceiptsHdrUid = NULL only if you intentionally want to repair all
matching Coats ADF receipt builds with NULL vessel_receipts_hdr.arrival_date.
*/

USE P21Import;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @TargetVesselReceiptsHdrUid int = 762;
DECLARE @ApplyRepair bit = 0;

;WITH repair_target AS
(
    SELECT
          vh.vessel_receipts_hdr_uid
        , vh.vessel_name
        , current_arrival_date = vh.arrival_date
        , repair_arrival_date = CONVERT(datetime, f.estimated_arrival_date)
        , vh.created_by
        , vh.date_created
    FROM dbo.vessel_receipts_hdr AS vh
    INNER JOIN dbo.coats_mexico_shipment_receipt_build AS rb
      ON rb.vessel_receipts_hdr_uid = vh.vessel_receipts_hdr_uid
    INNER JOIN dbo.coats_mexico_shipment_file AS f
      ON f.shipment_file_id = rb.shipment_file_id
    WHERE vh.arrival_date IS NULL
      AND f.estimated_arrival_date IS NOT NULL
      AND vh.created_by = 'ADF'
      AND rb.created_by = 'ADF'
      AND (@TargetVesselReceiptsHdrUid IS NULL OR vh.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
)
SELECT
      action_to_take = CASE WHEN @ApplyRepair = 1 THEN 'APPLY' ELSE 'PREVIEW_ONLY' END
    , vessel_receipts_hdr_uid
    , vessel_name
    , current_arrival_date
    , repair_arrival_date
FROM repair_target
ORDER BY
      vessel_receipts_hdr_uid;

IF @ApplyRepair = 1
BEGIN
    ;WITH repair_target AS
    (
        SELECT
              vh.vessel_receipts_hdr_uid
            , repair_arrival_date = CONVERT(datetime, f.estimated_arrival_date)
        FROM dbo.vessel_receipts_hdr AS vh
        INNER JOIN dbo.coats_mexico_shipment_receipt_build AS rb
          ON rb.vessel_receipts_hdr_uid = vh.vessel_receipts_hdr_uid
        INNER JOIN dbo.coats_mexico_shipment_file AS f
          ON f.shipment_file_id = rb.shipment_file_id
        WHERE vh.arrival_date IS NULL
          AND f.estimated_arrival_date IS NOT NULL
          AND vh.created_by = 'ADF'
          AND rb.created_by = 'ADF'
          AND (@TargetVesselReceiptsHdrUid IS NULL OR vh.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
    )
    UPDATE vh
    SET
          vh.arrival_date = rt.repair_arrival_date
        , vh.date_last_modified = dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL)
        , vh.last_maintained_by = 'ADF'
    FROM dbo.vessel_receipts_hdr AS vh
    INNER JOIN repair_target AS rt
      ON rt.vessel_receipts_hdr_uid = vh.vessel_receipts_hdr_uid;

    SELECT repaired_header_count = @@ROWCOUNT;
END;
GO
