--IF OBJECT_ID('P21Import.dbo.coats_mexico_truck_2026_04_17', 'U') IS NOT NULL
--    DROP TABLE P21Import.dbo.coats_mexico_truck_2026_04_17;

--CREATE TABLE P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24 (
--      Bin_IDs                      NVARCHAR(100)
--    , PO_Number                    NVARCHAR(20)
--    , Item_ID                      NVARCHAR(50)
--    , Invoiced_Qty                 DECIMAL(18,4)
--    , cancel_flag                  CHAR(1)
--    , po_line_uid                  INT
--    , has_duplicate_supplier_part  INT
--    , missing_supplier_part_flag   INT
--    , container_uom                NVARCHAR(50)
--    , vessel_receipts_line_uid     INT
--)

/*
always un-cancel the po line that is in the Coats spreadsheet? -- YES
*/

/*

Step 1: check Coats report for pallets like:
P-14, P15
If there is no extra information breaking down quantity per pallet, ask Mary for breakdowns.

*/

/*
Step 2: extract necessary columns from Coats Mexico spreadsheet
		import as flat file in P21Import
1. Bin_ID
2. PO_No
3. Item_ID
4. Invoiced_Qty

*/

select * from P21Import.dbo.coats_mexico_truck_2026_04_17;

DECLARE @SupplierID INT = 40408;

WITH cte_last_color_bin AS (
    SELECT
          dlb.bin_cd
        , dlb.date_created
        , CASE 
              WHEN p.prefix = 'BL' THEN 'Y'
              WHEN p.prefix = 'Y'  THEN 'BL'
              ELSE 'unknown'
          END AS next_bin_start
    FROM (    
        SELECT
              dlb.bin_cd
            , dlb.date_created
            , ROW_NUMBER() OVER (ORDER BY dlb.date_created DESC) AS rn
        FROM document_line_bin AS dlb
        WHERE dlb.document_type = 'CR' -- Container Receipts
    )     AS dlb
    CROSS APPLY (
        SELECT
              prefix =
                  CASE 
                      WHEN PATINDEX('%[0-9]%', dlb.bin_cd) > 0 
                          THEN LEFT(dlb.bin_cd, PATINDEX('%[0-9]%', dlb.bin_cd) - 1)
                      ELSE dlb.bin_cd
                  END
    ) AS p
    WHERE dlb.rn = 1
)
, cte_item_po AS (
    SELECT
          pol.po_line_uid
        , pol.po_no AS PO_Number
        , pol.cancel_flag
        , ivs.supplier_part_no
        , ivm.delete_flag AS inv_delete_flag
        , CASE
              WHEN ivm.default_purchasing_unit = pol.unit_of_measure
                   THEN pol.unit_of_measure
              ELSE ivm.default_purchasing_unit
          END AS container_uom
    FROM po_line AS pol
    LEFT JOIN inv_mast AS ivm
        ON ivm.inv_mast_uid = pol.inv_mast_uid
    LEFT JOIN inventory_supplier AS ivs
        ON ivs.inv_mast_uid = ivm.inv_mast_uid
       AND ivs.supplier_id = @SupplierID
    WHERE ivm.delete_flag <> 'Y'
      and pol.complete <> 'Y'     -- checks for duplicate items on the same PO
)
, cte_supplier_dup AS (
    SELECT
          ivs.supplier_part_no
        , CASE
              WHEN COUNT(*) > 1 THEN 1 ELSE 0
          END AS has_duplicate_supplier_part
    FROM inventory_supplier AS ivs
    JOIN inv_mast AS ivm
        ON ivm.inv_mast_uid = ivs.inv_mast_uid
    WHERE ivs.supplier_id = @SupplierID
      AND ISNULL(ivm.delete_flag, 'N') <> 'Y'
    GROUP BY
          ivs.supplier_part_no
)
, cte_supplier_missing AS (
    SELECT
          raw.Item_ID
        , ivm.item_id AS komar_item_id
        , CASE
              WHEN COUNT(ivs.inv_mast_uid) = 0 THEN 1 ELSE 0
          END AS missing_supplier_part_flag
    FROM (
        SELECT DISTINCT
              Item_ID
        FROM P21Import.dbo.coats_mexico_truck_2026_04_17
    ) AS raw
    LEFT JOIN inventory_supplier AS ivs
      ON ivs.supplier_id = @SupplierID
     AND ivs.supplier_part_no = raw.Item_ID
    LEFT JOIN inv_mast AS ivm
      ON ivm.inv_mast_uid = ivs.inv_mast_uid
    WHERE ivm.delete_flag <> 'Y'
    GROUP BY
          raw.Item_ID
        , ivm.item_id
)
, cte_cm_dedup AS (
    SELECT
          Bin_ID
        , PO_No AS PO_Number
        , Item_ID
        , SUM(Invoiced_Qty) AS Invoiced_Qty
    FROM P21Import.dbo.coats_mexico_truck_2026_04_17
    GROUP BY
          Bin_ID
        , PO_No
        , Item_ID
)
, cte_joined AS (
    SELECT
          CASE 
              WHEN CHARINDEX('-', cm.Bin_ID) > 0 THEN 
                    (SELECT next_bin_start FROM cte_last_color_bin)
                    + SUBSTRING(
                          cm.Bin_ID
                        , CHARINDEX('-', cm.Bin_ID)
                        , LEN(cm.Bin_ID)
                      )
              ELSE cm.Bin_ID
          END AS Bin_ID
        , cm.PO_Number
        , cm.Item_ID
        , mis.komar_item_id
        , cm.Invoiced_Qty
        , cip.po_line_uid
        , cip.cancel_flag
        , ISNULL(dup.has_duplicate_supplier_part, 0) AS has_duplicate_supplier_part
        , ISNULL(mis.missing_supplier_part_flag, 0)   AS missing_supplier_part_flag
        , cip.container_uom
    FROM cte_cm_dedup AS cm
    LEFT JOIN cte_item_po AS cip
      ON  cip.PO_Number       = cm.PO_Number
      AND cip.supplier_part_no = cm.Item_ID
    LEFT JOIN cte_supplier_dup AS dup
      ON dup.supplier_part_no = cm.Item_ID
    LEFT JOIN cte_supplier_missing AS mis
      ON mis.Item_ID          = cm.Item_ID
)
 INSERT INTO P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24
(
      Bin_IDs
    , PO_Number
    , Item_ID
    , Invoiced_Qty
    , cancel_flag
    , po_line_uid
    , has_duplicate_supplier_part
    , missing_supplier_part_flag
    , container_uom
)
SELECT
      STRING_AGG(cj.Bin_ID, ', ')              AS Bin_IDs
    , cj.PO_Number
    , COALESCE(cj.komar_item_id, cj.Item_ID)   AS Item_ID
    , SUM(cj.Invoiced_Qty)                     AS Invoiced_Qty
    , cj.cancel_flag
    , cj.po_line_uid
    , MAX(cj.has_duplicate_supplier_part)      AS has_duplicate_supplier_part
    , MAX(cj.missing_supplier_part_flag)       AS missing_supplier_part_flag
    , MAX(cj.container_uom)                    AS container_uom
FROM cte_joined AS cj
GROUP BY
      cj.PO_Number
    , cj.Item_ID
    , cj.komar_item_id
    , cj.cancel_flag
    , cj.po_line_uid;

--TRUNCATE TABLE P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24;
select * from P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24;

-- The following query checks if the item is not on the PO
SELECT *
FROM P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24
WHERE (
        po_line_uid IS NULL
     OR has_duplicate_supplier_part = 1
     OR missing_supplier_part_flag = 1
     OR cancel_flag = 'Y'
     OR Bin_IDs IS NULL
     OR (Bin_IDs NOT LIKE 'BL%' AND Bin_IDs NOT LIKE 'Y%')
);

/* todo: build automation for container_building
MANUAL STEPS:
1. Open Container Building
2. Input Location ID = 210
3. Click Retrieve
4. Under the new Container ID, enter the Trailer Number as the name
5. Click Save. Note the Container ID that is generated. That is the container_building_uid
6. On "Do you want to save changes made in the Unassigned PO container", click No.
*/

-- ***** TM672 is the Trailer Number ***** UPDATE THIS EACH TIME FROM MARY'S EMAIL
-- 12/10/2025: discovered issue where 54974 has been used as container_name before (container_building_uid 617)
-- Kevin's solution: use 6 digit date for container_name. for this case: '54974 120525'

select
    *
from container_building 
where container_building_uid = 898
--where container_name = 'TM672' -- this can check if there has Trailer Number has been used previously
;

select cb.* from dbo.container_building_po cb 
where container_building_uid = 898
order by container_building_po_uid desc;

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
      898 -- UPDATE THIS AND LINE 281 EACH TIME WITH THE NEW CONTAINER_BUILDING_UID
    , cmt.po_line_uid
    , 702
    , 10000
    , cmt.Invoiced_Qty
    , ISNULL(cmt.container_uom
        , CASE
            WHEN ivm.default_purchasing_unit = pol.unit_of_measure
                 THEN pol.unit_of_measure
            ELSE ivm.default_purchasing_unit
          END)
    , 1.000000000
    , NULL
    , 3103
    , GETDATE()
    , 'DSHAO'
    , GETDATE()
    , 'DSHAO'
FROM P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24 cmt
LEFT JOIN po_line  pol ON pol.po_line_uid  = cmt.po_line_uid
LEFT JOIN inv_mast ivm ON ivm.inv_mast_uid = pol.inv_mast_uid
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.container_building_po x
    WHERE x.container_building_uid   = 898
      AND x.po_line_uid              = cmt.po_line_uid
      AND ISNULL(x.po_line_schedule_uid, -1) = ISNULL(NULL, -1)
      AND x.sequence_no              = 10000
);

/* todo: build automated insertion into vessel_receipts_hdr and vessel_receipts_line 
    NEED:
        Vessel Name 'TM672' -- this should be the name of the trailer
        Departure Date 04/17/2026
        Estimated Arrival Date 04/24/2026
        Est Date Avail for Ship 04/24/2026
    1. Build Vessel Receipts details from above.
    2. Click Containers tab. Enter container name. Date Expected should populate from Estimated Arrival Date
        Under "Prebuild Container ID" select the container built in previous step.
        This will take some time to load as it is populating the vessel.
    3. Once data loads, click save. Make note of the Vessel Receipts ID. You can use the queries below to check the data.
    4. Run the update set script below.
*/

select * from P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24;
select * from vessel_receipts_hdr where vessel_receipts_hdr_uid = 759;
select * from vessel_receipts_line where vessel_receipts_hdr_uid = 759
;

with u as (
	select vessel_receipts_line_uid, po_line_uid from vessel_receipts_line 
    where vessel_receipts_hdr_uid = 759 -- UPDATE THIS EACH TIME WITH THE NEW vessel_receipts_hdr_uid
)
update cmt -- *** uncomment this out before running ***
set cmt.vessel_receipts_line_uid = u.vessel_receipts_line_uid
from P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24 cmt
join u on u.po_line_uid = cmt.po_line_uid
WHERE cmt.vessel_receipts_line_uid IS NULL
;

select * from P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24;

/* todo: build automated insertion into container_receipts_hdr and container_receipts_line 
1. create row in container_receipts_hdr. set row_status_flag = 971 (Unapproved)
2. create lines in container_receipts_line. join to vessel_receipts_line for the data
3. create rows in document_line_bin. set document_type = 'CR'. extract bin_cd from Bin_IDs

*/

-- *** BEFORE SAVING CONTAINER RECEIPT, SET STATUS TO UNAPPROVED ***
-- CONTAINER NAME: TM672 (UPDATE EACH TIME)

SELECT top 3 * FROM container_receipts_hdr order by date_created desc;
select top 5 * from container_receipts_line
--where container_receipts_hdr_uid = 677
--where container_receipts_line_uid = 101213
order by container_receipts_line_uid desc
;
-- OPEN SQL SCRIPT Coats transfer truck container receipts line insert step.sql
-- UPDATE COATS DEDUP FINAL DRUCK TABLE NAME / CONTAINER RECEIPTS HDR UID
-- RUN SCRIPT

/* Generate ordered list for Vernina Tamayo
1. gather correct order of items from Container Receipts window by manually copy paste.
2. clean item id from step 1 by replacing the space character. =SUBSTITUTE(D2,CHAR(160)," ")
3. create join key based on concat of PO Number and clean Item ID from step 2. =A2&" "&E2
4. create order column. 1 in cell G2, 2 in cell G3, etc
5. join to 

        WITH cte_last_color_bin AS (
            SELECT
              dlb.bin_cd
            , dlb.date_created
            , CASE 
                  WHEN p.prefix = 'BL' THEN 'Y'
                  WHEN p.prefix = 'Y'  THEN 'BL'
                  ELSE 'unknown'
              END AS next_bin_start
        FROM (    
            SELECT
                  dlb.bin_cd
                , dlb.date_created
                , ROW_NUMBER() OVER (ORDER BY dlb.date_created DESC) AS rn
            FROM document_line_bin AS dlb
            WHERE dlb.document_type = 'CR' -- Container Receipts
        )     AS dlb
        CROSS APPLY (
            SELECT
                  prefix =
                      CASE 
                          WHEN PATINDEX('%[0-9]%', dlb.bin_cd) > 0 
                              THEN LEFT(dlb.bin_cd, PATINDEX('%[0-9]%', dlb.bin_cd) - 1)
                          ELSE dlb.bin_cd
                      END
        ) AS p
        WHERE dlb.rn = 1
    )
    select 
        CASE 
              WHEN CHARINDEX('-', cmt.Bin_ID) > 0 THEN 
                    (SELECT next_bin_start FROM cte_last_color_bin)
                    + SUBSTRING(
                          cmt.Bin_ID
                        , CHARINDEX('-', cmt.Bin_ID)
                        , LEN(cmt.Bin_ID)
                      )
              ELSE cmt.Bin_ID
          END AS Bin_ID
      , cmt.PO_No
      , ivm.item_id
      , round(cmt.Invoiced_Qty,4) as Invoiced_Qty
      , concat(PO_No, ' ', ivm.item_id) as join_key
    from P21Import.dbo.coats_mexico_truck_2026_04_17 cmt
    LEFT JOIN inventory_supplier AS ivs
        ON cmt.Item_ID = ivs.supplier_part_no
       AND ivs.supplier_id = '40408'
    LEFT JOIN inv_mast ivm
        ON ivm.inv_mast_uid = ivs.inv_mast_uid
    ;
6. use vlookup to pull the correct order (=VLOOKUP(E2,Sheet1!F:G,2,FALSE))
7. add grid lines
8. print and give to Kevin

*/
select
      concat(PO_Number, '.', Item_ID) as join_key
    , cmt.*, crl.container_receipts_line_uid
from container_receipts_line crl 
left join P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24 cmt
    on cmt.vessel_receipts_line_uid = crl.vessel_receipts_line_uid
where cmt.Bin_IDs is not null
order by crl.container_receipts_line_uid
;

select * from P21Import.dbo.coats_mexico_truck_dedup_final_2026_04_24 cmt;
select * from container_receipts_line where vessel_receipts_line_uid = 93740;

select vrl.line_no, crl.* from container_receipts_line crl 
left join vessel_receipts_line vrl on vrl.vessel_receipts_line_uid = crl.vessel_receipts_line_uid
where crl.container_receipts_hdr_uid = 664
order by 1;

select top 1 bin_cd, date_created
from document_line_bin
where document_type = 'CR' -- Container Receipts
order by date_created desc;

select * from P21Import.dbo.coats_mexico_truck_dedup_final_2025_11_14 where Bin_IDs like '%,%';
select * from P21Import.dbo.coats_mexico_truck_2025_11_10;

/* the query below inserts into document_line_bin */
DECLARE @ContainerReceiptsHdrUid INT = 661;  -- your header UID

;WITH base AS (
    SELECT
          crl.container_receipts_hdr_uid
        , vrl.line_no
        , crl.vessel_receipts_line_uid
        , crl.qty_received
        , crl.unit_of_measure
        , crl.unit_size
        , cmt.Bin_IDs
    FROM dbo.container_receipts_line crl
    JOIN dbo.vessel_receipts_line vrl
      ON vrl.vessel_receipts_line_uid = crl.vessel_receipts_line_uid
    JOIN P21Import.dbo.coats_mexico_truck_dedup_final cmt
      ON cmt.vessel_receipts_line_uid = crl.vessel_receipts_line_uid
    WHERE crl.container_receipts_hdr_uid = @ContainerReceiptsHdrUid
),
bins AS (
    SELECT
          b.container_receipts_hdr_uid
        , b.line_no
        , b.vessel_receipts_line_uid
        , b.qty_received
        , b.unit_of_measure
        , b.unit_size
        , LTRIM(RTRIM(x.value)) AS bin_cd
    FROM base b
    CROSS APPLY STRING_SPLIT(b.Bin_IDs, ',') AS x
),
bins_with_qty AS (
    SELECT
          bins.container_receipts_hdr_uid
        , bins.line_no
        , bins.vessel_receipts_line_uid
        , bins.unit_of_measure
        , bins.unit_size
        , bins.PO_Number
        , bins.Item_ID
        , bins.bin_cd
        , src.Invoiced_Qty AS qty_for_bin
    FROM bins
    LEFT JOIN P21Import.dbo.coats_mexico_truck_2025_11_03 src
      ON src.PO_Number = bins.PO_Number
     AND src.Item_ID   = bins.Item_ID
     AND src.Bin_ID    = bins.bin_cd
),
src AS (
    SELECT
          bins_with_qty.container_receipts_hdr_uid
        , bins_with_qty.line_no
        , bins_with_qty.vessel_receipts_line_uid
        , bins_with_qty.unit_of_measure
        , bins_with_qty.unit_size
        , bins_with_qty.bin_cd
        , bins_with_qty.qty_for_bin
        , ROW_NUMBER() OVER (ORDER BY bins_with_qty.vessel_receipts_line_uid, bins_with_qty.bin_cd) AS rn
    FROM bins_with_qty
    WHERE bins_with_qty.bin_cd IS NOT NULL
      AND bins_with_qty.bin_cd <> ''
      AND NOT EXISTS (
            SELECT 1
            FROM dbo.document_line_bin d
            WHERE d.document_no   = bins_with_qty.container_receipts_hdr_uid
              AND d.line_no       = bins_with_qty.line_no
              AND d.document_type = 'CR'
              AND d.bin_cd        = bins_with_qty.bin_cd
      )
)
--INSERT INTO dbo.document_line_bin (
--      document_no
--    , line_no
--    , document_type
--    , bin_cd
--    , qty_applied
--    , unit_quantity
--    , unit_of_measure
--    , document_cd
--    , date_created
--    , date_last_modified
--    , last_maintained_by
--    , unit_size
--    , qty_to_change
--    , sub_line_no
--    , rf_qty_picked
--    , qty_from_tags
--    , source_dlb_uid
--    , created_by
--    , printed_flag
--    , work_order_uid
--    , pick_status
--    , assigned_workstation_id
--)
SELECT
      src.container_receipts_hdr_uid
    , src.line_no
    , 'CR'
    , src.bin_cd
    , 0.000000000
    , src.qty_for_bin                        
    , src.unit_of_measure
    , src.container_receipts_hdr_uid
    , GETDATE()
    , GETDATE()
    , 'DSHAO'
    , src.unit_size
    , src.qty_for_bin
    , 0
    , 0.000000000
    , -1.000000000
    , NULL
    , 'DSHAO'
    , NULL
    , NULL
    , NULL
    , NULL
FROM src;

select * from P21Import.dbo.coats_mexico_truck_dedup_final where Bin_IDs like '%,%';

select sum(unit_quantity)
from document_line_bin
where document_type = 'CR' -- Container Receipts
  and document_no = 661
;

select sum(Invoiced_Qty) from P21Import.dbo.coats_mexico_truck_2025_11_03
;