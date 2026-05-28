/*
Repair Coats Mexico live P21 vessel_receipts_line container PO links and costs.

Default target is the known ADF-created live P21 header 762. Review the preview
result sets, then set @ApplyRepair = 1 to apply. Set
@TargetVesselReceiptsHdrUid = NULL only if you intentionally want to repair all
matching Coats ADF receipt builds with missing container_building_po_uid or
incorrect PO SKU costs.
*/

USE P21;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @TargetVesselReceiptsHdrUid int = 762;
DECLARE @ApplyRepair bit = 0;

DROP TABLE IF EXISTS #receipt_build;
DROP TABLE IF EXISTS #cbp_match;
DROP TABLE IF EXISTS #line_eval;
DROP TABLE IF EXISTS #repair_target;

SELECT
      vessel_receipts_hdr_uid
    , container_building_uid = MIN(container_building_uid)
    , distinct_container_building_count = COUNT(DISTINCT container_building_uid)
INTO #receipt_build
FROM P21Import.dbo.coats_mexico_shipment_receipt_build
WHERE created_by = 'ADF'
GROUP BY
      vessel_receipts_hdr_uid;

SELECT
      vl.vessel_receipts_line_uid
    , container_building_po_uid = MIN(cbp.container_building_po_uid)
    , match_count = COUNT(cbp.container_building_po_uid)
INTO #cbp_match
FROM P21.dbo.vessel_receipts_line AS vl
INNER JOIN #receipt_build AS rb
  ON rb.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
LEFT JOIN P21.dbo.container_building_po AS cbp
  ON cbp.container_building_uid = rb.container_building_uid
 AND cbp.po_line_uid = vl.po_line_uid
 AND ISNULL(cbp.po_line_schedule_uid, -1) = -1
 AND cbp.sequence_no = 10000
WHERE (@TargetVesselReceiptsHdrUid IS NULL OR vl.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
GROUP BY
      vl.vessel_receipts_line_uid;

SELECT
      vl.vessel_receipts_hdr_uid
    , vl.vessel_receipts_line_uid
    , vl.line_no
    , vl.po_line_uid
    , rb.container_building_uid
    , rb.distinct_container_building_count
    , current_container_building_po_uid = vl.container_building_po_uid
    , repair_container_building_po_uid = cm.container_building_po_uid
    , cm.match_count
    , current_po_sku_cost = vl.po_sku_cost
    , current_po_sku_cost_display = vl.po_sku_cost_display
    , repair_po_sku_cost = pol.unit_price
    , repair_po_sku_cost_display = pol.unit_price
    , issue =
        CASE
            WHEN rb.distinct_container_building_count <> 1 THEN 'AMBIGUOUS_RECEIPT_BUILD_CONTAINER'
            WHEN cm.match_count = 0 THEN 'MISSING_CONTAINER_BUILDING_PO'
            WHEN cm.match_count > 1 THEN 'AMBIGUOUS_CONTAINER_BUILDING_PO'
            WHEN pol.unit_price IS NULL THEN 'MISSING_PO_LINE_UNIT_PRICE'
            ELSE NULL
        END
INTO #line_eval
FROM P21.dbo.vessel_receipts_line AS vl
INNER JOIN P21.dbo.vessel_receipts_hdr AS vh
  ON vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
INNER JOIN #receipt_build AS rb
  ON rb.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
INNER JOIN #cbp_match AS cm
  ON cm.vessel_receipts_line_uid = vl.vessel_receipts_line_uid
LEFT JOIN P21.dbo.po_line AS pol
  ON pol.po_line_uid = vl.po_line_uid
WHERE vl.created_by = 'ADF'
  AND vh.created_by = 'ADF'
  AND (@TargetVesselReceiptsHdrUid IS NULL OR vl.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid);

SELECT *
INTO #repair_target
FROM #line_eval
WHERE issue IS NULL
  AND
  (
      current_container_building_po_uid IS NULL
      OR current_container_building_po_uid <> repair_container_building_po_uid
      OR COALESCE(current_po_sku_cost, 0) <> repair_po_sku_cost
      OR COALESCE(current_po_sku_cost_display, 0) <> repair_po_sku_cost_display
  );

SELECT
      action_to_take = CASE WHEN @ApplyRepair = 1 THEN 'APPLY' ELSE 'PREVIEW_ONLY' END
    , vessel_receipts_hdr_uid
    , repair_line_count = CONVERT(int, COUNT(*))
    , missing_container_building_po_uid_count = CONVERT(int, SUM(CASE WHEN current_container_building_po_uid IS NULL THEN 1 ELSE 0 END))
    , zero_or_null_po_sku_cost_count = CONVERT(int, SUM(CASE WHEN COALESCE(current_po_sku_cost, 0) = 0 THEN 1 ELSE 0 END))
    , zero_or_null_po_sku_cost_display_count = CONVERT(int, SUM(CASE WHEN COALESCE(current_po_sku_cost_display, 0) = 0 THEN 1 ELSE 0 END))
    , first_vessel_receipts_line_uid = MIN(vessel_receipts_line_uid)
    , last_vessel_receipts_line_uid = MAX(vessel_receipts_line_uid)
FROM #repair_target
GROUP BY
      vessel_receipts_hdr_uid
ORDER BY
      vessel_receipts_hdr_uid;

SELECT
      vessel_receipts_hdr_uid
    , vessel_receipts_line_uid
    , line_no
    , po_line_uid
    , container_building_uid
    , current_container_building_po_uid
    , repair_container_building_po_uid
    , current_po_sku_cost = CONVERT(varchar(50), current_po_sku_cost)
    , repair_po_sku_cost = CONVERT(varchar(50), repair_po_sku_cost)
    , current_po_sku_cost_display = CONVERT(varchar(50), current_po_sku_cost_display)
    , repair_po_sku_cost_display = CONVERT(varchar(50), repair_po_sku_cost_display)
FROM #repair_target
ORDER BY
      vessel_receipts_hdr_uid
    , line_no
    , vessel_receipts_line_uid;

SELECT
      vessel_receipts_hdr_uid
    , issue
    , issue_line_count = CONVERT(int, COUNT(*))
    , first_vessel_receipts_line_uid = MIN(vessel_receipts_line_uid)
    , last_vessel_receipts_line_uid = MAX(vessel_receipts_line_uid)
FROM #line_eval
WHERE issue IS NOT NULL
GROUP BY
      vessel_receipts_hdr_uid
    , issue
ORDER BY
      vessel_receipts_hdr_uid
    , issue;

IF @ApplyRepair = 1
BEGIN
    UPDATE vl
    SET
          vl.container_building_po_uid = rt.repair_container_building_po_uid
        , vl.po_sku_cost = rt.repair_po_sku_cost
        , vl.po_sku_cost_display = rt.repair_po_sku_cost_display
        , vl.date_last_modified = dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL)
        , vl.last_maintained_by = 'ADF'
    FROM P21.dbo.vessel_receipts_line AS vl
    INNER JOIN #repair_target AS rt
      ON rt.vessel_receipts_line_uid = vl.vessel_receipts_line_uid;

    SELECT repaired_line_count = @@ROWCOUNT;
END;

;WITH verify_lines AS
(
    SELECT
          vl.vessel_receipts_hdr_uid
        , vl.vessel_receipts_line_uid
        , cbp.container_building_po_uid
        , vl.container_building_po_uid AS vessel_line_container_building_po_uid
        , vl.po_sku_cost
        , vl.po_sku_cost_display
        , pol.unit_price
    FROM P21.dbo.vessel_receipts_line AS vl
    INNER JOIN P21.dbo.vessel_receipts_hdr AS vh
      ON vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
    INNER JOIN #receipt_build AS rb
      ON rb.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
    LEFT JOIN P21.dbo.container_building_po AS cbp
      ON cbp.container_building_uid = rb.container_building_uid
     AND cbp.po_line_uid = vl.po_line_uid
     AND ISNULL(cbp.po_line_schedule_uid, -1) = -1
     AND cbp.sequence_no = 10000
    LEFT JOIN P21.dbo.po_line AS pol
      ON pol.po_line_uid = vl.po_line_uid
    WHERE vl.created_by = 'ADF'
      AND vh.created_by = 'ADF'
      AND (@TargetVesselReceiptsHdrUid IS NULL OR vl.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid)
)
SELECT
      vessel_receipts_hdr_uid
    , vessel_line_count = CONVERT(int, COUNT(DISTINCT vessel_receipts_line_uid))
    , missing_container_building_po_uid_count = CONVERT(int, COUNT(DISTINCT CASE WHEN vessel_line_container_building_po_uid IS NULL THEN vessel_receipts_line_uid END))
    , mismatched_container_building_po_uid_count = CONVERT(int, COUNT(DISTINCT CASE WHEN vessel_line_container_building_po_uid <> container_building_po_uid THEN vessel_receipts_line_uid END))
    , po_sku_cost_mismatch_count = CONVERT(int, COUNT(DISTINCT CASE WHEN po_sku_cost <> unit_price THEN vessel_receipts_line_uid END))
    , po_sku_cost_display_mismatch_count = CONVERT(int, COUNT(DISTINCT CASE WHEN po_sku_cost_display <> unit_price THEN vessel_receipts_line_uid END))
FROM verify_lines
GROUP BY
      vessel_receipts_hdr_uid
ORDER BY
      vessel_receipts_hdr_uid;
GO
