#!/usr/bin/env bash
# ClickHouse 공식 github_events 데이터셋(30억 건+, 압축 약 75GB / RAW 300GB+) 적재
# 표 기준 "공식 s3 버킷에서 직접 Import" 방식.
#
# 주의: 전체 데이터는 디스크 200GB+ 와 수 시간이 필요하다.
# 소규모 실습은 Java 로더(gradle :clickhouse-lab:bootRun --args="load ...") 권장.
set -euo pipefail

C=tuninglab-clickhouse

# 공식 문서(https://ghe.clickhouse.tech/) 의 스키마+데이터 적재를 컨테이너 안에서 실행
docker exec -it "$C" clickhouse-client --user tuner --password tuner --multiquery --query "
CREATE DATABASE IF NOT EXISTS github;

-- 스키마/데이터: ClickHouse가 공개한 스냅샷 사용
-- (최신 안내는 https://ghe.clickhouse.tech/ 'How to build this yourself' 참고)
CREATE TABLE IF NOT EXISTS github.github_events ENGINE = MergeTree ORDER BY (event_type, repo_name, created_at)
AS SELECT * FROM s3('https://datasets-documentation.s3.eu-west-3.amazonaws.com/github/github_events.native.zst', 'Native')
LIMIT 0;

INSERT INTO github.github_events
SELECT * FROM s3('https://datasets-documentation.s3.eu-west-3.amazonaws.com/github/github_events.native.zst', 'Native');
"

echo "적재 완료. 확인: SELECT count() FROM github.github_events"
