-- Q13: Customer Distribution (LEFT OUTER JOIN + 이중 집계)
-- 튜닝 포인트: outer join 조건의 NOT LIKE 필터 위치, HashAgg 메모리
select
    c_count,
    count(*) as custdist
from (
    select c_custkey, count(o_orderkey) as c_count
    from customer
    left outer join orders
      on c_custkey = o_custkey
     and o_comment not like '%special%requests%'
    group by c_custkey
) as c_orders
group by c_count
order by custdist desc, c_count desc
