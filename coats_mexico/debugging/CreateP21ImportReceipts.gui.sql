USE P21Import;

DECLARE @extractionPayload nvarchar(max) = @extraction_payload;
DECLARE @ShipmentFileId uniqueidentifier = TRY_CONVERT(uniqueidentifier, JSON_VALUE(@extractionPayload, '$.metadata.shipment_file_id'));
DECLARE @CreatedBy nvarchar(30) = @created_by;
DECLARE @ReceiptDate date = NULL;
DECLARE @AllowExisting bit = 1;

/*
Create Coats Mexico P21Import receipt records from validated staging rows.

Run in P21Import. This script intentionally does not use the P21 database and
does not insert document_line_bin rows.
*/


SET NOCOUNT ON;
SET XACT_ABORT ON;


IF OBJECT_ID('dbo.coats_mexico_shipment_receipt_build', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.coats_mexico_shipment_receipt_build
    (
          shipment_file_id uniqueidentifier NOT NULL
        , container_building_uid int NOT NULL
        , vessel_receipts_hdr_uid int NOT NULL
        , vessel_receipts_container_uid int NOT NULL
        , container_receipts_hdr_uid int NOT NULL
        , container_name nvarchar(255) NOT NULL
        , vessel_receipt_number decimal(19, 0) NOT NULL
        , line_count int NOT NULL
        , total_qty decimal(19, 9) NOT NULL
        , created_by nvarchar(30) NOT NULL
        , created_at datetime NOT NULL
        , CONSTRAINT PK_coats_mexico_shipment_receipt_build
            PRIMARY KEY CLUSTERED (shipment_file_id)
    );
END;


IF NOT EXISTS
(
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = 'FK_coats_mexico_receipt_build_file'
)
BEGIN
    ALTER TABLE dbo.coats_mexico_shipment_receipt_build
    ADD CONSTRAINT FK_coats_mexico_receipt_build_file
        FOREIGN KEY (shipment_file_id)
        REFERENCES dbo.coats_mexico_shipment_file (shipment_file_id);
END;


IF COL_LENGTH('dbo.coats_mexico_shipment_pallet_line', 'vessel_receipts_line_uid') IS NULL
BEGIN
    ALTER TABLE dbo.coats_mexico_shipment_pallet_line
    ADD vessel_receipts_line_uid int NULL;
END;


IF COL_LENGTH('dbo.coats_mexico_shipment_pallet_line', 'container_receipts_line_uid') IS NULL
BEGIN
    ALTER TABLE dbo.coats_mexico_shipment_pallet_line
    ADD container_receipts_line_uid int NULL;
END;



SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @Now datetime = dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL)
        , @ShipmentDate date
        , @EstimatedArrivalDate date
        , @TrailerName nvarchar(50)
        , @ContainerName nvarchar(255)
        , @CompanyId varchar(8) = 'KA'
        , @LocationId decimal(19, 0) = 210
        , @FreightTermsCd int = 1773
        , @DocumentsReceivedFlag char(1) = 'N'
        , @ApplyLandedCostsFlag char(1) = 'N'
        , @ContainerBuildingStatus int = 702
        , @ContainerBuildingPoStatus int = 702
        , @VesselHdrStatus int = 972
        , @VesselLineStatus int = 972
        , @VesselContainerStatus int = 701
        , @ContainerReceiptsHdrStatus int = 972
        , @ContainerPackagingWeight decimal(19, 9) = 0.0
        , @ContainerBuildingUid int
        , @VesselReceiptsHdrUid int
        , @VesselReceiptsContainerUid int
        , @ContainerReceiptsHdrUid int
        , @FirstVesselReceiptsLineUid bigint
        , @FirstContainerReceiptsLineUid bigint
        , @LastValue bigint
        , @LineCount int
        , @TotalQty decimal(19, 9);

    IF NULLIF(LTRIM(RTRIM(@CreatedBy)), '') IS NULL
    BEGIN
        THROW 52000, '@CreatedBy is required.', 1;
    END;

    IF DB_NAME() <> 'P21Import'
    BEGIN
        THROW 52001, 'This procedure must run in the P21Import database.', 1;
    END;

    DECLARE @required_column table
    (
          table_name sysname NOT NULL
        , column_name sysname NOT NULL
    );

    INSERT INTO @required_column (table_name, column_name)
    VALUES
          ('container_building', 'container_building_uid')
        , ('container_building', 'container_name')
        , ('container_building', 'location_id')
        , ('container_building', 'row_status_flag')
        , ('container_building', 'date_created')
        , ('container_building', 'created_by')
        , ('container_building', 'date_last_modified')
        , ('container_building', 'last_maintained_by')
        , ('container_building', 'container_type_uid')
        , ('container_building', 'container_packaging_weight')
        , ('container_building_po', 'container_building_uid')
        , ('container_building_po', 'po_line_uid')
        , ('container_building_po', 'row_status_flag')
        , ('container_building_po', 'sequence_no')
        , ('container_building_po', 'po_container_unit_qty')
        , ('container_building_po', 'container_uom')
        , ('container_building_po', 'container_unit_size')
        , ('container_building_po', 'po_line_schedule_uid')
        , ('container_building_po', 'priority_status_cd')
        , ('container_building_po', 'date_created')
        , ('container_building_po', 'created_by')
        , ('container_building_po', 'date_last_modified')
        , ('container_building_po', 'last_maintained_by')
        , ('vessel_receipts_hdr', 'vessel_receipts_hdr_uid')
        , ('vessel_receipts_hdr', 'vessel_receipt_number')
        , ('vessel_receipts_hdr', 'company_id')
        , ('vessel_receipts_hdr', 'location_id')
        , ('vessel_receipts_hdr', 'vessel_name')
        , ('vessel_receipts_hdr', 'departure_date')
        , ('vessel_receipts_hdr', 'freight_terms_cd')
        , ('vessel_receipts_hdr', 'documents_received_flag')
        , ('vessel_receipts_hdr', 'apply_landed_costs_flag')
        , ('vessel_receipts_hdr', 'period')
        , ('vessel_receipts_hdr', 'year_for_period')
        , ('vessel_receipts_hdr', 'row_status_flag')
        , ('vessel_receipts_hdr', 'date_created')
        , ('vessel_receipts_hdr', 'created_by')
        , ('vessel_receipts_hdr', 'date_last_modified')
        , ('vessel_receipts_hdr', 'last_maintained_by')
        , ('vessel_receipts_hdr', 'currency_line_uid')
        , ('vessel_receipts_hdr', 'exchange_date')
        , ('vessel_receipts_hdr', 'receipt_date')
        , ('vessel_receipts_hdr', 'currency_id')
        , ('vessel_receipts_hdr', 'loading_port')
        , ('vessel_receipts_hdr', 'loading_country')
        , ('vessel_receipts_hdr', 'discharge_port')
        , ('vessel_receipts_hdr', 'discharge_country')
        , ('vessel_receipts_hdr', 'delivery_method')
        , ('vessel_receipts_container', 'vessel_receipts_container_uid')
        , ('vessel_receipts_container', 'vessel_receipts_hdr_uid')
        , ('vessel_receipts_container', 'container_name')
        , ('vessel_receipts_container', 'expected_arrival_date')
        , ('vessel_receipts_container', 'row_status_flag')
        , ('vessel_receipts_container', 'container_building_uid')
        , ('vessel_receipts_container', 'date_created')
        , ('vessel_receipts_container', 'created_by')
        , ('vessel_receipts_container', 'date_last_modified')
        , ('vessel_receipts_container', 'last_maintained_by')
        , ('vessel_receipts_container', 'container_packaging_weight')
        , ('vessel_receipts_container', 'container_capacity')
        , ('vessel_receipts_container', 'received_date')
        , ('vessel_receipts_container', 'container_seal_id')
        , ('vessel_receipts_container', 'comments')
        , ('vessel_receipts_container', 'container_type_uid')
        , ('vessel_receipts_container', 'processing')
        , ('vessel_receipts_container', 'processing_by')
        , ('vessel_receipts_line', 'vessel_receipts_line_uid')
        , ('vessel_receipts_line', 'vessel_receipts_hdr_uid')
        , ('vessel_receipts_line', 'line_no')
        , ('vessel_receipts_line', 'po_line_uid')
        , ('vessel_receipts_line', 'container_qty_received')
        , ('vessel_receipts_line', 'container_uom')
        , ('vessel_receipts_line', 'container_unit_size')
        , ('vessel_receipts_line', 'row_status_flag')
        , ('vessel_receipts_line', 'date_created')
        , ('vessel_receipts_line', 'created_by')
        , ('vessel_receipts_line', 'date_last_modified')
        , ('vessel_receipts_line', 'last_maintained_by')
        , ('container_receipts_hdr', 'container_receipts_hdr_uid')
        , ('container_receipts_hdr', 'vessel_receipts_container_uid')
        , ('container_receipts_hdr', 'date_received')
        , ('container_receipts_hdr', 'period')
        , ('container_receipts_hdr', 'year_for_period')
        , ('container_receipts_hdr', 'row_status_flag')
        , ('container_receipts_hdr', 'date_created')
        , ('container_receipts_hdr', 'created_by')
        , ('container_receipts_hdr', 'date_last_modified')
        , ('container_receipts_hdr', 'last_maintained_by')
        , ('container_receipts_hdr', 'receiving_location_id')
        , ('container_receipts_hdr', 'currency_line_uid')
        , ('container_receipts_hdr', 'exchange_date')
        , ('container_receipts_hdr', 'rfnav_trans_no')
        , ('container_receipts_hdr', 'processing')
        , ('container_receipts_hdr', 'processing_by')
        , ('container_receipts_line', 'container_receipts_line_uid')
        , ('container_receipts_line', 'container_receipts_hdr_uid')
        , ('container_receipts_line', 'vessel_receipts_line_uid')
        , ('container_receipts_line', 'qty_received')
        , ('container_receipts_line', 'unit_of_measure')
        , ('container_receipts_line', 'unit_size')
        , ('container_receipts_line', 'date_created')
        , ('container_receipts_line', 'created_by')
        , ('container_receipts_line', 'date_last_modified')
        , ('container_receipts_line', 'last_maintained_by')
        , ('container_receipts_line', 'complete_po_line_flag')
        , ('container_receipts_line', 'transfer_flag')
        , ('container_receipts_line', 'wrong_part_no_flag')
        , ('container_receipts_line', 'currency_line_uid')
        , ('container_receipts_line', 'exclude_from_landed_cost_flag');

    IF EXISTS
    (
        SELECT 1
        FROM @required_column AS rc
        WHERE COL_LENGTH('dbo.' + rc.table_name, rc.column_name) IS NULL
    )
    BEGIN
        SELECT
              rc.table_name
            , rc.column_name
            , full_table_name = 'dbo.' + rc.table_name
            , col_length_value = COL_LENGTH('dbo.' + rc.table_name, rc.column_name)
            , issue = 'Missing required P21Import column according to ADF linked service login'
        FROM @required_column AS rc
        WHERE COL_LENGTH('dbo.' + rc.table_name, rc.column_name) IS NULL
        ORDER BY
              rc.table_name
            , rc.column_name;
    
        THROW 52009, 'One or more required P21Import target columns are missing. No counters were allocated.', 1;
    END;

    SELECT
          @ShipmentDate = f.shipment_date
        , @EstimatedArrivalDate = f.estimated_arrival_date
        , @TrailerName = f.trailer_name
    FROM dbo.coats_mexico_shipment_file AS f
    WHERE f.shipment_file_id = @ShipmentFileId;

    IF @ShipmentDate IS NULL OR @EstimatedArrivalDate IS NULL OR NULLIF(LTRIM(RTRIM(@TrailerName)), '') IS NULL
    BEGIN
        THROW 52002, 'Shipment file is missing shipment_date, estimated_arrival_date, or trailer_name.', 1;
    END;

    SET @ReceiptDate = COALESCE(@ReceiptDate, @EstimatedArrivalDate);
    SET @ContainerName = LEFT(@TrailerName, 255);

    IF EXISTS
    (
        SELECT 1
        FROM dbo.coats_mexico_shipment_validation_issue
        WHERE shipment_file_id = @ShipmentFileId
          AND severity = 'BLOCKING'
    )
    BEGIN
        THROW 52003, 'Blocking validation issues exist for this shipment. Resolve them before creating P21Import receipt records.', 1;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.coats_mexico_shipment_receipt_build
        WHERE shipment_file_id = @ShipmentFileId
    )
    BEGIN
        IF @AllowExisting = 1
        BEGIN
            SELECT
                  shipment_file_id
                , container_building_uid
                , vessel_receipts_hdr_uid
                , vessel_receipts_container_uid
                , container_receipts_hdr_uid
                , container_name
                , vessel_receipt_number
                , line_count
                , total_qty
                , created_by
                , created_at
            FROM dbo.coats_mexico_shipment_receipt_build
            WHERE shipment_file_id = @ShipmentFileId;

            RETURN;
        END;

        THROW 52004, 'Receipt records have already been created for this shipment_file_id.', 1;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.container_building
        WHERE location_id = @LocationId
          AND container_name = @ContainerName
    )
    BEGIN
        THROW 52005, 'A container_building row already exists for this location_id and trailer/container name.', 1;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.vessel_receipts_hdr
        WHERE location_id = @LocationId
          AND vessel_name = @ContainerName
          AND departure_date = @ShipmentDate
    )
    BEGIN
        THROW 52006, 'A vessel_receipts_hdr row already exists for this location, trailer, and shipment date.', 1;
    END;

    IF OBJECT_ID('tempdb..#shipment_line') IS NOT NULL
        DROP TABLE #shipment_line;

    ;WITH grouped AS
    (
        SELECT
              p.po_line_uid
            , sort_po_no = MIN(p.PO_No)
            , sort_item_id = MIN(p.Item_ID)
            , qty = SUM(CONVERT(decimal(19, 9), p.Invoiced_Qty))
            , container_uom = MAX(COALESCE(
                  p.container_uom,
                  CASE
                      WHEN ivm.default_purchasing_unit = pol.unit_of_measure
                          THEN pol.unit_of_measure
                      ELSE ivm.default_purchasing_unit
                  END
              ))
            , container_unit_size = CONVERT(decimal(19, 9), 1.0)
        FROM dbo.coats_mexico_shipment_pallet_line AS p
        LEFT JOIN dbo.po_line AS pol
          ON pol.po_line_uid = p.po_line_uid
        LEFT JOIN dbo.inv_mast AS ivm
          ON ivm.inv_mast_uid = pol.inv_mast_uid
        WHERE p.shipment_file_id = @ShipmentFileId
          AND p.po_line_uid IS NOT NULL
          AND p.Invoiced_Qty IS NOT NULL
        GROUP BY
              p.po_line_uid
    )
    SELECT
          po_line_uid
        , qty
        , container_uom
        , container_unit_size
        , line_no = ROW_NUMBER() OVER (ORDER BY sort_po_no, sort_item_id, po_line_uid)
    INTO #shipment_line
    FROM grouped;

    SELECT
          @LineCount = COUNT(*)
        , @TotalQty = COALESCE(SUM(qty), 0)
    FROM #shipment_line;

    IF @LineCount = 0
    BEGIN
        THROW 52007, 'No validated staged pallet lines with po_line_uid and quantity were found for this shipment.', 1;
    END;

    IF EXISTS
    (
        SELECT 1
        FROM #shipment_line
        WHERE container_uom IS NULL
    )
    BEGIN
        THROW 52008, 'One or more shipment lines could not resolve a container UOM.', 1;
    END;

    EXEC dbo.p21_get_counter
         @strCounterID = 'container_building'
       , @iIncrementValue = 1
       , @LastValue = @LastValue OUTPUT;
    SET @ContainerBuildingUid = CONVERT(int, @LastValue);

    EXEC dbo.p21_get_counter
         @strCounterID = 'vessel_receipts_hdr'
       , @iIncrementValue = 1
       , @LastValue = @LastValue OUTPUT;
    SET @VesselReceiptsHdrUid = CONVERT(int, @LastValue);
    SET @VesselReceiptsContainerUid = @VesselReceiptsHdrUid;

    EXEC dbo.p21_get_counter
         @strCounterID = 'container_receipts_hdr'
       , @iIncrementValue = 1
       , @LastValue = @LastValue OUTPUT;
    SET @ContainerReceiptsHdrUid = CONVERT(int, @LastValue);

    EXEC dbo.p21_get_counter
         @strCounterID = 'vessel_receipts_line'
       , @iIncrementValue = @LineCount
       , @LastValue = @LastValue OUTPUT;
    
    SET @FirstVesselReceiptsLineUid = @LastValue - @LineCount + 1;
    
    DECLARE @MaxVesselReceiptsLineUid bigint =
    (
        SELECT ISNULL(MAX(vessel_receipts_line_uid), 0)
        FROM dbo.vessel_receipts_line
    );
    
    IF @FirstVesselReceiptsLineUid <= @MaxVesselReceiptsLineUid
    BEGIN
        DECLARE @AdditionalVesselLineCounterIncrement bigint =
            (@MaxVesselReceiptsLineUid + @LineCount) - @LastValue;
    
        IF @AdditionalVesselLineCounterIncrement <= 0
        BEGIN
            THROW 52013, 'Calculated vessel_receipts_line counter catch-up increment was not positive.', 1;
        END;
    
        EXEC dbo.p21_get_counter
             @strCounterID = 'vessel_receipts_line'
           , @iIncrementValue = @AdditionalVesselLineCounterIncrement
           , @LastValue = @LastValue OUTPUT;
    
        SET @FirstVesselReceiptsLineUid = @LastValue - @LineCount + 1;
    END;
    
    IF @FirstVesselReceiptsLineUid <= @MaxVesselReceiptsLineUid
    BEGIN
        THROW 52013, 'Allocated vessel_receipts_line_uid block overlaps existing rows. Counter is behind.', 1;
    END;

    EXEC dbo.p21_get_counter
         @strCounterID = 'container_receipts_line'
       , @iIncrementValue = @LineCount
       , @LastValue = @LastValue OUTPUT;
    
    SET @FirstContainerReceiptsLineUid = @LastValue - @LineCount + 1;
    
    DECLARE @MaxContainerReceiptsLineUid bigint =
    (
        SELECT ISNULL(MAX(container_receipts_line_uid), 0)
        FROM dbo.container_receipts_line
    );
    
    IF @FirstContainerReceiptsLineUid <= @MaxContainerReceiptsLineUid
    BEGIN
        DECLARE @AdditionalContainerLineCounterIncrement bigint =
            (@MaxContainerReceiptsLineUid + @LineCount) - @LastValue;
    
        IF @AdditionalContainerLineCounterIncrement <= 0
        BEGIN
            THROW 52014, 'Calculated container_receipts_line counter catch-up increment was not positive.', 1;
        END;
    
        EXEC dbo.p21_get_counter
             @strCounterID = 'container_receipts_line'
           , @iIncrementValue = @AdditionalContainerLineCounterIncrement
           , @LastValue = @LastValue OUTPUT;
    
        SET @FirstContainerReceiptsLineUid = @LastValue - @LineCount + 1;
    END;
    
    IF @FirstContainerReceiptsLineUid <= @MaxContainerReceiptsLineUid
    BEGIN
        THROW 52014, 'Allocated container_receipts_line_uid block overlaps existing rows. Counter is behind.', 1;
    END;

    IF @ContainerBuildingUid <= ISNULL((SELECT MAX(container_building_uid) FROM dbo.container_building), 0)
    BEGIN
        THROW 52010, 'Allocated container_building_uid overlaps existing rows. Counter is behind.', 1;
    END;

    IF @VesselReceiptsHdrUid <= ISNULL((SELECT MAX(vessel_receipts_hdr_uid) FROM dbo.vessel_receipts_hdr), 0)
    BEGIN
        THROW 52011, 'Allocated vessel_receipts_hdr_uid overlaps existing rows. Counter is behind.', 1;
    END;

    IF @ContainerReceiptsHdrUid <= ISNULL((SELECT MAX(container_receipts_hdr_uid) FROM dbo.container_receipts_hdr), 0)
    BEGIN
        THROW 52012, 'Allocated container_receipts_hdr_uid overlaps existing rows. Counter is behind.', 1;
    END;

    IF @FirstVesselReceiptsLineUid <= ISNULL((SELECT MAX(vessel_receipts_line_uid) FROM dbo.vessel_receipts_line), 0)
    BEGIN
        THROW 52013, 'Allocated vessel_receipts_line_uid block overlaps existing rows. Counter is behind.', 1;
    END;

    IF @FirstContainerReceiptsLineUid <= ISNULL((SELECT MAX(container_receipts_line_uid) FROM dbo.container_receipts_line), 0)
    BEGIN
        THROW 52014, 'Allocated container_receipts_line_uid block overlaps existing rows. Counter is behind.', 1;
    END;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO dbo.container_building
        (
              container_building_uid
            , container_name
            , location_id
            , row_status_flag
            , date_created
            , created_by
            , date_last_modified
            , last_maintained_by
            , container_type_uid
            , container_packaging_weight
        )
        VALUES
        (
              @ContainerBuildingUid
            , @ContainerName
            , @LocationId
            , @ContainerBuildingStatus
            , @Now
            , @CreatedBy
            , @Now
            , @CreatedBy
            , NULL
            , @ContainerPackagingWeight
        );

        INSERT INTO dbo.container_building_po
        (
              container_building_uid
            , po_line_uid
            , row_status_flag
            , sequence_no
            , po_container_unit_qty
            , container_uom
            , container_unit_size
            , po_line_schedule_uid
            , priority_status_cd
            , date_created
            , created_by
            , date_last_modified
            , last_maintained_by
        )
        SELECT
              @ContainerBuildingUid
            , s.po_line_uid
            , @ContainerBuildingPoStatus
            , 10000
            , s.qty
            , s.container_uom
            , s.container_unit_size
            , NULL
            , 3103
            , @Now
            , @CreatedBy
            , @Now
            , @CreatedBy
        FROM #shipment_line AS s
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dbo.container_building_po AS x WITH (UPDLOCK, HOLDLOCK)
            WHERE x.container_building_uid = @ContainerBuildingUid
              AND x.po_line_uid = s.po_line_uid
              AND ISNULL(x.po_line_schedule_uid, -1) = -1
              AND x.sequence_no = 10000
        );

        INSERT INTO dbo.vessel_receipts_hdr
        (
              vessel_receipts_hdr_uid
            , vessel_receipt_number
            , company_id
            , location_id
            , vessel_name
            , departure_date
            , freight_terms_cd
            , documents_received_flag
            , apply_landed_costs_flag
            , period
            , year_for_period
            , row_status_flag
            , date_created
            , created_by
            , date_last_modified
            , last_maintained_by
            , currency_line_uid
            , exchange_date
            , receipt_date
            , currency_id
            , loading_port
            , loading_country
            , discharge_port
            , discharge_country
            , delivery_method
        )
        VALUES
        (
              @VesselReceiptsHdrUid
            , @VesselReceiptsHdrUid
            , @CompanyId
            , @LocationId
            , @ContainerName
            , @ShipmentDate
            , @FreightTermsCd
            , @DocumentsReceivedFlag
            , @ApplyLandedCostsFlag
            , DATEPART(month, @ShipmentDate)
            , DATEPART(year, @ShipmentDate)
            , @VesselHdrStatus
            , @Now
            , @CreatedBy
            , @Now
            , @CreatedBy
            , NULL
            , NULL
            , NULL
            , NULL
            , NULL
            , NULL
            , NULL
            , NULL
            , NULL
        );

        INSERT INTO dbo.vessel_receipts_container
        (
              vessel_receipts_container_uid
            , vessel_receipts_hdr_uid
            , container_name
            , expected_arrival_date
            , row_status_flag
            , date_created
            , created_by
            , date_last_modified
            , last_maintained_by
            , container_building_uid
            , container_packaging_weight
            , container_capacity
            , received_date
            , container_seal_id
            , comments
            , container_type_uid
            , processing
            , processing_by
        )
        VALUES
        (
              @VesselReceiptsContainerUid
            , @VesselReceiptsHdrUid
            , @ContainerName
            , @EstimatedArrivalDate
            , @VesselContainerStatus
            , @Now
            , @CreatedBy
            , @Now
            , @CreatedBy
            , @ContainerBuildingUid
            , @ContainerPackagingWeight
            , NULL
            , NULL
            , NULL
            , NULL
            , NULL
            , NULL
            , NULL
        );

        INSERT INTO dbo.vessel_receipts_line
        (
              vessel_receipts_line_uid
            , vessel_receipts_hdr_uid
            , line_no
            , po_line_uid
            , container_qty_received
            , container_uom
            , container_unit_size
            , row_status_flag
            , date_created
            , created_by
            , date_last_modified
            , last_maintained_by
        )
        SELECT
              @FirstVesselReceiptsLineUid + s.line_no - 1
            , @VesselReceiptsHdrUid
            , s.line_no
            , s.po_line_uid
            , 0
            , s.container_uom
            , s.container_unit_size
            , @VesselLineStatus
            , @Now
            , @CreatedBy
            , @Now
            , @CreatedBy
        FROM #shipment_line AS s;

        INSERT INTO dbo.container_receipts_hdr
        (
              container_receipts_hdr_uid
            , vessel_receipts_container_uid
            , date_received
            , period
            , year_for_period
            , row_status_flag
            , date_created
            , created_by
            , date_last_modified
            , last_maintained_by
            , receiving_location_id
            , currency_line_uid
            , exchange_date
            , rfnav_trans_no
            , processing
            , processing_by
        )
        VALUES
        (
              @ContainerReceiptsHdrUid
            , @VesselReceiptsContainerUid
            , @ReceiptDate
            , DATEPART(month, @ReceiptDate)
            , DATEPART(year, @ReceiptDate)
            , @ContainerReceiptsHdrStatus
            , @Now
            , @CreatedBy
            , @Now
            , @CreatedBy
            , NULL
            , NULL
            , NULL
            , NULL
            , NULL
            , NULL
        );

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
              @FirstContainerReceiptsLineUid + s.line_no - 1
            , @ContainerReceiptsHdrUid
            , @FirstVesselReceiptsLineUid + s.line_no - 1
            , s.qty
            , s.container_uom
            , s.container_unit_size
            , @Now
            , @CreatedBy
            , @Now
            , @CreatedBy
            , CASE
                  WHEN s.qty + ISNULL(pol.qty_received, 0) >= ISNULL(pol.qty_ordered, 0) THEN 'Y'
                  ELSE 'N'
              END
            , NULL
            , 'N'
            , NULL
            , 'N'
        FROM #shipment_line AS s
        LEFT JOIN dbo.po_line AS pol
          ON pol.po_line_uid = s.po_line_uid;

        UPDATE p
        SET
              p.vessel_receipts_line_uid = @FirstVesselReceiptsLineUid + s.line_no - 1
            , p.container_receipts_line_uid = @FirstContainerReceiptsLineUid + s.line_no - 1
        FROM dbo.coats_mexico_shipment_pallet_line AS p
        JOIN #shipment_line AS s
          ON s.po_line_uid = p.po_line_uid
        WHERE p.shipment_file_id = @ShipmentFileId;

        INSERT INTO dbo.coats_mexico_shipment_receipt_build
        (
              shipment_file_id
            , container_building_uid
            , vessel_receipts_hdr_uid
            , vessel_receipts_container_uid
            , container_receipts_hdr_uid
            , container_name
            , vessel_receipt_number
            , line_count
            , total_qty
            , created_by
            , created_at
        )
        VALUES
        (
              @ShipmentFileId
            , @ContainerBuildingUid
            , @VesselReceiptsHdrUid
            , @VesselReceiptsContainerUid
            , @ContainerReceiptsHdrUid
            , @ContainerName
            , @VesselReceiptsHdrUid
            , @LineCount
            , @TotalQty
            , @CreatedBy
            , @Now
        );

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK;

        THROW;
    END CATCH;

    SELECT
          shipment_file_id
        , container_building_uid
        , vessel_receipts_hdr_uid
        , vessel_receipts_container_uid
        , container_receipts_hdr_uid
        , container_name
        , vessel_receipt_number
        , line_count
        , total_qty
        , created_by
        , created_at
    FROM dbo.coats_mexico_shipment_receipt_build
    WHERE shipment_file_id = @ShipmentFileId;
