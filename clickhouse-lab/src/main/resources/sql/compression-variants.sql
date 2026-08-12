-- 컬럼 압축 코덱 비교 실험 (LZ4 vs ZSTD)
-- 적재 후 compare-compression 명령으로 system.columns 의 압축률을 비교한다.

DROP TABLE IF EXISTS gharchive.github_events_lz4;
DROP TABLE IF EXISTS gharchive.github_events_zstd;

CREATE TABLE gharchive.github_events_lz4 (
    event_id     UInt64       CODEC(LZ4),
    event_type   LowCardinality(String) CODEC(LZ4),
    actor_login  String       CODEC(LZ4),
    repo_name    String       CODEC(LZ4),
    created_at   DateTime     CODEC(DoubleDelta, LZ4),
    action       LowCardinality(String) CODEC(LZ4),
    number       UInt32       CODEC(LZ4),
    title        String       CODEC(LZ4),
    language     LowCardinality(String) CODEC(LZ4),
    ref          String       CODEC(LZ4),
    ref_type     LowCardinality(String) CODEC(LZ4),
    push_size    UInt16       CODEC(LZ4),
    comment_len  UInt32       CODEC(LZ4)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (event_type, repo_name, created_at);

CREATE TABLE gharchive.github_events_zstd (
    event_id     UInt64       CODEC(ZSTD(3)),
    event_type   LowCardinality(String) CODEC(ZSTD(3)),
    actor_login  String       CODEC(ZSTD(3)),
    repo_name    String       CODEC(ZSTD(3)),
    created_at   DateTime     CODEC(DoubleDelta, ZSTD(3)),
    action       LowCardinality(String) CODEC(ZSTD(3)),
    number       UInt32       CODEC(ZSTD(3)),
    title        String       CODEC(ZSTD(3)),
    language     LowCardinality(String) CODEC(ZSTD(3)),
    ref          String       CODEC(ZSTD(3)),
    ref_type     LowCardinality(String) CODEC(ZSTD(3)),
    push_size    UInt16       CODEC(ZSTD(3)),
    comment_len  UInt32       CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (event_type, repo_name, created_at);

INSERT INTO gharchive.github_events_lz4  SELECT * FROM gharchive.github_events;
INSERT INTO gharchive.github_events_zstd SELECT * FROM gharchive.github_events;
