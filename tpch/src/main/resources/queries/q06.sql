-- Q6: Forecasting Revenue Change (단일 테이블 범위 스캔)
-- 튜닝 포인트: l_shipdate 인덱스 vs Seq Scan 손익분기, BRIN 인덱스 실험에 적합
select
    sum(l_extendedprice * l_discount) as revenue
from lineitem
where l_shipdate >= date '1994-01-01'
  and l_shipdate < date '1994-01-01' + interval '1' year
  and l_discount between 0.05 and 0.07
  and l_quantity < 24
