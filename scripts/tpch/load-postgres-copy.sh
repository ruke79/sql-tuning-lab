#!/usr/bin/env bash
# 대용량 TPC-H 데이터를 PostgreSQL COPY 로 고속 적재 (JDBC 배치보다 5~10배 빠름)
# dbgen -C n -S i 로 분할된 lineitem.tbl.1 같은 파일도 자동으로 모두 적재한다.
#
# 사용법: ./load-postgres-copy.sh [데이터디렉토리]
#
# ⚠️ §T-1 지점 A(통계 없는 상태)를 측정할 거라면 이 스크립트를 쓰지 말 것.
#    맨 아래에서 ANALYZE 를 수행하므로 A 가 B(통계 있음)와 같아진다.
#    그때는 JDBC load 로 넣거나, 이 스크립트의 마지막 ANALYZE 줄만 빼고 돌린다.
#    추가로 autovacuum 도 꺼야 한다 — 안 끄면 길어야 1분 뒤 통계가 생긴다:
#      ALTER TABLE lineitem SET (autovacuum_enabled = off);   -- 측정 후 되돌릴 것
#    자세한 내용은 docs 매핑 문서 §T-0 ⑥ 참고.
set -euo pipefail

DIR="${1:-./data/tpch}"
export PGPASSWORD=tuner
PSQL="psql -h localhost -U tuner -d tpch -v ON_ERROR_STOP=1"

for t in region nation supplier customer part partsupp orders lineitem; do
  files=$(find "$DIR" -maxdepth 1 -type f \
            \( -name "${t}.tbl" -o -name "${t}.tbl.[0-9]*" \) 2>/dev/null | sort || true)
  if [ -z "$files" ]; then
    echo "skip $t (파일 없음)"
    continue
  fi
  for f in $files; do
    echo "loading $t <- $(basename "$f")"
    # dbgen 은 라인 끝에 '|' 를 하나 더 붙이므로 제거한 뒤 COPY.
    # QUOTE 를 백스페이스로 지정해 따옴표를 일반 문자로 취급 (데이터에 " 가 있어도 안전).
    sed 's/|$//' "$f" | $PSQL -c "\\copy $t FROM STDIN WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')"
  done
done

# 운영에서는 옳지만 §T-1 지점 A 측정에서는 이 줄이 실험을 깨뜨린다(§T-0 ⑥).
$PSQL -c "ANALYZE"
echo "완료. 인덱스 생성: ./gradlew :tpch:bootRun --args=\"index --db=postgres\""
