

CREATE FUNCTION [dbo].[p21_fnt_get_linkable_transactions]
(	@al_LocationID INTEGER
	,@as_ItemID VARCHAR(40)
	,@al_PoNo INTEGER
	,@al_PoLineNo INTEGER
	,@al_LookAheadDays INTEGER
	,@as_PurchaseGroup VARCHAR(20)
	,@as_GporFlag CHAR(1)
	,@al_PoLineUid INTEGER
	,@as_ProdOrdersEnabled CHAR(1)
	,@as_IncludeNSProdOrder CHAR(1)
	,@as_Type CHAR(1)
	,@dt_TodayNoTime datetime -- 12.13 USA 06/18/13 Scopus 1147231: Pass argument @dt_TodayNoTime
)	RETURNS 
@final TABLE 
(
    [order_no] [varchar](20) NULL
    , [item_id] [varchar](40) NULL
    , [order_date] [datetime] NULL
    , [item_desc] [varchar](40) NULL
    , [customer_name] [varchar](255) NULL
    , [qty_ordered] [decimal](19, 9) NULL
    , [required_date] [datetime] NULL
    , [qty_allocated] [decimal](19, 9) NULL
    , [qty_on_pick_tickets] [decimal](19, 9) NULL
    , [qty_invoiced] [decimal](19, 9) NULL
    , [order_quantity] [decimal](38, 9) NULL
    , [unit_size] [decimal](19, 4) NULL
    , [line_no] [decimal](19, 0) NULL
    , [qty_canceled] [decimal](19, 9) NULL
    , [qty_staged] [decimal](19, 9) NULL
    , [component_number] [decimal](19, 0) NULL
    , [c_ReleaseScheduleQty] [decimal](38, 9) NULL
    , [c_OpenReleaseSchedule] [varchar](1) NULL
    , [linked_qty] [decimal](38, 9) NULL
    , [c_qty_on_other_po] [decimal](38, 9) NULL
    , [oe_line_uid] [int] NULL
    , [source_loc_id] [decimal](19, 0) NULL
    , [c_ordertype] [varchar](6) NULL
    , [location_id] [decimal](19, 0) NULL
    , [po_no] [int] NULL
    , [po_line_no] [int] NULL
    , [po_line_uid] [int] NULL
    , [inv_mast_uid] [int] NULL
    , [original_linked_qty] [decimal](38, 9) NULL
    , [qty_confirmed] [decimal](19, 9) NULL
    , [revision_level] [varchar](255) NULL
    , [use_revisions_flag] [varchar](1) NULL
    , [company_id] [varchar](8) NULL
    , [customer_id] [decimal](19, 0) NULL
    , [supplier_id] [decimal](19, 0) NULL
    , [disposition] [varchar](1) NULL -- 12.15 JBH 05/06/14 - Feature 57035
    , [extended_desc] [varchar](255) NULL -- 12.17 CAA 10/14/15 - Scopus# 1335790
)
AS
BEGIN
        INSERT INTO @final
        (
            [order_no]
            ,[item_id]
            ,[order_date]
            ,[item_desc]
            ,[customer_name]
            ,[qty_ordered]
            ,[required_date]
            ,[qty_allocated]
            ,[qty_on_pick_tickets]
            ,[qty_invoiced]
            ,[order_quantity]
            ,[unit_size]
            ,[line_no]
            ,[qty_canceled]
            ,[qty_staged]
            ,[component_number]
            ,[c_ReleaseScheduleQty]
            ,[c_OpenReleaseSchedule]
            ,[linked_qty]
            ,[c_qty_on_other_po]
            ,[oe_line_uid]
            ,[source_loc_id]
            ,[c_ordertype]
            ,[location_id]
            ,[po_no]
            ,[po_line_no]
            ,[po_line_uid]
            ,[inv_mast_uid]
            ,[original_linked_qty]
            ,[qty_confirmed]
            ,[revision_level]
            ,[use_revisions_flag]
            ,[company_id]
            ,[customer_id]
            ,[supplier_id]
			,[disposition] -- 12.15 JBH 05/06/14 - Feature 57035
			,[extended_desc] -- 12.17 CAA 10/14/15 - Scopus# 1335790        
        )
	    SELECT oe_hdr.order_no,
             inv_mast.item_id,
             oe_hdr.order_date,
             inv_mast.item_desc,
             customer.customer_name,
             oe_line.qty_ordered,
             oe_line.required_date,
             oe_line.qty_allocated,
             oe_line.qty_on_pick_tickets,
             oe_line.qty_invoiced,
             inv_loc.order_quantity - COALESCE(drv_BlanketPOReleases.c_BlanketPO_Release_Qty, 0) order_quantity,
             item_uom.unit_size,
             oe_line.line_no,
             oe_line.qty_canceled,
             oe_line.qty_staged,
             NULL component_number,
             COALESCE(drv_TotalScheduleReleaseQty.c_release_qty, 0) + COALESCE(drv_KitReleaseQty.c_kitreleases_nonallocated, 0) c_ReleaseScheduleQty,
             COALESCE(drv_TotalScheduleReleaseQty.c_openreleaseschedule, drv_KitReleaseQty.c_openreleaseschedulekit, 'N') c_OpenReleaseSchedule,
             COALESCE(drv_ThisPOLinked.c_qty_on_po, 0) linked_qty,
             COALESCE(drv_OtherPOLinked.c_qty_on_po, 0) + COALESCE(drv_LinkQuantity.quantity, 0) c_qty_on_other_po,
             oe_line.oe_line_uid,
             oe_line.source_loc_id,
             'REG' c_ordertype,
             inv_loc.location_id,
             @al_PoNo po_no,
             @al_PoLineNo po_line_no,
             @al_PoLineUid po_line_uid,
             inv_mast.inv_mast_uid,
             COALESCE(drv_ThisPOLinked.c_qty_on_po, 0) original_linked_qty,
             0 qty_confirmed
             ,COALESCE(item_revision.revision_level, '') revision_level
             ,COALESCE(inv_mast.use_revisions_flag, 'N')  use_revisions_flag
             ,oe_hdr.company_id
             ,oe_hdr.customer_id
             ,oe_line.supplier_id
             ,oe_line.disposition -- 12.15 JBH 05/06/14 - Feature 57035
             ,oe_line.extended_desc -- 12.17 CAA 10/14/15 - Scopus# 1335790  
    FROM	inv_loc
    INNER JOIN   oe_line ON inv_loc.inv_mast_uid = oe_line.inv_mast_uid
                         AND inv_loc.location_id = oe_line.source_loc_id
    INNER JOIN   oe_hdr ON oe_line.order_no = oe_hdr.order_no
    INNER JOIN   customer ON oe_hdr.customer_id = customer.customer_id
                         AND oe_hdr.company_id = customer.company_id
    INNER JOIN   inv_mast ON inv_loc.inv_mast_uid = inv_mast.inv_mast_uid
    -- 12.14 - JRL 07/17/14 - SCOPUS #1238150 - Add check for slab items and group purchasing
						 AND (@as_GporFlag = 'L' OR inv_mast.product_type <> 'S')  
    INNER JOIN   item_uom ON inv_mast.inv_mast_uid = item_uom.inv_mast_uid
                         AND inv_mast.default_purchasing_unit = item_uom.unit_of_measure
	LEFT JOIN system_setting ss_hold ON ss_hold.[name] = 'link_to_hold_order'
    LEFT JOIN revision_transaction ON revision_transaction.transaction_no = cast(oe_line.order_no as int)
              AND revision_transaction.transaction_line_no = oe_line.line_no
              AND  revision_transaction.transaction_code_no = 1533
    LEFT JOIN item_revision ON item_revision.item_revision_uid = revision_transaction.item_revision_uid                                 
    LEFT JOIN   p21_fnt_Locations (@al_LocationID, @as_PurchaseGroup, @as_GporFlag)
                          ON p21_fnt_locations.location_id = inv_loc.location_id
    LEFT JOIN   (SELECT   COALESCE(SUM(oe_line_schedule.release_qty
                         - oe_line_schedule.allocated_qty
                         - oe_line_schedule.qty_staged
                         - oe_line_schedule.qty_picked
                         - oe_line_schedule.qty_canceled
                         - oe_line_schedule.qty_invoiced), 0) c_release_qty,
                           oe_line_schedule.order_no,
                           oe_line_schedule.line_no,
                           'Y' c_OpenReleaseSchedule
                    FROM  oe_line_schedule
					INNER JOIN system_setting ss_schedules  ON ss_schedules.name = 'allocate_to_planned_schedules'  
                    WHERE   
                    (
	                    (
							COALESCE(oe_line_schedule.disposition, '') = '' 
							AND
							oe_line_schedule.expedite_date <= @dt_TodayNoTime + @al_LookAheadDays
						)
						OR
						oe_line_schedule.disposition = 'B'
						OR
						@al_LookAheadDays IS NULL
                    )
                         -- 12.13 USA 06/18/13 Scopus 1147231: Added excluding planned schedules based on system setting allocate_to_planned_schedules and expedite date.
                    AND
                    (
						COALESCE(oe_line_schedule.release_status_flag,'') <> 'P'
						OR   
						oe_line_schedule.expedite_date >= @dt_TodayNoTime
						OR
						ss_schedules.value = 'Y'
					)
					
                GROUP BY   oe_line_schedule.order_no,
                         oe_line_schedule.line_no
                ) AS drv_TotalScheduleReleaseQty   ON oe_line.order_no = drv_TotalScheduleReleaseQty.order_no
                                                 AND oe_line.line_no = drv_TotalScheduleReleaseQty.line_no
												 -- 24.2 YCHEN 08/13/24 - Jira P21S-20518: Exclude kit components on scheduled release here, it existed in drv_KitReleaseQty. 
												 AND oe_line.detail_type <> 2
    LEFT JOIN   (SELECT   COALESCE(Sum(oe_line_po.quantity_on_po), 0) c_qty_on_po,
                         oe_line_po.order_number,
                         oe_line_po.line_number
                 FROM      oe_line_po
                 WHERE   oe_line_po.delete_flag = 'N' AND
                         oe_line_po.completed = 'N' AND
                         oe_line_po.cancel_flag = 'N' AND
                         ( oe_line_po.po_no <> @al_PoNo OR
                           oe_line_po.po_line_number <> @al_PoLineNo )
                GROUP BY   oe_line_po.order_number,
                         oe_line_po.line_number) AS drv_OtherPOLinked ON oe_line.order_no = drv_OtherPOLinked.order_number AND
                                                                         oe_line.line_no = drv_OtherPOLinked.line_number
    LEFT JOIN   (SELECT   COALESCE(Sum(oe_line_po.quantity_on_po), 0) c_qty_on_po,
                         oe_line_po.order_number,
                         oe_line_po.line_number
                 FROM      oe_line_po
                 WHERE   oe_line_po.delete_flag = 'N' AND
                         oe_line_po.completed = 'N' AND
                         oe_line_po.cancel_flag = 'N' AND
                         oe_line_po.po_no = @al_PoNo AND
                         oe_line_po.po_line_number = @al_PoLineNo
                GROUP BY   oe_line_po.order_number, 
                         oe_line_po.line_number) AS drv_ThisPOLinked ON oe_line.order_no = drv_ThisPOLinked.order_number AND
                                                                         oe_line.line_no = drv_ThisPOLinked.line_number
    LEFT JOIN   (SELECT   COALESCE(sum(release_qty), 0) c_BlanketPO_Release_Qty, 
                         po_line.inv_mast_uid
                         , po_hdr.location_id
                   FROM   po_line_schedule
             INNER JOIN   po_line ON (po_line.po_line_uid = po_line_schedule.po_line_uid)
             INNER JOIN   po_hdr ON (po_line.po_no = po_hdr.po_no)
                   WHERE	row_status_flag = 704
                     AND	(release_date >= @dt_TodayNoTime + @al_LookAheadDays
                      OR	@al_LookAheadDays IS NULL)
                GROUP BY po_line.inv_mast_uid, 
                         po_hdr.location_id
                ) AS drv_BlanketPOReleases ON drv_BlanketPOReleases.inv_mast_uid = inv_loc.inv_mast_uid
                                           AND drv_BlanketPOReleases.location_id = inv_loc.location_id
    LEFT JOIN   (SELECT   COALESCE(sum(link_quantity.quantity), 0) quantity,
                         to_uid
                   FROM   link_quantity
                   WHERE   to_type_cd = 706 AND
                         row_status_flag = 704
                GROUP BY   to_uid
                ) AS drv_LinkQuantity ON drv_LinkQuantity.to_uid = oe_line.oe_line_uid
    LEFT JOIN (SELECT COALESCE( SUM(COALESCE (oe_line_schedule_comp.release_qty, oe_line_schedule_kit.release_qty * oe_line_comp.qty_per_assembly * oe_line_comp.unit_size)
				- COALESCE (oe_line_schedule_comp.allocated_qty, oe_line_schedule_kit.allocated_qty * oe_line_comp.qty_per_assembly * oe_line_comp.unit_size)
				- COALESCE (oe_line_schedule_comp.qty_staged, oe_line_schedule_kit.qty_staged  * oe_line_comp.qty_per_assembly * oe_line_comp.unit_size)
				- COALESCE (oe_line_schedule_comp.qty_picked, oe_line_schedule_kit.qty_picked  * oe_line_comp.qty_per_assembly * oe_line_comp.unit_size)
				- COALESCE (oe_line_schedule_comp.qty_canceled, oe_line_schedule_kit.qty_canceled * oe_line_comp.qty_per_assembly * oe_line_comp.unit_size)
				- COALESCE (oe_line_schedule_comp.qty_invoiced, oe_line_schedule_kit.qty_invoiced  * oe_line_comp.qty_per_assembly * oe_line_comp.unit_size)
				), 0) c_KitReleases_nonallocated,  
				 oe_line_comp.order_no,  
				 oe_line_comp.line_no,
				'Y' c_OpenReleaseScheduleKit 
			FROM oe_line_schedule AS oe_line_schedule_kit
			INNER JOIN oe_line AS oe_line_kit ON oe_line_kit.order_no = oe_line_schedule_kit.order_no  
							AND oe_line_kit.line_no = oe_line_schedule_kit.line_no  
							AND oe_line_kit.assembly = 'B'
							AND oe_line_kit.complete = 'N'   
							AND oe_line_kit.delete_flag = 'N'   
							AND oe_line_kit.cancel_flag = 'N'  
			INNER JOIN oe_line AS oe_line_comp ON oe_line_comp.parent_oe_line_uid = oe_line_kit.oe_line_uid
							AND oe_line_comp.detail_type = 2
							AND oe_line_comp.complete = 'N'   
							AND oe_line_comp.delete_flag = 'N'   
							AND oe_line_comp.cancel_flag = 'N'  
			LEFT OUTER JOIN oe_line_schedule AS oe_line_schedule_comp ON oe_line_schedule_comp.order_no = oe_line_comp.order_no
							AND oe_line_schedule_comp.line_no = oe_line_comp.line_no
							AND oe_line_schedule_comp.release_no = oe_line_schedule_kit.release_no
			-- 12.13 USA 06/18/13 Scopus 1147231: Added excluding planned schedules based on system setting allocate_to_planned_schedules and expedite date.
			INNER JOIN system_setting ss_schedules ON ss_schedules.name = 'allocate_to_planned_schedules'  							

			WHERE 
					(
						(
							COALESCE(oe_line_schedule_comp.disposition, oe_line_schedule_kit.disposition, '') = ''
							AND
							COALESCE(oe_line_schedule_comp.expedite_date, oe_line_schedule_kit.expedite_date) <= @dt_TodayNoTime + @al_LookAheadDays
						)
						OR
						COALESCE(oe_line_schedule_comp.disposition, oe_line_schedule_kit.disposition, '') = 'B'
						OR
						@al_LookAheadDays IS NULL
					)
				-- 12.13 USA 06/18/13 Scopus 1147231: Added excluding planned schedules based on system setting allocate_to_planned_schedules and expedite date.
					AND   
					(
						COALESCE(oe_line_schedule_comp.release_status_flag,oe_line_schedule_kit.release_status_flag, '') <> 'P'
						OR  
						COALESCE(oe_line_schedule_comp.expedite_date, oe_line_schedule_kit.expedite_date) >= @dt_TodayNoTime
						OR
						ss_schedules.value = 'Y'
					)									

			GROUP BY oe_line_comp.order_no, oe_line_comp.line_no
			) AS drv_KitReleaseQty   ON oe_line.order_no = drv_KitReleaseQty.order_no
						AND oe_line.line_no = drv_KitReleaseQty.line_no  

	--EJF Scopus 1409990:  Add F disposition
    WHERE   ( ( ( COALESCE (oe_line.disposition, ' ') IN ('B', 'T', 'F') ) AND
                 ( ( oe_line.expedite_date <= @dt_TodayNoTime + @al_LookAheadDays ) OR
                    ( @al_LookAheadDays IS NULL ) OR
                   ( inv_loc.stockable = 'Y' ) ) ) OR
               ( oe_line.scheduled = 'Y' ) ) AND
             ( ( COALESCE(drv_TotalScheduleReleaseQty.c_release_qty, 0) + COALESCE(drv_KitReleaseQty.c_kitreleases_nonallocated, 0) - COALESCE(drv_OtherPOLinked.c_qty_on_po, 0) > 0) OR
               ( ( oe_line.scheduled = 'N' ) AND
                 ( oe_line.qty_ordered - oe_line.qty_allocated - oe_line.qty_on_pick_tickets - oe_line.qty_invoiced - oe_line.qty_canceled - oe_line.qty_staged - COALESCE(drv_OtherPOLinked.c_qty_on_po, 0) - COALESCE(drv_LinkQuantity.quantity, 0) > 0 ) ) ) AND
             ( ( oe_hdr.validation_status <> 'Hold' ) OR ( ss_hold.value = 'Y' ))  AND
             ( inv_mast.other_charge_item = 'N' ) AND
             ( inv_mast.item_id = @as_ItemID ) AND
             ( oe_hdr.delete_flag <> 'Y' ) AND
             ( oe_hdr.completed <> 'Y' ) AND
             ( oe_hdr.projected_order = 'N' ) AND
             ( oe_hdr.approved = 'Y' ) AND
             ( ( p21_fnt_locations.location_id IS NOT NULL ) OR
               ( drv_ThisPOLinked.c_qty_on_po > 0 ) )

    UNION

    SELECT   CAST ( prod_order_hdr.prod_order_number AS varchar(20) ) order_no, 
             inv_mast.item_id,   
             prod_order_hdr.order_date,   
             inv_mast.item_desc,   
             'Production Order' customer_name,   
             prod_order_line_component.qty_requested,   
             COALESCE(prod_order_line_component.required_date, prod_order_line.required_date, prod_order_hdr.required_date) 'required_date',
             prod_order_line_component.qty_allocated,   
             prod_order_line_component.qty_on_pick_tickets,   
             0 qty_invoiced,   
             inv_loc.order_quantity - COALESCE(drv_BlanketPOReleases.c_BlanketPO_Release_Qty, 0) order_quantity,
             item_uom.unit_size,
             prod_order_line_component.line_number,
             prod_order_line_component.qty_canceled,
             0 qty_staged,
             prod_order_line_component.component_number,
             0 c_ReleaseScheduleQty, 
             'N' c_OpenReleaseSchedule, 
             COALESCE(drv_ProdThisPOLinked.c_qty_on_po, 0) linked_qty,
             COALESCE(drv_ProdOtherPOLinked.c_qty_on_po, 0) c_qty_on_other_po,
             prod_order_line_component.prod_order_line_component_uid,
             prod_order_line_component.source_location_id,
             'PR ORD' c_OrderType,
             inv_loc.location_id,
             @al_PoNo po_no,
             @al_PoLineNo po_line_no,
             @al_PoLineUid po_line_uid,
             inv_mast.inv_mast_uid,
             COALESCE(drv_ProdThisPOLinked.c_qty_on_po, 0) original_linked_qty,
             prod_order_line_component.qty_confirmed
             ,COALESCE(item_revision.revision_level, '') revision_level
             ,COALESCE(inv_mast.use_revisions_flag, 'N')  use_revisions_flag
             ,prod_order_hdr.company_id
             ,NULL customer_id
             ,prod_order_line_component.supplier_id
             ,prod_order_line_component.disposition -- 12.15 JBH 05/06/14 - Feature 57035
             ,prod_order_line_component.extended_desc -- 12.17 CAA 10/14/15 - Scopus# 1335790             
    FROM prod_order_line_component
    INNER JOIN   prod_order_line ON prod_order_line.prod_order_number = prod_order_line_component.prod_order_number
                               AND prod_order_line.line_number = prod_order_line_component.line_number
    INNER JOIN   prod_order_hdr ON ( prod_order_hdr.prod_order_number = prod_order_line_component.prod_order_number )   
    INNER JOIN   inv_mast ON ( inv_mast.inv_mast_uid = prod_order_line_component.inv_mast_uid )
    -- 12.14 - JRL 07/17/14 - SCOPUS #1238150 - Add check for slab items and group purchasing
						 AND (@as_GporFlag = 'L' OR inv_mast.product_type <> 'S')  
    INNER JOIN   inv_loc ON ( inv_loc.location_id = prod_order_line_component.source_location_id ) AND
                              ( inv_loc.inv_mast_uid = prod_order_line_component.inv_mast_uid ) 
    INNER JOIN   item_uom ON ( item_uom.inv_mast_uid = inv_mast.inv_mast_uid ) AND
                            ( item_uom.unit_of_measure = inv_mast.default_purchasing_unit ) 
    LEFT JOIN revision_transaction ON    revision_transaction.transaction_code_no = 1132 AND revision_transaction.transaction_no = prod_order_line_component.prod_order_number AND
                  revision_transaction.transaction_line_no = prod_order_line_component.line_number AND revision_transaction.transaction_sub_line_no = prod_order_line_component.component_number
       LEFT JOIN item_revision ON item_revision.item_revision_uid = revision_transaction.item_revision_uid                                                         
    LEFT JOIN   p21_fnt_Locations (@al_LocationID, @as_PurchaseGroup, @as_GporFlag) 
                                   on p21_fnt_locations.location_id = inv_loc.location_id  
    LEFT JOIN   (SELECT   COALESCE(Sum(prod_ord_line_po.quantity),0) c_qty_on_po,
                         prod_ord_line_po.prod_order_number,
                         prod_ord_line_po.line_number,
                         prod_ord_line_po.component_number
                 FROM      prod_ord_line_po
                 WHERE   prod_ord_line_po.row_status_flag = 702 AND
                         ( prod_ord_line_po.po_number <> @al_PoNo OR
                           prod_ord_line_po.po_line_number <> @al_PoLineNo )
                GROUP BY   prod_ord_line_po.prod_order_number, 
                         prod_ord_line_po.line_number,
                         prod_ord_line_po.component_number) 
                AS drv_ProdOtherPOLinked ON prod_order_line_component.prod_order_number = drv_ProdOtherPOLinked.prod_order_number AND
                                           prod_order_line_component.line_number = drv_ProdOtherPOLinked.line_number AND
                                           prod_order_line_component.component_number = drv_ProdOtherPOLinked.component_number
    LEFT JOIN   (SELECT   COALESCE(Sum(prod_ord_line_po.quantity),0) c_qty_on_po,
                         prod_ord_line_po.prod_order_number,
                         prod_ord_line_po.line_number,
                         prod_ord_line_po.component_number
                 FROM      prod_ord_line_po
                 WHERE   prod_ord_line_po.row_status_flag = 702 AND
                         prod_ord_line_po.po_number = @al_PoNo AND
                         prod_ord_line_po.po_line_number = @al_PoLineNo
                GROUP BY   prod_ord_line_po.prod_order_number, 
                         prod_ord_line_po.line_number,
                         prod_ord_line_po.component_number) 
                AS drv_ProdThisPOLinked ON prod_order_line_component.prod_order_number = drv_ProdThisPOLinked.prod_order_number AND
                                           prod_order_line_component.line_number = drv_ProdThisPOLinked.line_number AND
                                           prod_order_line_component.component_number = drv_ProdThisPOLinked.component_number
    LEFT JOIN   (SELECT   COALESCE(sum(release_qty), 0) c_BlanketPO_Release_Qty, 
                         po_line.inv_mast_uid, po_hdr.location_id
				 FROM   po_line_schedule
				 INNER JOIN   po_line ON (po_line.po_line_uid = po_line_schedule.po_line_uid)
				 INNER JOIN   po_hdr ON (po_line.po_no = po_hdr.po_no)
                   WHERE   row_status_flag = 704 AND
                         ( release_date >= @dt_TodayNoTime + @al_LookAheadDays OR
                           @al_LookAheadDays IS NULL )
                GROUP BY   po_line.inv_mast_uid,
                         po_hdr.location_id
                   ) AS   drv_BlanketPOReleases ON drv_BlanketPOReleases.inv_mast_uid = inv_loc.inv_mast_uid AND
                         drv_BlanketPOReleases.location_id = inv_loc.location_id
    WHERE   ( ( prod_order_line_component.disposition in ('B', 'T', 'F') ) AND
               ( ( COALESCE(prod_order_line_component.required_date, prod_order_hdr.required_date) <= @dt_TodayNoTime + @al_LookAheadDays) OR
                 ( @al_LookAheadDays IS NULL ) OR
                 ( inv_loc.stockable = 'Y' ) ) ) AND
             ( prod_order_line_component.qty_requested - prod_order_line_component.qty_allocated - prod_order_line_component.qty_canceled - prod_order_line_component.qty_used - COALESCE(drv_ProdOtherPOLinked.c_qty_on_po, 0) > 0 ) AND
             ( inv_mast.other_charge_item = 'N' ) AND  
             ( inv_mast.item_id = @as_ItemID ) AND  
             ( prod_order_hdr.delete_flag <> 'Y' ) AND  
             ( prod_order_hdr.complete = 'N' ) AND  
             ( prod_order_hdr.approved = 'Y' ) AND
             ( @as_ProdOrdersEnabled = 'Y' ) AND
             ( ( @as_IncludeNSProdOrder = 'Y' ) OR
               ( inv_loc.stockable = 'Y' ) ) AND
             ( ( p21_fnt_locations.location_id IS NOT NULL ) OR
               ( drv_ProdThisPOLinked.c_qty_on_po > 0 ) )

    UNION

    SELECT   NULL order_no,   
             inv_mast.item_id,   
             transfer_backorders.date_created order_date,   
             inv_mast.item_desc,   
             'Transfer Backorder' customer_name,   
             transfer_backorders.qty_backordered qty_ordered,   
             NULL required_date,   
             CASE WHEN transfer_backorders.po_no IS NULL
                THEN 0
                ELSE transfer_backorders.qty_backordered
             END qty_allocated,   
             0 qty_on_pick_tickets,   
             0 qty_invoiced,   
             0 order_quantity,
             1 unit_size,
             NULL line_no,
             0 qty_canceled,
             0 qty_staged,
             NULL component_number,
             0 c_ReleaseScheduleQty, 
             'N' c_OpenReleaseSchedule, 
             CASE WHEN transfer_backorders.po_no IS NULL
                THEN 0
                ELSE transfer_backorders.qty_backordered
             END linked_qty,
             0 c_qty_on_other_po,
             transfer_backorders_uid,
             transfer_backorders.source_location_id,
             'TBO' c_OrderType,
             transfer_backorders.destination_location_id,
             @al_PoNo po_no,
             @al_PoLineNo po_line_no,
             @al_PoLineUid po_line_uid,
             inv_mast.inv_mast_uid,
             CASE WHEN transfer_backorders.po_no IS NULL
                THEN 0
                ELSE transfer_backorders.qty_backordered
             END original_linked_qty,
             0 qty_confirmed
             ,COALESCE(item_revision.revision_level, '') revision_level
             ,COALESCE(inv_mast.use_revisions_flag, 'N')  use_revisions_flag
             ,NULL company_id
             ,NULL customer_id
             ,NULL suppleir_id
             ,'' AS disposition -- 12.15 JBH 05/06/14 - Feature 57035
             ,NULL 'extended_desc' -- 12.17 CAA 10/14/15 - Scopus# 1335790             
    FROM      transfer_backorders
    INNER JOIN inv_loc ON ( transfer_backorders.inv_mast_uid = inv_loc.inv_mast_uid ) AND
             ( transfer_backorders.source_location_id = inv_loc.location_id )
    INNER JOIN   inv_mast ON inv_loc.inv_mast_uid = inv_mast.inv_mast_uid
        -- 12.14 - JRL 07/17/14 - SCOPUS #1238150 - Add check for slab items and group purchasing
						 AND (@as_GporFlag = 'L' OR inv_mast.product_type <> 'S')  
   LEFT JOIN item_revision ON item_revision.item_revision_uid = transfer_backorders.item_revision_uid 
    WHERE      ( ( ( transfer_backorders.po_no IS NULL ) AND
                 ( transfer_backorders.po_line_no IS NULL ) ) OR
               ( ( transfer_backorders.po_no = @al_PoNo ) AND
                 ( transfer_backorders.po_line_no = @al_PoLineNo ) ) ) AND
             ( inv_mast.other_charge_item = 'N' ) AND
             ( inv_mast.item_id = @as_ItemID ) AND
             ( inv_loc.location_id = @al_LocationID ) AND
             ( @as_Type IN ('P', 'G') )

    UNION

    SELECT   CAST ( process_x_transaction.process_x_transaction_uid AS varchar(20) ) order_no,   
             inv_mast.item_id,
             process_x_transaction.begin_date order_date,
             inv_mast.item_desc,
             'Process Transaction' customer_name,
             process_x_transaction.raw_qty_requested qty_ordered,
             process_x_transaction.expected_date required_date,
             process_x_transaction.raw_qty_allocated qty_allocated,
             0 qty_on_pick_tickets,
             process_x_transaction.qty_completed qty_invoiced,
             0 order_quantity,
             item_uom.unit_size unit_size,
             NULL line_no,
             0 qty_canceled,
             0 qty_staged,
             NULL component_number,
             0 c_ReleaseScheduleQty,
             'N' c_OpenReleaseSchedule,
             COALESCE(drv_ThisPOLinked.c_qty_on_po, 0) linked_qty,
             COALESCE(drv_OtherPOLinked.c_qty_on_po, 0) + COALESCE(drv_OtherXferLinked.c_qty_on_po, 0) c_qty_on_other_po,
             process_x_transaction.process_x_transaction_uid oe_line_uid,
             process_x_transaction.location_id source_loc_id,
             'MSP' c_OrderType,
             process_x_transaction.location_id location_id,
             @al_PoNo po_no,
             @al_PoLineNo po_line_no,
             @al_PoLineUid po_line_uid,
             inv_mast.inv_mast_uid,
             COALESCE(drv_ThisPOLinked.c_qty_on_po, 0) original_linked_qty,
             0 qty_confirmed
             ,COALESCE(item_revision_raw.revision_level, '') revision_level
             ,COALESCE(inv_mast.use_revisions_flag, 'N')  use_revisions_flag
             ,NULL company_id
             ,NULL customer_id 
             ,NULL supplier_id
             ,process_x_transaction.disposition -- 12.15 JBH 05/06/14 - Feature 57035
             ,NULL 'extended_desc' -- 12.17 CAA 10/14/15 - Scopus# 1335790
    FROM   process_x_transaction
    INNER JOIN   inv_loc ON inv_loc.inv_mast_uid = process_x_transaction.raw_inv_mast_uid AND
                            inv_loc.location_id = process_x_transaction.location_id
    INNER JOIN   inv_mast ON inv_loc.inv_mast_uid = inv_mast.inv_mast_uid
        -- 12.14 - JRL 07/17/14 - SCOPUS #1238150 - Add check for slab items and group purchasing
						 AND (@as_GporFlag = 'L' OR inv_mast.product_type <> 'S')  
    INNER JOIN   item_uom ON inv_mast.inv_mast_uid = item_uom.inv_mast_uid AND
                            inv_mast.default_purchasing_unit = item_uom.unit_of_measure
    LEFT JOIN revision_transaction AS revision_transaction_raw ON revision_transaction_raw.transaction_no = process_x_transaction.process_x_transaction_uid   
                                                                          AND revision_transaction_raw.transaction_code_no = 1086 AND revision_transaction_raw.transaction_sub_code_no = 1228                        
    LEFT OUTER JOIN item_revision AS item_revision_raw ON item_revision_raw.item_revision_uid = revision_transaction_raw.item_revision_uid
                                                                                          AND item_revision_raw.inv_mast_uid = process_x_transaction.raw_inv_mast_uid                                                                      
    LEFT JOIN   p21_fnt_Locations (@al_LocationID, @as_PurchaseGroup, @as_GporFlag)
                          ON p21_fnt_locations.location_id = inv_loc.location_id
    LEFT JOIN   (SELECT   COALESCE(Sum(link_quantity.quantity), 0) c_qty_on_po,
                         link_quantity.to_uid
                   FROM   link_quantity
                   WHERE   link_quantity.row_status_flag = 704 AND
                         link_quantity.from_type_cd = 916 AND
                         link_quantity.to_type_cd = 1229 AND
                         link_quantity.from_uid <> @al_PoLineUid
                GROUP BY   link_quantity.to_uid) AS drv_OtherPOLinked ON drv_OtherPOLinked.to_uid = process_x_transaction.process_x_transaction_uid
    LEFT JOIN   (SELECT   COALESCE(Sum(oe_line_po.quantity_on_po), 0) c_qty_on_po,
                         oe_line_po.order_number,
                         oe_line_po.line_number
                 FROM      oe_line_po
                 WHERE   oe_line_po.delete_flag = 'N' AND
                         oe_line_po.completed = 'N' AND
                         oe_line_po.cancel_flag = 'N' AND
                         oe_line_po.connection_type = 'M'
                GROUP BY   oe_line_po.order_number,
                         oe_line_po.line_number) AS drv_OtherXferLinked ON process_x_transaction.process_x_transaction_uid = drv_OtherXferLinked.order_number AND
                                                                         1 = drv_OtherXferLinked.line_number
    LEFT JOIN   (SELECT   COALESCE(Sum(link_quantity.quantity), 0) c_qty_on_po,
                         link_quantity.to_uid
                   FROM   link_quantity
                   WHERE   link_quantity.row_status_flag = 704 AND
                         link_quantity.from_type_cd = 916 AND
                         link_quantity.to_type_cd = 1229 AND
                         link_quantity.from_uid = @al_PoLineUid
                GROUP BY   link_quantity.to_uid) AS drv_ThisPOLinked ON drv_ThisPOLinked.to_uid = process_x_transaction.process_x_transaction_uid
    WHERE      ( inv_mast.other_charge_item = 'N' ) AND
             ( inv_mast.item_id = @as_ItemID ) AND
             ( @as_Type IN ('P', 'G') ) AND
             ( process_x_transaction.raw_qty_requested - process_x_transaction.raw_qty_allocated - process_x_transaction.qty_completed - COALESCE(drv_OtherPOLinked.c_qty_on_po, 0) - COALESCE(drv_OtherXferLinked.c_qty_on_po, 0) > 0) AND
             ( ( p21_fnt_locations.location_id IS NOT NULL ) OR
               ( drv_ThisPOLinked.c_qty_on_po > 0 ) ) AND
             ( process_x_transaction.row_status_flag NOT IN (713, 701) )
         AND   process_x_transaction.transaction_type <> 'PROD'	    

	RETURN 
END



------------------------------------------------------------
-- 08/15/24 13:00 Author: Luis Mendoza
-- Commit id: 169c8503d50247c5d51b817903c81a4e3e9782a4
-- Merged PR 116181: Updated p21_fnt_get_linkable_transactions.sql
--DEV: YC
--DBA: LM
--Jira: P21S-20518: Modify function p21_fnt_get_linkable_transactions and custom object.
--b024_001_063449.sql
--
------------------------------------------------------------
-- 08/14/24 19:41 Author: Luis Mendoza
-- Commit id: 0c0b193a198222e61a01e309e1215ecad027844f
-- Merged PR 116126: Updated p21_fnt_get_linkable_transactions.sql
--DEV: YC
--DBA: LM
--Jira: 	P21S-20518 Feature P21S-20518: P21S-20518: Modify function p21_fnt_get_linkable_transactions and custom object.
--b024_001_063449.sql
--
-- $Author: Bernie.pomidor $
-- $Revision: 16 $
-- $Date: 10/28/20 2:51p $
-- $Log: /Server/CommerceCenter/Z_Polecat (20.2)/Functions/p21_fnt_get_linkable_transactions.sql $
-- 
-- 16    10/28/20 2:51p Bernie.pomidor
-- DBA: BGP
-- DEV: EJF
-- add system_setting
-- b020_002_055178
-- 
-- 14    8/09/19 11:48a Bernie.pomidor
-- DBA: BGP
-- DEV: BGP
-- expand order no
-- b019_002_052187bu
-- 
-- 12    1/29/19 11:52a Bernie.pomidor
-- DBA: BGP
-- DEV: EJF
-- allow edited orders
-- b018_002_051066
-- 
-- 11    10/09/18 2:53p Bernie.pomidor
-- DBA: BGP
-- DEV: EJF
-- add F disposition
-- b018_001_050520a
-- 
-- 9     10/15/15 11:54a Ricardo.aguirre
-- DEV: CAA
-- DBA: RAR
-- Scopus# 1335790: Added column extended_desc to
-- p21_fnt_get_linkable_transactions.
-- b012_016_043428a-b.sql
-- 
-- 7     7/17/14 3:14p Bernie.pomidor
-- DBA: BGP
-- DEV: JRL
-- add slab check
-- b012_014_040219
-- 
-- 6     5/12/14 4:49p Bernie.pomidor
-- DBA: BGP
-- DEV: JBH
-- add disposition
-- b012_014_039701
-- 
-- 4     7/03/13 2:42p Bernie.pomidor
-- same
-- 
-- 3     6/21/13 2:50p Bernie.pomidor
-- same
-- 
-- 2     6/20/13 3:56p Bernie.pomidor
-- DBA: BGP
-- DEV: USA
-- remove date function
-- b012_012_037469
-- 
-- 1     6/14/13 3:32p Bernie.pomidor
-- DBA: BGP
-- DEV: JBH
-- new function
-- b012_012_037433
-- 

