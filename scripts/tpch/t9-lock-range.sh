#!/usr/bin/env bash
# §T-9 확장: FOR SHARE 락 범위가 대형 고객에서 얼마나 비싼가.
#
# t9-concurrency.sh 는 sync_cust 의 드리프트를 FOR SHARE 로 고쳤다. 그런데 sync_cust 는
# **한 고객의 주문 전체**를 잠근다. TPC-H 자연 분포는 고객당 평균 10 / 최대 25건이라
# 문제가 안 보이지만, 실무에는 주문 수천 건짜리 대형 계정이 있다.
#
# 이 스크립트가 답하는 질문
#   1) 잠그는 행이 많아지면 FOR SHARE 자체가 느려지는가?      → 그렇다. 5,000행에서 약 1.45배
#   2) 그럼 비용의 대부분은 어디서 나오는가?                   → 경합. 피해자가 통째로 막힌다
#   3) 대기 길이가 고객 크기에 비례하는가?                     → 아니다. 크기는 "막히는 범위"를 키운다
#   4) 그래서 처리량 손해는 무엇을 따라가는가?                 → 워크로드가 잠긴 범위와 겹치는 비율
#
# 주의: TPC-H 에는 대형 고객이 없으므로 **주문을 한 고객에게 몰아서 만든다.**
#       원본 데이터를 바꾸므로 끝나면 재적재를 권한다(맨 아래 안내).
#
# 사용법:
#   ./t9-lock-range.sh
#
# 선행 조건: schema → load → index 완료
set -uo pipefail

PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
# PGPASSWORD 은 export 한다. pgbench 도 이 환경변수를 쓰고, timeout 으로 감쌀 psql 도
# 셸 함수가 아니라 실제 명령이어야 하기 때문이다(아래 tsql 주석 참고).
export PGPASSWORD=tuner
PSQL(){ psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q "$@"; }
sql(){ PSQL -tAc "$1"; }
# timeout 은 외부 바이너리라 **셸 함수를 실행할 수 없다.**
#   timeout 20 sql "..."  →  "failed to run command 'sql'" 로 즉시 실패한다(정정 목록 10번).
tsql(){ timeout "$1" psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q -tAc "$2"; }

NIDX=$(sql "SELECT count(*) FROM pg_indexes WHERE tablename='lineitem'")
[ "${NIDX:-0}" -lt 2 ] && { echo "  [중단] index 를 먼저 실행하세요."; exit 1; }

echo "§T-9 FOR SHARE 락 범위"
echo
echo "── TPC-H 자연 분포 (편중이 없다) ──"
PSQL -c "WITH c AS (SELECT o_custkey, count(*) n FROM orders GROUP BY 1)
         SELECT min(n) AS 최소, round(avg(n),1) AS 평균, max(n) AS 최대 FROM c;"
echo "  → 대형 계정이 없으므로 인위적으로 만든다."
echo

# ── 준비 ──────────────────────────────────────────────────────────────
sql "SET client_min_messages=warning; DROP TABLE IF EXISTS lineitem_denorm CASCADE;" >/dev/null 2>&1
sql "CREATE TABLE lineitem_denorm (
       l_orderkey BIGINT NOT NULL, l_linenumber INTEGER NOT NULL,
       l_extendedprice DECIMAL(15,2) NOT NULL, l_discount DECIMAL(15,2) NOT NULL,
       l_shipdate DATE NOT NULL, c_mktsegment CHAR(10) NOT NULL,
       o_orderdate DATE NOT NULL, o_shippriority INTEGER NOT NULL,
       CONSTRAINT pk_ld PRIMARY KEY (l_orderkey, l_linenumber));" >/dev/null 2>&1
sql "CREATE INDEX ix_ld_ord ON lineitem_denorm(l_orderkey);" >/dev/null 2>&1

PSQL >/dev/null 2>&1 <<'EOSQL'
CREATE OR REPLACE FUNCTION sync_cust_naive() RETURNS trigger AS $$
BEGIN
  IF NEW.c_mktsegment IS DISTINCT FROM OLD.c_mktsegment THEN
    UPDATE lineitem_denorm SET c_mktsegment=NEW.c_mktsegment
     WHERE l_orderkey IN (SELECT o_orderkey FROM orders WHERE o_custkey=NEW.c_custkey);
  END IF; RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION sync_cust_fs() RETURNS trigger AS $$
BEGIN
  IF NEW.c_mktsegment IS DISTINCT FROM OLD.c_mktsegment THEN
    UPDATE lineitem_denorm SET c_mktsegment=NEW.c_mktsegment
     WHERE l_orderkey IN (SELECT o_orderkey FROM orders WHERE o_custkey=NEW.c_custkey FOR SHARE);
  END IF; RETURN NEW;
END $$ LANGUAGE plpgsql;
EOSQL

# 고객1이 주문 $1 건을 갖도록 만든다 (키 1..$1 을 몰아준다)
setsize(){
  sql "UPDATE orders SET o_custkey=(2+(o_orderkey%1000)) WHERE o_custkey=1;" >/dev/null 2>&1
  sql "UPDATE orders SET o_custkey=1 WHERE o_orderkey <= $1;" >/dev/null 2>&1
  sql "TRUNCATE lineitem_denorm;
       INSERT INTO lineitem_denorm SELECT l.l_orderkey,l.l_linenumber,l.l_extendedprice,l.l_discount,
              l.l_shipdate,c.c_mktsegment,o.o_orderdate,o.o_shippriority
       FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                       JOIN customer c ON o.o_custkey=c.c_custkey; ANALYZE lineitem_denorm;" >/dev/null 2>&1
}
usetrg(){ sql "DROP TRIGGER IF EXISTS t_sync_cust ON customer;
               CREATE TRIGGER t_sync_cust AFTER UPDATE ON customer
                 FOR EACH ROW EXECUTE FUNCTION $1();" >/dev/null 2>&1; }
mn(){ echo "$1"|tr ' ' '\n'|grep -v '^$'|sort -g|head -1; }

# ── ① 단일 세션 비용 ──────────────────────────────────────────────────
echo "── ① 단일 세션: 잠그는 행이 많아지면 FOR SHARE 가 느려지는가 ──"
# 등급값은 시퀀스로 매번 다르게 만든다. random() 로는 새 값이 옛 값과 같아
# IS DISTINCT FROM 가드에 걸려 트리거가 no-op 이 되는 시행이 섞이고,
# **최소값을 취하는 순간 정확히 그 no-op 만 골라내게 된다**(정정 목록 11번).
sql "DROP SEQUENCE IF EXISTS seg_seq; CREATE SEQUENCE seg_seq;" >/dev/null 2>&1
one(){ PSQL -c "\timing on" -c "BEGIN; UPDATE customer SET c_mktsegment='S'||nextval('seg_seq')
                                 WHERE c_custkey=1; ROLLBACK;" 2>/dev/null \
        | grep -m1 "^Time:" | grep -oE "[0-9]+\.[0-9]+"; }
printf "  %-10s %-11s %11s %12s %8s\n" "주문수" "denorm행" "naive(ms)" "FOR SHARE" "배수"
for N in 10 100 1000 5000; do
  setsize $N
  LD=$(sql "SELECT count(*) FROM lineitem_denorm d JOIN orders o ON d.l_orderkey=o.o_orderkey WHERE o.o_custkey=1")
  usetrg sync_cust_naive; one >/dev/null; A=""; for i in 1 2 3 4 5; do A="$A $(one)"; done
  usetrg sync_cust_fs;    one >/dev/null; B=""; for i in 1 2 3 4 5; do B="$B $(one)"; done
  a=$(mn "$A"); b=$(mn "$B")
  printf "  %-10s %-11s %11s %12s %8s\n" "$N" "$LD" "$a" "$b" "$(awk -v x=$a -v y=$b 'BEGIN{printf "%.2f배",y/x}')"
done
echo "  → 몸통은 denorm 행 갱신 비용이 맞다. 다만 같은 행 수에서 비교하면 1,000건 이상에서"
echo "     1.4~1.5배가 붙는다 — 행 공유 락 획득 비용은 실재한다. 단, 아래 경합 비용보다는 작다."
echo

# ── ② 경합 비용 ───────────────────────────────────────────────────────
echo "── ② 경합: 잠긴 주문 하나를 무관한 트랜잭션이 건드리면 ──"
setsize 5000
V=$(sql "SELECT o_orderkey FROM orders WHERE o_custkey=1 ORDER BY o_orderkey LIMIT 1")
for T in sync_cust_naive sync_cust_fs; do
  usetrg $T
  ( sql "BEGIN; UPDATE customer SET c_mktsegment='LK' WHERE c_custkey=1; SELECT pg_sleep(5); ROLLBACK;" >/dev/null 2>&1 ) &
  sleep 2.5
  s=$(date +%s%N); tsql 20 "UPDATE orders SET o_shippriority=7 WHERE o_orderkey=$V;" >/dev/null 2>&1; e=$(date +%s%N)
  printf "  %-18s 무관한 UPDATE orders 소요: %6d ms\n" "$T" $(( (e-s)/1000000 ))
  wait
done
echo "  → 등급과 아무 상관 없는 트랜잭션이 등급변경 트랜잭션의 커밋까지 통째로 막힌다."
echo "  ※ 대기 길이는 고객 크기가 아니라 '앞선 트랜잭션이 얼마나 오래 열려 있는가'로 정해진다."
echo "     고객 크기가 키우는 것은 대기 길이가 아니라 '막히는 범위'다 — 그것을 ③에서 잰다."
echo

# ── ③ 처리량: 적중률만 바꿔서 ─────────────────────────────────────────
echo "── ③ 처리량: 워크로드 키 범위는 1~5,000 고정, 고객1 소유 비율만 변경 ──"
cat > /tmp/t9_skew.sql <<'EOF'
\set r random(1, 100)
\set ord random(1, 5000)
BEGIN;
\if :r <= 5
  UPDATE customer SET c_mktsegment = 'S' || :r WHERE c_custkey = 1;
\endif
UPDATE orders SET o_shippriority = :r % 7 WHERE o_orderkey = :ord;
END;
EOF
run(){ pgbench -h "$PGHOST_" -p "$PGPORT_" -U tuner -f /tmp/t9_skew.sql \
        -c 8 -j 4 -T 12 -n tpch 2>&1 | grep -oP 'tps = \K[0-9.]+' | head -1; }
printf "  %-10s %-9s %13s %13s %8s\n" "주문수" "적중률" "naive tps" "FOR SHARE" "손해"
for N in 50 500 5000; do
  setsize $N
  for T in sync_cust_naive sync_cust_fs; do
    usetrg $T; r=$(run); [ "$T" = "sync_cust_naive" ] && A=$r || B=$r
  done
  printf "  %-10s %-9s %13s %13s %8s\n" "$N" "$(awk -v n=$N 'BEGIN{printf "%.0f%%",n/5000*100}')" \
         "$A" "$B" "$(awk -v x=$A -v y=$B 'BEGIN{printf "%.2f배",x/y}')"
done
echo
echo "해석:"
echo "  적중률이 낮으면 FOR SHARE 는 사실상 공짜이고, 겹치기 시작하면 급격히 비싸진다."
echo "  → 정합성 락의 비용은 '무엇을 잠그느냐'가 아니라 '누가 그걸 건드리느냐'다."
echo "  → 판단 기준은 락 범위의 크기가 아니라 그 범위가 쓰기 트래픽과 겹치는 비율이며,"
echo "     이건 스키마가 아니라 워크로드를 봐야 안다."
echo "  → 대형 계정에 쓰기가 몰리는 시스템이라면 행 락 대신 변경 큐 + 비동기 전파 +"
echo "     정합성 배치를 검토하거나, 애초에 그 컬럼을 반정규화하지 않는 쪽을 봐야 한다."
echo
echo "정리 (이 스크립트는 orders.o_custkey 를 바꾼다 — 재적재 권장):"
echo "  ./gradlew :tpch:bootRun --args=\"schema --db=postgres\""
echo "  ./gradlew :tpch:bootRun --args=\"load   --db=postgres\""
echo "  ./gradlew :tpch:bootRun --args=\"index  --db=postgres\""
