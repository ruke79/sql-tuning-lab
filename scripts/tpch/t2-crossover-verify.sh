#!/usr/bin/env bash
# §T-2 심화: "옵티마이저가 바꾼 지점"과 "실제로 빨라지는 지점"은 다르다.
#
# t2-selectivity-sweep.sh 는 옵티마이저가 *선택한* 계획을 보여준다.
# 이 스크립트는 각 범위에서 Bitmap 과 Seq Scan 을 **둘 다 강제 실행**해 직접 비교한다.
# 두 시간이 역전되는 지점이 이 하드웨어의 '진짜 교차점'이고,
# 옵티마이저가 계획을 바꾼 지점과의 차이가 곧 비용 모델의 오차다.
#
# 사용법: ./t2-crossover-verify.sh
#         TIMEOUT=5min ./t2-crossover-verify.sh    # 개별 실행 제한 (기본 60s)
# 선행 조건: schema → load → index 완료
set -uo pipefail

PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"
REPEAT="${REPEAT:-6}"
TIMEOUT="${TIMEOUT:-60s}"

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
  run_sql() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -tAc "$1"; }
  run_file() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -q -f "$1"; }
else
  run_sql() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -tAc "$1"; }
  run_file() { docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -q < "$1"; }
fi

TOTAL=$(run_sql "SELECT count(*) FROM lineitem")
PAGES=$(run_sql "SELECT relpages FROM pg_class WHERE relname='lineitem'")
echo "lineitem: $TOTAL 행 / $PAGES 페이지"
echo "각 조합을 ${REPEAT}회 실행한 최소값(ms). 최소값은 캐시가 가장 더워진 상태를 뜻한다."
echo

printf "%-10s %8s %9s  %10s %10s   %-18s %s\n" \
       "범위" "선택도" "읽은페이지" "Bitmap" "SeqScan" "실측 승자" "옵티마이저 선택"
printf "%s\n" "---------------------------------------------------------------------------------------------------"

timed() {  # $1 = SET 구문, $2 = 쿼리
  local tmp=/tmp/_t2x.sql out
  { echo "\set ON_ERROR_STOP on";
    echo "\timing on";
    echo "SET statement_timeout = '${TIMEOUT}';";
    echo "$1";
    for _ in $(seq "$REPEAT"); do echo "$2;"; done; } > "$tmp"
  out=$(run_file "$tmp" 2>&1 || true)
  if echo "$out" | grep -q "statement timeout"; then
    echo ">${TIMEOUT}"
    return
  fi
  echo "$out" | grep -oE '^Time: [0-9.]+' | awk '{print $2}' \
    | tail -n $((REPEAT - 1)) | sort -n | head -1
}

for IV in "1 month" "3 month" "6 month" "1 year" "18 month" "20 month" "2 year" "3 year"; do
  W="l_shipdate >= date '1994-01-01' AND l_shipdate < date '1994-01-01' + interval '$IV'"
  Q="SELECT sum(l_extendedprice * l_discount) FROM lineitem WHERE $W"

  MATCHED=$(run_sql "SELECT count(*) FROM lineitem WHERE $W")
  PCT=$(run_sql "SELECT round(100.0 * $MATCHED / $TOTAL, 2)")

  # 인덱스 기반(비트맵) 강제 / 순차 스캔 강제
  T_BITMAP=$(timed "SET enable_seqscan=off;" "$Q")
  T_SEQ=$(timed    "SET enable_bitmapscan=off; SET enable_indexscan=off;" "$Q")

  # 비트맵이 실제로 읽은 페이지 수
  RP=$(run_sql "SET enable_seqscan=off; EXPLAIN (ANALYZE,BUFFERS) $Q" \
        | grep -m1 -oE 'shared hit=[0-9]+' | grep -oE '[0-9]+')
  RPPCT=$(run_sql "SELECT round(100.0 * ${RP:-0} / $PAGES, 1)")

  CHOSEN=$(run_sql "EXPLAIN $Q" \
        | grep -oE '(Parallel Seq Scan|Seq Scan|Index Scan|Bitmap Heap Scan)' | head -1)

  # 한쪽이라도 시간초과면 배수 비교가 무의미하다 (문자열이 0으로 취급되어 오판됨)
  WINNER=$(awk -v b="$T_BITMAP" -v s="$T_SEQ" 'BEGIN {
      if (b !~ /^[0-9.]+$/ || s !~ /^[0-9.]+$/) { printf "비교불가(시간초과)" }
      else if (b+0 <= 0 || s+0 <= 0)           { printf "비교불가" }
      else if (b+0 <  s+0)                     { printf "Bitmap  (%.2fx)", s/b }
      else                                      { printf "SeqScan (%.2fx)", b/s } }')

  printf "%-10s %7s%% %8s%%  %9sms %9sms   %-18s %s\n" \
         "$IV" "$PCT" "$RPPCT" "$T_BITMAP" "$T_SEQ" "$WINNER" "$CHOSEN"
done

echo
echo "읽는 법:"
echo "  · '읽은페이지%' 가 100%에 가까워지면 비트맵 스캔은 이미 테이블 전체를 읽고 있다는 뜻이다."
echo "    그 위에 인덱스 탐색 + 비트맵 생성 비용이 더 얹히므로 순차 스캔보다 나을 수 없다."
echo "  · '실측 승자' 가 Bitmap → SeqScan 으로 뒤집히는 행이 이 하드웨어의 진짜 교차점이다."
echo "  · 그 행과 '옵티마이저 선택' 이 바뀌는 행이 다르면, 그 간격만큼 비용 모델이 어긋난 것이다."
echo "    (늦게 바꾸면 그 구간에서 손해를 보고 있다는 뜻 → random_page_cost 재조정 후보)"
