-- 특정 리포의 시간대별 활동 (repo_name 필터: ORDER BY 2번째 컬럼)
-- 튜닝 포인트: github_events vs github_events_by_time 테이블에서 각각 실행해 비교
select toStartOfHour(created_at) as hour, event_type, count() as cnt
from gharchive.github_events
where repo_name in (
    select repo_name from gharchive.github_events
    where event_type = 'WatchEvent'
    group by repo_name order by count() desc limit 1
)
group by hour, event_type
order by hour
