set nocount on;

declare @values nvarchar(max) = json_query(@payload, '$.values');

;with rows_to_check as
(
    select
        try_convert(int, j.[key]) + 1 as row_number
      , j.[value] as row_json
    from openjson(@values) j
    where try_convert(int, j.[key]) > 0
)
, parsed as
(
    select
        r.row_number
      , nullif(ltrim(rtrim(json_value(r.row_json, '$[3]'))), '') as order_number
      , case
            when nullif(ltrim(rtrim(coalesce(json_value(r.row_json, '$[0]'), ''))), '') is not null then 1
            when nullif(ltrim(rtrim(coalesce(json_value(r.row_json, '$[1]'), ''))), '') is not null then 1
            when nullif(ltrim(rtrim(coalesce(json_value(r.row_json, '$[2]'), ''))), '') is not null then 1
            when nullif(ltrim(rtrim(coalesce(json_value(r.row_json, '$[3]'), ''))), '') is not null then 1
            when nullif(ltrim(rtrim(coalesce(json_value(r.row_json, '$[4]'), ''))), '') is not null then 1
            when nullif(ltrim(rtrim(coalesce(json_value(r.row_json, '$[5]'), ''))), '') is not null then 1
            when nullif(ltrim(rtrim(coalesce(json_value(r.row_json, '$[6]'), ''))), '') is not null then 1
            when nullif(ltrim(rtrim(coalesce(json_value(r.row_json, '$[7]'), ''))), '') is not null then 1
            else 0
        end as has_row_data
    from rows_to_check r
)
select row_number
from parsed
where has_row_data = 1
  and order_number is null
order by row_number desc;
