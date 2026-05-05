set nocount on;

declare @batch_id uniqueidentifier = newid();
declare @cutoff_date date = dateadd(month, -2, cast(getdate() as date));
declare @graph_values nvarchar(max) = json_query(@payload, '$.values');

drop table if exists #incoming;
drop table if exists #validated;

;with graph_rows as
(
    select
        try_convert(int, g.[key]) as row_number
      , g.[value] as row_json
    from openjson(@graph_values) g
    where try_convert(int, g.[key]) > 0
)
, graph_src as
(
    select
        nullif(ltrim(rtrim(json_value(row_json, '$[3]'))), '') as prod_order_number
      , nullif(ltrim(rtrim(json_value(row_json, '$[0]'))), '') as item_desc
      , nullif(ltrim(rtrim(json_value(row_json, '$[1]'))), '') as actual_start_raw
      , nullif(ltrim(rtrim(json_value(row_json, '$[4]'))), '') as date_received_raw
      , nullif(ltrim(rtrim(json_value(row_json, '$[7]'))), '') as actual_end_raw
    from graph_rows
)
, lookup_src as
(
    select
        nullif(ltrim(rtrim(coalesce(
            json_value(j.[value], '$.prod_order_number'),
            json_value(j.[value], '$."ORDER #"')
        ))), '') as prod_order_number
      , nullif(ltrim(rtrim(coalesce(
            json_value(j.[value], '$.item_desc'),
            json_value(j.[value], '$."ITEM PRODUCED DESCRIPTION"')
        ))), '') as item_desc
      , nullif(ltrim(rtrim(coalesce(
            json_value(j.[value], '$.actual_start_date'),
            json_value(j.[value], '$."RUN DATE"')
        ))), '') as actual_start_raw
      , nullif(ltrim(rtrim(coalesce(
            json_value(j.[value], '$.date_received'),
            json_value(j.[value], '$."DATE RCVD"')
        ))), '') as date_received_raw
      , nullif(ltrim(rtrim(coalesce(
            json_value(j.[value], '$.actual_end_date'),
            json_value(j.[value], '$."DATE COMPLETED"')
        ))), '') as actual_end_raw
    from openjson(@payload) j
    where @graph_values is null
)
, src as
(
    select * from graph_src
    union all
    select * from lookup_src
)
select
    s.prod_order_number
  , s.item_desc
  , ca.actual_start_date
  , ca.actual_end_date
  , ca.date_received
  , concat(s.prod_order_number, '|', s.item_desc) as unique_key
into #incoming
from src s
cross apply
(
    select
        case
            when try_convert(int, s.actual_start_raw) is not null
                then dateadd(day, try_convert(int, s.actual_start_raw) - 2, convert(date, '1900-01-01'))
            else try_convert(date, s.actual_start_raw)
        end as actual_start_date
      , case
            when try_convert(int, s.actual_end_raw) is not null
                then dateadd(day, try_convert(int, s.actual_end_raw) - 2, convert(date, '1900-01-01'))
            else try_convert(date, s.actual_end_raw)
        end as actual_end_date
      , case
            when try_convert(int, s.date_received_raw) is not null
                then dateadd(day, try_convert(int, s.date_received_raw) - 2, convert(date, '1900-01-01'))
            else try_convert(date, s.date_received_raw)
        end as date_received
) ca
where s.prod_order_number is not null;

;with cte_incoming as
(
    select
        i.prod_order_number
      , i.item_desc
      , i.actual_start_date
      , i.actual_end_date
      , i.date_received
      , i.unique_key
      , count(*) over (partition by i.unique_key) as unique_key_count
      , case
            when i.prod_order_number is null then 0
            when i.item_desc is null then 0
            when @full_load = 1 then 1
            when coalesce(i.actual_start_date, i.actual_end_date, i.date_received) >= @cutoff_date then 1
            else 0
        end as passes_load_filter
    from #incoming i
)
select
    prod_order_number
  , item_desc
  , actual_start_date
  , actual_end_date
  , date_received
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
  , sum(case when actual_start_date is null and actual_end_date is null and date_received >= @cutoff_date then 1 else 0 end) as rows_loaded_by_date_received_only
from #validated;
