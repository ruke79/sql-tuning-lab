#!/usr/bin/env bash
# 멀티테넌시 분리 훈련 (TPC-H 판) — **테넌트 키가 팩트 테이블에 없을 때** 무엇이 달라지는가.
#
# tpcds 판(scripts/tpcds/mt-tenant-isolation.sh)과 같은 질문을 하지만 출발점이 다르다.
#
#   tpcds: 테넌트(매장)가 팩트에 **직접** 있다 — store_sales.ss_store_sk
#          → RLS 정책도, 파티션 키도, 복합 인덱스도 바로 쓸 수 있다.
#   tpch : 테넌트(국가)가 팩트에서 **2조인 떨어져 있다**
#          → lineitem → orders(o_custkey) → customer(c_nationkey) → nation
#          → RLS 정책을 쓸 컬럼이 **없다**. 파티션 키로 쓸 컬럼도 없다.
#
# 그래서 tpch 판의 첫 질문은 "어느 전략이 나은가"가 아니라
# **"격리를 논하기 전에 무엇을 먼저 지불해야 하는가"** 다. 답은 §T-9 의 그것 —
# 비정규화다. 이 스크립트는 그 입장료를 재고, 지불한 뒤에 무엇이 열리는지 본다.
#
#   N. 정규화 그대로      격리: 애플리케이션이 매번 2조인을 붙인다 (RLS 불가)
#   A. 비정규화           lineitem 에 l_nationkey 를 내린다 → 여기서부터 tpcds 의 A 와 같다
#   B. 비정규화 + LIST 파티션
#   C. 테넌트별 스키마 (25개)
#
# 재는 것:
#   ① 테넌트 범위 조회   — 2조인이 얼마나 비싼가, 비정규화가 그것을 얼마나 줄이는가
#   ② 비정규화 입장료     — 백필 시간·저장 증가 (§T-9 와 같은 계산, 다른 목적)
#   ③ RLS 가능성          — 정규화 상태에서는 **구조적으로 불가능**하다는 것을 보인다
#   ④ WHERE 누락 유출     — 전략별로 조건을 빼먹은 조회가 무엇을 돌려주는가
#   ⑤ 테넌트 이동         — **tpch 고유.** 매장은 안 움직이지만 고객은 국가를 옮긴다.
#                          파티션에서는 행이 파티션을 넘고, 옛 테넌트 키를 모르면 프루닝이 안 된다.
#   ⑥ 교차 테넌트 집계    — "전 국가 매출"이 전략마다 어떤 모양이 되는가
#
# 사용법:
#   ./mt-tenant-isolation.sh            # 전부, 각 측정 4회 최소값
#   ./mt-tenant-isolation.sh 6
#   ONLY=125 ./mt-tenant-isolation.sh   # ①②⑤만
#   KEEP=1 ./mt-tenant-isolation.sh     # 실험 객체를 남겨 둔다
#
# 선행 조건: tpch schema → load → index (§0-4). 없으면 ./scripts/restore-lab.sh
set -uo pipefail

REPEAT="${1:-4}"
ONLY="${ONLY:-123456}"
want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

WORK_MEM="${WORK_MEM:-4096MB}"
export PGOPTIONS="-c work_mem=$WORK_MEM"
export PGPASSWORD=tuner

if command -v psql >/dev/null 2>&1; then
  sql()  { psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q -tAc "$1"; }
  sqlv() { psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q -c "$1"; }
else
  sql()  { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -X -q -tAc "$1"; }
  sqlv() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -X -q -c "$1"; }
fi

if ! sql "SELECT 1 FROM lineitem LIMIT 1" >/dev/null 2>&1; then
  echo "  lineitem 이 없습니다. ./scripts/restore-lab.sh 를 먼저 실행하세요."; exit 1
fi

ms_of() { echo "$1" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+'; }
best_ms() {
  local pre="$1" Q="$2" b="" v
  sql "$pre EXPLAIN (ANALYZE) $Q" >/dev/null 2>&1
  for _ in $(seq "$REPEAT"); do
    v=$(ms_of "$(sql "$pre EXPLAIN (ANALYZE) $Q")")
    [ -z "$v" ] && continue
    [ -z "$b" ] && b="$v" || b=$(awk -v a="$b" -v c="$v" 'BEGIN{print (c+0<a+0)?c:a}')
  done
  echo "${b:-?}"
}
scan_of() { sql "$1 EXPLAIN (COSTS OFF) $2" | grep -oE '(Parallel )?(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan) (using [a-z0-9_]+ )?on [a-z0-9_.]+' | head -1; }
bufs_of() { sql "$1 EXPLAIN (ANALYZE, BUFFERS) $2" | grep -m1 -oE 'shared hit=[0-9]+( read=[0-9]+)?' | sed 's/shared //'; }
joins_of() { sql "EXPLAIN (COSTS OFF) $1" | grep -cE 'Nested Loop|Hash Join|Merge Join'; }

# tpcds 판의 teardown 버그를 그대로 답습하지 않는다 — 문장을 따로 보낸다.
# 한 -c 에 몰면 뒤의 실패가 앞의 DROP 까지 롤백시켜 정리가 조용히 안 된다.
teardown() {
  sql "SET client_min_messages=warning; DROP TABLE IF EXISTS li_mt CASCADE" >/dev/null 2>&1
  sql "SET client_min_messages=warning; DROP TABLE IF EXISTS li_part CASCADE" >/dev/null 2>&1
  sql "DO \$\$ DECLARE s text; BEGIN
         FOR s IN SELECT nspname FROM pg_namespace WHERE nspname LIKE 'mt_n%' LOOP
           EXECUTE 'DROP SCHEMA '||quote_ident(s)||' CASCADE'; END LOOP; END \$\$" >/dev/null 2>&1
  sql "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mt_app_tpch') THEN
         EXECUTE 'DROP OWNED BY mt_app_tpch'; EXECUTE 'DROP ROLE mt_app_tpch'; END IF; END \$\$" >/dev/null 2>&1
}

NT=$(sql "SELECT count(*) FROM nation")
T_ME=3; T_OTHER=7
NLI=$(sql "SELECT count(*) FROM lineitem")

echo "멀티테넌시 분리 훈련 (TPC-H) — 테넌트 ${NT}개(국가), lineitem ${NLI} 행, 각 측정 ${REPEAT}회 최소값"
echo "질문: \"국가 ${T_ME} 고객들의 매출 합계\""
echo
echo "  ※ tpcds 판과 다른 출발점: lineitem 에는 국가 컬럼이 **없다.**"
echo "     경로는 lineitem → orders(o_custkey) → customer(c_nationkey) 로 2조인이다."
echo

# ══════════════════════════════════════════════════════════════════════
# 준비
# ══════════════════════════════════════════════════════════════════════
echo "── 준비 ──"
teardown
T0=$(date +%s)

# A. 비정규화 — 테넌트 키(l_nationkey)를 팩트로 내린다.
#    o_custkey 도 같이 내린다: ⑤의 테넌트 이동이 "이 고객의 행"을 찾아야 하기 때문이다.
#    (원본 키 l_orderkey·l_linenumber 도 유지 — 없으면 행을 특정할 수 없다, §T-9 의 그 교훈)
sql "CREATE TABLE li_mt AS
       SELECT l.l_orderkey, l.l_linenumber, l.l_partkey, l.l_suppkey, l.l_quantity,
              l.l_extendedprice, l.l_discount, l.l_shipdate,
              c.c_nationkey AS l_nationkey, o.o_custkey
       FROM lineitem l JOIN orders o ON l.l_orderkey = o.o_orderkey
                       JOIN customer c ON o.o_custkey = c.c_custkey;
     CREATE INDEX ON li_mt (l_nationkey, l_shipdate);
     CREATE INDEX ON li_mt (o_custkey);
     ANALYZE li_mt;" >/dev/null 2>&1
TA=$(date +%s)

# B. LIST 파티션
PARTS=""
for n in $(seq 0 $((NT-1))); do PARTS="$PARTS CREATE TABLE li_p_$n PARTITION OF li_part FOR VALUES IN ($n);"; done
sql "CREATE TABLE li_part (LIKE li_mt) PARTITION BY LIST (l_nationkey);
     $PARTS
     INSERT INTO li_part SELECT * FROM li_mt;
     CREATE INDEX ON li_part (l_shipdate);
     CREATE INDEX ON li_part (o_custkey);
     ANALYZE li_part;" >/dev/null 2>&1
TB=$(date +%s)

# C. 테넌트별 스키마
SCH=""
for n in $(seq 0 $((NT-1))); do
  SCH="$SCH CREATE SCHEMA mt_n$n;
       CREATE TABLE mt_n$n.lineitem AS SELECT * FROM li_mt WHERE l_nationkey=$n;
       CREATE INDEX ON mt_n$n.lineitem (l_shipdate);
       ANALYZE mt_n$n.lineitem;"
done
sql "$SCH" >/dev/null 2>&1
TC=$(date +%s)

sql "CREATE ROLE mt_app_tpch NOLOGIN;
     GRANT USAGE ON SCHEMA public TO mt_app_tpch;
     GRANT SELECT ON li_mt, li_part, lineitem, orders, customer TO mt_app_tpch;
     ALTER TABLE li_mt ENABLE ROW LEVEL SECURITY;
     ALTER TABLE li_mt FORCE  ROW LEVEL SECURITY;
     CREATE POLICY tenant_only ON li_mt
       USING (l_nationkey = current_setting('app.nation', true)::int);" >/dev/null 2>&1
sql "CREATE POLICY owner_all ON li_mt TO tuner USING (true);" >/dev/null 2>&1

[ "$(sql "SELECT count(*) FROM li_mt")" = "$NLI" ] || {
  echo "  [중단] li_mt 가 제대로 만들어지지 않았다. teardown 후 재시도."; exit 1; }

printf "  A 비정규화 사본       %3ds   %s\n" $((TA-T0)) "$(sql "SELECT pg_size_pretty(pg_total_relation_size('li_mt'))")"
printf "  B LIST 파티션 %2d개    %3ds   %s\n" "$NT" $((TB-TA)) "$(sql "SELECT pg_size_pretty(sum(pg_total_relation_size(inhrelid))) FROM pg_inherits WHERE inhparent='li_part'::regclass")"
printf "  C 스키마 %2d개         %3ds   %s\n" "$NT" $((TC-TB)) "$(sql "SELECT pg_size_pretty(sum(pg_total_relation_size(c.oid))) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname LIKE 'mt_n%' AND c.relkind='r'")"
echo

QN="SELECT sum(l.l_extendedprice) FROM lineitem l
      JOIN orders o ON l.l_orderkey = o.o_orderkey
      JOIN customer c ON o.o_custkey = c.c_custkey
     WHERE c.c_nationkey = $T_ME"
QA="SELECT sum(l_extendedprice) FROM li_mt   WHERE l_nationkey = $T_ME"
QB="SELECT sum(l_extendedprice) FROM li_part WHERE l_nationkey = $T_ME"
QC="SELECT sum(l_extendedprice) FROM lineitem"
PRE_C="SET search_path = mt_n$T_ME;"
PRE_RLS="SET ROLE mt_app_tpch; SET app.nation = '$T_ME';"

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① 테넌트 범위 조회 — 2조인을 지불하는가, 비정규화로 없애는가 ──"
printf "  %-24s %6s %-40s %-16s %s\n" "전략" "조인" "스캔" "buffers" "min(ms)"
printf "  %s\n" "--------------------------------------------------------------------------------------------------------"
printf "  %-24s %6s %-40s %-16s %s\n" "N 정규화 (2조인)"  "$(joins_of "$QN")" "$(scan_of '' "$QN")" "$(bufs_of '' "$QN")" "$(best_ms '' "$QN")"
printf "  %-24s %6s %-40s %-16s %s\n" "A 비정규화"        "$(joins_of "$QA")" "$(scan_of '' "$QA")" "$(bufs_of '' "$QA")" "$(best_ms '' "$QA")"
printf "  %-24s %6s %-40s %-16s %s\n" "A + RLS"           "$(joins_of "$QA")" "$(scan_of "$PRE_RLS" "$QA")" "$(bufs_of "$PRE_RLS" "$QA")" "$(best_ms "$PRE_RLS" "$QA")"
printf "  %-24s %6s %-40s %-16s %s\n" "B 파티션"          "$(joins_of "$QB")" "$(scan_of '' "$QB")" "$(bufs_of '' "$QB")" "$(best_ms '' "$QB")"
printf "  %-24s %6s %-40s %-16s %s\n" "C 스키마"          "$(joins_of "$QC")" "$(scan_of "$PRE_C" "$QC")" "$(bufs_of "$PRE_C" "$QC")" "$(best_ms "$PRE_C" "$QC")"
echo
echo "  해석: N 의 조인 2개가 테넌트 조회 **한 번마다** 붙는다. 이게 tpcds 판에는 없던 비용이다."
echo "        tpcds 에서는 ①이 안 갈렸지만(전략 무관 2~3ms) 여기서는 N 만 확실히 다르다 —"
echo "        테넌트 키가 팩트에 없다는 것은 조회 경로의 문제로 먼저 나타난다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② 비정규화 입장료 — 격리를 논하기 전에 내야 하는 값 ──"
printf "  백필(CREATE TABLE AS + 인덱스 2개 + ANALYZE)   %ds\n" $((TA-T0))
sqlv "SELECT pg_size_pretty(pg_total_relation_size('lineitem')) AS 원본_lineitem,
             pg_size_pretty(pg_total_relation_size('li_mt'))    AS 비정규화_사본,
             pg_size_pretty(pg_total_relation_size('li_mt') + pg_total_relation_size('lineitem')) AS 합계;"
echo "  (사본이 원본보다 작은 것은 실습에 필요한 컬럼만 가져왔기 때문이다. 운영에서는"
echo "   원본 테이블에 컬럼을 **추가**하므로 원본이 그만큼 커진다 — ALTER TABLE ADD COLUMN"
echo "   자체는 즉시지만, 값을 채우는 UPDATE 는 전 행 재기록이라 테이블이 한 번 두 배가 된다.)"
echo
echo "  그리고 이 값은 한 번이 아니다 — **고객이 국가를 옮길 때마다 전파해야 한다**(⑤)."
echo "  §T-9 가 잰 것과 같은 종류의 대가이고, 여기서는 그것이 격리의 전제 조건이다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
echo "── ③ RLS 가능성 — 정규화 상태에서는 구조적으로 불가능하다 ──"
echo "  lineitem 에 정책을 걸려면 정책 식이 참조할 컬럼이 있어야 한다. 있는가:"
# table_schema 를 안 걸면 C 가 만든 mt_n*.lineitem 25개가 같이 잡혀
# "l_nationkey 가 25번" 이라는, 이 절의 결론과 정반대인 출력이 나온다(실제로 그랬다).
# 원본은 public.lineitem 하나다.
sql "SELECT '    public.lineitem 의 컬럼 중 nation 관련: '||
            coalesce(nullif(string_agg(column_name, ', '),''), '**없음**')
     FROM information_schema.columns
     WHERE table_schema='public' AND table_name='lineitem' AND column_name LIKE '%nation%'"
echo
echo "  그래서 이런 정책은 만들 수 없다 — 실제로 시도해 본다:"
ERR=$(sql "CREATE POLICY p_impossible ON lineitem USING (l_nationkey = 1)" 2>&1 | head -1)
echo "    CREATE POLICY ... USING (l_nationkey = 1)"
echo "    → ${ERR:-(예상과 달리 성공했다 — 확인 필요)}"
echo
echo "  조인을 넣은 정책은 문법상 가능하지만(서브쿼리), **모든 행마다** 그 서브쿼리가 돈다:"
sql "SET client_min_messages=warning;
     CREATE POLICY p_join ON lineitem USING (
       l_orderkey IN (SELECT o_orderkey FROM orders o JOIN customer c ON o.o_custkey=c.c_custkey
                      WHERE c.c_nationkey = current_setting('app.nation', true)::int))" >/dev/null 2>&1
sql "ALTER TABLE lineitem ENABLE ROW LEVEL SECURITY" >/dev/null 2>&1
JP=$(sql "SET ROLE mt_app_tpch; SET app.nation='$T_ME';
          EXPLAIN (COSTS OFF) SELECT count(*) FROM lineitem" 2>&1 | grep -cE 'Hash Join|Nested Loop|SubPlan|Seq Scan on orders')
echo "    정책이 계획에 밀어 넣은 조인·서브플랜 노드: ${JP}개"
sql "SET client_min_messages=warning; ALTER TABLE lineitem DISABLE ROW LEVEL SECURITY;
     DROP POLICY IF EXISTS p_join ON lineitem" >/dev/null 2>&1
echo
echo "  → RLS 는 '테넌트 키가 그 행에 있다'를 전제한다. 없으면 정책이 조인을 짊어지고,"
echo "     그 조인은 **그 테이블을 읽는 모든 쿼리**에 붙는다. 비정규화가 먼저인 이유다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 4; then
echo "── ④ WHERE 누락 유출 ──"
MINE=$(sql "SELECT count(*) FROM li_mt WHERE l_nationkey=$T_ME")
L_N=$(sql "SELECT count(*) FROM lineitem")
L_A=$(sql "SELECT count(*) FROM li_mt")
L_R=$(sql "$PRE_RLS SELECT count(*) FROM li_mt")
L_B=$(sql "SELECT count(*) FROM li_part")
L_C=$(sql "$PRE_C SELECT count(*) FROM lineitem")
printf "  내 테넌트 %s 행 / 전체 %s 행\n\n" "$MINE" "$NLI"
printf "  %-24s %12s   %s\n" "전략" "돌아온 행수" "판정"
printf "  %s\n" "---------------------------------------------------------"
jd() { [ "$1" = "$MINE" ] && echo "격리됨" || echo "**유출**"; }
printf "  %-24s %12s   %s\n" "N 정규화"   "$L_N" "$(jd "$L_N")"
printf "  %-24s %12s   %s\n" "A 비정규화" "$L_A" "$(jd "$L_A")"
printf "  %-24s %12s   %s\n" "A + RLS"    "$L_R" "$(jd "$L_R")"
printf "  %-24s %12s   %s\n" "B 파티션"   "$L_B" "$(jd "$L_B")"
printf "  %-24s %12s   %s\n" "C 스키마"   "$L_C" "$(jd "$L_C")"
echo
echo "  tpcds 판과 같은 결론이다 — 파티션은 격리가 아니고, 격리를 주는 것은 RLS 와 스키마뿐이다."
echo "  다만 tpch 에서는 그 RLS 를 쓰기 위해 ②의 비정규화를 먼저 지불해야 했다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 5; then
echo "── ⑤ 테넌트 이동 — tpcds 에는 없던 문제 ──"
echo "  매장은 다른 매장이 되지 않지만, **고객은 국가를 옮긴다.** 그러면 그 고객의 과거"
echo "  매출 행이 전부 다른 테넌트로 재분류돼야 한다. 전략마다 그 일이 다른 모양이 된다."
echo
CUST=$(sql "SELECT o_custkey FROM orders GROUP BY 1 ORDER BY count(*) DESC LIMIT 1")
CN=$(sql "SELECT l_nationkey FROM li_mt WHERE o_custkey=$CUST LIMIT 1")
CROWS=$(sql "SELECT count(*) FROM li_mt WHERE o_custkey=$CUST")
echo "  대상: 고객 $CUST (국가 $CN → $T_OTHER), 옮겨야 할 lineitem ${CROWS} 행"
echo
# 벽시계로 재면 안 된다 — psql 연결 오버헤드가 약 30ms 라 1ms 짜리 차이가 통째로 묻힌다.
# (처음에 그렇게 재서 네 전략이 42~47ms 로 다 같아 보였고, 차이가 없다고 쓸 뻔했다.)
# EXPLAIN (ANALYZE) 의 Execution Time 은 서버가 실제로 쓴 시간이다.
mv_ms() {  # $1 = UPDATE 문 → 서버 실행시간 최소값(ms)
  local b="" v
  sql "BEGIN; EXPLAIN (ANALYZE) $1; ROLLBACK;" >/dev/null 2>&1
  for _ in $(seq "$REPEAT"); do
    v=$(sql "BEGIN; EXPLAIN (ANALYZE) $1; ROLLBACK;" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+')
    [ -z "$v" ] && continue
    [ -z "$b" ] && b="$v" || b=$(awk -v a="$b" -v c="$v" 'BEGIN{print (c+0<a+0)?c:a}')
  done; echo "${b:-?}"
}
nparts() { sql "EXPLAIN (COSTS OFF) $1" | grep -c 'Update on li_p_'; }
U_N="UPDATE customer SET c_nationkey=$T_OTHER WHERE c_custkey=$CUST"
U_A="UPDATE li_mt   SET l_nationkey=$T_OTHER WHERE o_custkey=$CUST"
U_B0="UPDATE li_part SET l_nationkey=$T_OTHER WHERE o_custkey=$CUST"
U_B1="UPDATE li_part SET l_nationkey=$T_OTHER WHERE l_nationkey=$CN AND o_custkey=$CUST"

printf "  %-40s %10s %s\n" "전략" "서버(ms)" "건드리는 파티션"
printf "  %s\n" "----------------------------------------------------------------------"
printf "  %-40s %10s %s\n"   "N 정규화 — customer 1행만 고치면 끝" "$(mv_ms "$U_N")" "-"
printf "  %-40s %10s %s\n"   "A 비정규화 — 그 고객의 팩트 행 전부" "$(mv_ms "$U_A")" "-"
printf "  %-40s %10s %s개\n" "B 파티션 — 옛 국가 모름"             "$(mv_ms "$U_B0")" "$(nparts "$U_B0")"
printf "  %-40s %10s %s개\n" "B 파티션 — 옛 국가 앎"               "$(mv_ms "$U_B1")" "$(nparts "$U_B1")"
echo
echo "  행이 실제로 파티션을 넘는가:"
sql "BEGIN; $U_B1;
     SELECT '    li_p_$T_OTHER 에 도착한 행: '||count(*) FROM li_p_$T_OTHER WHERE o_custkey=$CUST;
     ROLLBACK;"
echo
# 프루닝이 얼마나 중요한지는 **인덱스가 있느냐에 달렸다.** 위 표는 o_custkey 인덱스가
# 있는 상태다(프루닝을 못 해도 파티션마다 인덱스로 찾아 싸다). 없으면 25번 풀스캔이 된다.
echo "  그런데 위 두 B 행의 차이가 작다면, 그건 o_custkey 인덱스 덕이다. 지우고 다시 재 본다:"
sql "SET client_min_messages=warning; DROP INDEX IF EXISTS li_part_o_custkey_idx" >/dev/null 2>&1
printf "    인덱스 없이 옛 국가 모름   %10s ms   (%s개 파티션, %s)\n" \
  "$(mv_ms "$U_B0")" "$(nparts "$U_B0")" \
  "$(sql "EXPLAIN (COSTS OFF) $U_B0" | grep -oE 'Seq Scan|Index Scan' | sort -u | tr '\n' ' ')"
printf "    인덱스 없이 옛 국가 앎     %10s ms   (%s개 파티션)\n" "$(mv_ms "$U_B1")" "$(nparts "$U_B1")"
sql "CREATE INDEX ON li_part (o_custkey); ANALYZE li_part;" >/dev/null 2>&1
echo
echo "  해석 — 여기가 tpch 판의 핵심이다."
echo "   · **N 이 압도적으로 싸다.** 정규화 모델에서 테넌트 이동은 customer 1행 UPDATE 로 끝난다."
echo "     ①에서 2조인 값을 치른 그 정규화가, ⑤에서는 정확히 그 이유로 한 자릿수 배 이득이 된다."
echo "     tpcds 에는 이 축이 아예 없었다 — 매장은 다른 매장이 되지 않기 때문이다."
echo "   · A·B 는 §T-9 의 전파 문제를 그대로 물려받는다. 비정규화로 산 조회 속도의 청구서다."
echo "   · B 에서 그 UPDATE 는 **행을 파티션 밖으로 옮긴다**(내부적으로 DELETE+INSERT)."
echo "   · 프루닝이 얼마나 중요한지는 **인덱스가 있느냐에 달렸다.** 인덱스가 있으면 프루닝을"
echo "     못 해도 파티션마다 싸게 찾아 차이가 작고, 없으면 파티션 수만큼 풀스캔이라 크게 벌어진다."
echo "     §T-3 의 'NL 이 무너지는 조건은 필터 폭이 아니라 안쪽 인덱스의 부재'와 같은 구조다."
echo "   · 그리고 테넌트 이동은 보통 '이 고객을 옮겨라'로 시작하지 **옛 국가를 모른 채** 시작한다."
echo "     프루닝을 받으려면 애플리케이션이 옛 테넌트를 기억해 조건에 실어야 한다 —"
echo "     스키마 선택이 애플리케이션에 숙제를 떠넘긴 셈이다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 6; then
echo "── ⑥ 교차 테넌트 집계 — '전 국가 매출' ──"
XN="SELECT c.c_nationkey, sum(l.l_extendedprice) FROM lineitem l
      JOIN orders o ON l.l_orderkey=o.o_orderkey JOIN customer c ON o.o_custkey=c.c_custkey
     GROUP BY 1 ORDER BY 2 DESC"
XA="SELECT l_nationkey, sum(l_extendedprice) FROM li_mt   GROUP BY 1 ORDER BY 2 DESC"
XB="SELECT l_nationkey, sum(l_extendedprice) FROM li_part GROUP BY 1 ORDER BY 2 DESC"
XC=""; for n in $(seq 0 $((NT-1))); do
  [ -n "$XC" ] && XC="$XC UNION ALL "
  XC="$XC SELECT $n AS l_nationkey, sum(l_extendedprice) FROM mt_n$n.lineitem"
done
XC="SELECT * FROM ($XC) u ORDER BY 2 DESC"
printf "  %-22s %9s %-16s %s\n" "전략" "min(ms)" "buffers" "쿼리 길이"
printf "  %s\n" "-----------------------------------------------------------------"
printf "  %-22s %9s %-16s %s자\n" "N 정규화 (2조인)" "$(best_ms '' "$XN")" "$(bufs_of '' "$XN")" "${#XN}"
printf "  %-22s %9s %-16s %s자\n" "A 비정규화"       "$(best_ms '' "$XA")" "$(bufs_of '' "$XA")" "${#XA}"
printf "  %-22s %9s %-16s %s자\n" "B 파티션"         "$(best_ms '' "$XB")" "$(bufs_of '' "$XB")" "${#XB}"
printf "  %-22s %9s %-16s %s자 (UNION ALL ×%s)\n" "C 스키마" "$(best_ms '' "$XC")" "$(bufs_of '' "$XC")" "${#XC}" "$NT"
echo
echo "  해석: 교차 집계는 tpcds 와 같은 방향이다 — C 의 쿼리가 테넌트 수만큼 자란다."
echo "        다만 tpch 에서는 테넌트가 ${NT}개라 그 부담이 더 크고(문자 ${#XC}), 국가가 하나"
echo "        늘 때마다 이 쿼리를 고쳐야 한다. 빠뜨리면 조용히 틀린 합계가 나온다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
echo "정리:"
if [ "${KEEP:-0}" = "1" ]; then
  echo "  KEEP=1 — 남겨 둔다: li_mt / li_part / 스키마 mt_n* / 롤 mt_app_tpch"
else
  teardown
  LEFT=$(sql "SELECT count(*) FROM pg_class WHERE relname LIKE 'li\_%'")
  POL=$(sql "SELECT count(*) FROM pg_policies WHERE tablename='lineitem'")
  RLS=$(sql "SELECT count(*) FROM pg_class WHERE relname='lineitem' AND relrowsecurity")
  echo "  실험 객체를 지웠다 (lineitem 원본은 건드리지 않았다)."
  echo "  남은 li_* ${LEFT}개 / lineitem 정책 ${POL}개 / lineitem RLS 활성 ${RLS}개  (전부 0 이어야 한다)"
fi
