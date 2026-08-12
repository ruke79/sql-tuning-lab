-- Primary Key(ORDER BY) 정렬 비교 실험용 변형 테이블
-- created_at 선두: 시간 범위 쿼리에 유리 / event_type+repo 필터에 불리
-- 적재:  INSERT INTO gharchive.github_events_by_time SELECT * FROM gharchive.github_events

DROP TABLE IF EXISTS gharchive.github_events_by_time;

CREATE TABLE gharchive.github_events_by_time
AS gharchive.github_events
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at, repo_name);
