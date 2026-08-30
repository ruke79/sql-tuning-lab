#!/usr/bin/env bash
# §T-4 (TPC-DS 판) — 인덱스를 죽이는 습관, 그리고 히스토그램이 실제로 하는 일.
#
# tpch 판은 문서 안의 SQL 로만 되어 있다. tpcds 판은 스크립트로 만든다 — 특히 ④는
# **tpch 에서는 보여줄 수 없었던 실험**이라 재현 가능한 형태로 남길 가치가 있다.
#
#   ① 함수로 감싸면 Index Cond 가 Filter 로 내려앉는다
#   ② 형변환도 같은 일을 한다 / 표현식 인덱스로 되살린다
#   ③ VACUUM 이 Index Only Scan 을 가능하게 만든다 (visibility map)
#   ④ statistics_target 은 **치우친 데이터에서만** 의미가 있다
#      → tpch 는 균일 분포라 이 효과를 못 보여줬다(정정 목록 3번).
#        tpcds 의 ss_coupon_amt 는 최빈값이 90% 인 진짜 편중 컬럼이라 여기서 실증된다.
#   ⑤ 스타 스키마 고유: 대리키에 형변환을 걸면 **조인 자체**가 죽는다
#
# 사용법: ./t4-index-defeat.sh
# 선행 조건: schema → load → index (통계·인덱스가 있는 상태)
set -euo pipefail

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
  sql()  { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -tAc "$1"; }
  sqlv() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -q -c "$1"; }
else
  sql()  { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -tAc "$1"; }
  sqlv() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -q -c "$1"; }
fi

node_of() { echo "$1" | grep -oE '(Parallel Seq Scan|Seq Scan|Parallel Index Only Scan|Index Only Scan|Parallel Index Scan|Index Scan|Bitmap Heap Scan)' | head -1; }
cond_of() { echo "$1" | grep -oE '(Index Cond|Filter|Recheck Cond): .*' | head -1 | cut -c1-58; }
est_act() { echo "$1" | grep -m1 -oE 'rows=[0-9]+ width=[0-9]+\) \(actual time=[0-9.]+\.\.[0-9.]+ rows=[0-9]+' \
            | sed -E 's/rows=([0-9]+) width=[0-9]+\) \(actual time=[0-9.]+\.\.[0-9.]+ rows=([0-9]+)/추정 \1 · 실제 \2/'; }
ms_of()   { echo "$1" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+'; }
# §T-0 ②: 단발 EXPLAIN ANALYZE 를 성능 지표로 쓰지 않는다. 4회 중 최소값을 쓴다.
# (처음 이 스크립트를 쓸 때 단발로 재서 ⑤의 결론을 정반대로 적었다 — 실제로 겪은 함정이다.)
best_ms() { local q="$1" b="" v; for _ in 1 2 3 4; do
              v=$(ms_of "$(sql "EXPLAIN (ANALYZE) $q")")
              [ -z "$b" ] && b="$v" || b=$(awk -v a="$b" -v c="$v" 'BEGIN{print (c+0<a+0)?c:a}')
            done; echo "$b"; }
# 추정 행수는 스캔 노드에서 뽑아야 한다. 집계 쿼리의 최상위 노드는 언제나 rows=1 이라
# 거기서 읽으면 target 을 아무리 바꿔도 "추정 1" 만 나온다(처음에 그렇게 잘못 뽑았다).
est_rows() { sql "EXPLAIN (FORMAT JSON) SELECT * FROM $1 WHERE $2" | grep -oE '"Plan Rows": [0-9]+' | head -1 | grep -oE '[0-9]+'; }

BASE=$(sql "SELECT min(d_date_sk) FROM date_dim WHERE d_date >= date '1998-06-01'")

echo "═══ ① 함수로 감싸면 인덱스가 죽는다 ═══"
echo "   같은 행을 세는 두 쿼리. idx_ss_sold_date 는 양쪽 다 '존재'한다."
for Q in \
  "SELECT count(*) FROM store_sales WHERE ss_sold_date_sk >= $BASE AND ss_sold_date_sk < $BASE + 30" \
  "SELECT count(*) FROM store_sales WHERE ss_sold_date_sk - $BASE BETWEEN 0 AND 29"
do
  P=$(sql "EXPLAIN (ANALYZE, BUFFERS) $Q")
  printf "   %-24s %-40s %9s ms\n" "$(node_of "$P")" "$(cond_of "$P")" "$(best_ms "$Q")"
done
echo "   → 스캔 노드 이름이 아니라 **Index Cond 냐 Filter 냐**를 봐야 한다."
echo

echo "═══ ② 형변환으로 무력화 → 표현식 인덱스로 되살리기 ═══"
Q="SELECT * FROM item WHERE i_item_sk = 1000"; P=$(sql "EXPLAIN (ANALYZE) $Q")
printf "   %-26s %-24s %9s ms\n" "정상 (PK)" "$(node_of "$P")" "$(best_ms "$Q")"
Q="SELECT * FROM item WHERE i_item_sk + 0 = 1000"; P=$(sql "EXPLAIN (ANALYZE) $Q")
printf "   %-26s %-24s %9s ms\n" "수식 (+0)" "$(node_of "$P")" "$(best_ms "$Q")"
Q="SELECT * FROM item WHERE i_item_sk::text = '1000'"; P=$(sql "EXPLAIN (ANALYZE) $Q")
printf "   %-26s %-24s %9s ms\n" "형변환 (::text)" "$(node_of "$P")" "$(best_ms "$Q")"
sqlv "CREATE INDEX IF NOT EXISTS idx_item_sk_text ON item ((i_item_sk::text)); ANALYZE item;" > /dev/null
P=$(sql "EXPLAIN (ANALYZE) $Q")
printf "   %-26s %-24s %9s ms\n" "형변환 + 표현식 인덱스" "$(node_of "$P")" "$(best_ms "$Q")"
sqlv "DROP INDEX IF EXISTS idx_item_sk_text;" > /dev/null
echo

echo "═══ ③ VACUUM 이 Index Only Scan 을 연다 (visibility map) ═══"
sqlv "CREATE TABLE IF NOT EXISTS t4_vm AS SELECT ss_sold_date_sk, ss_item_sk FROM store_sales;" > /dev/null
sqlv "CREATE INDEX IF NOT EXISTS idx_t4_vm ON t4_vm(ss_sold_date_sk); ANALYZE t4_vm;" > /dev/null
Q="SELECT count(*) FROM t4_vm WHERE ss_sold_date_sk >= $BASE AND ss_sold_date_sk < $BASE + 30"
V=$(sql "SELECT relpages||' 페이지 중 relallvisible '||relallvisible FROM pg_class WHERE relname='t4_vm'")
P=$(sql "EXPLAIN (ANALYZE, BUFFERS) $Q")
printf "   VACUUM 전  %-28s %8s ms   (%s)\n" "$(node_of "$P")" "$(ms_of "$P")" "$V"
sqlv "VACUUM ANALYZE t4_vm;" > /dev/null
V=$(sql "SELECT relpages||' 페이지 중 relallvisible '||relallvisible FROM pg_class WHERE relname='t4_vm'")
P=$(sql "EXPLAIN (ANALYZE, BUFFERS) $Q")
printf "   VACUUM 후  %-28s %8s ms   (%s)\n" "$(node_of "$P")" "$(ms_of "$P")" "$V"
sqlv "DROP TABLE IF EXISTS t4_vm;" > /dev/null
echo

echo "═══ ④ statistics_target — 치우친 데이터에서만 의미가 있다 ═══"
echo "   ss_coupon_amt: 0.00 이 90.04%, 나머지 값은 21행 이하인 **진짜 편중 컬럼**."
echo "   (tpch 는 균일 분포라 이 실험이 아무 차이도 못 냈다 — 정정 목록 3번)"
RARE=$(sql "SELECT ss_coupon_amt FROM store_sales WHERE ss_coupon_amt > 0 GROUP BY 1 ORDER BY count(*) DESC LIMIT 1")
ACT_C=$(sql "SELECT count(*) FROM store_sales WHERE ss_coupon_amt = 0")
ACT_R=$(sql "SELECT count(*) FROM store_sales WHERE ss_coupon_amt = $RARE")
printf "   %-8s │ %-26s │ %-23s │ %s\n" "target" "최빈값 0.00 (실제 $ACT_C)" "희소값 $RARE (실제 $ACT_R)" "MCV/히스토그램"
printf "   %-8s─┼─%-26s─┼─%-23s─┼─%s\n" "--------" "--------------------------" "-----------------------" "--------------"
for T in 1 10 100 1000; do
  sqlv "ALTER TABLE store_sales ALTER COLUMN ss_coupon_amt SET STATISTICS $T; ANALYZE store_sales;" > /dev/null
  EC=$(est_rows store_sales "ss_coupon_amt = 0")
  ER=$(est_rows store_sales "ss_coupon_amt = $RARE")
  MCV=$(sql "SELECT coalesce(array_length(most_common_vals::text::text[],1),0)||'/'||
                    coalesce(array_length(histogram_bounds::text::text[],1),0)
             FROM pg_stats WHERE tablename='store_sales' AND attname='ss_coupon_amt'")
  printf "   %-8s │ 추정 %-9s (%-7s) │ 추정 %-6s (%-7s) │ %s\n" "$T" "$EC" \
     "$(awk -v e=$EC -v a=$ACT_C 'BEGIN{printf "%.2f배", (e>a)?e/a:a/e}')" "$ER" \
     "$(awk -v e=$ER -v a=$ACT_R 'BEGIN{printf "%.2f배", (e>a)?e/a:a/e}')" "$MCV"
done
sqlv "ALTER TABLE store_sales ALTER COLUMN ss_coupon_amt SET STATISTICS -1; ANALYZE store_sales;" > /dev/null
echo "   → 예상과 다른 결과다. **최빈값은 target=1 에서도 정확하다**(오차 1.00배)."
echo "     MCV 목록은 target=1 이어도 1개는 담으므로, 90% 를 차지하는 값은 그 한 칸에 들어간다."
echo "   → 반대로 희소값은 target 을 1000 으로 올려도 오차가 남는다(2.95 → 2.62배)."
echo "     21행/200만 = 0.001% 는 **어느 target 에서도 MCV 에 못 들어가기** 때문이다."
echo "   ⇒ statistics_target 은 '편중을 잡는 손잡이'가 아니다. 지배적 최빈값은 공짜로 잡힌다."
echo "     target 이 하는 일은 MCV 목록을 늘려 **중간 빈도 값들**을 담는 것이고,"
echo "     극단적으로 희소한 값은 어차피 히스토그램 보간으로 추정된다."
echo "     즉 진짜 변수는 '데이터가 치우쳤는가'가 아니라 **'조회하는 값이 MCV 에 있는가'** 다."
echo

echo "═══ ⑤ 스타 스키마 고유 — 대리키에 형변환을 걸면 조인이 죽는다 ═══"
for J in "s.ss_item_sk = i.i_item_sk" "s.ss_item_sk::text = i.i_item_sk::text"; do
  Q="SELECT count(*) FROM store_sales s JOIN item i ON $J WHERE i.i_manufact_id = 128"
  P=$(sql "EXPLAIN (ANALYZE) $Q")
  JN=$(echo "$P" | grep -oE '(Nested Loop|Hash Join|Merge Join)' | head -1)
  printf "   %-36s %-13s %9s ms\n" "${J:0:36}" "$JN" "$(best_ms "$Q")"
done
echo "   → 조인 조건에 형변환이 들어가면 대리키 인덱스를 탈 수 없어 전량 해시가 된다."
echo "     스타 스키마는 조인이 전부이므로, 여기서 죽으면 §T-3 의 NL 이점이 통째로 사라진다."
echo "     (버퍼 수를 함께 보면 차이가 더 분명하다 — EXPLAIN (ANALYZE, BUFFERS) 로 확인할 것)"
