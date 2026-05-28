/*
Diagnose Coats Mexico automatic sales order allocation after container receipt.

Read-only diagnostic. This script does not create receipts, repair existing
receipts, update OE allocation, or update inventory. It is intended to compare
an ADF-created receipt that transferred stock but did not auto-allocate sales
orders against an optional known-good receipt where auto-allocation worked.

Usage:
  1. Set @TargetContainerReceiptsHdrUid to the failed ADF-created receipt.
  2. Optionally set @KnownGoodContainerReceiptsHdrUid to a GUI/working receipt.
  3. Optionally set @TargetVesselReceiptsHdrUid to narrow validation.
  4. Review result sets before changing the receipt builder.
*/

USE P21;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @TargetContainerReceiptsHdrUid int = 682;
DECLARE @KnownGoodContainerReceiptsHdrUid int = 681;
DECLARE @TargetVesselReceiptsHdrUid int = 762;
DECLARE @TargetLocationId decimal(19, 0) = 210;

IF @TargetContainerReceiptsHdrUid IS NULL
BEGIN
    THROW 53000, 'Set @TargetContainerReceiptsHdrUid before running this diagnostic.', 1;
END;

DROP TABLE IF EXISTS #receipt_scope;
DROP TABLE IF EXISTS #interesting_column;
DROP TABLE IF EXISTS #field_compare;
DROP TABLE IF EXISTS #receipt_line;
DROP TABLE IF EXISTS #receipt_item;
DROP TABLE IF EXISTS #transfer_candidate_table;
DROP TABLE IF EXISTS #transfer_evidence;
DROP TABLE IF EXISTS #near_transfer;

CREATE TABLE #receipt_scope
(
      sample_name varchar(20) NOT NULL
    , container_receipts_hdr_uid int NOT NULL
    , vessel_receipts_container_uid int NULL
    , vessel_receipts_hdr_uid int NULL
    , container_building_uid int NULL
    , container_name nvarchar(255) NULL
    , receipt_created_by nvarchar(30) NULL
    , receipt_status int NULL
    , receipt_date date NULL
);

INSERT INTO #receipt_scope
(
      sample_name
    , container_receipts_hdr_uid
    , vessel_receipts_container_uid
    , vessel_receipts_hdr_uid
    , container_building_uid
    , container_name
    , receipt_created_by
    , receipt_status
    , receipt_date
)
SELECT
      'TARGET'
    , crh.container_receipts_hdr_uid
    , crh.vessel_receipts_container_uid
    , vc.vessel_receipts_hdr_uid
    , vc.container_building_uid
    , vc.container_name
    , crh.created_by
    , crh.row_status_flag
    , crh.date_received
FROM P21.dbo.container_receipts_hdr AS crh
LEFT JOIN P21.dbo.vessel_receipts_container AS vc
  ON vc.vessel_receipts_container_uid = crh.vessel_receipts_container_uid
WHERE crh.container_receipts_hdr_uid = @TargetContainerReceiptsHdrUid
  AND (@TargetVesselReceiptsHdrUid IS NULL OR vc.vessel_receipts_hdr_uid = @TargetVesselReceiptsHdrUid);

IF @@ROWCOUNT = 0
BEGIN
    THROW 53001, 'Target container_receipts_hdr_uid was not found, or did not match @TargetVesselReceiptsHdrUid.', 1;
END;

IF @KnownGoodContainerReceiptsHdrUid IS NOT NULL
BEGIN
    INSERT INTO #receipt_scope
    (
          sample_name
        , container_receipts_hdr_uid
        , vessel_receipts_container_uid
        , vessel_receipts_hdr_uid
        , container_building_uid
        , container_name
        , receipt_created_by
        , receipt_status
        , receipt_date
    )
    SELECT
          'KNOWN_GOOD'
        , crh.container_receipts_hdr_uid
        , crh.vessel_receipts_container_uid
        , vc.vessel_receipts_hdr_uid
        , vc.container_building_uid
        , vc.container_name
        , crh.created_by
        , crh.row_status_flag
        , crh.date_received
    FROM P21.dbo.container_receipts_hdr AS crh
    LEFT JOIN P21.dbo.vessel_receipts_container AS vc
      ON vc.vessel_receipts_container_uid = crh.vessel_receipts_container_uid
    WHERE crh.container_receipts_hdr_uid = @KnownGoodContainerReceiptsHdrUid;
END;

SELECT
      result_set = 'receipt_scope'
    , rs.sample_name
    , container_receipts_hdr_uid = CONVERT(varchar(50), rs.container_receipts_hdr_uid)
    , vessel_receipts_container_uid = CONVERT(varchar(50), rs.vessel_receipts_container_uid)
    , vessel_receipts_hdr_uid = CONVERT(varchar(50), rs.vessel_receipts_hdr_uid)
    , container_building_uid = CONVERT(varchar(50), rs.container_building_uid)
    , rs.container_name
    , rs.receipt_created_by
    , receipt_status = CONVERT(varchar(50), rs.receipt_status)
    , receipt_date = CONVERT(varchar(30), rs.receipt_date, 23)
    , adf_receipt_build_found =
        CASE WHEN rb.shipment_file_id IS NULL THEN 'N' ELSE 'Y' END
    , shipment_file_id = CONVERT(varchar(50), rb.shipment_file_id)
    , line_count = CONVERT(varchar(50), rb.line_count)
    , total_qty = CONVERT(varchar(50), rb.total_qty)
FROM #receipt_scope AS rs
LEFT JOIN P21Import.dbo.coats_mexico_shipment_receipt_build AS rb
  ON rb.container_receipts_hdr_uid = rs.container_receipts_hdr_uid
ORDER BY
      CASE rs.sample_name WHEN 'TARGET' THEN 1 ELSE 2 END;

SELECT
      result_set = 'receipt_build_duplicate_check'
    , container_receipts_hdr_uid = CONVERT(varchar(50), rb.container_receipts_hdr_uid)
    , receipt_build_rows = CONVERT(varchar(50), COUNT(*))
    , distinct_shipment_file_count = CONVERT(varchar(50), COUNT(DISTINCT rb.shipment_file_id))
    , first_created_at = CONVERT(varchar(30), MIN(rb.created_at), 121)
    , last_created_at = CONVERT(varchar(30), MAX(rb.created_at), 121)
FROM P21Import.dbo.coats_mexico_shipment_receipt_build AS rb
WHERE rb.container_receipts_hdr_uid IN
(
    SELECT container_receipts_hdr_uid
    FROM #receipt_scope
)
GROUP BY
      rb.container_receipts_hdr_uid
ORDER BY
      rb.container_receipts_hdr_uid;

CREATE TABLE #interesting_column
(
      table_name sysname NOT NULL
    , column_name sysname NOT NULL
);

INSERT INTO #interesting_column (table_name, column_name)
SELECT
      t.name
    , c.name
FROM P21.sys.tables AS t
INNER JOIN P21.sys.schemas AS s
  ON s.schema_id = t.schema_id
INNER JOIN P21.sys.columns AS c
  ON c.object_id = t.object_id
WHERE s.name = 'dbo'
  AND t.name IN
  (
      'container_receipts_hdr',
      'container_receipts_line',
      'vessel_receipts_container',
      'vessel_receipts_line',
      'vessel_receipts_hdr',
      'container_building',
      'container_building_po',
      'oe_hdr',
      'oe_line',
      'inv_loc'
  )
  AND
  (
      c.name LIKE '%alloc%'
      OR c.name LIKE '%allocate%'
      OR c.name LIKE '%auto%'
      OR c.name LIKE '%complete%'
      OR c.name LIKE 'cc[_]%'
      OR c.name LIKE '%transfer%'
      OR c.name LIKE '%commit%'
      OR c.name LIKE '%demand%'
      OR c.name LIKE '%backorder%'
      OR c.name LIKE '%hold%'
      OR c.name LIKE '%cancel%'
      OR c.name LIKE '%pick%'
  )
ORDER BY
      t.name
    , c.name;

SELECT
      result_set = 'dynamic_column_discovery'
    , table_name
    , column_name
FROM #interesting_column
ORDER BY
      table_name
    , column_name;

CREATE TABLE #field_compare
(
      table_name sysname NOT NULL
    , column_name sysname NOT NULL
    , target_value nvarchar(4000) NULL
    , known_good_value nvarchar(4000) NULL
    , comparison_note varchar(100) NOT NULL
);

DECLARE
      @TableName sysname
    , @ColumnName sysname
    , @Sql nvarchar(max)
    , @JoinSql nvarchar(max);

DECLARE interesting_columns CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name, column_name
    FROM #interesting_column
    WHERE table_name IN
    (
        'container_receipts_hdr',
        'vessel_receipts_container',
        'vessel_receipts_hdr',
        'container_building'
    );

OPEN interesting_columns;
FETCH NEXT FROM interesting_columns INTO @TableName, @ColumnName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @JoinSql =
        CASE @TableName
            WHEN 'container_receipts_hdr'
                THEN 'INNER JOIN P21.dbo.container_receipts_hdr AS x ON x.container_receipts_hdr_uid = rs.container_receipts_hdr_uid'
            WHEN 'vessel_receipts_container'
                THEN 'INNER JOIN P21.dbo.vessel_receipts_container AS x ON x.vessel_receipts_container_uid = rs.vessel_receipts_container_uid'
            WHEN 'vessel_receipts_hdr'
                THEN 'INNER JOIN P21.dbo.vessel_receipts_hdr AS x ON x.vessel_receipts_hdr_uid = rs.vessel_receipts_hdr_uid'
            WHEN 'container_building'
                THEN 'INNER JOIN P21.dbo.container_building AS x ON x.container_building_uid = rs.container_building_uid'
        END;

    SET @Sql = N'
INSERT INTO #field_compare (table_name, column_name, target_value, known_good_value, comparison_note)
SELECT
      @TableName
    , @ColumnName
    , MAX(CASE WHEN rs.sample_name = ''TARGET'' THEN CONVERT(nvarchar(4000), x.' + QUOTENAME(@ColumnName) + N') END)
    , MAX(CASE WHEN rs.sample_name = ''KNOWN_GOOD'' THEN CONVERT(nvarchar(4000), x.' + QUOTENAME(@ColumnName) + N') END)
    , CASE
          WHEN COUNT(CASE WHEN rs.sample_name = ''KNOWN_GOOD'' THEN 1 END) = 0 THEN ''NO_KNOWN_GOOD''
          WHEN ISNULL(MAX(CASE WHEN rs.sample_name = ''TARGET'' THEN CONVERT(nvarchar(4000), x.' + QUOTENAME(@ColumnName) + N') END), ''<NULL>'')
             = ISNULL(MAX(CASE WHEN rs.sample_name = ''KNOWN_GOOD'' THEN CONVERT(nvarchar(4000), x.' + QUOTENAME(@ColumnName) + N') END), ''<NULL>'')
              THEN ''MATCH''
          ELSE ''DIFFERENT''
      END
FROM #receipt_scope AS rs
' + @JoinSql + N';';

    EXEC sys.sp_executesql
          @Sql
        , N'@TableName sysname, @ColumnName sysname'
        , @TableName = @TableName
        , @ColumnName = @ColumnName;

    FETCH NEXT FROM interesting_columns INTO @TableName, @ColumnName;
END;

CLOSE interesting_columns;
DEALLOCATE interesting_columns;

SELECT
      result_set = 'header_and_chain_flag_compare'
    , table_name
    , column_name
    , target_value
    , known_good_value
    , comparison_note
FROM #field_compare
ORDER BY
      CASE comparison_note WHEN 'DIFFERENT' THEN 1 WHEN 'NO_KNOWN_GOOD' THEN 2 ELSE 3 END
    , table_name
    , column_name;

CREATE TABLE #receipt_line
(
      sample_name varchar(20) NOT NULL
    , container_receipts_hdr_uid int NOT NULL
    , container_receipts_line_uid int NOT NULL
    , vessel_receipts_line_uid int NULL
    , vessel_receipts_hdr_uid int NULL
    , line_no decimal(19, 0) NULL
    , po_line_uid int NULL
    , inv_mast_uid int NULL
    , item_id nvarchar(40) NULL
    , qty_received decimal(19, 9) NULL
    , unit_of_measure nvarchar(10) NULL
    , unit_size decimal(19, 9) NULL
    , complete_po_line_flag char(1) NULL
    , transfer_flag char(1) NULL
    , vessel_line_status int NULL
    , container_qty_received decimal(19, 9) NULL
);

INSERT INTO #receipt_line
(
      sample_name
    , container_receipts_hdr_uid
    , container_receipts_line_uid
    , vessel_receipts_line_uid
    , vessel_receipts_hdr_uid
    , line_no
    , po_line_uid
    , inv_mast_uid
    , item_id
    , qty_received
    , unit_of_measure
    , unit_size
    , complete_po_line_flag
    , transfer_flag
    , vessel_line_status
    , container_qty_received
)
SELECT
      rs.sample_name
    , crl.container_receipts_hdr_uid
    , crl.container_receipts_line_uid
    , crl.vessel_receipts_line_uid
    , vl.vessel_receipts_hdr_uid
    , vl.line_no
    , vl.po_line_uid
    , pol.inv_mast_uid
    , im.item_id
    , CONVERT(decimal(19, 9), crl.qty_received)
    , crl.unit_of_measure
    , crl.unit_size
    , crl.complete_po_line_flag
    , crl.transfer_flag
    , vl.row_status_flag
    , CONVERT(decimal(19, 9), vl.container_qty_received)
FROM #receipt_scope AS rs
INNER JOIN P21.dbo.container_receipts_line AS crl
  ON crl.container_receipts_hdr_uid = rs.container_receipts_hdr_uid
LEFT JOIN P21.dbo.vessel_receipts_line AS vl
  ON vl.vessel_receipts_line_uid = crl.vessel_receipts_line_uid
LEFT JOIN P21.dbo.po_line AS pol
  ON pol.po_line_uid = vl.po_line_uid
LEFT JOIN P21.dbo.inv_mast AS im
  ON im.inv_mast_uid = pol.inv_mast_uid;

SELECT
      result_set = 'receipt_line_summary'
    , sample_name
    , container_receipts_hdr_uid = CONVERT(varchar(50), container_receipts_hdr_uid)
    , line_count = CONVERT(varchar(50), COUNT(*))
    , total_qty_received = CONVERT(varchar(50), SUM(COALESCE(qty_received, 0)))
    , missing_vessel_line_count = CONVERT(varchar(50), SUM(CASE WHEN vessel_receipts_line_uid IS NULL THEN 1 ELSE 0 END))
    , missing_po_line_count = CONVERT(varchar(50), SUM(CASE WHEN po_line_uid IS NULL THEN 1 ELSE 0 END))
    , missing_item_count = CONVERT(varchar(50), SUM(CASE WHEN inv_mast_uid IS NULL THEN 1 ELSE 0 END))
    , null_transfer_flag_count = CONVERT(varchar(50), SUM(CASE WHEN transfer_flag IS NULL THEN 1 ELSE 0 END))
    , transfer_flag_y_count = CONVERT(varchar(50), SUM(CASE WHEN transfer_flag = 'Y' THEN 1 ELSE 0 END))
    , transfer_flag_n_count = CONVERT(varchar(50), SUM(CASE WHEN transfer_flag = 'N' THEN 1 ELSE 0 END))
    , complete_po_line_y_count = CONVERT(varchar(50), SUM(CASE WHEN complete_po_line_flag = 'Y' THEN 1 ELSE 0 END))
    , vessel_line_status_702_count = CONVERT(varchar(50), SUM(CASE WHEN vessel_line_status = 702 THEN 1 ELSE 0 END))
    , zero_or_missing_container_qty_count =
        CONVERT(varchar(50), SUM(CASE WHEN COALESCE(container_qty_received, 0) = 0 THEN 1 ELSE 0 END))
FROM #receipt_line
GROUP BY
      sample_name
    , container_receipts_hdr_uid
ORDER BY
      CASE sample_name WHEN 'TARGET' THEN 1 ELSE 2 END;

SELECT
      result_set = 'receipt_line_detail'
    , sample_name
    , container_receipts_hdr_uid = CONVERT(varchar(50), container_receipts_hdr_uid)
    , container_receipts_line_uid = CONVERT(varchar(50), container_receipts_line_uid)
    , vessel_receipts_line_uid = CONVERT(varchar(50), vessel_receipts_line_uid)
    , vessel_receipts_hdr_uid = CONVERT(varchar(50), vessel_receipts_hdr_uid)
    , line_no = CONVERT(varchar(50), line_no)
    , po_line_uid = CONVERT(varchar(50), po_line_uid)
    , inv_mast_uid = CONVERT(varchar(50), inv_mast_uid)
    , item_id
    , qty_received = CONVERT(varchar(50), qty_received)
    , unit_of_measure
    , unit_size = CONVERT(varchar(50), unit_size)
    , complete_po_line_flag
    , transfer_flag
    , vessel_line_status = CONVERT(varchar(50), vessel_line_status)
    , container_qty_received = CONVERT(varchar(50), container_qty_received)
FROM #receipt_line
ORDER BY
      CASE sample_name WHEN 'TARGET' THEN 1 ELSE 2 END
    , line_no
    , container_receipts_line_uid;

SELECT
      result_set = 'document_line_bin_summary'
    , rs.sample_name
    , document_no = CONVERT(varchar(50), rs.container_receipts_hdr_uid)
    , dlb_count = CONVERT(varchar(50), COUNT(dlb.document_line_bin_uid))
    , line_count = CONVERT(varchar(50), COUNT(DISTINCT dlb.line_no))
    , bin_count = CONVERT(varchar(50), COUNT(DISTINCT dlb.bin_cd))
    , unit_quantity = CONVERT(varchar(50), SUM(COALESCE(dlb.unit_quantity, 0)))
    , qty_to_change = CONVERT(varchar(50), SUM(COALESCE(dlb.qty_to_change, 0)))
    , qty_applied = CONVERT(varchar(50), SUM(COALESCE(dlb.qty_applied, 0)))
FROM #receipt_scope AS rs
LEFT JOIN P21.dbo.document_line_bin AS dlb
  ON dlb.document_type = 'CR'
 AND dlb.document_no = rs.container_receipts_hdr_uid
GROUP BY
      rs.sample_name
    , rs.container_receipts_hdr_uid
ORDER BY
      CASE rs.sample_name WHEN 'TARGET' THEN 1 ELSE 2 END;

DECLARE line_columns CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name, column_name
    FROM #interesting_column
    WHERE table_name IN ('container_receipts_line', 'vessel_receipts_line');

OPEN line_columns;
FETCH NEXT FROM line_columns INTO @TableName, @ColumnName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @JoinSql =
        CASE @TableName
            WHEN 'container_receipts_line'
                THEN 'INNER JOIN P21.dbo.container_receipts_line AS x ON x.container_receipts_hdr_uid = rs.container_receipts_hdr_uid'
            WHEN 'vessel_receipts_line'
                THEN 'INNER JOIN P21.dbo.container_receipts_line AS crl ON crl.container_receipts_hdr_uid = rs.container_receipts_hdr_uid
                      INNER JOIN P21.dbo.vessel_receipts_line AS x ON x.vessel_receipts_line_uid = crl.vessel_receipts_line_uid'
        END;

    SET @Sql = N'
INSERT INTO #field_compare (table_name, column_name, target_value, known_good_value, comparison_note)
SELECT
      @TableName
    , @ColumnName
    , MAX(CASE WHEN sample_name = ''TARGET'' THEN sample_summary END)
    , MAX(CASE WHEN sample_name = ''KNOWN_GOOD'' THEN sample_summary END)
    , CASE
          WHEN COUNT(CASE WHEN sample_name = ''KNOWN_GOOD'' THEN 1 END) = 0 THEN ''NO_KNOWN_GOOD''
          WHEN ISNULL(MAX(CASE WHEN sample_name = ''TARGET'' THEN sample_summary END), ''<NULL>'')
             = ISNULL(MAX(CASE WHEN sample_name = ''KNOWN_GOOD'' THEN sample_summary END), ''<NULL>'')
              THEN ''MATCH''
          ELSE ''DIFFERENT''
      END
FROM
(
    SELECT
          rs.sample_name
        , sample_summary =
            CONCAT(
                  ''rows='', COUNT(*)
                , ''; nulls='', SUM(CASE WHEN x.' + QUOTENAME(@ColumnName) + N' IS NULL THEN 1 ELSE 0 END)
                , ''; distinct='', COUNT(DISTINCT CONVERT(nvarchar(4000), x.' + QUOTENAME(@ColumnName) + N'))
                , ''; min='', MIN(CONVERT(nvarchar(4000), x.' + QUOTENAME(@ColumnName) + N'))
                , ''; max='', MAX(CONVERT(nvarchar(4000), x.' + QUOTENAME(@ColumnName) + N'))
            )
    FROM #receipt_scope AS rs
    ' + @JoinSql + N'
    GROUP BY
          rs.sample_name
) AS summarized;';

    EXEC sys.sp_executesql
          @Sql
        , N'@TableName sysname, @ColumnName sysname'
        , @TableName = @TableName
        , @ColumnName = @ColumnName;

    FETCH NEXT FROM line_columns INTO @TableName, @ColumnName;
END;

CLOSE line_columns;
DEALLOCATE line_columns;

SELECT
      result_set = 'line_flag_compare'
    , table_name
    , column_name
    , target_value
    , known_good_value
    , comparison_note
FROM #field_compare
WHERE table_name IN ('container_receipts_line', 'vessel_receipts_line')
ORDER BY
      CASE comparison_note WHEN 'DIFFERENT' THEN 1 WHEN 'NO_KNOWN_GOOD' THEN 2 ELSE 3 END
    , table_name
    , column_name;

CREATE TABLE #receipt_item
(
      sample_name varchar(20) NOT NULL
    , inv_mast_uid int NOT NULL
    , item_id nvarchar(40) NULL
    , receipt_qty decimal(19, 9) NOT NULL
);

INSERT INTO #receipt_item (sample_name, inv_mast_uid, item_id, receipt_qty)
SELECT
      sample_name
    , inv_mast_uid
    , item_id = MIN(item_id)
    , receipt_qty = SUM(COALESCE(qty_received, 0))
FROM #receipt_line
WHERE inv_mast_uid IS NOT NULL
GROUP BY
      sample_name
    , inv_mast_uid;

CREATE TABLE #transfer_candidate_table
(
      table_name sysname NOT NULL
    , container_receipts_hdr_uid_column sysname NULL
    , container_receipts_line_uid_column sysname NULL
    , vessel_receipts_line_uid_column sysname NULL
    , inv_mast_uid_column sysname NULL
    , transfer_no_column sysname NULL
    , qty_column sysname NULL
);

INSERT INTO #transfer_candidate_table
(
      table_name
    , container_receipts_hdr_uid_column
    , container_receipts_line_uid_column
    , vessel_receipts_line_uid_column
    , inv_mast_uid_column
    , transfer_no_column
    , qty_column
)
SELECT
      t.name
    , MAX(CASE WHEN c.name = 'container_receipts_hdr_uid' THEN c.name END)
    , MAX(CASE WHEN c.name = 'container_receipts_line_uid' THEN c.name END)
    , MAX(CASE WHEN c.name = 'vessel_receipts_line_uid' THEN c.name END)
    , MAX(CASE WHEN c.name = 'inv_mast_uid' THEN c.name END)
    , MAX(CASE WHEN c.name IN ('transfer_no', 'transfer_number', 'transfer_hdr_uid', 'transfer_line_uid') THEN c.name END)
    , MAX(CASE WHEN c.name IN ('qty', 'quantity', 'qty_to_transfer', 'qty_transferred', 'quantity_transferred', 'unit_quantity') THEN c.name END)
FROM P21.sys.tables AS t
INNER JOIN P21.sys.schemas AS s
  ON s.schema_id = t.schema_id
INNER JOIN P21.sys.columns AS c
  ON c.object_id = t.object_id
WHERE s.name = 'dbo'
  AND t.name LIKE '%transfer%'
GROUP BY
      t.name
HAVING
      MAX(CASE WHEN c.name = 'container_receipts_hdr_uid' THEN 1 ELSE 0 END) = 1
   OR MAX(CASE WHEN c.name = 'container_receipts_line_uid' THEN 1 ELSE 0 END) = 1
   OR MAX(CASE WHEN c.name = 'vessel_receipts_line_uid' THEN 1 ELSE 0 END) = 1
   OR MAX(CASE WHEN c.name IN ('transfer_no', 'transfer_number', 'transfer_hdr_uid', 'transfer_line_uid') THEN 1 ELSE 0 END) = 1;

SELECT
      result_set = 'transfer_candidate_tables'
    , table_name
    , container_receipts_hdr_uid_column
    , container_receipts_line_uid_column
    , vessel_receipts_line_uid_column
    , inv_mast_uid_column
    , transfer_no_column
    , qty_column
FROM #transfer_candidate_table
ORDER BY
      table_name;

CREATE TABLE #near_transfer
(
      sample_name varchar(20) NOT NULL
    , transfer_no decimal(19, 0) NOT NULL
    , from_location_id decimal(19, 0) NULL
    , to_location_id decimal(19, 0) NULL
    , approved char(1) NULL
    , complete_flag char(1) NULL
    , shipped_flag char(1) NULL
    , oe_transfer_reserve_flag char(1) NULL
    , created_by varchar(255) NULL
    , last_maintained_by varchar(30) NULL
    , date_created datetime NULL
    , line_count int NOT NULL
    , matching_receipt_item_count int NOT NULL
    , qty_to_transfer decimal(19, 9) NULL
    , qty_transferred decimal(19, 9) NULL
    , qty_received decimal(19, 9) NULL
    , qty_reserved decimal(19, 9) NULL
);

INSERT INTO #near_transfer
(
      sample_name
    , transfer_no
    , from_location_id
    , to_location_id
    , approved
    , complete_flag
    , shipped_flag
    , oe_transfer_reserve_flag
    , created_by
    , last_maintained_by
    , date_created
    , line_count
    , matching_receipt_item_count
    , qty_to_transfer
    , qty_transferred
    , qty_received
    , qty_reserved
)
SELECT
      rs.sample_name
    , th.transfer_no
    , th.from_location_id
    , th.to_location_id
    , th.approved
    , th.complete_flag
    , th.shipped_flag
    , th.oe_transfer_reserve_flag
    , th.created_by
    , th.last_maintained_by
    , th.date_created
    , COUNT(tl.line_no)
    , COUNT(DISTINCT ri.inv_mast_uid)
    , SUM(COALESCE(tl.qty_to_transfer, 0))
    , SUM(COALESCE(tl.qty_transferred, 0))
    , SUM(COALESCE(tl.qty_received, 0))
    , SUM(COALESCE(tl.qty_reserved, 0))
FROM #receipt_scope AS rs
INNER JOIN P21.dbo.container_receipts_hdr AS crh
  ON crh.container_receipts_hdr_uid = rs.container_receipts_hdr_uid
INNER JOIN P21.dbo.transfer_hdr AS th
  ON th.date_created BETWEEN DATEADD(day, -1, crh.date_last_modified)
                         AND DATEADD(day, 1, crh.date_last_modified)
INNER JOIN P21.dbo.transfer_line AS tl
  ON tl.transfer_no = th.transfer_no
LEFT JOIN #receipt_item AS ri
  ON ri.sample_name = rs.sample_name
 AND ri.inv_mast_uid = tl.inv_mast_uid
WHERE (th.from_location_id = @TargetLocationId OR th.to_location_id = @TargetLocationId)
GROUP BY
      rs.sample_name
    , th.transfer_no
    , th.from_location_id
    , th.to_location_id
    , th.approved
    , th.complete_flag
    , th.shipped_flag
    , th.oe_transfer_reserve_flag
    , th.created_by
    , th.last_maintained_by
    , th.date_created
HAVING COUNT(DISTINCT ri.inv_mast_uid) > 0;

SELECT
      result_set = 'nearby_transfer_summary'
    , sample_name
    , transfer_count = CONVERT(varchar(50), COUNT(*))
    , reserve_flag_y_count = CONVERT(varchar(50), SUM(CASE WHEN oe_transfer_reserve_flag = 'Y' THEN 1 ELSE 0 END))
    , reserve_flag_n_count = CONVERT(varchar(50), SUM(CASE WHEN COALESCE(oe_transfer_reserve_flag, 'N') = 'N' THEN 1 ELSE 0 END))
    , approved_y_count = CONVERT(varchar(50), SUM(CASE WHEN approved = 'Y' THEN 1 ELSE 0 END))
    , total_qty_to_transfer = CONVERT(varchar(50), SUM(COALESCE(qty_to_transfer, 0)))
    , total_qty_reserved = CONVERT(varchar(50), SUM(COALESCE(qty_reserved, 0)))
FROM #near_transfer
GROUP BY
      sample_name
ORDER BY
      CASE sample_name WHEN 'TARGET' THEN 1 ELSE 2 END;

SELECT
      result_set = 'nearby_transfer_detail'
    , sample_name
    , transfer_no = CONVERT(varchar(50), transfer_no)
    , from_location_id = CONVERT(varchar(50), from_location_id)
    , to_location_id = CONVERT(varchar(50), to_location_id)
    , approved
    , complete_flag
    , shipped_flag
    , oe_transfer_reserve_flag
    , created_by
    , last_maintained_by
    , date_created = CONVERT(varchar(30), date_created, 121)
    , line_count = CONVERT(varchar(50), line_count)
    , matching_receipt_item_count = CONVERT(varchar(50), matching_receipt_item_count)
    , qty_to_transfer = CONVERT(varchar(50), qty_to_transfer)
    , qty_transferred = CONVERT(varchar(50), qty_transferred)
    , qty_received = CONVERT(varchar(50), qty_received)
    , qty_reserved = CONVERT(varchar(50), qty_reserved)
FROM #near_transfer
ORDER BY
      CASE sample_name WHEN 'TARGET' THEN 1 ELSE 2 END
    , transfer_no;

SELECT
      result_set = 'oe_line_po_transfer_link_summary'
    , nt.sample_name
    , transfer_no = CONVERT(varchar(50), nt.transfer_no)
    , oe_line_po_rows = CONVERT(varchar(50), COUNT(olp.po_no))
    , linked_quantity = CONVERT(varchar(50), SUM(COALESCE(olp.quantity_on_po, 0)))
FROM #near_transfer AS nt
LEFT JOIN P21.dbo.oe_line_po AS olp
  ON olp.po_no = nt.transfer_no
 AND olp.connection_type = 'T'
GROUP BY
      nt.sample_name
    , nt.transfer_no
ORDER BY
      CASE nt.sample_name WHEN 'TARGET' THEN 1 ELSE 2 END
    , nt.transfer_no;

CREATE TABLE #transfer_evidence
(
      table_name sysname NOT NULL
    , sample_name varchar(20) NOT NULL
    , matched_row_count int NOT NULL
    , matched_qty nvarchar(100) NULL
    , match_basis varchar(50) NOT NULL
);

DECLARE
      @HdrColumn sysname
    , @LineColumn sysname
    , @VesselLineColumn sysname
    , @QtyColumn sysname;

DECLARE transfer_tables CURSOR LOCAL FAST_FORWARD FOR
    SELECT
          table_name
        , container_receipts_hdr_uid_column
        , container_receipts_line_uid_column
        , vessel_receipts_line_uid_column
        , qty_column
    FROM #transfer_candidate_table;

OPEN transfer_tables;
FETCH NEXT FROM transfer_tables INTO @TableName, @HdrColumn, @LineColumn, @VesselLineColumn, @QtyColumn;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @HdrColumn IS NOT NULL
    BEGIN
        SET @Sql = N'
INSERT INTO #transfer_evidence (table_name, sample_name, matched_row_count, matched_qty, match_basis)
SELECT
      @TableName
    , rs.sample_name
    , COUNT(*)
    , ' + CASE WHEN @QtyColumn IS NULL THEN N'NULL' ELSE N'CONVERT(nvarchar(100), SUM(TRY_CONVERT(decimal(19, 9), x.' + QUOTENAME(@QtyColumn) + N')))' END + N'
    , ''container_receipts_hdr_uid''
FROM #receipt_scope AS rs
INNER JOIN P21.dbo.' + QUOTENAME(@TableName) + N' AS x
  ON x.' + QUOTENAME(@HdrColumn) + N' = rs.container_receipts_hdr_uid
GROUP BY
      rs.sample_name;';

        EXEC sys.sp_executesql @Sql, N'@TableName sysname', @TableName = @TableName;
    END;

    IF @LineColumn IS NOT NULL
    BEGIN
        SET @Sql = N'
INSERT INTO #transfer_evidence (table_name, sample_name, matched_row_count, matched_qty, match_basis)
SELECT
      @TableName
    , rl.sample_name
    , COUNT(*)
    , ' + CASE WHEN @QtyColumn IS NULL THEN N'NULL' ELSE N'CONVERT(nvarchar(100), SUM(TRY_CONVERT(decimal(19, 9), x.' + QUOTENAME(@QtyColumn) + N')))' END + N'
    , ''container_receipts_line_uid''
FROM #receipt_line AS rl
INNER JOIN P21.dbo.' + QUOTENAME(@TableName) + N' AS x
  ON x.' + QUOTENAME(@LineColumn) + N' = rl.container_receipts_line_uid
GROUP BY
      rl.sample_name;';

        EXEC sys.sp_executesql @Sql, N'@TableName sysname', @TableName = @TableName;
    END;

    IF @VesselLineColumn IS NOT NULL
    BEGIN
        SET @Sql = N'
INSERT INTO #transfer_evidence (table_name, sample_name, matched_row_count, matched_qty, match_basis)
SELECT
      @TableName
    , rl.sample_name
    , COUNT(*)
    , ' + CASE WHEN @QtyColumn IS NULL THEN N'NULL' ELSE N'CONVERT(nvarchar(100), SUM(TRY_CONVERT(decimal(19, 9), x.' + QUOTENAME(@QtyColumn) + N')))' END + N'
    , ''vessel_receipts_line_uid''
FROM #receipt_line AS rl
INNER JOIN P21.dbo.' + QUOTENAME(@TableName) + N' AS x
  ON x.' + QUOTENAME(@VesselLineColumn) + N' = rl.vessel_receipts_line_uid
GROUP BY
      rl.sample_name;';

        EXEC sys.sp_executesql @Sql, N'@TableName sysname', @TableName = @TableName;
    END;

    FETCH NEXT FROM transfer_tables INTO @TableName, @HdrColumn, @LineColumn, @VesselLineColumn, @QtyColumn;
END;

CLOSE transfer_tables;
DEALLOCATE transfer_tables;

SELECT
      result_set = 'transfer_evidence'
    , table_name
    , sample_name
    , matched_row_count = CONVERT(varchar(50), matched_row_count)
    , matched_qty
    , match_basis
FROM #transfer_evidence
ORDER BY
      table_name
    , CASE sample_name WHEN 'TARGET' THEN 1 ELSE 2 END
    , match_basis;

SELECT
      result_set = 'open_sales_order_demand_for_received_items'
    , ri.sample_name
    , inv_mast_uid = CONVERT(varchar(50), ri.inv_mast_uid)
    , ri.item_id
    , receipt_qty = CONVERT(varchar(50), ri.receipt_qty)
    , open_order_line_count = CONVERT(varchar(50), COUNT(ol.order_no))
    , open_qty_ordered = CONVERT(varchar(50), SUM(COALESCE(ol.qty_ordered, 0)))
    , current_qty_allocated = CONVERT(varchar(50), SUM(COALESCE(ol.qty_allocated, 0)))
    , qty_on_pick_tickets = CONVERT(varchar(50), SUM(COALESCE(ol.qty_on_pick_tickets, 0)))
    , qty_invoiced = CONVERT(varchar(50), SUM(COALESCE(ol.qty_invoiced, 0)))
    , apparent_unallocated_demand = CONVERT(varchar(50), SUM
      (
          CASE
              WHEN COALESCE(ol.qty_ordered, 0)
                 - COALESCE(ol.qty_allocated, 0)
                 - COALESCE(ol.qty_on_pick_tickets, 0)
                 - COALESCE(ol.qty_invoiced, 0) > 0
                  THEN COALESCE(ol.qty_ordered, 0)
                     - COALESCE(ol.qty_allocated, 0)
                     - COALESCE(ol.qty_on_pick_tickets, 0)
                     - COALESCE(ol.qty_invoiced, 0)
              ELSE 0
          END
      ))
    , rma_order_count = CONVERT(varchar(50), SUM(CASE WHEN COALESCE(oh.rma_flag, 'N') <> 'N' THEN 1 ELSE 0 END))
    , complete_line_count = CONVERT(varchar(50), SUM(CASE WHEN COALESCE(ol.complete, 'N') <> 'N' THEN 1 ELSE 0 END))
FROM #receipt_item AS ri
LEFT JOIN P21.dbo.oe_line AS ol
  ON ol.inv_mast_uid = ri.inv_mast_uid
 AND ol.ship_loc_id = @TargetLocationId
LEFT JOIN P21.dbo.oe_hdr AS oh
  ON oh.order_no = ol.order_no
GROUP BY
      ri.sample_name
    , ri.inv_mast_uid
    , ri.item_id
    , ri.receipt_qty
ORDER BY
      CASE ri.sample_name WHEN 'TARGET' THEN 1 ELSE 2 END
    , ri.item_id;

SELECT
      result_set = 'open_sales_order_detail_for_unallocated_demand'
    , ri.sample_name
    , ri.item_id
    , order_no = CONVERT(varchar(50), ol.order_no)
    , line_no = CONVERT(varchar(50), ol.line_no)
    , customer_id = CONVERT(varchar(50), oh.customer_id)
    , ship_loc_id = CONVERT(varchar(50), ol.ship_loc_id)
    , qty_ordered = CONVERT(varchar(50), ol.qty_ordered)
    , qty_allocated = CONVERT(varchar(50), ol.qty_allocated)
    , qty_on_pick_tickets = CONVERT(varchar(50), ol.qty_on_pick_tickets)
    , qty_invoiced = CONVERT(varchar(50), ol.qty_invoiced)
    , apparent_unallocated_demand =
        CONVERT(varchar(50), COALESCE(ol.qty_ordered, 0)
        - COALESCE(ol.qty_allocated, 0)
        - COALESCE(ol.qty_on_pick_tickets, 0)
        - COALESCE(ol.qty_invoiced, 0))
    , ol.complete
    , oh.rma_flag
FROM #receipt_item AS ri
INNER JOIN P21.dbo.oe_line AS ol
  ON ol.inv_mast_uid = ri.inv_mast_uid
 AND ol.ship_loc_id = @TargetLocationId
INNER JOIN P21.dbo.oe_hdr AS oh
  ON oh.order_no = ol.order_no
WHERE COALESCE(ol.complete, 'N') = 'N'
  AND COALESCE(oh.rma_flag, 'N') = 'N'
  AND
  (
      COALESCE(ol.qty_ordered, 0)
      - COALESCE(ol.qty_allocated, 0)
      - COALESCE(ol.qty_on_pick_tickets, 0)
      - COALESCE(ol.qty_invoiced, 0)
  ) > 0
ORDER BY
      CASE ri.sample_name WHEN 'TARGET' THEN 1 ELSE 2 END
    , ri.item_id
    , ol.order_no
    , ol.line_no;

SELECT
      result_set = 'inventory_available_for_received_items'
    , ri.sample_name
    , ri.item_id
    , location_id = CONVERT(varchar(50), il.location_id)
    , qty_on_hand = CONVERT(varchar(50), il.qty_on_hand)
    , qty_allocated = CONVERT(varchar(50), il.qty_allocated)
    , qty_available = CONVERT(varchar(50), il.qty_on_hand - il.qty_allocated)
    , il.stockable
FROM #receipt_item AS ri
INNER JOIN P21.dbo.p21_view_inv_loc AS il
  ON il.inv_mast_uid = ri.inv_mast_uid
 AND il.location_id = @TargetLocationId
ORDER BY
      CASE ri.sample_name WHEN 'TARGET' THEN 1 ELSE 2 END
    , ri.item_id;

SELECT
      result_set = 'allocation_gap_summary'
    , ri.sample_name
    , received_item_count = CONVERT(varchar(50), COUNT(*))
    , items_with_open_unallocated_demand =
        CONVERT(varchar(50), SUM(CASE WHEN od.apparent_unallocated_demand > 0 THEN 1 ELSE 0 END))
    , items_with_positive_available_qty =
        CONVERT(varchar(50), SUM(CASE WHEN COALESCE(il.qty_on_hand, 0) - COALESCE(il.qty_allocated, 0) > 0 THEN 1 ELSE 0 END))
    , items_with_both_demand_and_available_qty =
        CONVERT(varchar(50), SUM(CASE
            WHEN od.apparent_unallocated_demand > 0
             AND COALESCE(il.qty_on_hand, 0) - COALESCE(il.qty_allocated, 0) > 0
                THEN 1
            ELSE 0
        END))
FROM #receipt_item AS ri
OUTER APPLY
(
    SELECT apparent_unallocated_demand = SUM
    (
        CASE
            WHEN COALESCE(ol.qty_ordered, 0)
               - COALESCE(ol.qty_allocated, 0)
               - COALESCE(ol.qty_on_pick_tickets, 0)
               - COALESCE(ol.qty_invoiced, 0) > 0
                THEN COALESCE(ol.qty_ordered, 0)
                   - COALESCE(ol.qty_allocated, 0)
                   - COALESCE(ol.qty_on_pick_tickets, 0)
                   - COALESCE(ol.qty_invoiced, 0)
            ELSE 0
        END
    )
    FROM P21.dbo.oe_line AS ol
    INNER JOIN P21.dbo.oe_hdr AS oh
      ON oh.order_no = ol.order_no
    WHERE ol.inv_mast_uid = ri.inv_mast_uid
      AND ol.ship_loc_id = @TargetLocationId
      AND COALESCE(ol.complete, 'N') = 'N'
      AND COALESCE(oh.rma_flag, 'N') = 'N'
) AS od
LEFT JOIN P21.dbo.p21_view_inv_loc AS il
  ON il.inv_mast_uid = ri.inv_mast_uid
 AND il.location_id = @TargetLocationId
GROUP BY
      ri.sample_name
ORDER BY
      CASE ri.sample_name WHEN 'TARGET' THEN 1 ELSE 2 END;

SELECT
      result_set = 'next_step_guidance'
    , guidance =
        'If transfer evidence is healthy but TARGET differs from KNOWN_GOOD on allocation/auto/complete fields, update sql/main/004_create_coats_mexico_p21import_receipts.sql for future receipts only. Do not update oe_line or allocation tables directly.'
UNION ALL
SELECT
      'next_step_guidance'
    , 'If TARGET and KNOWN_GOOD receipt fields match, investigate order eligibility, item/location allocation settings, and P21 allocation process configuration rather than the ADF receipt builder.';
GO
