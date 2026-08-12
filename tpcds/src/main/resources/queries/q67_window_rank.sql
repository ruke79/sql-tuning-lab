-- TPC-DS Q67 계열(단순화): 윈도우 함수 rank()
-- 튜닝 포인트: 집계 + 윈도우 함수의 정렬 비용, work_mem/sort_buffer 영향
select *
from (
    select
        i_category,
        i_brand,
        d_year,
        d_moy,
        sum(ss_sales_price) sumsales,
        rank() over (partition by i_category
                     order by sum(ss_sales_price) desc) rk
    from store_sales, date_dim, item
    where ss_sold_date_sk = d_date_sk
      and ss_item_sk = i_item_sk
      and d_year = 2001
    group by i_category, i_brand, d_year, d_moy
) ranked
where rk <= 10
order by i_category, rk
