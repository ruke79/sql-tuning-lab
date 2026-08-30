#!/usr/bin/env bash
# §T-2 (TPC-DS 판) — 선택도에 따라 스캔 방식이 어디서 뒤집히는가.
#
# tpch 판(scripts/tpch/t2-selectivity-sweep.sh)은 lineitem.l_shipdate 라는 **날짜 컬럼에
# 직접** 범위 필터를 건다. 그런데 스타 스키마에는 그런 컬럼이 없다 —
# store_sales 가 가진 것은 날짜가 아니라 **대리키 ss_sold_date_sk** 이고,
# 사람이 쓰는 조건("1998년 3월")은 date_dim 을 거쳐야 한다.
#
# 그래서 이 스크립트는 같은 범위를 **두 가지 방법**으로 걸어 비교한다.
#   ① 팩트 직접 : WHERE ss_sold_date_sk BETWEEN ... AND ...      (대리키를 직접 안다고 가정)
#   ② 차원 경유 : JOIN date_dim ... WHERE d_date BETWEEN ...      (실무에서 실제로 쓰는 형태)
#
# 두 방법은 **같은 행을 읽는데 계획이 다르게 나올 수 있다.** 그 차이가 스타 스키마 튜닝의
# 출발점이며, §T-6(쿼리 다이어그램)에서 다룰 내용의 예고편이다.
#
# 사용법:
#   ./t2-selectivity-sweep.sh            # 현재 random_page_cost
#   ./t2-selectivity-sweep.sh 4.0        # random_page_cost=4.0 (HDD 가정) 비교
#
# 선행 조건: schema → load → index (§0-4 참고). 통계가 있어야 의미가 있다.
set -euo pipefail

RPC="${1:-}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

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
  run_sql() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -tAc "$1"; }
else
  run_sql() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -tAc "$1"; }
fi

SETUP=""
[ -n "$RPC" ] && SETUP="SET random_page_cost = $RPC; "

TOTAL=$(run_sql "SELECT count(*) FROM store_sales")
BASE=$(run_sql "SELECT min(d_date_sk) FROM date_dim WHERE d_date >= date '1998-01-01'")
echo "store_sales 총 행수: $TOTAL   (기준 d_date_sk=$BASE = 1998-01-01)"
[ -n "$RPC" ] && echo "random_page_cost = $RPC (오버라이드)"
echo

scan_of() { echo "$1" | grep -oE '(Parallel Seq Scan|Seq Scan|Parallel Index Scan|Index Scan|Bitmap Heap Scan|Index Only Scan)' | head -1; }
buf_of()  { echo "$1" | grep -m1 -oE 'shared hit=[0-9]+( read=[0-9]+)?' | sed 's/shared //'; }
ms_of()   { echo "$1" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+'; }

echo "── ① 팩트 직접: WHERE ss_sold_date_sk BETWEEN ... ──"
printf "%-10s %12s %8s  %-24s %14s %10s\n" "범위" "조회행수" "선택도" "스캔 방식" "buffers" "시간(ms)"
printf "%s\n" "--------------------------------------------------------------------------------------"
for D in 1 7 30 90 180 365 550 730 1095 1826; do
  W="ss_sold_date_sk >= $BASE AND ss_sold_date_sk < $BASE + $D"
  M=$(run_sql "SELECT count(*) FROM store_sales WHERE $W")
  P=$(run_sql "SELECT round(100.0 * $M / $TOTAL, 3)")
  Q="SELECT sum(ss_ext_sales_price) FROM store_sales WHERE $W"
  run_sql "$SETUP$Q" > /dev/null
  PLAN=$(run_sql "${SETUP}EXPLAIN (ANALYZE, BUFFERS) $Q")
  printf "%-10s %12s %7s%%  %-24s %14s %10s\n" \
         "${D}일" "$M" "$P" "$(scan_of "$PLAN")" "$(buf_of "$PLAN")" "$(ms_of "$PLAN")"
done
echo

echo "── ② 차원 경유: JOIN date_dim ON ... WHERE d_date BETWEEN ... ──"
echo "   (같은 행을 고르지만, 옵티마이저는 팩트 테이블의 선택도를 **추정**해야 한다)"
printf "%-10s %12s %8s  %-24s %14s %10s\n" "범위" "조회행수" "선택도" "팩트 스캔 방식" "buffers" "시간(ms)"
printf "%s\n" "--------------------------------------------------------------------------------------"
for D in 1 7 30 90 180 365 550 730 1095 1826; do
  W="d.d_date >= date '1998-01-01' AND d.d_date < date '1998-01-01' + $D"
  M=$(run_sql "SELECT count(*) FROM store_sales s JOIN date_dim d ON s.ss_sold_date_sk=d.d_date_sk WHERE $W")
  P=$(run_sql "SELECT round(100.0 * $M / $TOTAL, 3)")
  Q="SELECT sum(s.ss_ext_sales_price) FROM store_sales s JOIN date_dim d ON s.ss_sold_date_sk=d.d_date_sk WHERE $W"
  run_sql "$SETUP$Q" > /dev/null
  PLAN=$(run_sql "${SETUP}EXPLAIN (ANALYZE, BUFFERS) $Q")
  # 팩트 테이블 쪽 노드만 본다 (date_dim 스캔은 어차피 작다)
  FACT=$(echo "$PLAN" | grep -E 'on store_sales' | grep -oE '(Parallel Seq Scan|Seq Scan|Parallel Index Scan|Index Scan|Bitmap Heap Scan|Index Only Scan)' | head -1)
  printf "%-10s %12s %7s%%  %-24s %14s %10s\n" \
         "${D}일" "$M" "$P" "${FACT:-?}" "$(buf_of "$PLAN")" "$(ms_of "$PLAN")"
done
echo

echo "해석:"
echo "  · ①에서 전환점을 찾는다. 인덱스 → Bitmap → Seq 로 바뀌는 선택도 구간이 그것이다."
echo "  · ②를 ①과 비교한다. 같은 행수인데 **차원을 거치면 전환점이 앞당겨지는** 경향이 있다 —"
echo "    옵티마이저가 팩트 쪽 선택도를 조인 전에 알 수 없어 보수적으로 잡기 때문이다."
echo "  · 실무 쿼리는 대부분 ② 형태다. ①만 보고 '인덱스가 잘 듣는다'고 판단하면 안 된다."
echo "  · random_page_cost 를 바꿔 다시 돌리면 전환점이 통째로 이동한다 —"
echo "    전환점은 데이터의 성질이 아니라 **비용 모델 파라미터의 함수**다."
