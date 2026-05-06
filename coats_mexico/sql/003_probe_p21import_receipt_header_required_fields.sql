/*
Simulate required insert fields for the Coats Mexico P21Import receipt header path.

Run manually in SQL Server Management Studio or sqlcmd. This script is designed
to simulate the real insert path while still keeping the row data transient:

  - It uses database P21Import, not P21.
  - It reports likely required fields from catalog metadata.
  - It allocates P21 counters up front, outside the insert transaction.
  - It inserts explicit business values rather than cloning an existing row.
  - It creates the dependent `vessel_receipts_container` row so
    `container_receipts_hdr` has a valid foreign key target.
  - It rolls back the insert transaction at the end, so the rows do not remain
    in the test database even though the counters advance.
  - Database metadata checked on 2026-05-06 showed:
      * container_building PK: container_building_uid
      * container_building unique key: location_id, container_name
      * vessel_receipts_hdr PK: vessel_receipts_hdr_uid
      * vessel_receipts_hdr unique keys: vessel_receipt_number;
        location_id, vessel_name, departure_date
      * container_receipts_hdr PK: container_receipts_hdr_uid
      * container_receipts_hdr FK: vessel_receipts_container_uid references
        vessel_receipts_container

Target tables:
  - P21Import.dbo.container_building
  - P21Import.dbo.vessel_receipts_hdr
  - P21Import.dbo.container_receipts_hdr

This is a discovery script. If an insert fails, the error message plus the
metadata result sets should identify the missing/invalid required field.
*/

USE P21Import;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ProbePrefix varchar(20) = 'CODXTEST';
DECLARE @TrailerBase varchar(50) = 'TM672';
DECLARE @MaintainedBy varchar(30) = 'DSHAO';
DECLARE @Now datetime = dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL);
DECLARE @ShipmentDate date = CONVERT(date, @Now);
DECLARE @EstimatedArrivalDate date = DATEADD(day, 7, @ShipmentDate);
DECLARE @CompanyId varchar(8) = 'KA';
DECLARE @LocationId decimal(19, 0) = 210;
DECLARE @FreightTermsCd int = 1773;
DECLARE @DocumentsReceivedFlag char(1) = 'N';
DECLARE @ApplyLandedCostsFlag char(1) = 'N';
DECLARE @ContainerBuildingStatus int = 702;
DECLARE @VesselHdrStatus int = 972;
DECLARE @VesselContainerStatus int = 701;
DECLARE @ContainerReceiptsHdrStatus int = 972;
DECLARE @ContainerPackagingWeight decimal(19, 9) = 0.0;
DECLARE @CounterContainerBuilding bigint;
DECLARE @CounterVesselHdr bigint;
DECLARE @CounterContainerReceiptsHdr bigint;

DECLARE @TargetTables table
(
    table_name sysname NOT NULL PRIMARY KEY,
    uid_column sysname NOT NULL,
    name_column sysname NULL,
    status_column sysname NULL,
    manual_guidance varchar(4000) NULL
);

INSERT INTO @TargetTables
(
    table_name,
    uid_column,
    name_column,
    status_column,
    manual_guidance
)
VALUES
(
    'container_building',
    'container_building_uid',
    'container_name',
    NULL,
    'Manual guidance: location_id = 210; container_name is the trailer name; save to generate container_building_uid.'
),
(
    'vessel_receipts_hdr',
    'vessel_receipts_hdr_uid',
    'vessel_name',
    NULL,
    'Manual guidance: vessel name is the trailer; set departure, estimated arrival, and estimated available-for-ship dates.'
),
(
    'container_receipts_hdr',
    'container_receipts_hdr_uid',
    NULL,
    'row_status_flag',
    'Manual guidance: create header first and set row_status_flag = 972 in the live pattern before line inserts. This table does not expose a container_name column in INFORMATION_SCHEMA.'
);

IF EXISTS
(
    SELECT 1
    FROM @TargetTables AS t
    WHERE OBJECT_ID(QUOTENAME('dbo') + '.' + QUOTENAME(t.table_name), 'U') IS NULL
)
BEGIN
    SELECT
        t.table_name,
        'Missing table in P21Import.dbo' AS issue
    FROM @TargetTables AS t
    WHERE OBJECT_ID(QUOTENAME('dbo') + '.' + QUOTENAME(t.table_name), 'U') IS NULL;

    THROW 51000, 'One or more target tables do not exist in P21Import.dbo.', 1;
END;

PRINT 'Catalog metadata: NOT NULL columns without defaults are the first-pass required-field candidates.';

SELECT
    t.table_name,
    c.column_id,
    c.name AS column_name,
    ty.name AS data_type,
    c.max_length,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity,
    c.is_computed,
    CASE WHEN dc.object_id IS NULL THEN 0 ELSE 1 END AS has_default_constraint,
    CASE
        WHEN c.is_nullable = 0
         AND c.is_identity = 0
         AND c.is_computed = 0
         AND dc.object_id IS NULL
         AND ty.name NOT IN ('timestamp', 'rowversion')
        THEN 1
        ELSE 0
    END AS likely_required_for_insert
FROM @TargetTables AS t
JOIN sys.tables AS st
  ON st.object_id = OBJECT_ID(QUOTENAME('dbo') + '.' + QUOTENAME(t.table_name), 'U')
JOIN sys.columns AS c
  ON c.object_id = st.object_id
JOIN sys.types AS ty
  ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.default_constraints AS dc
  ON dc.parent_object_id = c.object_id
 AND dc.parent_column_id = c.column_id
ORDER BY
    t.table_name,
    c.column_id;

PRINT 'INFORMATION_SCHEMA column check for insert mappings.';

SELECT
    t.table_name,
    t.uid_column,
    t.name_column,
    t.status_column,
    CASE
        WHEN t.name_column IS NULL THEN 'No name column configured'
        WHEN EXISTS
        (
            SELECT 1
            FROM information_schema.columns AS c
            WHERE c.table_schema = 'dbo'
              AND c.table_name = t.table_name
              AND c.column_name = t.name_column
        ) THEN 'Name column exists'
        ELSE 'Name column missing'
    END AS name_column_check,
    CASE
        WHEN t.status_column IS NULL THEN 'No status column configured'
        WHEN EXISTS
        (
            SELECT 1
            FROM information_schema.columns AS c
            WHERE c.table_schema = 'dbo'
              AND c.table_name = t.table_name
              AND c.column_name = t.status_column
        ) THEN 'Status column exists'
        ELSE 'Status column missing'
    END AS status_column_check
FROM @TargetTables AS t
ORDER BY t.table_name;

PRINT 'Unique indexes/constraints: cloned rows may need these fields changed in addition to UID/name fields.';

SELECT
    t.table_name,
    i.name AS index_name,
    i.is_unique,
    i.is_primary_key,
    STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_columns
FROM @TargetTables AS t
JOIN sys.tables AS st
  ON st.object_id = OBJECT_ID(QUOTENAME('dbo') + '.' + QUOTENAME(t.table_name), 'U')
JOIN sys.indexes AS i
  ON i.object_id = st.object_id
JOIN sys.index_columns AS ic
  ON ic.object_id = i.object_id
 AND ic.index_id = i.index_id
JOIN sys.columns AS c
  ON c.object_id = ic.object_id
 AND c.column_id = ic.column_id
WHERE i.is_unique = 1
  AND ic.is_included_column = 0
GROUP BY
    t.table_name,
    i.name,
    i.is_unique,
    i.is_primary_key
ORDER BY
    t.table_name,
    i.is_primary_key DESC,
    i.name;

EXEC dbo.p21_get_counter
     @strCounterID = 'container_building'
   , @iIncrementValue = 1
   , @LastValue = @CounterContainerBuilding OUTPUT;

EXEC dbo.p21_get_counter
     @strCounterID = 'vessel_receipts_hdr'
   , @iIncrementValue = 1
   , @LastValue = @CounterVesselHdr OUTPUT;

EXEC dbo.p21_get_counter
     @strCounterID = 'container_receipts_hdr'
   , @iIncrementValue = 1
   , @LastValue = @CounterContainerReceiptsHdr OUTPUT;

DECLARE @ContainerBuildingUid int = CONVERT(int, @CounterContainerBuilding);
DECLARE @VesselReceiptsHdrUid int = CONVERT(int, @CounterVesselHdr);
DECLARE @VesselReceiptsContainerUid int = CONVERT(int, @CounterVesselHdr);
DECLARE @ContainerReceiptsHdrUid int = CONVERT(int, @CounterContainerReceiptsHdr);
DECLARE @TrailerName varchar(255) = LEFT(CONCAT(@ProbePrefix, '_', @TrailerBase, '_', @ContainerBuildingUid), 255);
DECLARE @VesselName varchar(255) = LEFT(CONCAT(@ProbePrefix, '_', @TrailerBase, '_', @VesselReceiptsHdrUid), 255);

BEGIN TRY
    BEGIN TRAN;

    PRINT 'Beginning actual insert simulation with advanced counters.';

    IF OBJECT_ID('tempdb..#InsertResults') IS NOT NULL
        DROP TABLE #InsertResults;

    CREATE TABLE #InsertResults
    (
        table_name sysname NOT NULL,
        inserted_uid bigint NOT NULL,
        business_key varchar(255) NULL,
        inserted_row_count int NOT NULL,
        note varchar(4000) NULL
    );

    INSERT INTO dbo.container_building
    (
        container_building_uid,
        container_name,
        location_id,
        row_status_flag,
        date_created,
        created_by,
        date_last_modified,
        last_maintained_by,
        container_type_uid,
        container_packaging_weight
    )
    VALUES
    (
        @ContainerBuildingUid,
        @TrailerName,
        @LocationId,
        @ContainerBuildingStatus,
        @Now,
        @MaintainedBy,
        @Now,
        @MaintainedBy,
        NULL,
        @ContainerPackagingWeight
    );

    INSERT INTO #InsertResults
    (
        table_name,
        inserted_uid,
        business_key,
        inserted_row_count,
        note
    )
    VALUES
    (
        'container_building',
        @ContainerBuildingUid,
        @TrailerName,
        1,
        'container_building_uid allocated from p21_get_counter and row inserted with explicit business fields.'
    );

    INSERT INTO dbo.vessel_receipts_hdr
    (
        vessel_receipts_hdr_uid,
        vessel_receipt_number,
        company_id,
        location_id,
        vessel_name,
        departure_date,
        freight_terms_cd,
        documents_received_flag,
        apply_landed_costs_flag,
        period,
        year_for_period,
        row_status_flag,
        date_created,
        created_by,
        date_last_modified,
        last_maintained_by,
        currency_line_uid,
        exchange_date,
        receipt_date,
        currency_id,
        loading_port,
        loading_country,
        discharge_port,
        discharge_country,
        delivery_method
    )
    VALUES
    (
        @VesselReceiptsHdrUid,
        @VesselReceiptsHdrUid,
        @CompanyId,
        @LocationId,
        @VesselName,
        @ShipmentDate,
        @FreightTermsCd,
        @DocumentsReceivedFlag,
        @ApplyLandedCostsFlag,
        DATEPART(month, @ShipmentDate),
        DATEPART(year, @ShipmentDate),
        @VesselHdrStatus,
        @Now,
        @MaintainedBy,
        @Now,
        @MaintainedBy,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL
    );

    INSERT INTO #InsertResults
    (
        table_name,
        inserted_uid,
        business_key,
        inserted_row_count,
        note
    )
    VALUES
    (
        'vessel_receipts_hdr',
        @VesselReceiptsHdrUid,
        @VesselName,
        1,
        'vessel_receipts_hdr_uid and vessel_receipt_number allocated from p21_get_counter.'
    );

    INSERT INTO dbo.vessel_receipts_container
    (
        vessel_receipts_container_uid,
        vessel_receipts_hdr_uid,
        container_name,
        expected_arrival_date,
        row_status_flag,
        date_created,
        created_by,
        date_last_modified,
        last_maintained_by,
        container_building_uid,
        container_packaging_weight,
        container_capacity,
        received_date,
        container_seal_id,
        comments,
        container_type_uid,
        processing,
        processing_by
    )
    VALUES
    (
        @VesselReceiptsContainerUid,
        @VesselReceiptsHdrUid,
        @TrailerName,
        @EstimatedArrivalDate,
        @VesselContainerStatus,
        @Now,
        @MaintainedBy,
        @Now,
        @MaintainedBy,
        @ContainerBuildingUid,
        @ContainerPackagingWeight,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL
    );

    INSERT INTO #InsertResults
    (
        table_name,
        inserted_uid,
        business_key,
        inserted_row_count,
        note
    )
    VALUES
    (
        'vessel_receipts_container',
        @VesselReceiptsContainerUid,
        @TrailerName,
        1,
        'vessel_receipts_container_uid reuses the vessel receipts counter in the live pattern.'
    );

    INSERT INTO dbo.container_receipts_hdr
    (
        container_receipts_hdr_uid,
        vessel_receipts_container_uid,
        date_received,
        period,
        year_for_period,
        row_status_flag,
        date_created,
        created_by,
        date_last_modified,
        last_maintained_by,
        receiving_location_id,
        currency_line_uid,
        exchange_date,
        rfnav_trans_no,
        processing,
        processing_by
    )
    VALUES
    (
        @ContainerReceiptsHdrUid,
        @VesselReceiptsContainerUid,
        @EstimatedArrivalDate,
        DATEPART(month, @EstimatedArrivalDate),
        DATEPART(year, @EstimatedArrivalDate),
        @ContainerReceiptsHdrStatus,
        @Now,
        @MaintainedBy,
        @Now,
        @MaintainedBy,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL
    );

    INSERT INTO #InsertResults
    (
        table_name,
        inserted_uid,
        business_key,
        inserted_row_count,
        note
    )
    VALUES
    (
        'container_receipts_hdr',
        @ContainerReceiptsHdrUid,
        @TrailerName,
        1,
        'container_receipts_hdr_uid allocated from p21_get_counter and linked to the inserted vessel_receipts_container row.'
    );

    SELECT
        table_name,
        inserted_uid,
        business_key,
        inserted_row_count,
        note
    FROM #InsertResults
    ORDER BY
        CASE table_name
            WHEN 'container_building' THEN 1
            WHEN 'vessel_receipts_hdr' THEN 2
            WHEN 'vessel_receipts_container' THEN 3
            WHEN 'container_receipts_hdr' THEN 4
            ELSE 99
        END;

    PRINT 'Actual insert simulation succeeded. Rolling back inserted rows, counters remain advanced.';
    ROLLBACK TRAN;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRAN;

    SELECT
        ERROR_NUMBER() AS error_number,
        ERROR_SEVERITY() AS error_severity,
        ERROR_STATE() AS error_state,
        ERROR_PROCEDURE() AS error_procedure,
        ERROR_LINE() AS error_line,
        ERROR_MESSAGE() AS error_message;

    THROW;
END CATCH;

SELECT
    'Rollback verification complete. No simulated rows should remain, but counters may have advanced.' AS verification_note;
