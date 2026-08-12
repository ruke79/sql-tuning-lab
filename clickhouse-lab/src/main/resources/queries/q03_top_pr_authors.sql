-- PR을 가장 많이 연 사용자 Top 20
-- 튜닝 포인트: event_type 필터 + actor_login 집계 (비정렬 컬럼 집계 비용)
select actor_login, count() as prs
from gharchive.github_events
where event_type = 'PullRequestEvent' and action = 'opened'
group by actor_login
order by prs desc
limit 20
