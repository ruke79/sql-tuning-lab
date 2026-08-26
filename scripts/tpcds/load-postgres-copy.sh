#!/usr/bin/env bash
# 대용량 TPC-DS 데이터를 PostgreSQL COPY 로 고속 적재 (JDBC 배치보다 5~10배 빠름)
# dsdgen -parallel 로 분할된 store_sales_1_8.dat 같은 파일도 자동으로 모두 적재한다.
#
# 사용법: ./load-postgres-copy.sh [데이터디렉토리]
#
# 사용법:
#   ./load-postgres-copy.sh [데이터디렉토리] [옵션]
#
#   (옵션 없음)            적재 후 ANALYZE 수행 — **평소에는 이쪽**.
#                          §T-2 이후 대부분의 실습은 통계가 있어야 의미 있는 계획이 나온다.
#   --no-analyze           적재 후 ANALYZE 를 하지 않고, 대상 테이블의 autovacuum 도 끈다.
#                          §T-1 지점 A(통계 없는 상태)를 재기 위한 모드다.
#                          ANALYZE 만 건너뛰고 autovacuum 을 두면 길어야 1분 뒤 통계가
#                          생겨 버리므로(§T-0 ⑥ 실측), 둘을 같이 처리한다.
#   --restore-autovacuum   위에서 끈 autovacuum 을 되돌린다(적재는 하지 않는다).
#                          A 측정이 끝나면 반드시 실행할 것 — 안 그러면 §T-0 ⑤(VACUUM 이
#                          계획을 바꾸는 문제)가 대신 생긴다.
#
# 예)
#   ./load-postgres-copy.sh ./data/tpcds                       # 평소
#   ./load-postgres-copy.sh ./data/tpcds --no-analyze          # T-1 지점 A 준비
#   ./load-postgres-copy.sh --restore-autovacuum           # A 측정 후 원복
#
set -euo pipefail

DIR="./data/tpcds"
DO_ANALYZE=true
RESTORE_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --no-analyze)         DO_ANALYZE=false ;;
    --restore-autovacuum) RESTORE_ONLY=true ;;
    -*) echo "알 수 없는 옵션: $arg" >&2; exit 2 ;;
    *)  DIR="$arg" ;;
  esac
done
export PGPASSWORD=tuner
PSQL="psql -h localhost -U tuner -d tpcds -v ON_ERROR_STOP=1"

# 차원 → 팩트 순서
TABLES="date_dim item store customer_address customer_demographics household_demographics customer promotion store_sales"

set_autovacuum() {   # $1 = on|off
  for t in $TABLES; do
    $PSQL -c "ALTER TABLE $t SET (autovacuum_enabled = $1);" >/dev/null
  done
}

if [ "$RESTORE_ONLY" = true ]; then
  set_autovacuum on
  echo "autovacuum 을 다시 켰다 ($TABLES)"
  exit 0
fi

if [ "$DO_ANALYZE" = false ]; then
  # ANALYZE 를 건너뛰는 것만으로는 부족하다 — autovacuum 이 1분 뒤 통계를 만든다.
  set_autovacuum off
  echo "[--no-analyze] autovacuum 을 껐다. 적재 후에도 통계는 생기지 않는다."
fi

for t in $TABLES; do
  # {table}.dat 와 {table}_<child>_<parallel>.dat 만 매칭 (customer 가 customer_address 를 삼키지 않도록)
  files=$(find "$DIR" -maxdepth 1 -type f \
            \( -name "${t}.dat" -o -regex ".*/${t}_[0-9]+_[0-9]+\.dat" \) 2>/dev/null | sort || true)
  if [ -z "$files" ]; then
    echo "skip $t (파일 없음)"
    continue
  fi
  for f in $files; do
    echo "loading $t <- $(basename "$f")"
    # dsdgen 은 라인 끝에 '|' 가 하나 더 붙으므로 제거한 뒤 COPY
    # QUOTE 를 백스페이스로 지정해 따옴표를 일반 문자로 취급 (데이터에 " 가 들어있어도 안전)
    sed 's/|$//' "$f" | $PSQL -c "\\copy $t FROM STDIN WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')"
  done
done

if [ "$DO_ANALYZE" = true ]; then
  $PSQL -c "ANALYZE"
else
  echo
  echo "[--no-analyze] ANALYZE 를 건너뛰었고 autovacuum 도 꺼져 있다 — §T-1 지점 A 상태다."
  echo "  확인:  SELECT count(*) FROM pg_stats WHERE tablename = '$(echo $TABLES | awk '{print $NF}')';   -- 0 이어야 한다"
  echo "  원복:  $0 --restore-autovacuum        <- A 측정이 끝나면 반드시"
fi
echo "완료. 인덱스 생성: ./gradlew :tpcds:bootRun --args=\"index --db=postgres\""
