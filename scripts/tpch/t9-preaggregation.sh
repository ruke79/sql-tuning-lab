#!/usr/bin/env bash
# §T-9 실습: 인덱스로 못 넘는 벽을 모델 변경으로 넘는다.
#
# Dan Tow 10장: 선택적 필터가 조인 트리의 서로 다른 가지에 흩어져 있으면,
# 그 조합에 도달하기 전에 이미 큰 테이블을 다 헤집게 된다("분산된 필터").
# 처방은 두 가지다.
#   A. 필터 컬럼을 조인 트리 위로 끌어올려 한 테이블에 모은다 (반정규화)
#   B. 결과 자체를 미리 계산해 둔다 (사전 집계 / Materialized View)
#
# §T-8 에서 lineitem probe 228,320 buffers 가 인덱스로는 못 넘는 하한임을 확인했다
# (74,024회 B-tree 하강 자체). 이 스크립트는 그 벽을 넘는 것이 목적이다.
#
# 중요: 이 실습은 **대가를 같이 잰다.** 빨라진 것만 보고 끝내면 반쪽짜리다.
#   - 반정규화: 저장 증가 + 전파 비용(원본 1건 변경 → N행 갱신)
#   - MV: 갱신 비용 + 파라미터가 정의에 박혀 범용성을 잃는 것
#
# 사용법:
#   ./t9-preaggregation.sh          # 기본 8라운드
#   ./t9-preaggregation.sh 12
#
# 선행 조건: schema → load → index 완료
set -uo pipefail

ROUNDS="${1:-8}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

HERE="$(cd "$(dirname "$0")" && pwd)"
for CAND in "$HERE/../../tpch/src/main/resources/queries/q03.sql" \
            "./tpch/src/main/resources/queries/q03.sql"; do
  [ -f "$CAND" ] && QFILE="$CAND" && break
done
[ -z "${QFILE:-}" ] && { echo "q03.sql 을 찾을 수 없습니다."; exit 1; }
Q=$(grep -v '^\s*--' "$QFILE" | sed 's/;[[:space:]]*$//' | tr '\n' ' ')

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
  sql()  { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q -tAc "$1"; }
  sqlv() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q -c "$1"; }
else
  sql()  { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -X -q -tAc "$1"; }
  sqlv() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -X -q -c "$1"; }
fi

ms()  { sql "EXPLAIN (ANALYZE, BUFFERS) $1" | grep "Execution Time" | grep -oE "[0-9]+\.[0-9]+"; }
buf() { sql "EXPLAIN (ANALYZE, BUFFERS) $1" | grep -m1 -oE "hit=[0-9]+" | head -1; }
hash_of() { sql "SELECT md5(string_agg(l_orderkey||':'||round(revenue,2)||':'||o_orderdate||':'||o_shippriority,'|' ORDER BY revenue DESC, o_orderdate)) FROM ( $1 ) x"; }

echo "§T-9 사전 집계 / 필터 끌어올리기 — ${ROUNDS}라운드"
echo

# ── 1) 문제를 정량화한다 ──────────────────────────────────────────────
echo "── 분산된 필터: q03 의 필터는 3개 테이블에 흩어져 있다 ──"
sqlv "SELECT 'customer.c_mktsegment' AS 위치, round(count(*) FILTER (WHERE c_mktsegment='BUILDING')::numeric/count(*),4) AS 선택도 FROM customer
      UNION ALL SELECT 'orders.o_orderdate', round(count(*) FILTER (WHERE o_orderdate < date '1995-03-15')::numeric/count(*),4) FROM orders
      UNION ALL SELECT 'lineitem.l_shipdate', round(count(*) FILTER (WHERE l_shipdate > date '1995-03-15')::numeric/count(*),4) FROM lineitem;"
ACTUAL=$(sql "SELECT count(*) FROM customer, orders, lineitem WHERE c_mktsegment='BUILDING' AND c_custkey=o_custkey AND l_orderkey=o_orderkey AND o_orderdate < date '1995-03-15' AND l_shipdate > date '1995-03-15'")
echo "  독립 가정으로 곱하면 약 149,646 행이 나와야 하는데 실제는 ${ACTUAL} 행."
echo "  o_orderdate 와 l_shipdate 가 상관되어(주문 후 배송) 결합 선택도가 10배 강하다."
echo "  → 최종적으로 0.5% 만 필요한데, 필터가 흩어져 있어 그 조합에 도달하려면"
echo "     이미 큰 테이블을 다 헤집은 뒤여야 한다는 것이 문제의 본질이다."
echo

# ── 2) 해법 A: 필터를 한 테이블로 끌어올린다 ──────────────────────────
echo "── 해법 A: 반정규화 (필터 컬럼을 lineitem 쪽으로 상속) ──"
sql "SET client_min_messages=warning; DROP TABLE IF EXISTS lineitem_denorm;" >/dev/null 2>&1
sql "CREATE TABLE lineitem_denorm AS
     SELECT l.l_orderkey, l.l_extendedprice, l.l_discount, l.l_shipdate,
            c.c_mktsegment, o.o_orderdate, o.o_shippriority
     FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                     JOIN customer c ON o.o_custkey=c.c_custkey;" >/dev/null 2>&1
sql "CREATE INDEX idx_ld_filters ON lineitem_denorm (c_mktsegment, o_orderdate, l_shipdate); ANALYZE lineitem_denorm;" >/dev/null 2>&1

QD="select l_orderkey, sum(l_extendedprice*(1-l_discount)) as revenue, o_orderdate, o_shippriority
    from lineitem_denorm
    where c_mktsegment='BUILDING' and o_orderdate < date '1995-03-15' and l_shipdate > date '1995-03-15'
    group by l_orderkey, o_orderdate, o_shippriority
    order by revenue desc, o_orderdate limit 10"
ms "$QD" >/dev/null
sql "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) $QD" | grep -E "Bitmap Index Scan|Index Cond|Buffers: shared hit" | head -3 | sed 's/^ */  /'
echo "  ↑ 세 필터가 하나의 Index Cond 로 합쳐졌다. 조인은 0개."
echo

# ── 3) 해법 B: 결과를 사전 집계한다 ───────────────────────────────────
echo "── 해법 B: 사전 집계 (Materialized View) ──"
sql "SET client_min_messages=warning; DROP MATERIALIZED VIEW IF EXISTS mv_q03;" >/dev/null 2>&1
sql "CREATE MATERIALIZED VIEW mv_q03 AS
     select l_orderkey, sum(l_extendedprice*(1-l_discount)) as revenue, o_orderdate, o_shippriority
     from customer, orders, lineitem
     where c_mktsegment='BUILDING' and c_custkey=o_custkey and l_orderkey=o_orderkey
       and o_orderdate < date '1995-03-15' and l_shipdate > date '1995-03-15'
     group by l_orderkey, o_orderdate, o_shippriority;" >/dev/null 2>&1
sql "CREATE INDEX ON mv_q03 (revenue DESC, o_orderdate); ANALYZE mv_q03;" >/dev/null 2>&1
QM="select l_orderkey, revenue, o_orderdate, o_shippriority from mv_q03 order by revenue desc, o_orderdate limit 10"

# ── 4) 정합성 먼저 검증한다 (빨라도 답이 다르면 의미 없다) ────────────
echo "── 정합성 검증: 세 방식의 결과가 같은가 ──"
H1=$(hash_of "$Q"); H2=$(hash_of "$QD"); H3=$(hash_of "$QM")
printf "  원본     %s\n  반정규화 %s\n  사전집계 %s\n" "$H1" "$H2" "$H3"
if [ "$H1" = "$H2" ] && [ "$H2" = "$H3" ]; then echo "  ✓ 일치"; else echo "  ✗ 불일치 — 아래 측정은 의미 없다"; fi
echo

# ── 5) 시간 측정 (교차) ───────────────────────────────────────────────
BQ=$(buf "$Q"); BD=$(buf "$QD"); BM=$(buf "$QM")
A=""; B=""; C=""
for r in $(seq 1 "$ROUNDS"); do
  A="$A $(ms "$Q")"; B="$B $(ms "$QD")"; C="$C $(ms "$QM")"; printf "."
done
echo; echo
stat(){ echo "$1"|tr ' ' '\n'|grep -v '^$'|sort -g|awk -v l="$2" -v b="$3" '{a[NR]=$1} END{printf "%-26s %-12s min=%8.1f  median=%8.1f\n", l, b, a[1], a[int(NR/2)+1]}'; }
printf "%-26s %-12s %s\n" "방식" "buffers" "실행시간(ms)"
printf "%s\n" "----------------------------------------------------------------------------"
stat "$A" "① 조인 3개 (원본)"   "$BQ"
stat "$B" "④ 반정규화 (조인 0)" "$BD"
stat "$C" "⑤ 사전 집계 MV"      "$BM"
echo

# ── 6) 대가를 잰다 — 이게 없으면 반쪽짜리 결론이다 ────────────────────
echo "── 대가 ──"
sqlv "SELECT pg_size_pretty(pg_total_relation_size('lineitem_denorm')) AS 반정규화_저장,
             pg_size_pretty(pg_total_relation_size('mv_q03')) AS MV_저장,
             (SELECT round(count(*)::numeric/(SELECT count(*) FROM customer),1) FROM lineitem_denorm) AS 고객1건당_전파행수;"
echo "  전파 비용 실측 (고객 1명의 등급 변경):"
T1=$( { time -p sql "BEGIN; UPDATE customer SET c_mktsegment='MACHINERY' WHERE c_custkey=1; ROLLBACK;" >/dev/null; } 2>&1 | awk '/real/{printf "%.0f", $2*1000}')
T2=$( { time -p sql "BEGIN; UPDATE lineitem_denorm SET c_mktsegment='MACHINERY' WHERE l_orderkey IN (SELECT o_orderkey FROM orders WHERE o_custkey=1); ROLLBACK;" >/dev/null; } 2>&1 | awk '/real/{printf "%.0f", $2*1000}')
echo "    정규화(1행)      ${T1} ms"
echo "    반정규화(전파)   ${T2} ms"
echo "  MV 갱신 비용:"
T3=$( { time -p sql "REFRESH MATERIALIZED VIEW mv_q03;" >/dev/null; } 2>&1 | awk '/real/{printf "%.0f", $2*1000}')
echo "    REFRESH          ${T3} ms  (전량 재계산)"
echo
echo "  MV 의 근본 제약 — 파라미터가 정의에 박혀 있다:"
sql "SELECT substring(definition from 'o_orderdate < [^)]*') FROM pg_matviews WHERE matviewname='mv_q03'" | sed 's/^/    /'
echo "    → 날짜나 세그먼트가 바뀌면 이 MV 는 쓸 수 없다."
echo

echo "해석:"
echo "  §T-8 이 인덱스로 228,320 에서 멈춘 벽을, 모델을 바꾸니 한 번에 넘는다."
echo "  다만 순서를 지켜야 한다 — 인덱스로 되는 것을 반정규화로 풀면"
echo "  쓰기 비용 몇 배를 내고 몇 밀리초를 사는 나쁜 거래가 된다."
echo "  Tow 가 반정규화를 책 맨 마지막에 '다른 방법이 없을 때만'으로 못박은 이유다."
echo
# **직접 지운다.** 매트뷰는 원본 테이블에 의존하므로 남으면 schema 재적재가 통째로 막힌다
# (DROP TABLE lineitem 이 거절당하고, 모르고 load 를 이어 돌리면 '중복 키'라는 엉뚱한
#  에러로 나온다). 실제로 그렇게 막혔다 — 명령을 찍어 두는 것만으로는 부족했다.
echo "정리:"
if [ "${KEEP:-0}" = "1" ]; then
  echo "  KEEP=1 — mv_q03 / lineitem_denorm 을 남겨 둔다."
  echo "  ⚠️ 매트뷰가 남으면 schema 재적재가 막힌다. 다음 재적재 전에 지울 것:"
  echo "     psql -d tpch -c 'DROP MATERIALIZED VIEW IF EXISTS mv_q03; DROP TABLE IF EXISTS lineitem_denorm;'"
else
  sql "DROP MATERIALIZED VIEW IF EXISTS mv_q03; DROP TABLE IF EXISTS lineitem_denorm;" >/dev/null 2>&1
  LMV=$(sql "SELECT count(*) FROM pg_matviews WHERE matviewname='mv_q03'")
  echo "  mv_q03 / lineitem_denorm 을 지웠다.  남은 매트뷰 ${LMV}   (0 이어야 한다)"
fi
