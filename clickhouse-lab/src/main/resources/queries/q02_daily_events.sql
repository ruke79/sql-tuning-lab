-- 일별 이벤트 유형 분포 (MV의 원본 쿼리 - mv_daily_repo_stats 와 시간 비교)
select toDate(created_at) as day, event_type, count() as cnt
from gharchive.github_events
group by day, event_type
order by day, cnt desc
