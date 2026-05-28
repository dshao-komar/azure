/*
Capture before/after P21 data changes around GUI container receipt approval.

Purpose
-------
Use this in a test environment to answer: "What exactly changes when a user
approves a container receipt, selects Allocate Automatically, optionally marks
the container completely received, and saves?"

Workflow
--------
1. In SQL, set:
     @Mode = 'CAPTURE_BEFORE'
     @ContainerReceiptsHdrUid = <test container receipt header uid>
     @CaptureLabel = '<short label>'
   Run this script and note the returned capture_run_uid.

2. In the P21 GUI, approve/save the same container receipt with the exact test
   options the purchaser would use.

3. In SQL, set:
     @Mode = 'CAPTURE_AFTER'
     @ContainerReceiptsHdrUid = <same header uid>
     @CaptureLabel = '<same short label>'
   Run this script and note the returned capture_run_uid.

4. In SQL, set:
     @Mode = 'DIFF'
     @BeforeRunUid = <before capture_run_uid>
     @AfterRunUid = <after capture_run_uid>
   Run this script to see added/deleted/changed rows.

Notes
-----
- This script creates and writes only to P21Import debug capture tables.
- It does not update P21 business tables, allocations, receipts, transfers, or
  sales orders.
- Run this in test first. The capture tables are intentionally durable so the
  before/after comparison can survive the GUI step.
*/

USE P21Import;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Mode varchar(20) = 'CAPTURE_BEFORE'; -- CAPTURE_BEFORE, CAPTURE_AFTER, DIFF, LIST
DECLARE @ContainerReceiptsHdrUid int = NULL;
DECLARE @CaptureLabel nvarchar(100) = N'container approval allocation test';
DECLARE @EnvironmentNote nvarchar(200) = N'test';
DECLARE @BeforeRunUid int = NULL;
DECLARE @AfterRunUid int = NULL;
DECLARE @TargetLocationId decimal(19, 0) = 210;
DECLARE @TransferSearchDaysBefore int = 3;
DECLARE @TransferSearchDaysAfter int = 3;

IF OBJECT_ID('dbo.coats_mexico_gui_approval_capture_run', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.coats_mexico_gui_approval_capture_run
    (
          capture_run_uid int IDENTITY(1,1) NOT NULL
        , capture_label nvarchar(100) NOT NULL
        , capture_phase varchar(20) NOT NULL
        , environment_note nvarchar(200) NULL
        , container_receipts_hdr_uid int NULL
        , captured_at datetime NOT NULL
        , captured_by sysname NOT NULL
        , CONSTRAINT PK_coats_mexico_gui_approval_capture_run
            PRIMARY KEY CLUSTERED (capture_run_uid)
    );
END;

IF OBJECT_ID('dbo.coats_mexico_gui_approval_capture_row', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.coats_mexico_gui_approval_capture_row
    (
          capture_run_uid int NOT NULL
        , entity_name sysname NOT NULL
        , entity_key nvarchar(300) NOT NULL
        , row_hash varbinary(32) NOT NULL
        , row_json nvarchar(max) NOT NULL
        , CONSTRAINT PK_coats_mexico_gui_approval_capture_row
            PRIMARY KEY CLUSTERED (capture_run_uid, entity_name, entity_key)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = 'FK_coats_mexico_gui_approval_capture_row_run'
      AND parent_object_id = OBJECT_ID('dbo.coats_mexico_gui_approval_capture_row')
)
BEGIN
    ALTER TABLE dbo.coats_mexico_gui_approval_capture_row
    ADD CONSTRAINT FK_coats_mexico_gui_approval_capture_row_run
        FOREIGN KEY (capture_run_uid)
        REFERENCES dbo.coats_mexico_gui_approval_capture_run (capture_run_uid);
END;

IF @Mode = 'LIST'
BEGIN
    SELECT TOP (100)
          capture_run_uid
        , capture_label
        , capture_phase
        , environment_note
        , container_receipts_hdr_uid
        , captured_at
        , captured_by
    FROM dbo.coats_mexico_gui_approval_capture_run
    ORDER BY
          capture_run_uid DESC;

    RETURN;
END;

IF @Mode = 'DIFF'
BEGIN
    IF @BeforeRunUid IS NULL OR @AfterRunUid IS NULL
    BEGIN
        THROW 54000, 'Set @BeforeRunUid and @AfterRunUid when @Mode = DIFF.', 1;
    END;

    ;WITH before_rows AS
    (
        SELECT
              entity_name
            , entity_key
            , row_hash
            , row_json
        FROM dbo.coats_mexico_gui_approval_capture_row
        WHERE capture_run_uid = @BeforeRunUid
    )
    , after_rows AS
    (
        SELECT
              entity_name
            , entity_key
            , row_hash
            , row_json
        FROM dbo.coats_mexico_gui_approval_capture_row
        WHERE capture_run_uid = @AfterRunUid
    )
    SELECT
          diff_type =
              CASE
                  WHEN b.entity_key IS NULL THEN 'ADDED'
                  WHEN a.entity_key IS NULL THEN 'DELETED'
                  WHEN b.row_hash <> a.row_hash THEN 'CHANGED'
                  ELSE 'UNCHANGED'
              END
        , entity_name = COALESCE(b.entity_name, a.entity_name)
        , entity_key = COALESCE(b.entity_key, a.entity_key)
        , before_json = b.row_json
        , after_json = a.row_json
    FROM before_rows AS b
    FULL OUTER JOIN after_rows AS a
      ON a.entity_name = b.entity_name
     AND a.entity_key = b.entity_key
    WHERE
      (
          b.entity_key IS NULL
          OR a.entity_key IS NULL
          OR b.row_hash <> a.row_hash
      )
    ORDER BY
          CASE
              WHEN COALESCE(b.entity_name, a.entity_name) = 'container_receipts_hdr' THEN 10
              WHEN COALESCE(b.entity_name, a.entity_name) = 'container_receipts_line' THEN 20
              WHEN COALESCE(b.entity_name, a.entity_name) = 'vessel_receipts_container' THEN 30
              WHEN COALESCE(b.entity_name, a.entity_name) = 'vessel_receipts_line' THEN 40
              WHEN COALESCE(b.entity_name, a.entity_name) = 'transfer_hdr' THEN 50
              WHEN COALESCE(b.entity_name, a.entity_name) = 'transfer_line' THEN 60
              WHEN COALESCE(b.entity_name, a.entity_name) = 'oe_line_po' THEN 70
              WHEN COALESCE(b.entity_name, a.entity_name) = 'anticipated_allocation' THEN 80
              WHEN COALESCE(b.entity_name, a.entity_name) = 'oe_line' THEN 90
              WHEN COALESCE(b.entity_name, a.entity_name) = 'inv_loc' THEN 100
              ELSE 999
          END
        , COALESCE(b.entity_name, a.entity_name)
        , COALESCE(b.entity_key, a.entity_key);

    ;WITH before_rows AS
    (
        SELECT
              entity_name
            , entity_key
            , row_hash
        FROM dbo.coats_mexico_gui_approval_capture_row
        WHERE capture_run_uid = @BeforeRunUid
    )
    , after_rows AS
    (
        SELECT
              entity_name
            , entity_key
            , row_hash
        FROM dbo.coats_mexico_gui_approval_capture_row
        WHERE capture_run_uid = @AfterRunUid
    )
    SELECT
          entity_name = COALESCE(b.entity_name, a.entity_name)
        , added_count = SUM(CASE WHEN b.entity_key IS NULL THEN 1 ELSE 0 END)
        , deleted_count = SUM(CASE WHEN a.entity_key IS NULL THEN 1 ELSE 0 END)
        , changed_count = SUM(CASE WHEN b.entity_key IS NOT NULL AND a.entity_key IS NOT NULL AND b.row_hash <> a.row_hash THEN 1 ELSE 0 END)
    FROM before_rows AS b
    FULL OUTER JOIN after_rows AS a
      ON a.entity_name = b.entity_name
     AND a.entity_key = b.entity_key
    WHERE
      (
          b.entity_key IS NULL
          OR a.entity_key IS NULL
          OR b.row_hash <> a.row_hash
      )
    GROUP BY
          COALESCE(b.entity_name, a.entity_name)
    ORDER BY
          COALESCE(b.entity_name, a.entity_name);

    RETURN;
END;

IF @Mode NOT IN ('CAPTURE_BEFORE', 'CAPTURE_AFTER')
BEGIN
    THROW 54001, '@Mode must be CAPTURE_BEFORE, CAPTURE_AFTER, DIFF, or LIST.', 1;
END;

IF @ContainerReceiptsHdrUid IS NULL
BEGIN
    THROW 54002, 'Set @ContainerReceiptsHdrUid when capturing before/after.', 1;
END;

DECLARE @CaptureRunUid int;
DECLARE @CapturedAt datetime = P21.dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL);

INSERT INTO dbo.coats_mexico_gui_approval_capture_run
(
      capture_label
    , capture_phase
    , environment_note
    , container_receipts_hdr_uid
    , captured_at
    , captured_by
)
VALUES
(
      @CaptureLabel
    , @Mode
    , @EnvironmentNote
    , @ContainerReceiptsHdrUid
    , @CapturedAt
    , SUSER_SNAME()
);

SET @CaptureRunUid = SCOPE_IDENTITY();

DROP TABLE IF EXISTS #receipt_line;
DROP TABLE IF EXISTS #receipt_item;
DROP TABLE IF EXISTS #near_transfer;
DROP TABLE IF EXISTS #open_oe_line;

SELECT
      crl.container_receipts_hdr_uid
    , crl.container_receipts_line_uid
    , crl.vessel_receipts_line_uid
    , vl.vessel_receipts_hdr_uid
    , vl.vessel_receipts_container_uid
    , vl.line_no
    , vl.po_line_uid
    , pol.po_no
    , pol.line_no AS po_line_no
    , pol.inv_mast_uid
    , im.item_id
    , crl.qty_received
INTO #receipt_line
FROM P21.dbo.container_receipts_line AS crl
INNER JOIN P21.dbo.vessel_receipts_line AS vl
  ON vl.vessel_receipts_line_uid = crl.vessel_receipts_line_uid
INNER JOIN P21.dbo.po_line AS pol
  ON pol.po_line_uid = vl.po_line_uid
INNER JOIN P21.dbo.inv_mast AS im
  ON im.inv_mast_uid = pol.inv_mast_uid
WHERE crl.container_receipts_hdr_uid = @ContainerReceiptsHdrUid;

SELECT
      inv_mast_uid
    , item_id = MIN(item_id)
    , receipt_qty = SUM(qty_received)
INTO #receipt_item
FROM #receipt_line
GROUP BY
      inv_mast_uid;

SELECT
      th.transfer_no
INTO #near_transfer
FROM P21.dbo.container_receipts_hdr AS crh
INNER JOIN P21.dbo.transfer_hdr AS th
  ON th.date_created BETWEEN DATEADD(day, -@TransferSearchDaysBefore, crh.date_last_modified)
                         AND DATEADD(day, @TransferSearchDaysAfter, crh.date_last_modified)
INNER JOIN P21.dbo.transfer_line AS tl
  ON tl.transfer_no = th.transfer_no
INNER JOIN #receipt_item AS ri
  ON ri.inv_mast_uid = tl.inv_mast_uid
WHERE crh.container_receipts_hdr_uid = @ContainerReceiptsHdrUid
  AND (th.from_location_id = @TargetLocationId OR th.to_location_id = @TargetLocationId)
GROUP BY
      th.transfer_no;

SELECT DISTINCT
      ol.order_no
    , ol.line_no
INTO #open_oe_line
FROM #receipt_item AS ri
INNER JOIN P21.dbo.oe_line AS ol
  ON ol.inv_mast_uid = ri.inv_mast_uid
 AND ol.ship_loc_id = @TargetLocationId
INNER JOIN P21.dbo.oe_hdr AS oh
  ON oh.order_no = ol.order_no
WHERE COALESCE(ol.complete, 'N') = 'N'
  AND COALESCE(ol.cancel_flag, 'N') = 'N'
  AND COALESCE(oh.rma_flag, 'N') = 'N'
  AND COALESCE(oh.cancel_flag, 'N') = 'N';

DECLARE @RowsCaptured int = 0;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'container_receipts_hdr')
        , entity_key = CONCAT('container_receipts_hdr_uid=', crh.container_receipts_hdr_uid)
        , row_json =
          (
              SELECT crh.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.container_receipts_hdr AS crh
    WHERE crh.container_receipts_hdr_uid = @ContainerReceiptsHdrUid
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'container_receipts_line')
        , entity_key = CONCAT('container_receipts_line_uid=', crl.container_receipts_line_uid)
        , row_json =
          (
              SELECT crl.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.container_receipts_line AS crl
    WHERE crl.container_receipts_hdr_uid = @ContainerReceiptsHdrUid
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'vessel_receipts_hdr')
        , entity_key = CONCAT('vessel_receipts_hdr_uid=', vh.vessel_receipts_hdr_uid)
        , row_json =
          (
              SELECT vh.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.vessel_receipts_hdr AS vh
    WHERE EXISTS
    (
        SELECT 1
        FROM #receipt_line AS rl
        WHERE rl.vessel_receipts_hdr_uid = vh.vessel_receipts_hdr_uid
    )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'vessel_receipts_container')
        , entity_key = CONCAT('vessel_receipts_container_uid=', vc.vessel_receipts_container_uid)
        , row_json =
          (
              SELECT vc.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.vessel_receipts_container AS vc
    WHERE EXISTS
    (
        SELECT 1
        FROM #receipt_line AS rl
        WHERE rl.vessel_receipts_container_uid = vc.vessel_receipts_container_uid
    )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'vessel_receipts_line')
        , entity_key = CONCAT('vessel_receipts_line_uid=', vl.vessel_receipts_line_uid)
        , row_json =
          (
              SELECT vl.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.vessel_receipts_line AS vl
    WHERE EXISTS
    (
        SELECT 1
        FROM #receipt_line AS rl
        WHERE rl.vessel_receipts_line_uid = vl.vessel_receipts_line_uid
    )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'document_line_bin')
        , entity_key = CONCAT('document_no=', CONVERT(varchar(50), dlb.document_no), ';line_no=', dlb.line_no, ';bin_cd=', dlb.bin_cd, ';sub_line_no=', dlb.sub_line_no)
        , row_json =
          (
              SELECT dlb.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.document_line_bin AS dlb
    WHERE dlb.document_type = 'CR'
      AND dlb.document_no = @ContainerReceiptsHdrUid
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'transfer_hdr')
        , entity_key = CONCAT('transfer_no=', th.transfer_no)
        , row_json =
          (
              SELECT th.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.transfer_hdr AS th
    WHERE EXISTS
    (
        SELECT 1
        FROM #near_transfer AS nt
        WHERE nt.transfer_no = th.transfer_no
    )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'transfer_line')
        , entity_key = CONCAT('transfer_no=', tl.transfer_no, ';line_no=', tl.line_no)
        , row_json =
          (
              SELECT tl.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.transfer_line AS tl
    WHERE EXISTS
    (
        SELECT 1
        FROM #near_transfer AS nt
        WHERE nt.transfer_no = tl.transfer_no
    )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'oe_line_po')
        , entity_key = CONCAT('order_number=', olp.order_number, ';line_number=', olp.line_number, ';po_no=', olp.po_no, ';po_line_number=', olp.po_line_number, ';connection_type=', olp.connection_type)
        , row_json =
          (
              SELECT olp.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.oe_line_po AS olp
    WHERE EXISTS
    (
        SELECT 1
        FROM #near_transfer AS nt
        WHERE nt.transfer_no = olp.po_no
    )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'transfer_backorders')
        , entity_key = CONCAT('transfer_backorders_uid=', tb.transfer_backorders_uid)
        , row_json =
          (
              SELECT tb.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.transfer_backorders AS tb
    WHERE EXISTS
    (
        SELECT 1
        FROM #near_transfer AS nt
        WHERE nt.transfer_no = tb.transfer_no
    )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'anticipated_allocation')
        , entity_key = CONCAT('anticipated_allocation_uid=', aa.anticipated_allocation_uid)
        , row_json =
          (
              SELECT aa.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.anticipated_allocation AS aa
    WHERE aa.location_id = @TargetLocationId
      AND EXISTS
      (
          SELECT 1
          FROM #receipt_item AS ri
          WHERE ri.inv_mast_uid = aa.inv_mast_uid
      )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'inv_loc')
        , entity_key = CONCAT('location_id=', il.location_id, ';inv_mast_uid=', il.inv_mast_uid)
        , row_json =
          (
              SELECT
                    il.location_id
                  , il.inv_mast_uid
                  , il.qty_on_hand
                  , il.qty_allocated
                  , il.qty_backordered
                  , il.qty_reserved_due_in
                  , il.date_last_modified
                  , il.last_maintained_by
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.inv_loc AS il
    WHERE il.location_id IN (@TargetLocationId, 200)
      AND EXISTS
      (
          SELECT 1
          FROM #receipt_item AS ri
          WHERE ri.inv_mast_uid = il.inv_mast_uid
      )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'oe_hdr')
        , entity_key = CONCAT('order_no=', oh.order_no)
        , row_json =
          (
              SELECT oh.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.oe_hdr AS oh
    WHERE EXISTS
    (
        SELECT 1
        FROM #open_oe_line AS ol
        WHERE ol.order_no = oh.order_no
    )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(sysname, 'oe_line')
        , entity_key = CONCAT('order_no=', ol.order_no, ';line_no=', ol.line_no)
        , row_json =
          (
              SELECT ol.*
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM P21.dbo.oe_line AS ol
    WHERE EXISTS
    (
        SELECT 1
        FROM #open_oe_line AS x
        WHERE x.order_no = ol.order_no
          AND x.line_no = ol.line_no
    )
)
INSERT INTO dbo.coats_mexico_gui_approval_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

SELECT
      capture_run_uid = @CaptureRunUid
    , mode = @Mode
    , container_receipts_hdr_uid = @ContainerReceiptsHdrUid
    , captured_at = @CapturedAt
    , rows_captured = @RowsCaptured;

SELECT
      entity_name
    , row_count = COUNT(*)
FROM dbo.coats_mexico_gui_approval_capture_row
WHERE capture_run_uid = @CaptureRunUid
GROUP BY
      entity_name
ORDER BY
      entity_name;
GO
