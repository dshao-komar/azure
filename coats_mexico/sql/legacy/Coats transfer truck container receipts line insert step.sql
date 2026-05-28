SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ContainerReceiptsHdrUid int = 680;
DECLARE @now datetime = dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL);

IF NOT EXISTS (
    SELECT 1
    FROM dbo.container_receipts_hdr
    WHERE container_receipts_hdr_uid = @ContainerReceiptsHdrUid
)
BEGIN
    THROW 50000, 'container_receipts_hdr_uid does not exist in dbo.container_receipts_hdr', 1;
END;

IF OBJECT_ID('tempdb..#src') IS NOT NULL
    DROP TABLE #src;

-- Build a de-duped source set up front (no rn stored anywhere)
SELECT
    cmt.vessel_receipts_line_uid
  , MIN(cmt.Invoiced_Qty) AS Invoiced_Qty
  , MIN(cmt.po_line_uid)  AS po_line_uid
INTO #src
FROM P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24 cmt
WHERE cmt.vessel_receipts_line_uid IS NOT NULL
GROUP BY
    cmt.vessel_receipts_line_uid;

-- Remove anything already present (global by VRL UID)
DELETE s
FROM #src s
WHERE EXISTS (
    SELECT 1
    FROM dbo.container_receipts_line crl
    WHERE crl.vessel_receipts_line_uid = s.vessel_receipts_line_uid
);

DECLARE @n int = (SELECT COUNT(*) FROM #src);
IF @n = 0
    RETURN;

DECLARE @last_uid bigint;
EXEC dbo.p21_get_counter
     @strCounterID = 'container_receipts_line'
   , @iIncrementValue = @n
   , @LastValue = @last_uid OUTPUT;

DECLARE @first_uid bigint = @last_uid - @n + 1;

-- Sanity check: make sure the allocated block is above current max(uid)
DECLARE @max_uid bigint =
(
    SELECT MAX(container_receipts_line_uid)
    FROM dbo.container_receipts_line
);

IF @first_uid <= @max_uid
BEGIN
    THROW 50001, 'Allocated UID block overlaps existing container_receipts_line_uid values. Counter is behind again.', 1;
END;

;WITH numbered AS (
    SELECT
        s.vessel_receipts_line_uid
      , s.Invoiced_Qty
      , s.po_line_uid
      , ROW_NUMBER() OVER (ORDER BY s.vessel_receipts_line_uid) AS rn
    FROM #src s
)
INSERT INTO dbo.container_receipts_line
(
    container_receipts_line_uid
  , container_receipts_hdr_uid
  , vessel_receipts_line_uid
  , qty_received
  , unit_of_measure
  , unit_size
  , date_created
  , created_by
  , date_last_modified
  , last_maintained_by
  , complete_po_line_flag
  , transfer_flag
  , wrong_part_no_flag
  , currency_line_uid
  , exclude_from_landed_cost_flag
)
SELECT
    @first_uid + n.rn - 1
  , @ContainerReceiptsHdrUid
  , n.vessel_receipts_line_uid
  , n.Invoiced_Qty
  , vrl.container_uom
  , vrl.container_unit_size
  , @now
  , 'DSHAO'
  , @now
  , 'DSHAO'
  , CASE
        WHEN n.Invoiced_Qty + ISNULL(pol.qty_received, 0) >= ISNULL(pol.qty_ordered, 0) THEN 'Y'
        ELSE 'N'
    END
  , NULL
  , 'N'
  , NULL
  , 'N'
FROM numbered n
JOIN dbo.vessel_receipts_line vrl
  ON vrl.vessel_receipts_line_uid = n.vessel_receipts_line_uid
LEFT JOIN dbo.po_line pol
  ON pol.po_line_uid = n.po_line_uid
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.container_receipts_line crl WITH (UPDLOCK, HOLDLOCK)
    WHERE crl.vessel_receipts_line_uid = n.vessel_receipts_line_uid
);