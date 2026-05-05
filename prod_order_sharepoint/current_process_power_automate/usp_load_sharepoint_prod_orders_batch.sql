create   procedure dbo.usp_load_sharepoint_prod_orders_batch  
    @payload nvarchar(max)  
  , @source_file nvarchar(260) = null  
  , @full_load bit = 0  
as  
begin  
    set nocount on;  
  
    declare @batch_id uniqueidentifier = newid();  
    declare @cutoff_date date = dateadd(month, -2, cast(getdate() as date));  
  
    drop table if exists #incoming;  
    drop table if exists #validated;  
  
    select  
        nullif(ltrim(rtrim(j.prod_order_number)), '') as prod_order_number  
      , nullif(ltrim(rtrim(j.item_desc)), '') as item_desc  
      , try_cast(j.actual_start_date as date) as actual_start_date  
      , try_cast(j.actual_end_date as date) as actual_end_date  
      , concat(  
            nullif(ltrim(rtrim(j.prod_order_number)), '')  
          , '|'  
          , nullif(ltrim(rtrim(j.item_desc)), '')  
        ) as unique_key  
    into #incoming  
    from openjson(@payload)  
    with  
    (  
        prod_order_number nvarchar(100) '$.prod_order_number'  
      , actual_start_date nvarchar(50) '$.actual_start_date'  
      , actual_end_date nvarchar(50) '$.actual_end_date'  
      , item_desc nvarchar(300) '$.item_desc'  
    ) j;  
  
    ;with cte_incoming as  
    (  
        select  
            i.prod_order_number  
          , i.item_desc  
          , i.actual_start_date  
          , i.actual_end_date  
          , i.unique_key  
          , count(*) over (partition by i.unique_key) as unique_key_count  
          , case  
                when i.prod_order_number is null then 0  
                when i.item_desc is null then 0  
                when @full_load = 1 then 1  
                when coalesce(i.actual_start_date, i.actual_end_date) >= @cutoff_date then 1  
                else 0  
            end as passes_load_filter  
        from #incoming i  
    )  
    select  
        prod_order_number  
      , item_desc  
      , actual_start_date  
      , actual_end_date  
      , unique_key  
      , unique_key_count  
      , passes_load_filter  
    into #validated  
    from cte_incoming;  
  
    insert into dbo.stg_sharepoint_prod_orders_excel_import  
    (  
        batch_id  
      , source_file  
      , unique_key  
      , prod_order_number  
      , item_desc  
      , actual_start_date  
      , actual_end_date  
    )  
    select  
        @batch_id  
      , @source_file  
      , v.unique_key  
      , v.prod_order_number  
      , v.item_desc  
      , v.actual_start_date  
      , v.actual_end_date  
    from #validated v  
    where v.unique_key_count = 1  
      and v.passes_load_filter = 1;  
  
    merge dbo.prod_orders_sharepoint as tgt  
    using  
    (  
        select  
            s.unique_key  
          , s.prod_order_number  
          , s.item_desc  
          , s.actual_start_date  
          , s.actual_end_date  
        from dbo.stg_sharepoint_prod_orders_excel_import s  
        where s.batch_id = @batch_id  
    ) as src  
        on tgt.unique_key = src.unique_key  
    when matched then  
        update set  
            tgt.prod_order_number = src.prod_order_number  
          , tgt.item_desc = src.item_desc  
          , tgt.actual_start_date = src.actual_start_date  
          , tgt.actual_end_date = src.actual_end_date  
          , tgt.last_updated = sysdatetime()  
    when not matched then  
        insert  
        (  
            unique_key  
          , prod_order_number  
          , item_desc  
          , actual_start_date  
          , actual_end_date  
          , created_at  
          , last_updated  
        )  
        values  
        (  
            src.unique_key  
          , src.prod_order_number  
          , src.item_desc  
          , src.actual_start_date  
          , src.actual_end_date  
          , sysdatetime()  
          , sysdatetime()  
        );  
  
    select  
        @batch_id as batch_id  
      , @source_file as source_file  
      , @cutoff_date as cutoff_date  
      , count(*) as total_rows_received  
      , sum(case when prod_order_number is null or item_desc is null then 1 else 0 end) as rows_missing_key_parts  
      , sum(case when unique_key_count > 1 then 1 else 0 end) as rows_skipped_non_unique_key  
      , sum(case when passes_load_filter = 0 then 1 else 0 end) as rows_skipped_by_date_filter  
      , sum(case when unique_key_count = 1 and passes_load_filter = 1 then 1 else 0 end) as rows_inserted_to_staging  
    from #validated;  
end;  