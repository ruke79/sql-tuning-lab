-- TPC-DS Q3 계열: 기본 Star Join (fact 1 + dim 2)
-- 튜닝 포인트: 차원 필터(d_moy, i_manufact_id) 선택도 → 조인 순서, Star Join 변환
select
    d_year,
    i_brand_id brand_id,
    i_brand brand,
    sum(ss_ext_sales_price) sum_agg
from date_dim, store_sales, item
where d_date_sk = ss_sold_date_sk
  and ss_item_sk = i_item_sk
  and i_manufact_id = 128
  and d_moy = 11
group by d_year, i_brand_id, i_brand
order by d_year, sum_agg desc, brand_id
limit 100
