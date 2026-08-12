-- Materialized View 실험: 일별/리포별 이벤트 집계를 MV로 사전 집계
-- run 명령의 mv_daily_repo_stats vs q02_daily_events 원본 쿼리 시간을 비교한다.

DROP TABLE IF EXISTS gharchive.daily_repo_stats;
DROP VIEW IF EXISTS gharchive.daily_repo_stats_mv;

CREATE TABLE gharchive.daily_repo_stats (
    day          Date,
    repo_name    String,
    event_type   LowCardinality(String),
    cnt          UInt64
)
ENGINE = SummingMergeTree(cnt)
ORDER BY (day, repo_name, event_type);

CREATE MATERIALIZED VIEW gharchive.daily_repo_stats_mv
TO gharchive.daily_repo_stats
AS SELECT
    toDate(created_at) AS day,
    repo_name,
    event_type,
    count() AS cnt
FROM gharchive.github_events
GROUP BY day, repo_name, event_type;

-- 기존 데이터 백필
INSERT INTO gharchive.daily_repo_stats
SELECT toDate(created_at), repo_name, event_type, count()
FROM gharchive.github_events
GROUP BY 1, 2, 3;
