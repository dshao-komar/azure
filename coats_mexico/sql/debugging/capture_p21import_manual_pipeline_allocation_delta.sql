/*
Capture before/after P21Import data changes across the full manual container workflow, including PO/SO link and allocation state.

Purpose
-------
Use this in a test environment to answer: "What exactly changes as a purchaser
goes through the manual path from container building, to vessel receipts, to
container receipt creation, to container receipt approval/allocation?"

Database topology
-----------------
- Business/application tables are read from P21Import (three-part qualified).
- Debug capture tables are created and written in KOMAR_DATA.dbo (this is the
  USE database), so they survive P21Import/P21Play rebuilds and never mingle
  with the P21 vendor schema. The two capture tables carry an intra-database
  foreign key, which is why they live together in KOMAR_DATA rather than being
  split across databases.

Workflow
--------
Run this script after setting @Mode and @ContainerName at each checkpoint:

1. @Mode = 'CAPTURE_BEFORE_CONTAINER_BUILDING'
   Run before the container is created in Container Building.

2. @Mode = 'CAPTURE_AFTER_CONTAINER_BUILDING'
   Run after the user creates/saves the container building record and PO rows.

3. @Mode = 'CAPTURE_AFTER_VESSEL_RECEIPTS'
   Run after vessel receipt header/container/lines are created.

4. @Mode = 'CAPTURE_AFTER_CONTAINER_RECEIPT_CREATION'
   Run after the unapproved container receipt is created.

5. @Mode = 'CAPTURE_AFTER_CONTAINER_RECEIPT_APPROVAL'
   Run after the user approves/saves with the intended Allocate Automatically
   and Mark Container Completely Received options.

6. @Mode = 'DIFF'
   Set @BeforeRunUid and @AfterRunUid to compare any two checkpoints.

Notes
-----
- This script creates and writes only to KOMAR_DATA.dbo debug capture tables.
- It reads P21 business/application tables from P21Import.
- It does not update P21 business tables, allocations, receipts, transfers,
  sales orders, general ledger, or counters.
- Key the test with a unique @ContainerName when possible, such as a trailer
  plus date suffix, so "before" captures prove no stale rows already exist.
- For the pre-container-building checkpoint, set at least one of the targeted
  PO/item fields below so the script can capture backorder/link/allocation
  state before any container/vessel rows exist.

General ledger tracking
-----------------------
Creating a vessel receipt in P21 posts a balanced pair of rows to dbo.gl:

    journal_id      = 'IR'
    source_type_cd  = 1674            (code_p21 description "Vessel Receipts")
    source          = vessel_receipts_hdr_uid (as varchar)
    description     = vessel_name
    seq 1           = credit A/P Vessel/Container account (e.g. 2161000)
    seq 2           = debit  Inventory In Transit account (e.g. 1345210)

This script captures those gl rows (and any gl_trans_x_dimension rows keyed on
their transaction_number) scoped to the in-scope vessel receipt header(s). The
gl rows do not exist until the vessel receipt is created, so a DIFF between
CAPTURE_AFTER_CONTAINER_BUILDING and CAPTURE_AFTER_VESSEL_RECEIPTS isolates
exactly what the vessel receipt window wrote to the general ledger.
*/

USE KOMAR_DATA;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Mode varchar(50) = 'CAPTURE_BEFORE_CONTAINER_BUILDING';
DECLARE @ContainerName nvarchar(255) = NULL;
DECLARE @CaptureLabel nvarchar(100) = N'container manual pipeline test';
DECLARE @EnvironmentNote nvarchar(200) = N'test';
DECLARE @BeforeRunUid int = NULL;
DECLARE @AfterRunUid int = NULL;
DECLARE @TargetLocationId decimal(19, 0) = 210;
DECLARE @TransferSearchDaysBefore int = 3;
DECLARE @TransferSearchDaysAfter int = 3;

-- Optional narrowing fields. Leave NULL unless the container name is not unique.
DECLARE @ContainerBuildingUid int = NULL;
DECLARE @VesselReceiptsHdrUid int = NULL;
DECLARE @VesselReceiptsContainerUid int = NULL;
DECLARE @ContainerReceiptsHdrUid int = NULL;
DECLARE @VesselReceiptNumber decimal(19, 0) = NULL;

-- Optional targeted PO/item fields for allocation diagnostics.
DECLARE @TargetPoNo decimal(19, 0) = NULL;
DECLARE @TargetPoLineNo int = NULL;
DECLARE @TargetPoLineUid int = NULL;
DECLARE @TargetItemId varchar(40) = NULL;
DECLARE @TargetInvMastUid int = NULL;
DECLARE @LinkLookAheadDays int = NULL;
DECLARE @LinkType char(1) = 'P';
DECLARE @CurrentDateNoTime datetime = NULL;

-- GL balances watch: capture dbo.balances for the accounts a Coats vessel receipt
-- posts to, so a before/after DIFF reveals whether/how vessel receipt creation
-- provisions the period balance row (carry-forward) and the trigger updates it.
DECLARE @GlWatchCompanyNo varchar(8) = 'KA';
DECLARE @GlWatchAccounts varchar(400) = '2161000,1345210';  -- A/P Vessel/Container - Coats, Inventory In Transit

IF OBJECT_ID('dbo.coats_mexico_manual_pipeline_capture_run', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.coats_mexico_manual_pipeline_capture_run
    (
          capture_run_uid int IDENTITY(1,1) NOT NULL
        , capture_label nvarchar(100) NOT NULL
        , capture_phase varchar(50) NOT NULL
        , environment_note nvarchar(200) NULL
        , container_name nvarchar(255) NULL
        , location_id decimal(19, 0) NULL
        , container_building_uid int NULL
        , vessel_receipts_hdr_uid int NULL
        , vessel_receipts_container_uid int NULL
        , container_receipts_hdr_uid int NULL
        , vessel_receipt_number decimal(19, 0) NULL
        , captured_at datetime NOT NULL
        , captured_by sysname NOT NULL
        , CONSTRAINT PK_coats_mexico_manual_pipeline_capture_run
            PRIMARY KEY CLUSTERED (capture_run_uid)
    );
END;

IF OBJECT_ID('dbo.coats_mexico_manual_pipeline_capture_row', 'U') IS NULL
BEGIN
    -- entity_name / entity_key are ASCII structural keys (table names + numeric
    -- ids), kept as varchar so the clustered PK stays under the 900-byte limit
    -- (int 4 + varchar 128 + varchar 400 = 532 bytes). row_json stays nvarchar
    -- to preserve unicode business data.
    CREATE TABLE dbo.coats_mexico_manual_pipeline_capture_row
    (
          capture_run_uid int NOT NULL
        , entity_name varchar(128) NOT NULL
        , entity_key varchar(400) NOT NULL
        , row_hash varbinary(32) NOT NULL
        , row_json nvarchar(max) NOT NULL
        , CONSTRAINT PK_coats_mexico_manual_pipeline_capture_row
            PRIMARY KEY CLUSTERED (capture_run_uid, entity_name, entity_key)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = 'FK_coats_mexico_manual_pipeline_capture_row_run'
      AND parent_object_id = OBJECT_ID('dbo.coats_mexico_manual_pipeline_capture_row')
)
BEGIN
    ALTER TABLE dbo.coats_mexico_manual_pipeline_capture_row
    ADD CONSTRAINT FK_coats_mexico_manual_pipeline_capture_row_run
        FOREIGN KEY (capture_run_uid)
        REFERENCES dbo.coats_mexico_manual_pipeline_capture_run (capture_run_uid);
END;

IF @Mode = 'LIST'
BEGIN
    SELECT TOP (100)
          capture_run_uid
        , capture_label
        , capture_phase
        , environment_note
        , container_name
        , location_id
        , container_building_uid
        , vessel_receipts_hdr_uid
        , vessel_receipts_container_uid
        , container_receipts_hdr_uid
        , vessel_receipt_number
        , captured_at
        , captured_by
    FROM dbo.coats_mexico_manual_pipeline_capture_run
    ORDER BY
          capture_run_uid DESC;

    RETURN;
END;

IF @Mode = 'DIFF'
BEGIN
    IF @BeforeRunUid IS NULL OR @AfterRunUid IS NULL
    BEGIN
        THROW 55000, 'Set @BeforeRunUid and @AfterRunUid when @Mode = DIFF.', 1;
    END;

    ;WITH before_rows AS
    (
        SELECT entity_name, entity_key, row_hash, row_json
        FROM dbo.coats_mexico_manual_pipeline_capture_row
        WHERE capture_run_uid = @BeforeRunUid
    )
    , after_rows AS
    (
        SELECT entity_name, entity_key, row_hash, row_json
        FROM dbo.coats_mexico_manual_pipeline_capture_row
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
    WHERE b.entity_key IS NULL
       OR a.entity_key IS NULL
       OR b.row_hash <> a.row_hash
    ORDER BY
          CASE
              WHEN COALESCE(b.entity_name, a.entity_name) = 'container_building' THEN 10
              WHEN COALESCE(b.entity_name, a.entity_name) = 'container_building_po' THEN 20
              WHEN COALESCE(b.entity_name, a.entity_name) = 'vessel_receipts_hdr' THEN 30
              WHEN COALESCE(b.entity_name, a.entity_name) = 'vessel_receipts_container' THEN 40
              WHEN COALESCE(b.entity_name, a.entity_name) = 'vessel_receipts_line' THEN 50
              WHEN COALESCE(b.entity_name, a.entity_name) = 'gl' THEN 55
              WHEN COALESCE(b.entity_name, a.entity_name) = 'gl_trans_x_dimension' THEN 56
              WHEN COALESCE(b.entity_name, a.entity_name) = 'balances' THEN 57
              WHEN COALESCE(b.entity_name, a.entity_name) = 'container_receipts_hdr' THEN 60
              WHEN COALESCE(b.entity_name, a.entity_name) = 'container_receipts_line' THEN 70
              WHEN COALESCE(b.entity_name, a.entity_name) = 'document_line_bin' THEN 80
              WHEN COALESCE(b.entity_name, a.entity_name) = 'transfer_hdr' THEN 90
              WHEN COALESCE(b.entity_name, a.entity_name) = 'transfer_line' THEN 100
              WHEN COALESCE(b.entity_name, a.entity_name) = 'oe_line_po' THEN 110
              WHEN COALESCE(b.entity_name, a.entity_name) = 'linkable_transaction' THEN 120
              WHEN COALESCE(b.entity_name, a.entity_name) = 'linkable_transaction_summary' THEN 130
              WHEN COALESCE(b.entity_name, a.entity_name) = 'transfer_backorders' THEN 140
              WHEN COALESCE(b.entity_name, a.entity_name) = 'anticipated_allocation' THEN 150
              WHEN COALESCE(b.entity_name, a.entity_name) = 'oe_line' THEN 160
              WHEN COALESCE(b.entity_name, a.entity_name) = 'inv_loc' THEN 170
              ELSE 999
          END
        , COALESCE(b.entity_name, a.entity_name)
        , COALESCE(b.entity_key, a.entity_key);

    ;WITH before_rows AS
    (
        SELECT entity_name, entity_key, row_hash
        FROM dbo.coats_mexico_manual_pipeline_capture_row
        WHERE capture_run_uid = @BeforeRunUid
    )
    , after_rows AS
    (
        SELECT entity_name, entity_key, row_hash
        FROM dbo.coats_mexico_manual_pipeline_capture_row
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
    WHERE b.entity_key IS NULL
       OR a.entity_key IS NULL
       OR b.row_hash <> a.row_hash
    GROUP BY
          COALESCE(b.entity_name, a.entity_name)
    ORDER BY
          COALESCE(b.entity_name, a.entity_name);

    RETURN;
END;

IF @Mode NOT IN
(
      'CAPTURE_BEFORE_CONTAINER_BUILDING'
    , 'CAPTURE_AFTER_CONTAINER_BUILDING'
    , 'CAPTURE_AFTER_VESSEL_RECEIPTS'
    , 'CAPTURE_AFTER_CONTAINER_RECEIPT_CREATION'
    , 'CAPTURE_AFTER_CONTAINER_RECEIPT_APPROVAL'
)
BEGIN
    THROW 55001, '@Mode must be a capture checkpoint, DIFF, or LIST.', 1;
END;

IF NULLIF(LTRIM(RTRIM(@ContainerName)), N'') IS NULL
   AND @ContainerBuildingUid IS NULL
   AND @VesselReceiptsHdrUid IS NULL
   AND @VesselReceiptsContainerUid IS NULL
   AND @ContainerReceiptsHdrUid IS NULL
   AND @VesselReceiptNumber IS NULL
BEGIN
    THROW 55002, 'Set @ContainerName or one optional UID/receipt number when capturing.', 1;
END;

DROP TABLE IF EXISTS #scope_container_building;
DROP TABLE IF EXISTS #scope_container_building_po;
DROP TABLE IF EXISTS #scope_vessel_hdr;
DROP TABLE IF EXISTS #scope_vessel_container;
DROP TABLE IF EXISTS #scope_vessel_line;
DROP TABLE IF EXISTS #scope_container_receipt_hdr;
DROP TABLE IF EXISTS #scope_container_receipt_line;
DROP TABLE IF EXISTS #scope_item;
DROP TABLE IF EXISTS #target_po_line;
DROP TABLE IF EXISTS #near_transfer;
DROP TABLE IF EXISTS #open_oe_line;
DROP TABLE IF EXISTS #scope_gl;

CREATE TABLE #scope_container_building
(
      container_building_uid int NOT NULL PRIMARY KEY
);

CREATE TABLE #scope_container_building_po
(
      container_building_po_uid int NOT NULL PRIMARY KEY
    , po_line_uid int NULL
);

CREATE TABLE #scope_vessel_hdr
(
      vessel_receipts_hdr_uid int NOT NULL PRIMARY KEY
);

CREATE TABLE #scope_vessel_container
(
      vessel_receipts_container_uid int NOT NULL PRIMARY KEY
    , vessel_receipts_hdr_uid int NULL
    , container_building_uid int NULL
);

CREATE TABLE #scope_vessel_line
(
      vessel_receipts_line_uid int NOT NULL PRIMARY KEY
    , vessel_receipts_hdr_uid int NULL
    , vessel_receipts_container_uid int NULL
    , po_line_uid int NULL
    , container_building_po_uid int NULL
);

CREATE TABLE #scope_container_receipt_hdr
(
      container_receipts_hdr_uid int NOT NULL PRIMARY KEY
    , vessel_receipts_container_uid int NULL
    , date_created datetime NULL
    , date_last_modified datetime NULL
);

CREATE TABLE #scope_container_receipt_line
(
      container_receipts_line_uid int NOT NULL PRIMARY KEY
    , container_receipts_hdr_uid int NULL
    , vessel_receipts_line_uid int NULL
);

CREATE TABLE #scope_item
(
      inv_mast_uid int NOT NULL PRIMARY KEY
    , item_id varchar(40) NULL
);

CREATE TABLE #target_po_line
(
      po_line_uid int NOT NULL PRIMARY KEY
    , po_no decimal(19, 0) NULL
    , po_line_no int NULL
    , inv_mast_uid int NULL
    , item_id varchar(40) NULL
);

CREATE TABLE #near_transfer
(
      transfer_no decimal(19, 0) NOT NULL PRIMARY KEY
);

SET @CurrentDateNoTime = COALESCE(@CurrentDateNoTime, CONVERT(date, P21Import.dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL)));

INSERT INTO #target_po_line
(
      po_line_uid
    , po_no
    , po_line_no
    , inv_mast_uid
    , item_id
)
SELECT
      pol.po_line_uid
    , pol.po_no
    , pol.line_no
    , pol.inv_mast_uid
    , im.item_id
FROM P21Import.dbo.po_line AS pol
INNER JOIN P21Import.dbo.inv_mast AS im
  ON im.inv_mast_uid = pol.inv_mast_uid
WHERE
  (
      (@TargetPoLineUid IS NOT NULL AND pol.po_line_uid = @TargetPoLineUid)
      OR
      (
          @TargetPoNo IS NOT NULL
          AND pol.po_no = @TargetPoNo
          AND (@TargetPoLineNo IS NULL OR pol.line_no = @TargetPoLineNo)
          AND (@TargetInvMastUid IS NULL OR pol.inv_mast_uid = @TargetInvMastUid)
          AND (@TargetItemId IS NULL OR im.item_id = @TargetItemId)
      )
      OR
      (
          @TargetInvMastUid IS NOT NULL
          AND pol.inv_mast_uid = @TargetInvMastUid
          AND @TargetPoNo IS NULL
          AND @TargetPoLineUid IS NULL
      )
      OR
      (
          @TargetItemId IS NOT NULL
          AND im.item_id = @TargetItemId
          AND @TargetPoNo IS NULL
          AND @TargetPoLineUid IS NULL
      )
  );

CREATE TABLE #open_oe_line
(
      order_no decimal(19, 0) NOT NULL
    , line_no decimal(19, 0) NOT NULL
    , PRIMARY KEY (order_no, line_no)
);

INSERT INTO #scope_container_building (container_building_uid)
SELECT cb.container_building_uid
FROM P21Import.dbo.container_building AS cb
WHERE
  (
      (@ContainerBuildingUid IS NOT NULL AND cb.container_building_uid = @ContainerBuildingUid)
      OR (@ContainerName IS NOT NULL AND cb.container_name = @ContainerName)
  )
  AND (@TargetLocationId IS NULL OR cb.location_id = @TargetLocationId);

INSERT INTO #scope_vessel_container
(
      vessel_receipts_container_uid
    , vessel_receipts_hdr_uid
    , container_building_uid
)
SELECT
      vc.vessel_receipts_container_uid
    , vc.vessel_receipts_hdr_uid
    , vc.container_building_uid
FROM P21Import.dbo.vessel_receipts_container AS vc
INNER JOIN P21Import.dbo.vessel_receipts_hdr AS vh
  ON vh.vessel_receipts_hdr_uid = vc.vessel_receipts_hdr_uid
WHERE
  (
      (@VesselReceiptsContainerUid IS NOT NULL AND vc.vessel_receipts_container_uid = @VesselReceiptsContainerUid)
      OR (@VesselReceiptsHdrUid IS NOT NULL AND vc.vessel_receipts_hdr_uid = @VesselReceiptsHdrUid)
      OR (@ContainerName IS NOT NULL AND vc.container_name = @ContainerName)
      OR (@ContainerBuildingUid IS NOT NULL AND vc.container_building_uid = @ContainerBuildingUid)
      OR (@VesselReceiptNumber IS NOT NULL AND vh.vessel_receipt_number = @VesselReceiptNumber)
  )
  AND (@TargetLocationId IS NULL OR vh.location_id = @TargetLocationId);

INSERT INTO #scope_container_building (container_building_uid)
SELECT DISTINCT vc.container_building_uid
FROM #scope_vessel_container AS vc
WHERE vc.container_building_uid IS NOT NULL
  AND NOT EXISTS
  (
      SELECT 1
      FROM #scope_container_building AS cb
      WHERE cb.container_building_uid = vc.container_building_uid
  );

INSERT INTO #scope_vessel_hdr (vessel_receipts_hdr_uid)
SELECT vh.vessel_receipts_hdr_uid
FROM P21Import.dbo.vessel_receipts_hdr AS vh
WHERE
  (
      (@VesselReceiptsHdrUid IS NOT NULL AND vh.vessel_receipts_hdr_uid = @VesselReceiptsHdrUid)
      OR (@VesselReceiptNumber IS NOT NULL AND vh.vessel_receipt_number = @VesselReceiptNumber)
      OR (@ContainerName IS NOT NULL AND vh.vessel_name = @ContainerName)
  )
  AND (@TargetLocationId IS NULL OR vh.location_id = @TargetLocationId)
UNION
SELECT DISTINCT vessel_receipts_hdr_uid
FROM #scope_vessel_container
WHERE vessel_receipts_hdr_uid IS NOT NULL;

INSERT INTO #scope_vessel_container
(
      vessel_receipts_container_uid
    , vessel_receipts_hdr_uid
    , container_building_uid
)
SELECT
      vc.vessel_receipts_container_uid
    , vc.vessel_receipts_hdr_uid
    , vc.container_building_uid
FROM P21Import.dbo.vessel_receipts_container AS vc
WHERE EXISTS
(
    SELECT 1
    FROM #scope_vessel_hdr AS vh
    WHERE vh.vessel_receipts_hdr_uid = vc.vessel_receipts_hdr_uid
)
AND (@ContainerName IS NULL OR vc.container_name = @ContainerName)
AND NOT EXISTS
(
    SELECT 1
    FROM #scope_vessel_container AS existing
    WHERE existing.vessel_receipts_container_uid = vc.vessel_receipts_container_uid
);

INSERT INTO #scope_container_receipt_hdr
(
      container_receipts_hdr_uid
    , vessel_receipts_container_uid
    , date_created
    , date_last_modified
)
SELECT
      crh.container_receipts_hdr_uid
    , crh.vessel_receipts_container_uid
    , crh.date_created
    , crh.date_last_modified
FROM P21Import.dbo.container_receipts_hdr AS crh
WHERE (@ContainerReceiptsHdrUid IS NULL OR crh.container_receipts_hdr_uid = @ContainerReceiptsHdrUid)
  AND
  (
      EXISTS
      (
          SELECT 1
          FROM #scope_vessel_container AS vc
          WHERE vc.vessel_receipts_container_uid = crh.vessel_receipts_container_uid
      )
      OR @ContainerReceiptsHdrUid IS NOT NULL
  );

INSERT INTO #scope_vessel_container
(
      vessel_receipts_container_uid
    , vessel_receipts_hdr_uid
    , container_building_uid
)
SELECT
      vc.vessel_receipts_container_uid
    , vc.vessel_receipts_hdr_uid
    , vc.container_building_uid
FROM P21Import.dbo.vessel_receipts_container AS vc
WHERE EXISTS
(
    SELECT 1
    FROM #scope_container_receipt_hdr AS crh
    WHERE crh.vessel_receipts_container_uid = vc.vessel_receipts_container_uid
)
AND NOT EXISTS
(
    SELECT 1
    FROM #scope_vessel_container AS existing
    WHERE existing.vessel_receipts_container_uid = vc.vessel_receipts_container_uid
);

INSERT INTO #scope_vessel_hdr (vessel_receipts_hdr_uid)
SELECT DISTINCT vc.vessel_receipts_hdr_uid
FROM #scope_vessel_container AS vc
WHERE vc.vessel_receipts_hdr_uid IS NOT NULL
  AND NOT EXISTS
  (
      SELECT 1
      FROM #scope_vessel_hdr AS vh
      WHERE vh.vessel_receipts_hdr_uid = vc.vessel_receipts_hdr_uid
  );

INSERT INTO #scope_container_building (container_building_uid)
SELECT DISTINCT vc.container_building_uid
FROM #scope_vessel_container AS vc
WHERE vc.container_building_uid IS NOT NULL
  AND NOT EXISTS
  (
      SELECT 1
      FROM #scope_container_building AS cb
      WHERE cb.container_building_uid = vc.container_building_uid
  );

INSERT INTO #scope_container_building_po
(
      container_building_po_uid
    , po_line_uid
)
SELECT
      cbp.container_building_po_uid
    , cbp.po_line_uid
FROM P21Import.dbo.container_building_po AS cbp
WHERE EXISTS
(
    SELECT 1
    FROM #scope_container_building AS cb
    WHERE cb.container_building_uid = cbp.container_building_uid
);

INSERT INTO #scope_vessel_line
(
      vessel_receipts_line_uid
    , vessel_receipts_hdr_uid
    , vessel_receipts_container_uid
    , po_line_uid
    , container_building_po_uid
)
SELECT
      vl.vessel_receipts_line_uid
    , vl.vessel_receipts_hdr_uid
    , vl.vessel_receipts_container_uid
    , vl.po_line_uid
    , vl.container_building_po_uid
FROM P21Import.dbo.vessel_receipts_line AS vl
WHERE EXISTS
(
    SELECT 1
    FROM #scope_vessel_hdr AS vh
    WHERE vh.vessel_receipts_hdr_uid = vl.vessel_receipts_hdr_uid
)
OR EXISTS
(
    SELECT 1
    FROM #scope_vessel_container AS vc
    WHERE vc.vessel_receipts_container_uid = vl.vessel_receipts_container_uid
)
OR EXISTS
(
    SELECT 1
    FROM #scope_container_building_po AS cbp
    WHERE cbp.container_building_po_uid = vl.container_building_po_uid
);

INSERT INTO #scope_container_building_po
(
      container_building_po_uid
    , po_line_uid
)
SELECT
      cbp.container_building_po_uid
    , cbp.po_line_uid
FROM P21Import.dbo.container_building_po AS cbp
WHERE EXISTS
(
    SELECT 1
    FROM #scope_vessel_line AS vl
    WHERE vl.container_building_po_uid = cbp.container_building_po_uid
)
AND NOT EXISTS
(
    SELECT 1
    FROM #scope_container_building_po AS existing
    WHERE existing.container_building_po_uid = cbp.container_building_po_uid
);

INSERT INTO #scope_container_receipt_line
(
      container_receipts_line_uid
    , container_receipts_hdr_uid
    , vessel_receipts_line_uid
)
SELECT
      crl.container_receipts_line_uid
    , crl.container_receipts_hdr_uid
    , crl.vessel_receipts_line_uid
FROM P21Import.dbo.container_receipts_line AS crl
WHERE EXISTS
(
    SELECT 1
    FROM #scope_container_receipt_hdr AS crh
    WHERE crh.container_receipts_hdr_uid = crl.container_receipts_hdr_uid
)
OR EXISTS
(
    SELECT 1
    FROM #scope_vessel_line AS vl
    WHERE vl.vessel_receipts_line_uid = crl.vessel_receipts_line_uid
);

INSERT INTO #target_po_line
(
      po_line_uid
    , po_no
    , po_line_no
    , inv_mast_uid
    , item_id
)
SELECT DISTINCT
      pol.po_line_uid
    , pol.po_no
    , pol.line_no
    , pol.inv_mast_uid
    , im.item_id
FROM P21Import.dbo.po_line AS pol
INNER JOIN P21Import.dbo.inv_mast AS im
  ON im.inv_mast_uid = pol.inv_mast_uid
WHERE
  (
      EXISTS
      (
          SELECT 1
          FROM #scope_container_building_po AS cbp
          WHERE cbp.po_line_uid = pol.po_line_uid
      )
      OR EXISTS
      (
          SELECT 1
          FROM #scope_vessel_line AS vl
          WHERE vl.po_line_uid = pol.po_line_uid
      )
  )
  AND NOT EXISTS
  (
      SELECT 1
      FROM #target_po_line AS existing
      WHERE existing.po_line_uid = pol.po_line_uid
  );

INSERT INTO #scope_item
(
      inv_mast_uid
    , item_id
)
SELECT DISTINCT
      pol.inv_mast_uid
    , im.item_id
FROM P21Import.dbo.po_line AS pol
INNER JOIN P21Import.dbo.inv_mast AS im
  ON im.inv_mast_uid = pol.inv_mast_uid
WHERE EXISTS
(
    SELECT 1
    FROM #scope_container_building_po AS cbp
    WHERE cbp.po_line_uid = pol.po_line_uid
)
OR EXISTS
(
    SELECT 1
    FROM #scope_vessel_line AS vl
    WHERE vl.po_line_uid = pol.po_line_uid
)
OR EXISTS
(
    SELECT 1
    FROM #target_po_line AS tpl
    WHERE tpl.po_line_uid = pol.po_line_uid
);

INSERT INTO #near_transfer (transfer_no)
SELECT th.transfer_no
FROM P21Import.dbo.transfer_hdr AS th
INNER JOIN P21Import.dbo.transfer_line AS tl
  ON tl.transfer_no = th.transfer_no
INNER JOIN #scope_item AS si
  ON si.inv_mast_uid = tl.inv_mast_uid
WHERE (th.from_location_id = @TargetLocationId OR th.to_location_id = @TargetLocationId)
  AND
  (
      EXISTS
      (
          SELECT 1
          FROM #scope_container_receipt_hdr AS crh
          WHERE th.date_created BETWEEN DATEADD(day, -@TransferSearchDaysBefore, COALESCE(crh.date_last_modified, crh.date_created))
                                    AND DATEADD(day, @TransferSearchDaysAfter, COALESCE(crh.date_last_modified, crh.date_created))
      )
      OR
      (
          @Mode = 'CAPTURE_AFTER_CONTAINER_RECEIPT_APPROVAL'
          AND th.date_created BETWEEN DATEADD(day, -@TransferSearchDaysBefore, P21Import.dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL))
                                  AND DATEADD(day, @TransferSearchDaysAfter, P21Import.dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL))
      )
  )
GROUP BY
      th.transfer_no;

INSERT INTO #open_oe_line
(
      order_no
    , line_no
)
SELECT DISTINCT
      ol.order_no
    , ol.line_no
FROM #scope_item AS si
INNER JOIN P21Import.dbo.oe_line AS ol
  ON ol.inv_mast_uid = si.inv_mast_uid
 AND ol.ship_loc_id = @TargetLocationId
INNER JOIN P21Import.dbo.oe_hdr AS oh
  ON oh.order_no = ol.order_no
WHERE COALESCE(ol.complete, 'N') = 'N'
  AND COALESCE(ol.cancel_flag, 'N') = 'N'
  AND COALESCE(oh.rma_flag, 'N') = 'N'
  AND COALESCE(oh.cancel_flag, 'N') = 'N';

INSERT INTO #open_oe_line
(
      order_no
    , line_no
)
SELECT DISTINCT
      olp.order_number
    , olp.line_number
FROM P21Import.dbo.oe_line_po AS olp
WHERE EXISTS
(
    SELECT 1
    FROM #target_po_line AS tpl
    WHERE tpl.po_no = olp.po_no
      AND tpl.po_line_no = olp.po_line_number
)
AND NOT EXISTS
(
    SELECT 1
    FROM #open_oe_line AS existing
    WHERE existing.order_no = olp.order_number
      AND existing.line_no = olp.line_number
);

-- General ledger rows posted by vessel receipt creation.
-- gl.source holds the vessel_receipts_hdr_uid (as varchar) for source_type_cd
-- 1674 (Vessel Receipts). Also match vessel_receipt_number defensively in case
-- a header ever numbers differently from its uid. Driven from the small scope
-- header set so gl is seeked by source, not scanned.
CREATE TABLE #scope_gl
(
      gl_uid int NOT NULL PRIMARY KEY
    , transaction_number decimal(19, 0) NULL
);

INSERT INTO #scope_gl
(
      gl_uid
    , transaction_number
)
SELECT DISTINCT
      gl.gl_uid
    , gl.transaction_number
FROM #scope_vessel_hdr AS svh
INNER JOIN P21Import.dbo.vessel_receipts_hdr AS vh
  ON vh.vessel_receipts_hdr_uid = svh.vessel_receipts_hdr_uid
INNER JOIN P21Import.dbo.gl AS gl
  ON gl.source_type_cd = 1674
 AND gl.source IN
     (
         CONVERT(varchar(50), vh.vessel_receipts_hdr_uid)
       , CONVERT(varchar(50), vh.vessel_receipt_number)
     );

DECLARE @DiscoveredContainerBuildingUid int = (SELECT MIN(container_building_uid) FROM #scope_container_building);
DECLARE @DiscoveredVesselReceiptsHdrUid int = (SELECT MIN(vessel_receipts_hdr_uid) FROM #scope_vessel_hdr);
DECLARE @DiscoveredVesselReceiptsContainerUid int = (SELECT MIN(vessel_receipts_container_uid) FROM #scope_vessel_container);
DECLARE @DiscoveredContainerReceiptsHdrUid int = (SELECT MIN(container_receipts_hdr_uid) FROM #scope_container_receipt_hdr);
DECLARE @DiscoveredVesselReceiptNumber decimal(19, 0) =
(
    SELECT MIN(vh.vessel_receipt_number)
    FROM P21Import.dbo.vessel_receipts_hdr AS vh
    WHERE EXISTS
    (
        SELECT 1
        FROM #scope_vessel_hdr AS scope_vh
        WHERE scope_vh.vessel_receipts_hdr_uid = vh.vessel_receipts_hdr_uid
    )
);

DECLARE @CaptureRunUid int;
DECLARE @CapturedAt datetime = P21Import.dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL);

INSERT INTO dbo.coats_mexico_manual_pipeline_capture_run
(
      capture_label
    , capture_phase
    , environment_note
    , container_name
    , location_id
    , container_building_uid
    , vessel_receipts_hdr_uid
    , vessel_receipts_container_uid
    , container_receipts_hdr_uid
    , vessel_receipt_number
    , captured_at
    , captured_by
)
VALUES
(
      @CaptureLabel
    , @Mode
    , @EnvironmentNote
    , @ContainerName
    , @TargetLocationId
    , @DiscoveredContainerBuildingUid
    , @DiscoveredVesselReceiptsHdrUid
    , @DiscoveredVesselReceiptsContainerUid
    , @DiscoveredContainerReceiptsHdrUid
    , @DiscoveredVesselReceiptNumber
    , @CapturedAt
    , SUSER_SNAME()
);

SET @CaptureRunUid = SCOPE_IDENTITY();

DECLARE @RowsCaptured int = 0;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'container_building')
        , entity_key = CONCAT('container_building_uid=', cb.container_building_uid)
        , row_json = (SELECT cb.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.container_building AS cb
    WHERE EXISTS
    (
        SELECT 1
        FROM #scope_container_building AS scope_cb
        WHERE scope_cb.container_building_uid = cb.container_building_uid
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'container_building_po')
        , entity_key = CONCAT('container_building_po_uid=', cbp.container_building_po_uid)
        , row_json = (SELECT cbp.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.container_building_po AS cbp
    WHERE EXISTS
    (
        SELECT 1
        FROM #scope_container_building_po AS scope_cbp
        WHERE scope_cbp.container_building_po_uid = cbp.container_building_po_uid
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'vessel_receipts_hdr')
        , entity_key = CONCAT('vessel_receipts_hdr_uid=', vh.vessel_receipts_hdr_uid)
        , row_json = (SELECT vh.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.vessel_receipts_hdr AS vh
    WHERE EXISTS
    (
        SELECT 1
        FROM #scope_vessel_hdr AS scope_vh
        WHERE scope_vh.vessel_receipts_hdr_uid = vh.vessel_receipts_hdr_uid
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'vessel_receipts_container')
        , entity_key = CONCAT('vessel_receipts_container_uid=', vc.vessel_receipts_container_uid)
        , row_json = (SELECT vc.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.vessel_receipts_container AS vc
    WHERE EXISTS
    (
        SELECT 1
        FROM #scope_vessel_container AS scope_vc
        WHERE scope_vc.vessel_receipts_container_uid = vc.vessel_receipts_container_uid
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'vessel_receipts_line')
        , entity_key = CONCAT('vessel_receipts_line_uid=', vl.vessel_receipts_line_uid)
        , row_json = (SELECT vl.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.vessel_receipts_line AS vl
    WHERE EXISTS
    (
        SELECT 1
        FROM #scope_vessel_line AS scope_vl
        WHERE scope_vl.vessel_receipts_line_uid = vl.vessel_receipts_line_uid
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'gl')
        , entity_key = CONCAT('gl_uid=', gl.gl_uid)
        , row_json = (SELECT gl.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.gl AS gl
    WHERE EXISTS
    (
        SELECT 1
        FROM #scope_gl AS sg
        WHERE sg.gl_uid = gl.gl_uid
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'gl_trans_x_dimension')
        , entity_key = CONCAT('gl_trans_x_dimension_uid=', gtd.gl_trans_x_dimension_uid)
        , row_json = (SELECT gtd.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.gl_trans_x_dimension AS gtd
    WHERE gtd.transaction_number IS NOT NULL
      AND EXISTS
      (
          SELECT 1
          FROM #scope_gl AS sg
          WHERE sg.transaction_number = gtd.transaction_number
      )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

-- GL account balances for the watched accounts (all periods/years), so a DIFF
-- shows period rows ADDED (provisioned by vessel receipt creation) vs CHANGED
-- (rolled by the t_gl_iu trigger). Seeded carry-forward can be backed out as
-- (cumulative_after - posted_amount).
;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'balances')
        , entity_key = CONCAT('company_no=', b.company_no, ';account_no=', b.account_no, ';period=', b.period, ';year_for_period=', b.year_for_period, ';currency_id=', b.currency_id)
        , row_json = (SELECT b.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.balances AS b
    WHERE b.company_no = @GlWatchCompanyNo
      -- delimited-LIKE membership test. STRING_SPLIT needs compat level >= 130,
      -- and this script runs under USE KOMAR_DATA (compat 100), so built-in
      -- resolution happens there, not in P21Import. @GlWatchAccounts is a comma
      -- list with no spaces.
      AND (',' + @GlWatchAccounts + ',') LIKE ('%,' + RTRIM(LTRIM(b.account_no)) + ',%')
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'container_receipts_hdr')
        , entity_key = CONCAT('container_receipts_hdr_uid=', crh.container_receipts_hdr_uid)
        , row_json = (SELECT crh.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.container_receipts_hdr AS crh
    WHERE EXISTS
    (
        SELECT 1
        FROM #scope_container_receipt_hdr AS scope_crh
        WHERE scope_crh.container_receipts_hdr_uid = crh.container_receipts_hdr_uid
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'container_receipts_line')
        , entity_key = CONCAT('container_receipts_line_uid=', crl.container_receipts_line_uid)
        , row_json = (SELECT crl.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.container_receipts_line AS crl
    WHERE EXISTS
    (
        SELECT 1
        FROM #scope_container_receipt_line AS scope_crl
        WHERE scope_crl.container_receipts_line_uid = crl.container_receipts_line_uid
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'document_line_bin')
        , entity_key = CONCAT('document_no=', CONVERT(varchar(50), dlb.document_no), ';line_no=', dlb.line_no, ';bin_cd=', dlb.bin_cd, ';sub_line_no=', dlb.sub_line_no)
        , row_json = (SELECT dlb.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.document_line_bin AS dlb
    WHERE dlb.document_type = 'CR'
      AND EXISTS
      (
          SELECT 1
          FROM #scope_container_receipt_hdr AS crh
          WHERE crh.container_receipts_hdr_uid = dlb.document_no
      )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'transfer_hdr')
        , entity_key = CONCAT('transfer_no=', th.transfer_no)
        , row_json = (SELECT th.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.transfer_hdr AS th
    WHERE EXISTS
    (
        SELECT 1
        FROM #near_transfer AS nt
        WHERE nt.transfer_no = th.transfer_no
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'transfer_line')
        , entity_key = CONCAT('transfer_no=', tl.transfer_no, ';line_no=', tl.line_no)
        , row_json = (SELECT tl.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.transfer_line AS tl
    WHERE EXISTS
    (
        SELECT 1
        FROM #near_transfer AS nt
        WHERE nt.transfer_no = tl.transfer_no
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'oe_line_po')
        , entity_key = CONCAT('order_number=', olp.order_number, ';line_number=', olp.line_number, ';po_no=', olp.po_no, ';po_line_number=', olp.po_line_number, ';connection_type=', olp.connection_type)
        , row_json = (SELECT olp.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.oe_line_po AS olp
    WHERE EXISTS
    (
        SELECT 1
        FROM #target_po_line AS tpl
        WHERE tpl.po_no = olp.po_no
          AND tpl.po_line_no = olp.po_line_number
    )
    OR EXISTS
    (
        SELECT 1
        FROM #open_oe_line AS ol
        WHERE ol.order_no = olp.order_number
          AND ol.line_no = olp.line_number
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'linkable_transaction')
        , entity_key = CONCAT('po_line_uid=', tpl.po_line_uid, ';order_no=', lt.order_no, ';line_no=', lt.line_no, ';oe_line_uid=', lt.oe_line_uid)
        , row_json =
          (
              SELECT
                    capture_phase = @Mode
                  , tpl.po_no
                  , tpl.po_line_no
                  , tpl.po_line_uid
                  , target_item_id = tpl.item_id
                  , lt.order_no
                  , lt.item_id
                  , lt.order_date
                  , lt.item_desc
                  , lt.customer_name
                  , lt.qty_ordered
                  , lt.required_date
                  , lt.qty_allocated
                  , lt.qty_on_pick_tickets
                  , lt.qty_invoiced
                  , lt.order_quantity
                  , lt.unit_size
                  , lt.line_no
                  , lt.qty_canceled
                  , lt.qty_staged
                  , lt.c_ReleaseScheduleQty
                  , lt.c_OpenReleaseSchedule
                  , lt.linked_qty
                  , lt.c_qty_on_other_po
                  , lt.oe_line_uid
                  , lt.source_loc_id
                  , lt.c_ordertype
                  , lt.location_id
                  , lt.original_linked_qty
                  , lt.qty_confirmed
                  , lt.inv_mast_uid
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM #target_po_line AS tpl
    CROSS APPLY P21Import.dbo.p21_fnt_get_linkable_transactions
    (
          CONVERT(int, @TargetLocationId)
        , tpl.item_id
        , CONVERT(int, tpl.po_no)
        , tpl.po_line_no
        , @LinkLookAheadDays
        , NULL
        , 'N'
        , tpl.po_line_uid
        , 'N'
        , 'N'
        , @LinkType
        , @CurrentDateNoTime
    ) AS lt
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'linkable_transaction_summary')
        , entity_key = CONCAT('po_line_uid=', tpl.po_line_uid)
        , row_json =
          (
              SELECT
                    capture_phase = @Mode
                  , tpl.po_no
                  , tpl.po_line_no
                  , tpl.po_line_uid
                  , tpl.item_id
                  , linkable_row_count = COUNT(lt.oe_line_uid)
                  , linked_qty_sum = COALESCE(SUM(lt.linked_qty), 0)
                  , original_linked_qty_sum = COALESCE(SUM(lt.original_linked_qty), 0)
                  , open_order_qty_sum = COALESCE(SUM(lt.qty_ordered - lt.qty_allocated - lt.qty_on_pick_tickets - lt.qty_invoiced - lt.qty_canceled - lt.qty_staged), 0)
              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
          )
    FROM #target_po_line AS tpl
    OUTER APPLY P21Import.dbo.p21_fnt_get_linkable_transactions
    (
          CONVERT(int, @TargetLocationId)
        , tpl.item_id
        , CONVERT(int, tpl.po_no)
        , tpl.po_line_no
        , @LinkLookAheadDays
        , NULL
        , 'N'
        , tpl.po_line_uid
        , 'N'
        , 'N'
        , @LinkType
        , @CurrentDateNoTime
    ) AS lt
    GROUP BY
          tpl.po_no
        , tpl.po_line_no
        , tpl.po_line_uid
        , tpl.item_id
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'transfer_backorders')
        , entity_key = CONCAT('transfer_backorders_uid=', tb.transfer_backorders_uid)
        , row_json = (SELECT tb.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.transfer_backorders AS tb
    WHERE EXISTS
    (
        SELECT 1
        FROM #near_transfer AS nt
        WHERE nt.transfer_no = tb.transfer_no
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'anticipated_allocation')
        , entity_key = CONCAT('anticipated_allocation_uid=', aa.anticipated_allocation_uid)
        , row_json = (SELECT aa.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.anticipated_allocation AS aa
    WHERE aa.location_id = @TargetLocationId
      AND EXISTS
      (
          SELECT 1
          FROM #scope_item AS si
          WHERE si.inv_mast_uid = aa.inv_mast_uid
      )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'inv_loc')
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
    FROM P21Import.dbo.inv_loc AS il
    WHERE il.location_id IN (@TargetLocationId, 200)
      AND EXISTS
      (
          SELECT 1
          FROM #scope_item AS si
          WHERE si.inv_mast_uid = il.inv_mast_uid
      )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'oe_hdr')
        , entity_key = CONCAT('order_no=', oh.order_no)
        , row_json = (SELECT oh.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.oe_hdr AS oh
    WHERE EXISTS
    (
        SELECT 1
        FROM #open_oe_line AS ol
        WHERE ol.order_no = oh.order_no
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

;WITH src AS
(
    SELECT
          entity_name = CONVERT(varchar(128), 'oe_line')
        , entity_key = CONCAT('order_no=', ol.order_no, ';line_no=', ol.line_no)
        , row_json = (SELECT ol.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM P21Import.dbo.oe_line AS ol
    WHERE EXISTS
    (
        SELECT 1
        FROM #open_oe_line AS scope_ol
        WHERE scope_ol.order_no = ol.order_no
          AND scope_ol.line_no = ol.line_no
    )
)
INSERT INTO dbo.coats_mexico_manual_pipeline_capture_row (capture_run_uid, entity_name, entity_key, row_hash, row_json)
SELECT @CaptureRunUid, entity_name, entity_key, HASHBYTES('SHA2_256', CONVERT(varbinary(max), row_json)), row_json
FROM src;
SET @RowsCaptured += @@ROWCOUNT;

SELECT
      capture_run_uid = @CaptureRunUid
    , mode = @Mode
    , container_name = @ContainerName
    , location_id = @TargetLocationId
    , discovered_container_building_uid = @DiscoveredContainerBuildingUid
    , discovered_vessel_receipts_hdr_uid = @DiscoveredVesselReceiptsHdrUid
    , discovered_vessel_receipts_container_uid = @DiscoveredVesselReceiptsContainerUid
    , discovered_container_receipts_hdr_uid = @DiscoveredContainerReceiptsHdrUid
    , discovered_vessel_receipt_number = @DiscoveredVesselReceiptNumber
    , captured_at = @CapturedAt
    , rows_captured = @RowsCaptured;

SELECT
      entity_name
    , row_count = COUNT(*)
FROM dbo.coats_mexico_manual_pipeline_capture_row
WHERE capture_run_uid = @CaptureRunUid
GROUP BY
      entity_name
ORDER BY
      entity_name;
GO

