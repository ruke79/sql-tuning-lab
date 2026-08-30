#!/usr/bin/env bash
# §T-8 실습: 조인키+필터 결합 인덱스가 NL 을 얼마나 살리는지 측정한다.
#
# Dan Tow 9장(Merged Join and Filter Index): 외래키와 필터 컬럼을 한 인덱스에 합치면
# 테이블(힙) 에 가기 전에 인덱스 수준에서 행을 버릴 수 있다.
# q03 의 lineitem probe 가 전체 LIO 의 60% 를 쓰는 것이 §T-5에서 확인됐고,
# 그 노드를 정조준하는 것이 이 실습이다.
#
# 확인할 것:
#   1) l_shipdate 가 Filter → Index Cond 로 올라가는가
#   2) Rows Removed by Filter 가 사라지는가
#   3) 그래서 NL 이 Hash 를 다시 이기는가
#   4) 커버링(INCLUDE)까지 가면 더 좋아지는가 — 어디서 멈춰야 하는가
#
# 사용법:
#   ./t8-combined-index.sh            # 기본 6라운드
#   ./t8-combined-index.sh 10         # 10라운드
#
# 이 스크립트는 조건들을 **한 라운드 안에서 교차(interleave)** 측정한다.
# 조건 A 를 N회, 그다음 조건 B 를 N회 재는 batch 방식은 그 사이의 시간대 드리프트를
# 조건 차이로 착각하게 만든다 — 실제로 이 실습에서 그 오판이 한 번 있었다(§T-0 원칙 6).
#
# 선행 조건: schema → load → index 완료 (+ VACUUM ANALYZE 권장)
set -uo pipefail

ROUNDS="${1:-6}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

HERE="$(cd "$(dirname "$0")" && pwd)"
for CAND in "$HERE/../../tpch/src/main/resources/queries/q03.sql" \
            "./tpch/src/main/resources/queries/q03.sql"; do
  [ -f "$CAND" ] && QFILE="$CAND" && break
done
if [ -z "${QFILE:-}" ]; then
  echo "q03.sql 을 찾을 수 없습니다."
  exit 1
fi
QUERY=$(grep -v '^\s*--' "$QFILE" | sed 's/;\s*$//' | tr '\n' ' ')

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
  run_sql() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q -tAc "$1"; }
else
  run_sql() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -X -q -tAc "$1"; }
fi

# 사전 점검
NIDX=$(run_sql "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND tablename='lineitem'" | tr -d ' ')
if [ "${NIDX:-0}" -lt 2 ]; then
  echo "  [경고] lineitem 인덱스가 부족합니다. 먼저 실행하세요:"
  echo "         ./gradlew :tpch:bootRun --args=\"index --db=postgres\""
  echo
fi

# 실행시간(ms) 1회
one() { run_sql "$1 EXPLAIN (ANALYZE, BUFFERS) $QUERY" | grep "Execution Time" | grep -oE "[0-9]+\.[0-9]+"; }

# 인덱스 상태 전환 ($1 = 만들 인덱스 DDL, 비우면 기본 상태)
setidx() {
  run_sql "SET client_min_messages=warning;
           DROP INDEX IF EXISTS idx_li_orderkey_shipdate; DROP INDEX IF EXISTS idx_li_cover;" >/dev/null 2>&1
  [ -n "$1" ] && run_sql "$1" >/dev/null 2>&1
  run_sql "ANALYZE lineitem;" >/dev/null 2>&1
}

IDX_COMBINED="CREATE INDEX idx_li_orderkey_shipdate ON lineitem (l_orderkey, l_shipdate)"
IDX_COVER="CREATE INDEX idx_li_cover ON lineitem (l_orderkey, l_shipdate) INCLUDE (l_extendedprice, l_discount)"

echo "§T-8 결합 인덱스 — ${ROUNDS}라운드 교차 측정"
echo

# ── 1) 계획이 어떻게 바뀌는지 먼저 보여준다 (이 실습의 핵심) ─────────────
echo "── lineitem probe 노드의 변화 ──"
for pair in "기본(lineitem_pkey)|" "결합 인덱스|$IDX_COMBINED" "커버링 인덱스|$IDX_COVER"; do
  label="${pair%%|*}"; ddl="${pair#*|}"
  setidx "$ddl"
  one "SET enable_nestloop=on;" >/dev/null   # 워밍업
  echo "[$label]"
  # lineitem 노드부터 그 노드의 Buffers 줄까지만 잘라낸다
  # (-A4 로 자르면 노드가 짧을 때 뒤따르는 Planning 의 Buffers 까지 딸려온다)
  run_sql "SET enable_nestloop=on; EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) $QUERY" \
    | awk '/on lineitem/{f=1} f{print; if(/Buffers: shared hit/) exit}' \
    | grep -E "on lineitem|Index Cond|Filter:|Rows Removed|Heap Fetches|Buffers: shared hit" \
    | sed 's/^ */  /'
  echo
done

# ── 2) 시간 측정 (교차) ────────────────────────────────────────────────
A=""; B=""; C=""; H=""
echo "── 측정 중 (${ROUNDS}라운드) ──"
for r in $(seq 1 "$ROUNDS"); do
  setidx "";            one "SET enable_nestloop=on;" >/dev/null
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
  | awk -v l="$2" '{a[NR]=$1} END{printf "%-28s min=%8.1f   median=%8.1f\n", l, a[1], a[int(NR/2)+1]}'; }

printf "%-28s %s\n" "조건" "실행시간(ms)"
printf "%s\n" "---------------------------------------------------------------"
stat "$A" "① NL, 결합 인덱스 없음"
stat "$B" "② NL + 결합 인덱스"
stat "$C" "③ NL + 커버링 인덱스"
stat "$H" "④ Hash (인덱스와 무관)"
echo
echo "해석:"
echo "  ①→② 에서 시간이 줄고 ②가 ④보다 빨라졌다면, 결합 인덱스가 조인 방식의 판정을 뒤집은 것이다."
echo "  ②→③ 의 이득이 작다면, 남은 비용은 B-tree 하강 자체이므로 ②에서 멈추는 것이 옳다."
echo "  (probe 74,024회 × 약 3 buffers ≈ 222,000 이 NL 의 하한이다)"
echo

# ── 3) 병목이 옮겨간 orders probe 에 같은 기법을 적용한다 ─────────────
echo "════════════════════════════════════════════════════════════════"
echo "이어서: orders probe (②를 적용하면 여기가 새 병목이 된다)"
echo "════════════════════════════════════════════════════════════════"
echo

setidx "$IDX_COMBINED"   # ② 상태로 고정
run_sql "SET client_min_messages=warning;
         DROP INDEX IF EXISTS idx_ord_custkey_orderdate;
         CREATE INDEX IF NOT EXISTS idx_orders_custkey ON orders(o_custkey);
         ANALYZE orders;" >/dev/null 2>&1
one "SET enable_nestloop=on;" >/dev/null

show_orders() {
  run_sql "SET enable_nestloop=on; EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) $QUERY" \
    | awk '/on orders/{f=1} f{print; if(/Buffers: shared hit/) exit}' \
    | grep -E "on orders|Index Cond|Filter:|Rows Removed|Buffers: shared hit" | sed 's/^ */  /'
}
echo "[개선 전]"; show_orders; echo

# 결합 인덱스를 만들어도 옵티마이저가 쓰지 않는다는 것을 보여준다
run_sql "CREATE INDEX idx_ord_custkey_orderdate ON orders (o_custkey, o_orderdate); ANALYZE orders;" >/dev/null 2>&1
one "SET enable_nestloop=on;" >/dev/null
echo "[결합 인덱스를 만든 직후 — 좁은 인덱스가 아직 남아 있음]"; show_orders
echo "  ↑ 만들었는데도 좁은 인덱스를 계속 쓴다면, 그것이 이 실습의 핵심이다."
echo "     추정 비용 차이가 2% 미만이라 더 작은 쪽이 이긴다:"
run_sql "EXPLAIN $QUERY" | grep -E "Index Scan.*orders" | sed 's/^ */       /'
echo

run_sql "SET client_min_messages=warning; DROP INDEX IF EXISTS idx_orders_custkey; ANALYZE orders;" >/dev/null 2>&1
one "SET enable_nestloop=on;" >/dev/null
echo "[좁은 인덱스를 지운 뒤]"; show_orders; echo

# orders 단계 시간 비교 (교차)
D=""; E=""
for r in $(seq 1 "$ROUNDS"); do
  run_sql "SET client_min_messages=warning; DROP INDEX IF EXISTS idx_ord_custkey_orderdate;
           CREATE INDEX IF NOT EXISTS idx_orders_custkey ON orders(o_custkey); ANALYZE orders;" >/dev/null 2>&1
  one "SET enable_nestloop=on;" >/dev/null
  D="$D $(one 'SET enable_nestloop=on;')"
  run_sql "SET client_min_messages=warning; DROP INDEX IF EXISTS idx_orders_custkey;
           CREATE INDEX IF NOT EXISTS idx_ord_custkey_orderdate ON orders(o_custkey,o_orderdate); ANALYZE orders;" >/dev/null 2>&1
  one "SET enable_nestloop=on;" >/dev/null
  E="$E $(one 'SET enable_nestloop=on;')"
  printf "."
done
echo; echo
stat "$D" "② orders 좁은 인덱스"
stat "$E" "③ orders 결합 인덱스"
echo
echo "해석:"
echo "  (A) 와 (A,B) 가 공존하면 PostgreSQL 은 '더 작다'는 이유로 좁은 쪽을 계속 고른다."
echo "  (A) 는 (A,B) 의 선행 부분집합이라 기능적으로 중복인데도 그렇다."
echo "  → 넓은 인덱스를 만들었다면 좁은 것을 반드시 지워야 한다."
echo
echo "정리:"
echo "  psql -d tpch -c \"DROP INDEX IF EXISTS idx_li_orderkey_shipdate, idx_li_cover,"
echo "                    idx_ord_custkey_orderdate;"
echo "                    CREATE INDEX IF NOT EXISTS idx_orders_custkey ON orders(o_custkey);\""
