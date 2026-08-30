#!/usr/bin/env bash
# §T-2 (TPC-DS 판) — 진짜 전환점은 어디인가, 옵티마이저는 어디서 바꾸는가.
#
# t2-selectivity-sweep.sh 는 "옵티마이저가 무엇을 골랐는지"를 보여준다. 그런데 그 선택이
# **옳았는지는 별개 문제**다. 여기서는 두 방식을 강제로 각각 돌려 실측 승자를 가리고,
# 옵티마이저의 선택과 비교한다. 둘이 어긋나는 구간이 곧 손해 보는 구간이다.
#
# tpch 판과 다른 점: 스타 스키마에서는 필터가 차원(date_dim)에 걸리므로
# **차원 경유 형태**로도 같이 잰다. 팩트에 직접 거는 형태만 재면 실무와 동떨어진다.
#
# 사용법:
#   ./t2-crossover-verify.sh          # 각 조합 4회, 최소값 비교
#   ./t2-crossover-verify.sh 6        # 6회
#
# 선행 조건: schema → load → index
set -euo pipefail

REPEAT="${1:-4}"
TIMEOUT="${TIMEOUT:-60s}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

# work_mem — 큰 해시·정렬이 디스크로 넘치지 않게 **이 스크립트가 여는 세션에만** 건다.
# PGOPTIONS 는 libpq 환경변수라 psql 과 pgbench 모두에 전달된다.
# 서버 기본값은 건드리지 않는다 — 다른 실습의 측정 조건을 바꾸지 않기 위해서다.
#
# work_mem 은 **미리 잡아 두는 양이 아니라 상한**이다. 넘칠 일이 없으면 올려도
# 아무 일도 안 일어나고(200만 행 tpcds·SF=0.5 tpch 에서 64MB 와 4GB 가 동일),
# **넘기는 순간부터 지배적이 된다** — 해시가 디스크로 흘러 비용이 계단처럼 뛴다.
# 그 경계는 생각보다 낮다: t7 의 UNION 은 팩트 200만 행당 약 28.7MB 를 쓰므로
# 기본값 64MB 를 넘기는 지점이 약 457만 행이다(억 단위가 아니다).
# 넘치는지는 EXPLAIN 의 'Batches: N(N>1)' / 'Disk Usage' 로 판별한다.
#
# 다만 연산 노드당·병렬 워커당 붙으므로 RAM 이 작은 장비에서는 낮춰 잡을 것:
#   WORK_MEM=512MB ./<script>.sh
WORK_MEM="${WORK_MEM:-4096MB}"
export PGOPTIONS="-c work_mem=$WORK_MEM"

if command -v psql >/dev/null 2>&1; then
  run_sql()  { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -tAc "$1"; }
  run_file() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -q -f "$1"; }
else
  run_sql()  { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -tAc "$1"; }
  run_file() { docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -q < "$1"; }
fi

TOTAL=$(run_sql "SELECT count(*) FROM store_sales")
PAGES=$(run_sql "SELECT relpages FROM pg_class WHERE relname='store_sales'")
BASE=$(run_sql "SELECT min(d_date_sk) FROM date_dim WHERE d_date >= date '1998-01-01'")
echo "store_sales: $TOTAL 행 / $PAGES 페이지"
echo "각 조합을 ${REPEAT}회 실행한 최소값(ms) — 첫 회는 버린다(캐시 미충전)."
echo

timed() {  # $1 = SET 구문, $2 = 쿼리
  local tmp=/tmp/_t2x_ds.sql out
  { echo "\\set ON_ERROR_STOP on"; echo "\\timing on";
    echo "SET statement_timeout = '${TIMEOUT}';"; echo "$1";
    for _ in $(seq "$REPEAT"); do echo "$2;"; done; } > "$tmp"
  out=$(run_file "$tmp" 2>&1 || true)
  echo "$out" | grep -q "statement timeout" && { echo ">${TIMEOUT}"; return; }
  echo "$out" | grep -oE '^Time: [0-9.]+' | awk '{print $2}' \
    | tail -n $((REPEAT - 1)) | sort -n | head -1
}

sweep() {  # $1 = 라벨, $2 = 쿼리 템플릿 함수 이름
  printf "%-8s %8s %11s %11s   %-14s %s\n" "범위" "선택도" "인덱스경로" "SeqScan" "실측 승자" "옵티마이저 선택"
  printf "%s\n" "----------------------------------------------------------------------------------------"
  for D in 30 90 180 365 550 730; do
    local W Q M P TI TS WIN CHOSE
    if [ "$1" = "fact" ]; then
      W="ss_sold_date_sk >= $BASE AND ss_sold_date_sk < $BASE + $D"
      Q="SELECT sum(ss_ext_sales_price) FROM store_sales WHERE $W"
      M=$(run_sql "SELECT count(*) FROM store_sales WHERE $W")
    else
      W="d.d_date >= date '1998-01-01' AND d.d_date < date '1998-01-01' + $D"
      Q="SELECT sum(s.ss_ext_sales_price) FROM store_sales s JOIN date_dim d ON s.ss_sold_date_sk=d.d_date_sk WHERE $W"
      M=$(run_sql "SELECT count(*) FROM store_sales s JOIN date_dim d ON s.ss_sold_date_sk=d.d_date_sk WHERE $W")
    fi
    P=$(run_sql "SELECT round(100.0 * $M / $TOTAL, 2)")
    TI=$(timed "SET enable_seqscan=off;" "$Q")
    TS=$(timed "SET enable_indexscan=off; SET enable_bitmapscan=off;" "$Q")
    # 옵티마이저가 자연 상태에서 무엇을 골랐나 (팩트 노드 기준)
    CHOSE=$(run_sql "EXPLAIN $Q" | grep -E 'store_sales' \
            | grep -oE '(Parallel Seq Scan|Seq Scan|Parallel Index Scan|Index Scan|Bitmap Heap Scan|Index Only Scan)' | head -1)
    WIN=$(awk -v a="$TI" -v b="$TS" 'BEGIN{
            if (a ~ /^>/) {print "SeqScan"; exit}
            if (b ~ /^>/) {print "인덱스경로"; exit}
            printf (a+0 < b+0) ? "인덱스경로" : "SeqScan" }')
    printf "%-8s %7s%% %11s %11s   %-14s %s\n" "${D}일" "$P" "$TI" "$TS" "$WIN" "${CHOSE:-?}"
  done
}

echo "── ① 팩트 직접 (ss_sold_date_sk 범위) ──"
sweep fact
echo
echo "── ② 차원 경유 (date_dim 조인) ──"
sweep dim
echo
echo "해석:"
echo "  · '실측 승자'와 '옵티마이저 선택'이 어긋나는 행이 손해 구간이다."
echo "  · ①과 ②의 전환점 위치를 비교한다. 차원을 거치면 옵티마이저가 팩트 쪽 선택도를"
echo "    조인 전에 알 수 없어 더 일찍 Seq 로 넘어가는 경향이 있다."
echo "  · 여기서 나온 전환점은 이 장비·이 캐시 상태의 값이다. random_page_cost 와"
echo "    shared_buffers 를 바꾸면 이동한다(§T-2 tpch 판에서 실측)."
