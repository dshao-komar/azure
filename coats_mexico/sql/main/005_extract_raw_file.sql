DECLARE @ShipmentFileId uniqueidentifier = '00000000-0000-0000-0000-000000000000';

IF @ShipmentFileId = '00000000-0000-0000-0000-000000000000'
BEGIN
    THROW 53000, 'Set @ShipmentFileId before running the raw file extract.', 1;
END;

WITH cte_last_color_bin AS (
    SELECT TOP (1)
          dlb.bin_cd
        , dlb.date_created
        , CASE 
              WHEN p.prefix = 'BL' THEN 'Y'
              WHEN p.prefix = 'Y'  THEN 'BL'
              ELSE 'unknown'
          END AS next_bin_start
    FROM document_line_bin AS dlb
    CROSS APPLY (
        SELECT
              prefix =
                  CASE 
                      WHEN PATINDEX('%[0-9]%', dlb.bin_cd) > 0 
                          THEN LEFT(dlb.bin_cd, PATINDEX('%[0-9]%', dlb.bin_cd) - 1)
                      ELSE dlb.bin_cd
                  END
    ) AS p
    WHERE dlb.document_type = 'CR'
      AND p.prefix IN ('BL', 'Y')
    ORDER BY
          dlb.date_created DESC
        , dlb.bin_cd DESC
)

SELECT 
      CASE 
          WHEN CHARINDEX('-', cmt.Bin_ID) > 0 THEN 
                lcb.next_bin_start
                + SUBSTRING(
                      cmt.Bin_ID
                    , CHARINDEX('-', cmt.Bin_ID) + 1
                    , LEN(cmt.Bin_ID)
                  )
          ELSE cmt.Bin_ID
      END AS Bin_ID
    , cmt.PO_No
    , ivm.item_id
    , ROUND(cmt.Invoiced_Qty, 4) AS Invoiced_Qty
    , CONCAT(cmt.PO_No, ' ', ivm.item_id) AS join_key
    , ' ' AS order_no
FROM P21Import.dbo.coats_mexico_shipment_raw_line AS cmt

LEFT JOIN cte_last_color_bin AS lcb
    ON 1 = 1

LEFT JOIN inventory_supplier AS ivs
    ON cmt.Item_ID = ivs.supplier_part_no
   AND ivs.supplier_id = '40408'

LEFT JOIN inv_mast AS ivm
    ON ivm.inv_mast_uid = ivs.inv_mast_uid
WHERE cmt.shipment_file_id = @ShipmentFileId
;
