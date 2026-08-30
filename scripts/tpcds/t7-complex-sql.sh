#!/usr/bin/env bash
# §T-7 실습 (TPC-DS 판) — 복잡한 SQL 의 세 가지 함정을 **실제로 밟아 본다.**
#
# Dan Tow 7장이 다루는 것은 "느린 쿼리"가 아니라 **틀린 쿼리**다.
# 셋 다 문법 오류가 없고, 셋 다 아무 경고 없이 조용히 다른 답을 내거나 낭비한다.
#
#   ① 아우터 조인의 필터 위치 : ON → WHERE 로 옮기면 LEFT JOIN 이 INNER JOIN 이 된다
#   ② NOT IN 의 NULL 함정      : NULL 한 건이 답을 전부 지운다 + Anti Join 을 못 쓴다
#   ③ UNION vs UNION ALL       : 중복이 없는데도 중복 제거를 시킨다
#
# tpch 판(§T-7 문서의 SQL)과 다른 점: 스타 스키마에서는 팩트가 크고 차원이 작아
# ②의 계획 차이(hashed SubPlan vs Anti Join)가 훨씬 크게 벌어진다.
#
# 사용법:
#   ./t7-complex-sql.sh          # 기본 3회 측정
#   ./t7-complex-sql.sh 5
#
# 선행 조건: tpcds schema → load → index (§0-4)
set -uo pipefail

REPEAT="${1:-3}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

if command -v psql >/dev/null 2>&1; then
  sql() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -X -q -tAc "$1"; }
else
  sql() { docker exec -e PGPASSWORD=tuner "$CONTAINER" psql -U tuner -d tpcds -X -q -tAc "$1"; }
fi

if ! sql "SELECT 1 FROM store_sales LIMIT 1" >/dev/null 2>&1; then
  echo "  store_sales 가 없습니다. §0-4 의 tpcds 준비 명령을 먼저 실행하세요."
  exit 1
fi

ms_of() { echo "$1" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+'; }
best_ms() {
  local Q="$1" b="" v
  sql "EXPLAIN (ANALYZE) $Q" >/dev/null 2>&1
  for _ in $(seq "$REPEAT"); do
    v=$(ms_of "$(sql "EXPLAIN (ANALYZE) $Q")")
    [ -z "$b" ] && b="$v" || b=$(awk -v a="$b" -v c="$v" 'BEGIN{print (c+0<a+0)?c:a}')
  done
  echo "$b"
}
node_of() { sql "EXPLAIN (COSTS OFF) $1" | grep -oE '(Parallel )?(Hash|Nested Loop|Merge) (Right |Left |Anti |Right Anti )?(Join|Anti Join)?' | head -1; }

echo "§T-7 복잡한 SQL 의 함정 — TPC-DS"
echo

# ══════════════════════════════════════════════════════════════════════
echo "── ① 아우터 조인의 필터 위치: ON 절 vs WHERE 절 ──"
echo "   \"매출이 있으면 이익 나는 건만, 없으면 없는 대로\" 를 뜻하는 질문이다."
echo

A="SELECT count(*) FROM customer c
     LEFT JOIN store_sales s ON c.c_customer_sk = s.ss_customer_sk AND s.ss_net_profit > 0"
B="SELECT count(*) FROM customer c
     LEFT JOIN store_sales s ON c.c_customer_sk = s.ss_customer_sk
    WHERE s.ss_net_profit > 0"

RA=$(sql "$A"); RB=$(sql "$B")
printf "  (a) 필터가 ON 절   결과 %10s 행   계획: %s\n" "$RA" "$(node_of "$A")"
printf "  (b) 필터가 WHERE   결과 %10s 행   계획: %s\n" "$RB" "$(node_of "$B")"
LOST=$(awk -v a="$RA" -v b="$RB" 'BEGIN{print a-b}')
echo
echo "  차이 ${LOST} 행 — 이만큼의 고객이 결과에서 조용히 사라졌다."
echo "  누가 사라졌는지 직접 본다:"
sql "SELECT '  · 매출 자체가 없는 고객: '||count(*) FROM customer c
     WHERE NOT EXISTS (SELECT 1 FROM store_sales s WHERE s.ss_customer_sk=c.c_customer_sk)"
sql "SELECT '  · 매출은 있으나 전부 이익 <= 0 인 고객: '||count(*) FROM customer c
     WHERE EXISTS (SELECT 1 FROM store_sales s WHERE s.ss_customer_sk=c.c_customer_sk)
       AND NOT EXISTS (SELECT 1 FROM store_sales s WHERE s.ss_customer_sk=c.c_customer_sk AND s.ss_net_profit>0)"
echo
echo "  핵심은 시간이 아니라 **계획 노드 이름**이다:"
echo "    (a) Hash Right Join  ← 아우터가 보존됨"
echo "    (b) Hash Join        ← 이너 조인으로 변질됨"
echo "  WHERE 절의 s.ss_net_profit > 0 은 NULL 로 채워진 행을 전부 탈락시킨다."
echo "  옵티마이저는 그것을 알고 아우터 조인 자체를 이너로 되돌린다(join strength reduction)."
echo "  → 에러도 경고도 없다. 행수를 세어 보지 않으면 영원히 모른다."
echo

# ══════════════════════════════════════════════════════════════════════
echo "── ② NOT IN vs NOT EXISTS ──"
echo

NI="SELECT count(*) FROM customer c WHERE c.c_customer_sk NOT IN (SELECT ss_customer_sk FROM store_sales)"
NE="SELECT count(*) FROM customer c WHERE NOT EXISTS (SELECT 1 FROM store_sales s WHERE s.ss_customer_sk = c.c_customer_sk)"

PNI=$(sql "EXPLAIN (COSTS OFF) $NI" | grep -oE '(hashed SubPlan|Anti Join|SubPlan)' | head -1)
PNE=$(sql "EXPLAIN (COSTS OFF) $NE" | grep -oE '(Nested Loop Anti Join|Hash Anti Join|Merge Anti Join)' | head -1)
TNI=$(best_ms "$NI"); TNE=$(best_ms "$NE")
printf "  %-14s %-26s %10s ms\n" "NOT IN"     "${PNI:-?}" "$TNI"
printf "  %-14s %-26s %10s ms\n" "NOT EXISTS" "${PNE:-?}" "$TNE"
printf "  → %sx 차이\n" "$(awk -v a="$TNE" -v b="$TNI" 'BEGIN{printf "%.1f", b/a}')"
echo
echo "  NOT IN 은 Anti Join 으로 변환되지 못한다. 이유는 성능이 아니라 **의미론**이다:"
echo "  서브쿼리에 NULL 이 한 건이라도 있으면 NOT IN 은 전체를 UNKNOWN 으로 만들어야 한다."
echo "  옵티마이저는 컬럼이 nullable 인 이상 그 가능성을 배제할 수 없어 안전한(느린) 길을 택한다."
echo
echo "  실제로 그런지 NULL 을 한 건 넣어 본다:"
sql "SET client_min_messages=warning;
     DROP TABLE IF EXISTS ss_probe;
     CREATE TABLE ss_probe AS SELECT ss_customer_sk FROM store_sales;" >/dev/null 2>&1
N0=$(sql "SELECT count(*) FROM customer c WHERE c.c_customer_sk NOT IN (SELECT ss_customer_sk FROM ss_probe)")
sql "INSERT INTO ss_probe VALUES (NULL)" >/dev/null 2>&1
N1=$(sql "SELECT count(*) FROM customer c WHERE c.c_customer_sk NOT IN (SELECT ss_customer_sk FROM ss_probe)")
N2=$(sql "SELECT count(*) FROM customer c WHERE NOT EXISTS (SELECT 1 FROM ss_probe p WHERE p.ss_customer_sk = c.c_customer_sk)")
sql "SET client_min_messages=warning; DROP TABLE IF EXISTS ss_probe;" >/dev/null 2>&1
printf "    NULL 0건  NOT IN     → %s 행\n" "$N0"
printf "    NULL 1건  NOT IN     → %s 행   ← 200만 건 중 단 1건의 NULL 이 답을 지웠다\n" "$N1"
printf "    NULL 1건  NOT EXISTS → %s 행   ← 영향 없음\n" "$N2"
echo
echo "  → NOT IN 은 느린 게 문제가 아니라 **틀릴 수 있는 것**이 문제다."
echo "     느린 것은 그 위험을 감수하느라 치르는 대가일 뿐이다."
echo

# ══════════════════════════════════════════════════════════════════════
echo "── ③ UNION vs UNION ALL ──"
echo
echo "   (가) 두 가지가 겹치는 경우 — 답이 다르므로 바꿔 쓰면 안 된다"
O1="SELECT ss_customer_sk FROM store_sales WHERE ss_store_sk=1"
O2="SELECT ss_customer_sk FROM store_sales WHERE ss_store_sk=2"
UO=$(sql "SELECT count(*) FROM ($O1 UNION $O2) x")
AO=$(sql "SELECT count(*) FROM ($O1 UNION ALL $O2) x")
TUO=$(best_ms "$O1 UNION $O2"); TAO=$(best_ms "$O1 UNION ALL $O2")
printf "     UNION     %10s 행  %9s ms\n" "$UO" "$TUO"
printf "     UNION ALL %10s 행  %9s ms   ← 행수가 다르다\n" "$AO" "$TAO"
echo
echo "   (나) 두 가지가 겹치지 않는 경우 — 답이 같은데 중복 제거만 한다"
D1="SELECT ss_item_sk, ss_ticket_number FROM store_sales WHERE ss_store_sk=1"
D2="SELECT ss_item_sk, ss_ticket_number FROM store_sales WHERE ss_store_sk=2"
UD=$(sql "SELECT count(*) FROM ($D1 UNION $D2) x")
AD=$(sql "SELECT count(*) FROM ($D1 UNION ALL $D2) x")
TUD=$(best_ms "$D1 UNION $D2"); TAD=$(best_ms "$D1 UNION ALL $D2")
printf "     UNION     %10s 행  %9s ms   (%s)\n" "$UD" "$TUD" "$(sql "EXPLAIN (COSTS OFF) $D1 UNION $D2" | head -1 | sed 's/^ *//')"
printf "     UNION ALL %10s 행  %9s ms   (%s)\n" "$AD" "$TAD" "$(sql "EXPLAIN (COSTS OFF) $D1 UNION ALL $D2" | head -1 | sed 's/^ *//')"
if [ "$UD" = "$AD" ]; then
  printf "     → 행수 동일. 중복 제거는 순수한 낭비이고 그 값이 %sx 다.\n" \
         "$(awk -v a="$TAD" -v b="$TUD" 'BEGIN{printf "%.2f", b/a}')"
fi
echo
echo "  해석:"
echo "    UNION → UNION ALL 은 **무조건 하는 치환이 아니다.** (가)에서는 답이 바뀐다."
echo "    쓸 수 있는 조건은 '분기들이 서로소임을 사람이 알고 있을 때' 뿐이고,"
echo "    옵티마이저는 그것을 알 방법이 없어 (나)에서도 성실하게 HashAggregate 를 돌린다."
echo "    Millsap 12장의 6.5시간 → 10.9초 사례가 정확히 (나) 유형이다 —"
echo "    분기가 서로소인 것을 개발자만 알고 있었고, DB 는 매번 전체를 정렬하고 있었다."
echo
echo "정리: 이 스크립트는 임시 테이블(ss_probe)을 만들고 스스로 지운다. 남는 것은 없다."
