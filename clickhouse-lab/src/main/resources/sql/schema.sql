-- GitHub Archive 이벤트 로그 - ClickHouse MergeTree
-- 단일 대용량 이벤트 테이블 (Columnar OLAP)
--
-- 튜닝 핵심:
--   ORDER BY (= Primary Key) 절이 데이터 정렬/스킵 인덱스를 결정한다.
--   schema-orderby-variant.sql 과 비교하여 같은 쿼리의 read granule 수 차이를 관찰할 것.

CREATE DATABASE IF NOT EXISTS gharchive;

DROP TABLE IF EXISTS gharchive.github_events;

CREATE TABLE gharchive.github_events (
    event_id     UInt64,
    event_type   LowCardinality(String),
    actor_login  String,
    repo_name    String,
    created_at   DateTime,
    action       LowCardinality(String),
    number       UInt32 DEFAULT 0,          -- issue/PR 번호
    title        String DEFAULT '',          -- issue/PR 제목
    language     LowCardinality(String) DEFAULT '',
    ref          String DEFAULT '',
    ref_type     LowCardinality(String) DEFAULT '',
    push_size    UInt16 DEFAULT 0,
    comment_len  UInt32 DEFAULT 0
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (event_type, repo_name, created_at);
