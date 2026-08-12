#!/usr/bin/env bash
# 대용량 TPC-DS 데이터를 PostgreSQL COPY 로 고속 적재 (JDBC 배치보다 5~10배 빠름)
# dsdgen -parallel 로 분할된 store_sales_1_8.dat 같은 파일도 자동으로 모두 적재한다.
#
# 사용법: ./load-postgres-copy.sh [데이터디렉토리]
set -euo pipefail

DIR="${1:-./data/tpcds}"
export PGPASSWORD=tuner
PSQL="psql -h localhost -U tuner -d tpcds -v ON_ERROR_STOP=1"

# 차원 → 팩트 순서
TABLES="date_dim item store customer_address customer_demographics household_demographics customer promotion store_sales"

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

$PSQL -c "ANALYZE"
echo "완료. 인덱스 생성: ./gradlew :tpcds:bootRun --args=\"index --db=postgres\""
