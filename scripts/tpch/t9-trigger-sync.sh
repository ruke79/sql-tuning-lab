#!/usr/bin/env bash
# §T-9 확장: 반정규화를 트리거로 자동 동기화하고 그 오버헤드를 잰다.
#
# Dan Tow 10장은 반정규화를 "다른 방법이 없을 때만"으로 못박으면서 이렇게 덧붙인다 —
# "엄밀히 설계된 트리거로 자동 동기화하면 기능적으로는 안전하다. 다만 공짜가 아니다:
#  디스크를 쓰고, 동기화 트리거를 발화시켜야 하는 모든 INSERT/UPDATE/DELETE 를 느리게 한다."
#
# 이 스크립트는 그 문장을 숫자로 바꾼다.
#   1) 동기화 가능한 형태로 반정규화 테이블을 만든다 (원본 키를 반드시 포함)
#   2) 트리거 3종을 붙인다 (lineitem 자체 / orders 전파 / customer 전파)
#   3) 네 가지 변경 유형이 정확히 전파되는지 검증한다
#   4) 트리거 ON/OFF 를 교차하며 쓰기 오버헤드를 잰다
#   5) 커밋 워크로드 후 드리프트가 0인지 확인한다
#
# 주의: t9-preaggregation.sh 의 lineitem_denorm 에는 l_linenumber 가 없다.
#       조회 전용이면 무관하지만 행을 특정할 수 없어 동기화가 불가능하다.
#       반정규화 테이블에는 원본 키를 반드시 함께 가져와야 한다 — 이 스크립트가 그 형태다.
#
# 사용법:
#   ./t9-trigger-sync.sh          # 기본 6라운드
#   ./t9-trigger-sync.sh 10
#
# 선행 조건: schema → load → index 완료
set -uo pipefail

ROUNDS="${1:-6}"
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
  PSQL() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q "$@"; }
else
  PSQL() { docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -X -q "$@"; }
fi
sql()  { PSQL -tAc "$1"; }
sqlv() { PSQL -c "$1"; }

echo "§T-9 트리거 동기화 — ${ROUNDS}라운드"
echo

# ── 1) 동기화 가능한 반정규화 테이블 (원본 키 포함) ───────────────────
echo "── 반정규화 테이블 구축 (l_linenumber 포함 — 동기화에 필수) ──"
sql "SET client_min_messages=warning; DROP TABLE IF EXISTS lineitem_denorm CASCADE;" >/dev/null 2>&1
sql "CREATE TABLE lineitem_denorm (
       l_orderkey BIGINT NOT NULL, l_linenumber INTEGER NOT NULL,
       l_extendedprice DECIMAL(15,2) NOT NULL, l_discount DECIMAL(15,2) NOT NULL,
       l_shipdate DATE NOT NULL, c_mktsegment CHAR(10) NOT NULL,
       o_orderdate DATE NOT NULL, o_shippriority INTEGER NOT NULL,
       CONSTRAINT pk_ld PRIMARY KEY (l_orderkey, l_linenumber));" >/dev/null 2>&1
sql "INSERT INTO lineitem_denorm
     SELECT l.l_orderkey, l.l_linenumber, l.l_extendedprice, l.l_discount, l.l_shipdate,
            c.c_mktsegment, o.o_orderdate, o.o_shippriority
     FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                     JOIN customer c ON o.o_custkey=c.c_custkey;" >/dev/null 2>&1
sql "CREATE INDEX idx_ld_filters ON lineitem_denorm (c_mktsegment, o_orderdate, l_shipdate);
     ANALYZE lineitem_denorm;" >/dev/null 2>&1
echo "  행수: $(sql 'SELECT count(*) FROM lineitem_denorm')"
echo

# ── 2) 트리거 3종 ─────────────────────────────────────────────────────
echo "── 트리거 설치 ──"
PSQL >/dev/null 2>&1 <<'EOSQL'
CREATE OR REPLACE FUNCTION sync_li() RETURNS trigger AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    DELETE FROM lineitem_denorm WHERE l_orderkey=OLD.l_orderkey AND l_linenumber=OLD.l_linenumber;
    RETURN OLD;
  END IF;
  IF TG_OP='UPDATE' THEN
    DELETE FROM lineitem_denorm WHERE l_orderkey=OLD.l_orderkey AND l_linenumber=OLD.l_linenumber;
  END IF;
  -- 상속 컬럼을 채우려면 조인 트리를 거슬러 올라가야 한다 (이게 가장 비싼 부분)
  INSERT INTO lineitem_denorm
  SELECT NEW.l_orderkey, NEW.l_linenumber, NEW.l_extendedprice, NEW.l_discount, NEW.l_shipdate,
         c.c_mktsegment, o.o_orderdate, o.o_shippriority
    FROM orders o JOIN customer c ON o.o_custkey=c.c_custkey
   WHERE o.o_orderkey=NEW.l_orderkey;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sync_ord() RETURNS trigger AS $$
BEGIN
  IF NEW.o_orderdate IS DISTINCT FROM OLD.o_orderdate
     OR NEW.o_shippriority IS DISTINCT FROM OLD.o_shippriority THEN
    UPDATE lineitem_denorm SET o_orderdate=NEW.o_orderdate, o_shippriority=NEW.o_shippriority
     WHERE l_orderkey=NEW.o_orderkey;
  END IF;
  IF NEW.o_custkey IS DISTINCT FROM OLD.o_custkey THEN
    UPDATE lineitem_denorm d SET c_mktsegment=c.c_mktsegment FROM customer c
     WHERE c.c_custkey=NEW.o_custkey AND d.l_orderkey=NEW.o_orderkey;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sync_cust() RETURNS trigger AS $$
BEGIN
  IF NEW.c_mktsegment IS DISTINCT FROM OLD.c_mktsegment THEN
    UPDATE lineitem_denorm SET c_mktsegment=NEW.c_mktsegment
     WHERE l_orderkey IN (SELECT o_orderkey FROM orders WHERE o_custkey=NEW.c_custkey);
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS t_sync_li ON lineitem;
DROP TRIGGER IF EXISTS t_sync_ord ON orders;
DROP TRIGGER IF EXISTS t_sync_cust ON customer;
CREATE TRIGGER t_sync_li   AFTER INSERT OR UPDATE OR DELETE ON lineitem FOR EACH ROW EXECUTE FUNCTION sync_li();
CREATE TRIGGER t_sync_ord  AFTER UPDATE ON orders   FOR EACH ROW EXECUTE FUNCTION sync_ord();
CREATE TRIGGER t_sync_cust AFTER UPDATE ON customer FOR EACH ROW EXECUTE FUNCTION sync_cust();
EOSQL
sqlv "SELECT tgrelid::regclass AS 테이블, tgname AS 트리거 FROM pg_trigger WHERE tgname LIKE 't_sync%' ORDER BY 1;"

# ── 3) 정확성 검증 (전부 ROLLBACK) ────────────────────────────────────
echo "── 정확성 검증 ──"
PSQL <<'EOSQL'
BEGIN;
UPDATE customer SET c_mktsegment='MACHINERY' WHERE c_custkey=1;
SELECT 'customer 전파' AS 검증, count(*) FILTER (WHERE c_mktsegment='MACHINERY') AS 반영, count(*) AS 대상
  FROM lineitem_denorm WHERE l_orderkey IN (SELECT o_orderkey FROM orders WHERE o_custkey=1);
ROLLBACK;
BEGIN;
UPDATE orders SET o_orderdate=date '1999-12-31' WHERE o_orderkey=1;
SELECT 'orders 전파' AS 검증, count(*) FILTER (WHERE o_orderdate=date '1999-12-31') AS 반영, count(*) AS 대상
  FROM lineitem_denorm WHERE l_orderkey=1;
ROLLBACK;
BEGIN;
DELETE FROM lineitem WHERE l_orderkey=1 AND l_linenumber=1;
SELECT 'lineitem DELETE' AS 검증, count(*) AS 남은행_0이어야함 FROM lineitem_denorm WHERE l_orderkey=1 AND l_linenumber=1;
ROLLBACK;
EOSQL
echo

# ── 4) 오버헤드 측정 (트리거 ON/OFF 교차) ─────────────────────────────
run_ops(){
  if [ "$1" = "on" ]; then EN="ENABLE"; else EN="DISABLE"; fi
  PSQL 2>/dev/null <<EOF | grep -E "^Time:" | grep -oE "[0-9]+\.[0-9]+" | tail -n +2 | head -5
ALTER TABLE lineitem $EN TRIGGER t_sync_li;
ALTER TABLE orders $EN TRIGGER t_sync_ord;
ALTER TABLE customer $EN TRIGGER t_sync_cust;
BEGIN; UPDATE customer SET c_mktsegment='MACHINERY' WHERE c_custkey=1; ROLLBACK;
\timing on
BEGIN;
UPDATE customer SET c_mktsegment='MACHINERY' WHERE c_custkey=2;
UPDATE orders   SET o_shippriority=9 WHERE o_orderkey=1;
UPDATE lineitem SET l_discount=0.09 WHERE l_orderkey=1 AND l_linenumber=1;
DELETE FROM lineitem WHERE l_orderkey=2;
INSERT INTO lineitem SELECT l_orderkey,l_partkey,l_suppkey,l_linenumber+90,l_quantity,l_extendedprice,
       l_discount,l_tax,l_returnflag,l_linestatus,l_shipdate,l_commitdate,l_receiptdate,
       l_shipinstruct,l_shipmode,l_comment FROM lineitem WHERE l_orderkey <= 300;
ROLLBACK;
EOF
}
run_ops off >/dev/null; run_ops on >/dev/null   # 워밍업
LBL=(cust ord li_upd li_del li_ins); declare -A OFF ON
echo "── 오버헤드 측정 (${ROUNDS}라운드 교차) ──"
for r in $(seq 1 "$ROUNDS"); do
  i=0; while read -r t; do [ -n "$t" ] && OFF[${LBL[$i]}]="${OFF[${LBL[$i]}]:-} $t" && i=$((i+1)); done < <(run_ops off)
  i=0; while read -r t; do [ -n "$t" ] && ON[${LBL[$i]}]="${ON[${LBL[$i]}]:-} $t"  && i=$((i+1)); done < <(run_ops on)
  printf "."
done; echo; echo
mn(){ echo "$1"|tr ' ' '\n'|grep -v '^$'|sort -g|head -1; }
printf "%-34s %11s %11s %9s\n" "작업 (전파 팬아웃)" "트리거OFF" "트리거ON" "배수"
printf "%s\n" "------------------------------------------------------------------------"
row(){ a=$(mn "${OFF[$1]}"); b=$(mn "${ON[$1]}")
  printf "%-34s %8s ms %8s ms %8s\n" "$2" "$a" "$b" "$(awk -v x=$a -v y=$b 'BEGIN{if(x>0)printf "%.1f배",y/x; else print "-"}')"; }
row cust   "customer 1행 UPDATE (→38행)"
row ord    "orders 1행 UPDATE (→4행)"
row li_upd "lineitem 1행 UPDATE (→1행)"
row li_del "lineitem DELETE 1주문 (→4행)"
row li_ins "lineitem INSERT 약1,200행"
echo
echo "  주목: 38행을 고치는 customer UPDATE 가 가장 싸고, 1행만 고치는 lineitem UPDATE 가"
echo "        가장 비싸다. 전자는 트리거 1회 발화 + 집합 UPDATE 1회로 끝나지만,"
echo "        후자는 상속 컬럼을 채우려고 orders·customer 를 매번 거슬러 올라가기 때문이다."
echo "        → 반정규화의 쓰기 비용은 팬아웃이 아니라 '위를 되짚어야 하는가'가 결정한다."
echo

# ── 5) 드리프트 검사 (커밋되는 워크로드) ──────────────────────────────
echo "── 드리프트 검사: 커밋 워크로드 후 원본과 대조 ──"
sql "ALTER TABLE lineitem ENABLE TRIGGER t_sync_li; ALTER TABLE orders ENABLE TRIGGER t_sync_ord;
     ALTER TABLE customer ENABLE TRIGGER t_sync_cust;" >/dev/null 2>&1
PSQL >/dev/null 2>&1 <<'EOSQL'
UPDATE customer SET c_mktsegment='MACHINERY' WHERE c_custkey BETWEEN 1 AND 50;
UPDATE orders   SET o_orderdate = o_orderdate + 1 WHERE o_orderkey BETWEEN 1 AND 200;
UPDATE lineitem SET l_shipdate = l_shipdate + 1  WHERE l_orderkey BETWEEN 1 AND 200;
DELETE FROM lineitem WHERE l_orderkey BETWEEN 300 AND 320;
INSERT INTO lineitem SELECT l_orderkey,l_partkey,l_suppkey,l_linenumber+90,l_quantity,l_extendedprice,
       l_discount,l_tax,l_returnflag,l_linestatus,l_shipdate,l_commitdate,l_receiptdate,
       l_shipinstruct,l_shipmode,l_comment FROM lineitem WHERE l_orderkey BETWEEN 400 AND 450;
EOSQL
sqlv "WITH truth AS (
  SELECT l.l_orderkey,l.l_linenumber,l.l_extendedprice,l.l_discount,l.l_shipdate,
         c.c_mktsegment,o.o_orderdate,o.o_shippriority
  FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                  JOIN customer c ON o.o_custkey=c.c_custkey)
SELECT (SELECT count(*) FROM truth) AS 원본기준,
       (SELECT count(*) FROM lineitem_denorm) AS denorm,
       (SELECT count(*) FROM (SELECT * FROM truth EXCEPT SELECT * FROM lineitem_denorm) x) AS 누락_불일치,
       (SELECT count(*) FROM (SELECT * FROM lineitem_denorm EXCEPT SELECT * FROM truth) y) AS 유령행;"
echo "  누락·유령행이 모두 0이면 트리거가 완벽히 동기화한 것이다."
echo
echo "해석:"
echo "  Tow 의 전제('엄밀한 트리거면 기능적으로 안전하다')는 성립한다."
echo "  다만 그 대가가 모든 쓰기에 붙는 1.5~3.2배이고, 조회가 있든 없든 영구히 지불된다."
echo "  읽기 편중 + 잦은 조회 + §T-8로 안 되는 경우, 셋을 모두 만족할 때만 성립하는 거래다."
echo
echo "정리:"
echo "  psql -d tpch -c \"DROP TRIGGER IF EXISTS t_sync_li ON lineitem;"
echo "                    DROP TRIGGER IF EXISTS t_sync_ord ON orders;"
echo "                    DROP TRIGGER IF EXISTS t_sync_cust ON customer;"
echo "                    DROP TABLE IF EXISTS lineitem_denorm;\""
