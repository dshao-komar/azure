USE P21Import;
SET NOCOUNT ON;

DECLARE @today date = CONVERT(date, dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL));

DECLARE @counter_check table
(
      counter_id sysname NOT NULL
    , table_name sysname NOT NULL
    , uid_column sysname NOT NULL
    , max_uid_in_table bigint NULL
);

INSERT INTO @counter_check (counter_id, table_name, uid_column, max_uid_in_table)
VALUES
      ('container_building', 'container_building', 'container_building_uid', (SELECT MAX(container_building_uid) FROM dbo.container_building))
    , ('vessel_receipts_hdr', 'vessel_receipts_hdr', 'vessel_receipts_hdr_uid', (SELECT MAX(vessel_receipts_hdr_uid) FROM dbo.vessel_receipts_hdr))
    , ('vessel_receipts_container', 'vessel_receipts_container', 'vessel_receipts_container_uid', (SELECT MAX(vessel_receipts_container_uid) FROM dbo.vessel_receipts_container))
    , ('vessel_receipts_line', 'vessel_receipts_line', 'vessel_receipts_line_uid', (SELECT MAX(vessel_receipts_line_uid) FROM dbo.vessel_receipts_line))
    , ('container_receipts_hdr', 'container_receipts_hdr', 'container_receipts_hdr_uid', (SELECT MAX(container_receipts_hdr_uid) FROM dbo.container_receipts_hdr))
    , ('container_receipts_line', 'container_receipts_line', 'container_receipts_line_uid', (SELECT MAX(container_receipts_line_uid) FROM dbo.container_receipts_line));

SELECT
      cc.counter_id
    , c.seq_name
    , c.counter_num
    , seq_current = CONVERT(bigint, s.current_value)
    , seq_increment = CONVERT(bigint, s.increment)
    , cc.table_name
    , cc.uid_column
    , max_uid_in_table = cc.max_uid_in_table
    , next_allocated_value =
        CASE
            WHEN c.counter_num = -1 AND s.object_id IS NOT NULL THEN CONVERT(bigint, s.current_value) + CONVERT(bigint, s.increment)
            WHEN c.counter_num <> -1 THEN CONVERT(bigint, c.counter_num) + 1
            ELSE NULL
        END
    , status =
        CASE
            WHEN c.counter_num = -1 AND s.object_id IS NOT NULL AND ISNULL(cc.max_uid_in_table, 0) <= CONVERT(bigint, s.current_value)
                THEN 'OK (sequence is ahead of table)'
            WHEN c.counter_num = -1 AND s.object_id IS NOT NULL AND ISNULL(cc.max_uid_in_table, 0) > CONVERT(bigint, s.current_value)
                THEN 'BAD (sequence behind table: collision risk)'
            WHEN c.counter_num <> -1 AND ISNULL(cc.max_uid_in_table, 0) <= CONVERT(bigint, c.counter_num)
                THEN 'OK (counter_num is ahead of table)'
            WHEN c.counter_num <> -1 AND ISNULL(cc.max_uid_in_table, 0) > CONVERT(bigint, c.counter_num)
                THEN 'BAD (counter_num behind table: collision risk)'
            ELSE 'CHECK CONFIG'
        END
FROM @counter_check AS cc
LEFT JOIN dbo.counter AS c
  ON c.id = cc.counter_id
LEFT JOIN sys.sequences AS s
  ON s.name = c.seq_name
ORDER BY cc.counter_id;

SELECT
      today_db_date = @today
    , receipt_builds_created_today = COUNT(*)
    , min_created_at = MIN(created_at)
    , max_created_at = MAX(created_at)
    , min_container_building_uid = MIN(container_building_uid)
    , max_container_building_uid = MAX(container_building_uid)
    , min_vessel_receipts_hdr_uid = MIN(vessel_receipts_hdr_uid)
    , max_vessel_receipts_hdr_uid = MAX(vessel_receipts_hdr_uid)
    , min_container_receipts_hdr_uid = MIN(container_receipts_hdr_uid)
    , max_container_receipts_hdr_uid = MAX(container_receipts_hdr_uid)
    , total_receipt_lines = SUM(line_count)
FROM dbo.coats_mexico_shipment_receipt_build
WHERE created_at >= @today
  AND created_at < DATEADD(day, 1, @today);

SELECT
      shipment_file_id
    , container_name
    , container_building_uid
    , vessel_receipts_hdr_uid
    , vessel_receipts_container_uid
    , container_receipts_hdr_uid
    , vessel_receipt_number
    , line_count
    , total_qty
    , created_by
    , created_at
FROM dbo.coats_mexico_shipment_receipt_build
WHERE created_at >= @today
  AND created_at < DATEADD(day, 1, @today)
ORDER BY created_at DESC;

SELECT
      target_table = 'container_building'
    , rows_created_today = COUNT(*)
    , min_uid = MIN(CONVERT(bigint, container_building_uid))
    , max_uid = MAX(CONVERT(bigint, container_building_uid))
FROM dbo.container_building
WHERE date_created >= @today AND date_created < DATEADD(day, 1, @today)
UNION ALL
SELECT 'vessel_receipts_hdr', COUNT(*), MIN(CONVERT(bigint, vessel_receipts_hdr_uid)), MAX(CONVERT(bigint, vessel_receipts_hdr_uid))
FROM dbo.vessel_receipts_hdr
WHERE date_created >= @today AND date_created < DATEADD(day, 1, @today)
UNION ALL
SELECT 'vessel_receipts_container', COUNT(*), MIN(CONVERT(bigint, vessel_receipts_container_uid)), MAX(CONVERT(bigint, vessel_receipts_container_uid))
FROM dbo.vessel_receipts_container
WHERE date_created >= @today AND date_created < DATEADD(day, 1, @today)
UNION ALL
SELECT 'vessel_receipts_line', COUNT(*), MIN(CONVERT(bigint, vessel_receipts_line_uid)), MAX(CONVERT(bigint, vessel_receipts_line_uid))
FROM dbo.vessel_receipts_line
WHERE date_created >= @today AND date_created < DATEADD(day, 1, @today)
UNION ALL
SELECT 'container_receipts_hdr', COUNT(*), MIN(CONVERT(bigint, container_receipts_hdr_uid)), MAX(CONVERT(bigint, container_receipts_hdr_uid))
FROM dbo.container_receipts_hdr
WHERE date_created >= @today AND date_created < DATEADD(day, 1, @today)
UNION ALL
SELECT 'container_receipts_line', COUNT(*), MIN(CONVERT(bigint, container_receipts_line_uid)), MAX(CONVERT(bigint, container_receipts_line_uid))
FROM dbo.container_receipts_line
WHERE date_created >= @today AND date_created < DATEADD(day, 1, @today)
ORDER BY target_table;

SELECT
      relationship_check = 'vessel_receipts_container_uid compared with vessel_receipts_hdr_uid'
    , equal_uid_count = SUM(CASE WHEN vessel_receipts_container_uid = vessel_receipts_hdr_uid THEN 1 ELSE 0 END)
    , different_uid_count = SUM(CASE WHEN vessel_receipts_container_uid <> vessel_receipts_hdr_uid THEN 1 ELSE 0 END)
FROM dbo.vessel_receipts_container;

SELECT
      issue = 'Coats receipt build container UID missing in vessel_receipts_container'
    , issue_count = COUNT(*)
FROM dbo.coats_mexico_shipment_receipt_build AS rb
WHERE rb.created_at >= @today
  AND rb.created_at < DATEADD(day, 1, @today)
  AND NOT EXISTS
  (
      SELECT 1
      FROM dbo.vessel_receipts_container AS vc
      WHERE vc.vessel_receipts_container_uid = rb.vessel_receipts_container_uid
        AND vc.vessel_receipts_hdr_uid = rb.vessel_receipts_hdr_uid
  );
