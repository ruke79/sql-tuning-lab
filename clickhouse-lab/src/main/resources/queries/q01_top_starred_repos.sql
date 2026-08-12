-- 별(WatchEvent) 많이 받은 리포 Top 20
-- 튜닝 포인트: ORDER BY 선두 컬럼(event_type) 필터 → granule pruning 관찰
select repo_name, count() as stars
from gharchive.github_events
where event_type = 'WatchEvent'
group by repo_name
order by stars desc
limit 20
