#!/usr/bin/env bash
# §T-2 실습 자동화: 조회 범위를 넓혀가며 Index Scan → Seq Scan 전환점을 찾는다.
#
# Dan Tow 《SQL Tuning》 2장: "전체의 20% 초과면 풀스캔, 0.5% 미만이면 인덱스"
# 그 전환점이 내 하드웨어/설정에서 실제로 몇 %인지 직접 측정하는 것이 목적이다.
#
# 사용법:
#   ./t2-selectivity-sweep.sh                      # 기본 (random_page_cost 현재값)
#   ./t2-selectivity-sweep.sh 4.0                  # random_page_cost=4.0 (HDD 가정)으로 비교
#
# 선행 조건: tpch 스키마 + 데이터 적재 + index 명령까지 완료된 상태
set -euo pipefail

RPC="${1:-}"                       # random_page_cost 오버라이드 (선택)
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

# psql 이 로컬에 있으면 직접, 없으면 docker exec 로 실행
# work_mem — 큰 해시·정렬이 디스크로 넘치지 않게 **이 스크립트가 여는 세션에만** 건다.
# PGOPTIONS 는 libpq 환경변수라 psql 과 pgbench 모두에 전달된다.
# 서버 기본값은 건드리지 않는다 — 다른 실습의 측정 조건을 바꾸지 않기 위해서다.
#
# work_mem 은 **미리 잡아 두는 양이 아니라 상한**이다. 넘칠 일이 없으면 올려도
# 아무 일도 안 일어난다(SF=0.5 tpch·200만 행 tpcds 에서 Batches:1 / Memory Usage 동일 확인).
# 다만 연산 노드당·병렬 워커당 붙으므로 RAM 이 작은 장비에서는 낮춰 잡을 것:
#   WORK_MEM=512MB ./<script>.sh
WORK_MEM="${WORK_MEM:-4096MB}"
export PGOPTIONS="-c work_mem=$WORK_MEM"

if command -v psql >/dev/null 2>&1; then
  run_sql() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -tAc "$1"; }
else
  run_sql() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -tAc "$1"; }
fi

SETUP=""
[ -n "$RPC" ] && SETUP="SET random_page_cost = $RPC; "

TOTAL=$(run_sql "SELECT count(*) FROM lineitem")
echo "lineitem 총 행수: $TOTAL"
[ -n "$RPC" ] && echo "random_page_cost = $RPC (오버라이드)"
echo
printf "%-10s %12s %8s  %-26s %12s %10s\n" \
       "범위" "조회행수" "선택도" "스캔 방식" "buffers" "시간(ms)"
printf "%s\n" "------------------------------------------------------------------------------------------"

for IV in "1 day" "15 day" "1 month" "3 month" "6 month" "1 year" "18 month" "20 month" "2 year" "3 year"; do
  WHERE="l_shipdate >= date '1994-01-01' AND l_shipdate < date '1994-01-01' + interval '$IV'"

  MATCHED=$(run_sql "SELECT count(*) FROM lineitem WHERE $WHERE")
  PCT=$(run_sql "SELECT round(100.0 * $MATCHED / $TOTAL, 3)")

  Q="SELECT sum(l_extendedprice * l_discount) FROM lineitem WHERE $WHERE"

  # 워밍업 1회 (캐시 상태를 맞춰 공정하게 비교)
  run_sql "$SETUP$Q" > /dev/null

  PLAN=$(run_sql "${SETUP}EXPLAIN (ANALYZE, BUFFERS) $Q")
  SCAN=$(echo "$PLAN" | grep -oE '(Parallel Seq Scan|Seq Scan|Parallel Index Scan|Index Scan|Bitmap Heap Scan|Index Only Scan)' | head -1)
  BUF=$(echo "$PLAN"  | grep -m1 -oE 'shared hit=[0-9]+( read=[0-9]+)?' | sed 's/shared //')
  MS=$(echo "$PLAN"   | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+')
  JIT=$(echo "$PLAN"  | grep -qE '^JIT:' && echo " +JIT" || echo "")

  printf "%-10s %12s %7s%%  %-26s %12s %10s%s\n" \
         "$IV" "$MATCHED" "$PCT" "$SCAN" "$BUF" "$MS" "$JIT"
done

echo
echo "물리적 상관도 (correlation: 1.0 = 인덱스 순서와 저장 순서 일치, 0 = 완전 분산):"
run_sql "SELECT '  ' || attname || ' = ' || round(correlation::numeric, 4)
         FROM pg_stats WHERE tablename='lineitem'
           AND attname IN ('l_shipdate','l_orderkey') ORDER BY attname"

echo
echo "관찰 포인트:"
echo "  · 스캔 방식이 Index Scan → Bitmap Heap Scan → Parallel Seq Scan 으로"
echo "    넘어가는 선택도를 기록한다. 그 값이 이 하드웨어/설정에서의 '진짜 전환점'이다."
echo "  · 책의 0.5% / 20% 기준과 얼마나 다른가?"
echo "  · l_shipdate 의 correlation 이 0에 가까우면 인덱스 순서와 저장 순서가 무관하다는 뜻이다."
echo "    그래서 좁은 범위를 빼면 plain Index Scan 대신 Bitmap Heap Scan 이 선택된다."
echo "    (비트맵 스캔은 TID 를 미리 정렬해 랜덤 접근을 순차 접근으로 바꾸는 기법으로,"
echo "     2003년 책이 말한 '0.5%~20% 회색지대'에 대한 현대 옵티마이저의 답이다)"
echo "  · ./t2-selectivity-sweep.sh 4.0 으로 다시 돌려 HDD 가정과 전환점을 비교한다."
