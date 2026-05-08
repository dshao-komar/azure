/*
Coats Mexico shipment staging objects.

Run in the P21Import database. These tables intentionally stop before P21
container/vessel/container-receipt writes.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID('dbo.coats_mexico_shipment_validation_issue', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.coats_mexico_shipment_validation_issue
    (
          validation_issue_id bigint IDENTITY(1,1) NOT NULL
        , shipment_file_id uniqueidentifier NOT NULL
        , severity nvarchar(20) NOT NULL
        , issue_code nvarchar(100) NOT NULL
        , message nvarchar(1000) NOT NULL
        , source_sheet nvarchar(128) NULL
        , source_row_number int NULL
        , Bin_ID nvarchar(100) NULL
        , Item_ID nvarchar(100) NULL
        , PO_No nvarchar(50) NULL
        , raw_pallet_comment nvarchar(max) NULL
        , created_at_utc datetime2(0) NOT NULL
            CONSTRAINT DF_coats_mexico_validation_issue_created_at_utc DEFAULT SYSUTCDATETIME()
        , CONSTRAINT PK_coats_mexico_shipment_validation_issue
            PRIMARY KEY CLUSTERED (validation_issue_id)
    );
END;

IF OBJECT_ID('dbo.coats_mexico_shipment_pallet_line', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.coats_mexico_shipment_pallet_line
    (
          shipment_pallet_line_id bigint IDENTITY(1,1) NOT NULL
        , shipment_file_id uniqueidentifier NOT NULL
        , source_sheet nvarchar(128) NOT NULL
        , source_row_number int NOT NULL
        , Bin_ID nvarchar(100) NULL
        , P21_Bin_ID nvarchar(100) NULL
        , Item_ID nvarchar(100) NULL
        , PO_No nvarchar(50) NULL
        , Invoiced_Qty decimal(18,4) NULL
        , Parsed_Qty_Unit nvarchar(30) NULL
        , raw_pallet_value nvarchar(100) NULL
        , raw_pallet_comment nvarchar(max) NULL
        , comment_line nvarchar(1000) NULL
        , quantity_reconciled bit NOT NULL
        , po_line_uid int NULL
        , cancel_flag char(1) NULL
        , has_duplicate_supplier_part bit NULL
        , missing_supplier_part_flag bit NULL
        , komar_item_id nvarchar(100) NULL
        , container_uom nvarchar(50) NULL
        , created_at_utc datetime2(0) NOT NULL
            CONSTRAINT DF_coats_mexico_pallet_line_created_at_utc DEFAULT SYSUTCDATETIME()
        , CONSTRAINT PK_coats_mexico_shipment_pallet_line
            PRIMARY KEY CLUSTERED (shipment_pallet_line_id)
    );
END;

IF OBJECT_ID('dbo.coats_mexico_shipment_raw_line', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.coats_mexico_shipment_raw_line
    (
          shipment_raw_line_id bigint IDENTITY(1,1) NOT NULL
        , shipment_file_id uniqueidentifier NOT NULL
        , source_sheet nvarchar(128) NOT NULL
        , source_row_number int NOT NULL
        , Bin_ID nvarchar(100) NULL
        , Item_ID nvarchar(100) NULL
        , PO_No nvarchar(50) NULL
        , Invoiced_Qty decimal(18,4) NULL
        , raw_pallet_comment nvarchar(max) NULL
        , created_at_utc datetime2(0) NOT NULL
            CONSTRAINT DF_coats_mexico_raw_line_created_at_utc DEFAULT SYSUTCDATETIME()
        , CONSTRAINT PK_coats_mexico_shipment_raw_line
            PRIMARY KEY CLUSTERED (shipment_raw_line_id)
    );
END;

IF OBJECT_ID('dbo.coats_mexico_shipment_file', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.coats_mexico_shipment_file
    (
          shipment_file_id uniqueidentifier NOT NULL
        , source_file_name nvarchar(260) NOT NULL
        , source_web_url nvarchar(1000) NULL
        , shipment_date date NULL
        , trailer_name nvarchar(50) NULL
        , estimated_arrival_date date NULL
        , pipeline_run_id nvarchar(100) NULL
        , loaded_at_utc datetime2(0) NOT NULL
        , raw_payload nvarchar(max) NOT NULL
        , created_at_utc datetime2(0) NOT NULL
            CONSTRAINT DF_coats_mexico_file_created_at_utc DEFAULT SYSUTCDATETIME()
        , CONSTRAINT PK_coats_mexico_shipment_file
            PRIMARY KEY CLUSTERED (shipment_file_id)
    );
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = 'FK_coats_mexico_raw_line_file'
)
BEGIN
    ALTER TABLE dbo.coats_mexico_shipment_raw_line
    ADD CONSTRAINT FK_coats_mexico_raw_line_file
        FOREIGN KEY (shipment_file_id)
        REFERENCES dbo.coats_mexico_shipment_file (shipment_file_id);
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = 'FK_coats_mexico_pallet_line_file'
)
BEGIN
    ALTER TABLE dbo.coats_mexico_shipment_pallet_line
    ADD CONSTRAINT FK_coats_mexico_pallet_line_file
        FOREIGN KEY (shipment_file_id)
        REFERENCES dbo.coats_mexico_shipment_file (shipment_file_id);
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = 'FK_coats_mexico_validation_issue_file'
)
BEGIN
    ALTER TABLE dbo.coats_mexico_shipment_validation_issue
    ADD CONSTRAINT FK_coats_mexico_validation_issue_file
        FOREIGN KEY (shipment_file_id)
        REFERENCES dbo.coats_mexico_shipment_file (shipment_file_id);
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.coats_mexico_shipment_file')
      AND name = 'IX_coats_mexico_file_source'
)
BEGIN
    CREATE INDEX IX_coats_mexico_file_source
        ON dbo.coats_mexico_shipment_file (source_file_name, shipment_date, trailer_name);
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.coats_mexico_shipment_pallet_line')
      AND name = 'IX_coats_mexico_pallet_line_validate'
)
BEGIN
    CREATE INDEX IX_coats_mexico_pallet_line_validate
        ON dbo.coats_mexico_shipment_pallet_line (shipment_file_id, PO_No, Item_ID)
        INCLUDE (Bin_ID, P21_Bin_ID, Invoiced_Qty, po_line_uid);
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

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.coats_mexico_shipment_validation_issue')
      AND name = 'IX_coats_mexico_validation_issue_file'
)
BEGIN
    CREATE INDEX IX_coats_mexico_validation_issue_file
        ON dbo.coats_mexico_shipment_validation_issue (shipment_file_id, severity, issue_code);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_stage_coats_mexico_shipment_json
    @payload nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@payload) <> 1
    BEGIN
        THROW 50000, 'Payload is not valid JSON.', 1;
    END;

    DECLARE @shipment_file_id uniqueidentifier =
        TRY_CONVERT(uniqueidentifier, JSON_VALUE(@payload, '$.metadata.shipment_file_id'));

    IF @shipment_file_id IS NULL
    BEGIN
        THROW 50001, 'Payload metadata.shipment_file_id is missing or invalid.', 1;
    END;

    BEGIN TRAN;

    IF EXISTS (
        SELECT 1
        FROM dbo.coats_mexico_shipment_file
        WHERE shipment_file_id = @shipment_file_id
    )
    BEGIN
        UPDATE dbo.coats_mexico_shipment_file
        SET
              source_file_name = JSON_VALUE(@payload, '$.metadata.source_file_name')
            , source_web_url = JSON_VALUE(@payload, '$.metadata.source_web_url')
            , shipment_date = TRY_CONVERT(date, JSON_VALUE(@payload, '$.metadata.shipment_date'))
            , trailer_name = JSON_VALUE(@payload, '$.metadata.trailer_name')
            , estimated_arrival_date = TRY_CONVERT(date, JSON_VALUE(@payload, '$.metadata.estimated_arrival_date'))
            , pipeline_run_id = JSON_VALUE(@payload, '$.metadata.pipeline_run_id')
            , loaded_at_utc = COALESCE(
                  TRY_CONVERT(datetime2(0), JSON_VALUE(@payload, '$.metadata.loaded_at_utc'), 127)
                , SYSUTCDATETIME()
              )
            , raw_payload = @payload
        WHERE shipment_file_id = @shipment_file_id;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.coats_mexico_shipment_file
        (
              shipment_file_id
            , source_file_name
            , source_web_url
            , shipment_date
            , trailer_name
            , estimated_arrival_date
            , pipeline_run_id
            , loaded_at_utc
            , raw_payload
        )
        VALUES
        (
              @shipment_file_id
            , JSON_VALUE(@payload, '$.metadata.source_file_name')
            , JSON_VALUE(@payload, '$.metadata.source_web_url')
            , TRY_CONVERT(date, JSON_VALUE(@payload, '$.metadata.shipment_date'))
            , JSON_VALUE(@payload, '$.metadata.trailer_name')
            , TRY_CONVERT(date, JSON_VALUE(@payload, '$.metadata.estimated_arrival_date'))
            , JSON_VALUE(@payload, '$.metadata.pipeline_run_id')
            , COALESCE(
                  TRY_CONVERT(datetime2(0), JSON_VALUE(@payload, '$.metadata.loaded_at_utc'), 127)
                , SYSUTCDATETIME()
              )
            , @payload
        );
    END;

    INSERT INTO dbo.coats_mexico_shipment_raw_line
    (
          shipment_file_id
        , source_sheet
        , source_row_number
        , Bin_ID
        , Item_ID
        , PO_No
        , Invoiced_Qty
        , raw_pallet_comment
    )
    SELECT
          @shipment_file_id
        , j.source_sheet
        , j.source_row_number
        , j.Bin_ID
        , j.Item_ID
        , j.PO_No
        , TRY_CONVERT(decimal(18,4), j.Invoiced_Qty)
        , j.raw_pallet_comment
    FROM OPENJSON(@payload, '$.raw_lines')
    WITH
    (
          source_sheet nvarchar(128) '$.source_sheet'
        , source_row_number int '$.source_row_number'
        , Bin_ID nvarchar(100) '$.Bin_ID'
        , Item_ID nvarchar(100) '$.Item_ID'
        , PO_No nvarchar(50) '$.PO_No'
        , Invoiced_Qty nvarchar(50) '$.Invoiced_Qty'
        , raw_pallet_comment nvarchar(max) '$.raw_pallet_comment'
    ) AS j
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.coats_mexico_shipment_raw_line existing
        WHERE existing.shipment_file_id = @shipment_file_id
          AND existing.source_row_number = j.source_row_number
          AND ISNULL(existing.Bin_ID, '') = ISNULL(j.Bin_ID, '')
          AND ISNULL(existing.Item_ID, '') = ISNULL(j.Item_ID, '')
          AND ISNULL(existing.PO_No, '') = ISNULL(j.PO_No, '')
          AND ISNULL(existing.Invoiced_Qty, -1) = ISNULL(TRY_CONVERT(decimal(18,4), j.Invoiced_Qty), -1)
    );

    INSERT INTO dbo.coats_mexico_shipment_pallet_line
    (
          shipment_file_id
        , source_sheet
        , source_row_number
        , Bin_ID
        , Item_ID
        , PO_No
        , Invoiced_Qty
        , Parsed_Qty_Unit
        , raw_pallet_value
        , raw_pallet_comment
        , comment_line
        , quantity_reconciled
    )
    SELECT
          @shipment_file_id
        , j.source_sheet
        , j.source_row_number
        , j.Bin_ID
        , j.Item_ID
        , j.PO_No
        , TRY_CONVERT(decimal(18,4), j.Invoiced_Qty)
        , j.Parsed_Qty_Unit
        , j.raw_pallet_value
        , j.raw_pallet_comment
        , j.comment_line
        , COALESCE(j.quantity_reconciled, 0)
    FROM OPENJSON(@payload, '$.pallet_lines')
    WITH
    (
          source_sheet nvarchar(128) '$.source_sheet'
        , source_row_number int '$.source_row_number'
        , Bin_ID nvarchar(100) '$.Bin_ID'
        , Item_ID nvarchar(100) '$.Item_ID'
        , PO_No nvarchar(50) '$.PO_No'
        , Invoiced_Qty nvarchar(50) '$.Invoiced_Qty'
        , Parsed_Qty_Unit nvarchar(30) '$.Parsed_Qty_Unit'
        , raw_pallet_value nvarchar(100) '$.raw_pallet_value'
        , raw_pallet_comment nvarchar(max) '$.raw_pallet_comment'
        , comment_line nvarchar(1000) '$.comment_line'
        , quantity_reconciled bit '$.quantity_reconciled'
    ) AS j
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.coats_mexico_shipment_pallet_line existing
        WHERE existing.shipment_file_id = @shipment_file_id
          AND existing.source_row_number = j.source_row_number
          AND ISNULL(existing.Bin_ID, '') = ISNULL(j.Bin_ID, '')
          AND ISNULL(existing.Item_ID, '') = ISNULL(j.Item_ID, '')
          AND ISNULL(existing.PO_No, '') = ISNULL(j.PO_No, '')
          AND ISNULL(existing.Invoiced_Qty, -1) = ISNULL(TRY_CONVERT(decimal(18,4), j.Invoiced_Qty), -1)
          AND ISNULL(existing.Parsed_Qty_Unit, '') = ISNULL(j.Parsed_Qty_Unit, '')
          AND ISNULL(existing.raw_pallet_value, '') = ISNULL(j.raw_pallet_value, '')
          AND ISNULL(existing.comment_line, '') = ISNULL(j.comment_line, '')
    );

    INSERT INTO dbo.coats_mexico_shipment_validation_issue
    (
          shipment_file_id
        , severity
        , issue_code
        , message
        , source_sheet
        , source_row_number
        , Bin_ID
        , Item_ID
        , PO_No
        , raw_pallet_comment
    )
    SELECT
          @shipment_file_id
        , COALESCE(j.severity, 'BLOCKING')
        , j.issue_code
        , j.message
        , j.source_sheet
        , j.source_row_number
        , j.Bin_ID
        , j.Item_ID
        , j.PO_No
        , j.raw_pallet_comment
    FROM OPENJSON(@payload, '$.validation_issues')
    WITH
    (
          severity nvarchar(20) '$.severity'
        , issue_code nvarchar(100) '$.issue_code'
        , message nvarchar(1000) '$.message'
        , source_sheet nvarchar(128) '$.source_sheet'
        , source_row_number int '$.source_row_number'
        , Bin_ID nvarchar(100) '$.Bin_ID'
        , Item_ID nvarchar(100) '$.Item_ID'
        , PO_No nvarchar(50) '$.PO_No'
        , raw_pallet_comment nvarchar(max) '$.raw_pallet_comment'
    ) AS j
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.coats_mexico_shipment_validation_issue existing
        WHERE existing.shipment_file_id = @shipment_file_id
          AND existing.severity = COALESCE(j.severity, 'BLOCKING')
          AND existing.issue_code = j.issue_code
          AND ISNULL(existing.source_sheet, '') = ISNULL(j.source_sheet, '')
          AND ISNULL(existing.source_row_number, -1) = ISNULL(j.source_row_number, -1)
          AND ISNULL(existing.Bin_ID, '') = ISNULL(j.Bin_ID, '')
          AND ISNULL(existing.Item_ID, '') = ISNULL(j.Item_ID, '')
          AND ISNULL(existing.PO_No, '') = ISNULL(j.PO_No, '')
          AND ISNULL(existing.raw_pallet_comment, '') = ISNULL(j.raw_pallet_comment, '')
    );

    COMMIT;

    SELECT
          f.shipment_file_id
        , f.source_file_name
        , f.shipment_date
        , f.trailer_name
        , f.estimated_arrival_date
        , raw_line_count = (SELECT COUNT(*) FROM dbo.coats_mexico_shipment_raw_line r WHERE r.shipment_file_id = f.shipment_file_id)
        , pallet_line_count = (SELECT COUNT(*) FROM dbo.coats_mexico_shipment_pallet_line p WHERE p.shipment_file_id = f.shipment_file_id)
        , blocking_issue_count = (
              SELECT COUNT(*)
              FROM dbo.coats_mexico_shipment_validation_issue i
              WHERE i.shipment_file_id = f.shipment_file_id
                AND i.severity = 'BLOCKING'
          )
    FROM dbo.coats_mexico_shipment_file f
    WHERE f.shipment_file_id = @shipment_file_id;
END;
GO
