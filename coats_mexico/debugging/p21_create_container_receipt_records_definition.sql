

CREATE PROCEDURE p21_create_container_receipt_records
AS
  SET NOCOUNT ON

  BEGIN
	  -- If we're in the middle of processing PO's through Container Receipts, and after saving 
	  -- off a couple PO Receipts the app crashes before we had a chance to create Container
	  -- Receipt records, we're obviously going to have no history of those records.  This procedure
	  -- will attempt to find and create those missing records under the assumption that something 
	  -- is indeed more useful than nothing.
	  BEGIN TRANSACTION

      IF Object_id('tempdb..#container_receipt_records') IS NOT NULL
        DROP TABLE #container_receipt_records

      DECLARE @error INTEGER
      DECLARE @li_CRLCounter INTEGER
      DECLARE @li_CRHdrUID INTEGER
      DECLARE @li_VRLUID INTEGER
      DECLARE @ldc_QtyReceived DECIMAL(19, 9)
      DECLARE @ldc_UnitSize DECIMAL(19, 6)
      DECLARE @ls_UOM VARCHAR(8)
      DECLARE @msg VARCHAR(255)
      DECLARE @procname VARCHAR(255)

	  DECLARE @ld_current_timestamp datetime
	  SET @ld_current_timestamp = dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP,NULL,NULL)

      -- Create a temp table to store the items we need to add or update. 
      CREATE TABLE #container_receipt_records
        (
           container_receipts_hdr_uid     INTEGER NOT NULL,
           vessel_receipts_container_name VARCHAR(255) NOT NULL,
           inv_mast_uid                   INTEGER NOT NULL,
           po_no                          DECIMAL(19, 0) NOT NULL,
           po_line_no                     INTEGER NOT NULL,
           qty_received                   DECIMAL(19, 9) NOT NULL,
           unit_of_measure                VARCHAR(255) NOT NULL,
           unit_size                      DECIMAL(19, 9) NOT NULL,
           vessel_receipt_records         INTEGER NOT NULL,
           vessel_receipts_line_uid       INTEGER NULL,
           vessel_receipts_container_uid  INTEGER NULL
        )

      INSERT INTO #container_receipt_records
                  (container_receipts_hdr_uid,
                   vessel_receipts_container_name,
                   inv_mast_uid,
                   po_no,
                   po_line_no,
                   qty_received,
                   unit_of_measure,
                   unit_size,
                   vessel_receipt_records)
      -- Grab any Container Receipts that are tied to a PO Receipt, but do not actually exist in the database.
      SELECT inventory_receipts_hdr.container_receipts_hdr_uid,
             inventory_receipts_hdr.external_reference_no,
             inventory_receipts_line.inv_mast_uid,
             inventory_receipts_hdr.po_number,
             inventory_receipts_line.po_line_number,
             inventory_receipts_line.qty_received, -- qty_received for CRL is in SKU's
             inventory_receipts_line.unit_of_measure,
			 inventory_receipts_line.unit_size,
			 drv_vrl_records.vessel_receipt_records
      FROM   inventory_receipts_line
             INNER JOIN inventory_receipts_hdr
               ON inventory_receipts_line.receipt_number = inventory_receipts_hdr.receipt_number
             LEFT JOIN container_receipts_hdr
               ON inventory_receipts_hdr.container_receipts_hdr_uid = container_receipts_hdr.container_receipts_hdr_uid
             LEFT JOIN (SELECT Count(*) vessel_receipt_records,
                               po_line.inv_mast_uid,
                               po_line.line_no,
     
---CHUNK---
                          po_line.po_no,
                               vessel_receipts_container.container_name
                        FROM   vessel_receipts_line
                               INNER JOIN po_line
                                 ON po_line.po_line_uid = vessel_receipts_line.po_line_uid
                               INNER JOIN po_hdr
                                 ON po_line.po_no = po_hdr.po_no
                               INNER JOIN vessel_receipts_container
                                 ON vessel_receipts_container.vessel_receipts_container_uid = vessel_receipts_line.vessel_receipts_container_uid
                        GROUP  BY po_line.inv_mast_uid,
                                  po_line.line_no,
                                  po_line.po_no,
                                  vessel_receipts_container.container_name) AS drv_vrl_records
               ON ( inventory_receipts_line.inv_mast_uid = drv_vrl_records.inv_mast_uid )
                  AND ( inventory_receipts_line.po_line_number = drv_vrl_records.line_no )
                  AND ( inventory_receipts_hdr.po_number = drv_vrl_records.po_no )
                  AND ( inventory_receipts_hdr.external_reference_no = drv_vrl_records.container_name )
      WHERE  inventory_receipts_hdr.container_receipts_hdr_uid IS NOT NULL
             AND container_receipts_hdr.container_receipts_hdr_uid IS NULL
             AND inventory_receipts_hdr.approved = 'Y'

      -- We need to tie these PO Receipt records back to a correct vessel receipt line record.  It's possible that 
      -- a PO/PO Line could be associated with multiple vessel receipts.  If that's the case, then hopefully
      -- the container name will help us determine which is the correct vessel.  However, if they have the same
      -- container name (we don't force them to be unique in the app) then we have no way to know which was the
      -- right vessel receipt line record.  The column vessel_receipt_records should tell us if we cannot
      -- correctly link to a VRL record.  If we can't, just remove them.
      DELETE FROM #container_receipt_records
      WHERE  #container_receipt_records.vessel_receipt_records > 1

      -- Now correctly update the records to their proper vessel_receipts_line/vessel_receipts_container records.
      UPDATE #container_receipt_records
      SET    vessel_receipts_line_uid = drv_vrl_records.vessel_receipts_line_uid,
             vessel_receipts_container_uid = drv_vrl_records.vessel_receipts_container_uid
      FROM   #container_receipt_records
             LEFT JOIN (SELECT vessel_receipts_line.vessel_receipts_line_uid,
                               vessel_receipts_line.vessel_receipts_container_uid,
                               po_line.inv_mast_uid,
                               po_line.line_no,
                               po_line.po_no,
                               vessel_receipts_container.container_name
                        FROM   vessel_receipts_line
                               INNER JOIN po_line
                                 ON po_line.po_line_uid = vessel_receipts_line.po_line_uid
                               INNER JOIN po_hdr
                                 ON po_line.po_no = po_hdr.po_no
                               INNER JOIN vessel_receipts_container
                                 ON vessel_receipts_container.vessel_receipts_container_uid = vessel_receipts_line.vessel_receipts_c
---CHUNK---
ontainer_uid
                        GROUP  BY vessel_receipts_line.vessel_receipts_line_uid,
                                  vessel_receipts_line.vessel_receipts_container_uid,
                                  po_line.inv_mast_uid,
                                  po_line.line_no,
                                  po_line.po_no,
                                  vessel_receipts_container.container_name) AS drv_vrl_records
               ON ( #container_receipt_records.inv_mast_uid = drv_vrl_records.inv_mast_uid )
                  AND ( #container_receipt_records.po_line_no = drv_vrl_records.line_no )
                  AND ( #container_receipt_records.po_no = drv_vrl_records.po_no )
                  AND ( #container_receipt_records.vessel_receipts_container_name = drv_vrl_records.container_name )

      -- Go ahead with inserting the values into the container_receipts_hdr/container_receipts_line.
      INSERT INTO container_receipts_hdr
                  (container_receipts_hdr_uid,
                   vessel_receipts_container_uid,
                   date_received,
                   period,
                   year_for_period,
                   row_status_flag,
                   date_created,
                   created_by,
                   date_last_modified,
                   last_maintained_by)
      SELECT DISTINCT #container_receipt_records.container_receipts_hdr_uid,
                      #container_receipt_records.vessel_receipts_container_uid,
                      Dateadd(D, 0, Datediff(D, 0, inventory_receipts_hdr.date_created)),
                      inventory_receipts_hdr.period,
                      inventory_receipts_hdr.year_for_period,
                      972, -- Approved row status
                      @ld_current_timestamp,
                      'p21_create_container_receipt_records',
                      @ld_current_timestamp,
                      'p21_create_container_receipt_records'
      FROM   #container_receipt_records
             INNER JOIN inventory_receipts_hdr
               ON inventory_receipts_hdr.container_receipts_hdr_uid = #container_receipt_records.container_receipts_hdr_uid

      DECLARE lc_CreateContainerReceiptLine CURSOR STATIC FORWARD_ONLY FOR
        SELECT #container_receipt_records.container_receipts_hdr_uid,
               #container_receipt_records.vessel_receipts_line_uid,
               #container_receipt_records.qty_received,
               #container_receipt_records.unit_of_measure,
               #container_receipt_records.unit_size
        FROM   #container_receipt_records
        ORDER  BY #container_receipt_records.container_receipts_hdr_uid

      OPEN lc_CreateContainerReceiptLine

      IF ( @@ERROR = 0 )
        BEGIN
            FETCH NEXT FROM lc_CreateContainerReceiptLine INTO @li_CRHdrUID, @li_VRLUID, @ldc_QtyReceived, @ls_UOM, @ldc_UnitSize

            WHILE @@FETCH_STATUS = 0
              BEGIN
                  EXECUTE @li_CRLCounter = P21_get_counter 'container_receipts_line', 1

                  INSERT INTO container_receipts_line
                              (container_receipts_line_uid,
                               container_receipts_hdr_uid,
                               vessel_receipts_line_uid,
                               qty_received,
                               unit_of_measure,
                               unit_size,
                               date_created,
      
---CHUNK---
                         created_by,
                               date_last_modified,
                               last_maintained_by,
                               complete_po_line_flag)
                  SELECT @li_CRLCounter,
                         @li_CRHdrUID,
                         @li_VRLUID,
                         @ldc_QtyReceived,
                         @ls_UOM,
                         @ldc_UnitSize,
                         @ld_current_timestamp,
                         'p21_create_container_receipt_records',
                         @ld_current_timestamp,
                         'p21_create_container_receipt_records',
                         'N'

                  FETCH NEXT FROM lc_CreateContainerReceiptLine INTO @li_CRHdrUID, @li_VRLUID, @ldc_QtyReceived, @ls_UOM, @ldc_UnitSize
              END
        END
      ELSE
        RAISERROR( 'Error: could not open cursor',
                   16,
                   1)

      CLOSE lc_CreateContainerReceiptLine

      DEALLOCATE lc_CreateContainerReceiptLine

      SELECT @error = @@ERROR

      IF ( @error <> 0 )
        BEGIN
            SELECT @procname = Object_name(@@PROCID)

            SELECT @msg = @procname + ' : '

            SELECT @msg = @msg + 'Error ' + Ltrim(Str(@error)) + ' when performing insert into container_receipts_line'

            GOTO error_return
        END

      -- Update the vessel line container_qty_unloaded
      UPDATE vessel_receipts_line
      SET    container_qty_unloaded = vessel_receipts_line.container_qty_unloaded + #container_receipt_records.qty_received
      FROM   vessel_receipts_line
             INNER JOIN #container_receipt_records
               ON #container_receipt_records.vessel_receipts_line_uid = vessel_receipts_line.vessel_receipts_line_uid

      COMMIT TRANSACTION

      RETURN 1

      ERROR_RETURN:
		  --RAISERROR 50050 @msg
    		  RAISERROR (@msg,16,1)
		  ROLLBACK TRANSACTION
		  RETURN -1
  END 

--$Author: Claudia.gonzalez $
--$Date: 3/27/19 2:24p $
--$Revision: 6 $
--$Log: /Server/CommerceCenter/Z_Leemar (18.2)/Stored Procedures/p21_create_container_receipt_records.sql $
-- 
-- 6     3/27/19 2:24p Claudia.gonzalez
-- DEV: CEG
-- DBA: CEG 
-- JIRA: P21CD-14008: Modify Stored Procedures for Timezone feature to use
-- @current_timestamp variable
-- b018_002_051346(familyA).sql
-- 
-- 5     8/27/18 4:55p Syed.yunus
-- Feature 69545: P21CD-11361 Modifying CURRENT_TIMESTAMP/GETDATE() to
-- support timezone settings
-- DBA: SYUNUS
-- DEV: SYUNUS
-- Script: b018_002_050038 Family
-- 
-- 3     8/21/12 4:58p Bridgitte.hoganperry
-- Update objects to 2012 syntax of RAISERROR
-- dev:bhp
-- b012_010_035290 family
-- 
-- 1     11/30/11 11:09a Steve.rosendale
-- DEV: RSM
-- DBA: SAR
-- Feature: 49584
-- Script: b012_008_033434a.sql


