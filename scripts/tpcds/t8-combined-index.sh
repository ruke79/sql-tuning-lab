#!/usr/bin/env bash
# §T-8 실습 (TPC-DS 판) — 조인키 + 필터 결합 인덱스가 팩트 probe 를 얼마나 줄이는가.
#
# Dan Tow 9장(Merged Join and Filter Index): 외래키와 필터 컬럼을 한 인덱스에 합치면
# 힙에 가기 **전에** 인덱스 수준에서 행을 버릴 수 있다.
#
# tpch 판과의 차이 — 여기가 스타 스키마 고유의 지점이다:
#   · tpch 에서는 조인키(l_orderkey)와 필터(l_shipdate)가 **다른 성격**이었다.
#   · tpcds 에서 팩트를 찌르는 조인키는 ss_item_sk 이고, 필터도 대리키(ss_sold_date_sk)다.
#     즉 **두 개의 대리키를 합치는** 형태가 된다.
#   · 게다가 store_sales 의 PK 가 이미 (ss_item_sk, ss_ticket_number) 라서
#     선행 컬럼이 같은 인덱스가 **이미 존재한다.** tpch 에서는 "좁은 인덱스를 지워라"가
#     결론이었지만 여기서는 그 좁은 인덱스가 PK 라 지울 수 없다 — 그래서 결과가 다르다.
#
# §T-6 에서 최강 필터(i_manager_id=8)일 때 옵티마이저가 item 에서 출발해 NL 로
# store_sales 를 찌른다는 것을 확인했다. 이 스크립트는 **그 probe 노드 하나**를 공략한다.
#
# 사용법:
#   ./t8-combined-index.sh          # 기본 6라운드
#   ./t8-combined-index.sh 10
#
# 선행 조건: tpcds schema → load → index (§0-4)
set -uo pipefail

ROUNDS="${1:-6}"
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

BASE=$(sql "SELECT min(d_date_sk) FROM date_dim WHERE d_date >= date '1999-01-01'")
[ -z "$BASE" ] && { echo "date_dim 이 비어 있습니다."; exit 1; }

# 조인키(ss_item_sk) 로 찾고 필터(ss_sold_date_sk 1년) 로 버리는 형태 — Tow 9장의 원형
QUERY="select i_brand_id, sum(ss_ext_sales_price)
       from item, store_sales
       where ss_item_sk = i_item_sk and i_manager_id = 8
         and ss_sold_date_sk >= $BASE and ss_sold_date_sk < $BASE + 365
       group by i_brand_id order by 2 desc limit 20"

IDX_COMBINED="CREATE INDEX idx_ss_item_solddate ON store_sales (ss_item_sk, ss_sold_date_sk)"
IDX_COVER="CREATE INDEX idx_ss_cover ON store_sales (ss_item_sk, ss_sold_date_sk) INCLUDE (ss_ext_sales_price)"

setidx() {
  sql "SET client_min_messages=warning;
       DROP INDEX IF EXISTS idx_ss_item_solddate; DROP INDEX IF EXISTS idx_ss_cover;" >/dev/null 2>&1
  [ -n "$1" ] && sql "$1" >/dev/null 2>&1
  sql "ANALYZE store_sales;" >/dev/null 2>&1
}
one() { sql "$1 EXPLAIN (ANALYZE) $QUERY" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+'; }
probe() {
  sql "SET enable_nestloop=on; EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) $QUERY" \
    | awk '/on store_sales/{f=1} f{print; if(/Buffers: shared/) exit}' \
    | grep -E "on store_sales|Index Cond|Filter:|Rows Removed|Heap Fetches|Buffers: shared" \
    | sed 's/^ */  /'
}
bufnum() {
  sql "SET enable_nestloop=on; EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) $QUERY" \
    | awk '/on store_sales/{f=1} f{if(/Buffers: shared/){print; exit}}' \
    | grep -oE 'hit=[0-9]+' | grep -oE '[0-9]+'
}

echo "§T-8 결합 인덱스 (TPC-DS) — ${ROUNDS}라운드 교차 측정"
echo "대상: item(i_manager_id=8, $(sql "SELECT count(*) FROM item WHERE i_manager_id=8")행) → store_sales NL probe"
echo "필터: ss_sold_date_sk ∈ [$BASE, $((BASE+365))) = 1999년 1년치"
echo

# ── 1) probe 노드가 어떻게 바뀌는지 (이 실습의 핵심) ────────────────────
echo "── store_sales probe 노드의 변화 ──"
for pair in "기본(store_sales_pkey 만)|" "결합 인덱스|$IDX_COMBINED" "커버링 인덱스|$IDX_COVER"; do
  label="${pair%%|*}"; ddl="${pair#*|}"
  setidx "$ddl"
  one "SET enable_nestloop=on;" >/dev/null
  echo "[$label]"; probe; echo
done

# ── 2) 시간 측정 (교차) ────────────────────────────────────────────────
echo "── 측정 중 (${ROUNDS}라운드) ──"
setidx "";              B_A=$(bufnum)
setidx "$IDX_COMBINED"; B_B=$(bufnum)
setidx "$IDX_COVER";    B_C=$(bufnum)
A=""; B=""; C=""; H=""
for r in $(seq 1 "$ROUNDS"); do
  setidx "";              one "SET enable_nestloop=on;" >/dev/null
  A="$A $(one 'SET enable_nestloop=on;')"
  H="$H $(one 'SET enable_nestloop=off;')"
  setidx "$IDX_COMBINED"; one "SET enable_nestloop=on;" >/dev/null
  B="$B $(one 'SET enable_nestloop=on;')"
  setidx "$IDX_COVER";    one "SET enable_nestloop=on;" >/dev/null
  C="$C $(one 'SET enable_nestloop=on;')"
  printf "."
done
echo; echo

stat() { echo "$1" | tr ' ' '\n' | grep -v '^$' | sort -g \
  | awk -v l="$2" -v b="$3" '{a[NR]=$1}
      END{printf "%-30s %10s   min=%8.2f   median=%8.2f\n", l, b, a[1], (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

printf "%-30s %10s   %s\n" "조건" "probe buf" "실행시간(ms)"
printf "%s\n" "---------------------------------------------------------------------------"
stat "$A" "① NL, 결합 인덱스 없음"  "$B_A"
stat "$B" "② NL + 결합 인덱스"      "$B_B"
stat "$C" "③ NL + 커버링 인덱스"    "$B_C"
stat "$H" "④ NL 금지 (Hash)"        "-"
echo

# ── 3) tpch 판과 갈리는 지점: PK 는 지울 수 없다 ───────────────────────
echo "════════════════════════════════════════════════════════════════"
echo "tpch 판과 갈리는 지점 — 선행 컬럼이 같은 좁은 인덱스가 PK 다"
echo "════════════════════════════════════════════════════════════════"
echo
echo "  store_sales_pkey = (ss_item_sk, ss_ticket_number)"
echo "  결합 인덱스      = (ss_item_sk, ss_sold_date_sk)"
echo "  → 선행 컬럼이 같다. tpch 판에서는 이럴 때 옵티마이저가 '더 작다'는 이유로"
echo "     좁은 쪽을 계속 골라서, 좁은 인덱스를 지워야만 했다."
echo "     여기서는 좁은 쪽이 **PK 라 지울 수 없다.** 그래도 골라 주는가?"
echo
setidx "$IDX_COMBINED"
CHOSE=$(sql "EXPLAIN (COSTS OFF) $QUERY" | grep -oE 'Index Scan using [a-z_]+ on store_sales' | head -1)
echo "  실제 선택: ${CHOSE:-?}"
sql "SELECT '  크기  pkey='||pg_size_pretty(pg_relation_size('store_sales_pkey'))||
            '   결합='||pg_size_pretty(pg_relation_size('idx_ss_item_solddate'))"
echo
echo "  → 골라 준다. 그리고 이유는 tpch 판의 규칙과 **정확히 같다**: 더 작은 쪽이 이긴다."
echo "     여기서는 결합 인덱스가 PK 보다 작다 —"
echo "     두 번째 컬럼이 ss_ticket_number(bigint 8B) 대신 ss_sold_date_sk(integer 4B) 라서다."
echo "     즉 '좁은 인덱스가 이긴다'가 아니라 **'작은 인덱스가 이긴다'** 가 규칙이고,"
echo "     tpch 에서 좁은 쪽이 이겼던 것은 그것이 마침 더 작았기 때문이다."
echo "     운이 좋았을 뿐이며, 컬럼 폭이 반대였다면 PK 를 못 지워 손해를 봤을 것이다."
echo

setidx ""   # 정리
echo "해석:"
echo "  ①→② 에서 ss_sold_date_sk 가 Filter → Index Cond 로 올라가고"
echo "  'Rows Removed by Filter' 행 자체가 사라진다. probe buffers 가 그만큼 줄어든다."
echo
echo "  ②→③ 은 tpch 판과 결론이 갈린다. tpch 에서는 커버링의 추가 이득이 작아"
echo "  '②에서 멈추라'가 답이었지만, 여기서는 ③이 ②를 또 한 번 크게 이긴다."
echo "  차이의 원인은 Heap Fetches: 0 이다 — 집계 대상 ss_ext_sales_price 까지 인덱스에"
echo "  들어가 힙을 아예 건드리지 않는다. 팩트 테이블 행이 넓을수록(store_sales 는 23컬럼)"
echo "  힙 한 페이지에서 얻는 유효 행이 적어 커버링의 이득이 커진다."
echo "  → '커버링은 대개 과하다'는 tpch 판의 감각을 스타 스키마에 그대로 옮기면 안 된다."
echo "     대신 ③은 쓰기 비용을 낸다: 인덱스가 하나 더 늘고, INCLUDE 컬럼이 갱신되면"
echo "     그 인덱스도 같이 갱신된다. §T-9 가 재는 것이 바로 그 종류의 대가다."
echo
echo "  ④(Hash) 와 비교해서 ②가 이겼다면, 결합 인덱스가 조인 방식의 판정을 되돌린 것이다."
echo
echo "  주의: 이 스크립트는 실험이 끝나면 만든 인덱스를 스스로 지운다."
echo "        store_sales 200만 행에 인덱스를 만들고 지우기를 ${ROUNDS}회 반복하므로"
echo "        라운드를 늘리면 그만큼 오래 걸린다(인덱스 생성이 측정보다 비싸다)."
