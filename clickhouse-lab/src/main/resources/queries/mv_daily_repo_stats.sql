-- MV 사전 집계 조회 (materialized-view.sql 적용 후 사용 가능)
-- q02_daily_events 원본 쿼리와 실행 시간을 비교한다
select day, event_type, sum(cnt) as cnt
from gharchive.daily_repo_stats
group by day, event_type
order by day, cnt desc
