#!/usr/bin/env bash
# §T-9 동시성 검증: 트리거 동기화가 여러 세션에서도 안전한가.
#
# t9-trigger-sync.sh 는 단일 세션에서 드리프트 0을 확인했다. 이 스크립트는 그 결론이
# 동시성에서도 성립하는지 본다. 결론부터: **성립하지 않는다.**
#
# 이 스크립트가 보여주는 것
#   1) 트리거의 동시 쓰기 처리량 비용 (pgbench)
#   2) 무작위 부하로는 드리프트가 안 잡힌다는 사실 (거짓 안심)
#   3) 겨냥하면 드리프트가 재현된다는 사실 (READ COMMITTED 이상현상)
#   4) FOR SHARE 로 고쳐지고, 처리량 손해는 거의 없다는 사실
#
# 핵심 교훈: 파생 데이터의 정합성은 부하 테스트로 검증되지 않는다.
#            "이 두 트랜잭션이 겹치면 어떻게 되는가"를 손으로 따져야 한다.
#
# 사용법:
#   ./t9-concurrency.sh            # 8 clients / 20초
#   ./t9-concurrency.sh 16 30      # 16 clients / 30초
#
# 선행 조건: schema → load → **index** 완료
#   ※ index 를 빼먹으면 lineitem 에 PK 가 없어 ON CONFLICT 가 무력화되고 중복이 들어간다.
#     실제로 그 실수를 했고 측정값이 39배 어긋났다(정정 목록 8번).
set -uo pipefail

CLIENTS="${1:-8}"
SECS="${2:-20}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"

PSQL(){ PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q "$@"; }
sql(){ PSQL -tAc "$1"; }

# ── 선행 조건 점검 ────────────────────────────────────────────────────
NIDX=$(sql "SELECT count(*) FROM pg_indexes WHERE tablename='lineitem'")
if [ "${NIDX:-0}" -lt 2 ]; then
  echo "  [중단] lineitem 에 인덱스가 없습니다. 먼저 실행하세요:"
  echo "         ./gradlew :tpch:bootRun --args=\"index --db=postgres\""
  exit 1
fi

rebuild_denorm(){
  sql "SET client_min_messages=warning; DROP TABLE IF EXISTS lineitem_denorm CASCADE;" >/dev/null 2>&1
  sql "CREATE TABLE lineitem_denorm (
         l_orderkey BIGINT NOT NULL, l_linenumber INTEGER NOT NULL,
         l_extendedprice DECIMAL(15,2) NOT NULL, l_discount DECIMAL(15,2) NOT NULL,
         l_shipdate DATE NOT NULL, c_mktsegment CHAR(10) NOT NULL,
         o_orderdate DATE NOT NULL, o_shippriority INTEGER NOT NULL,
         CONSTRAINT pk_ld PRIMARY KEY (l_orderkey, l_linenumber));" >/dev/null 2>&1
  sql "INSERT INTO lineitem_denorm
       SELECT l.l_orderkey,l.l_linenumber,l.l_extendedprice,l.l_discount,l.l_shipdate,
              c.c_mktsegment,o.o_orderdate,o.o_shippriority
       FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                       JOIN customer c ON o.o_custkey=c.c_custkey; ANALYZE lineitem_denorm;" >/dev/null 2>&1
}

# 소박한 구현 (해저드 있음)
install_naive(){
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
  INSERT INTO lineitem_denorm
  SELECT NEW.l_orderkey,NEW.l_linenumber,NEW.l_extendedprice,NEW.l_discount,NEW.l_shipdate,
         c.c_mktsegment,o.o_orderdate,o.o_shippriority
    FROM orders o JOIN customer c ON o.o_custkey=c.c_custkey
   WHERE o.o_orderkey=NEW.l_orderkey;      -- 잠그지 않고 읽는다 ← 여기가 해저드
  RETURN NEW;
END $$ LANGUAGE plpgsql;
EOSQL
}

# 수정본 (FOR SHARE)
install_fixed(){
PSQL >/dev/null 2>&1 <<'EOSQL'
CREATE OR REPLACE FUNCTION sync_li() RETURNS trigger AS $$
DECLARE seg CHAR(10); od DATE; sp INTEGER;
BEGIN
  IF TG_OP='DELETE' THEN
    DELETE FROM lineitem_denorm WHERE l_orderkey=OLD.l_orderkey AND l_linenumber=OLD.l_linenumber;
    RETURN OLD;
  END IF;
  IF TG_OP='UPDATE' THEN
    DELETE FROM lineitem_denorm WHERE l_orderkey=OLD.l_orderkey AND l_linenumber=OLD.l_linenumber;
  END IF;
  SELECT c.c_mktsegment,o.o_orderdate,o.o_shippriority INTO seg,od,sp
    FROM orders o JOIN customer c ON o.o_custkey=c.c_custkey
   WHERE o.o_orderkey=NEW.l_orderkey
     FOR SHARE OF o, c;                    -- 동시 갱신 중이면 커밋을 기다렸다가 최신 값을 읽는다
  IF FOUND THEN
    INSERT INTO lineitem_denorm VALUES (NEW.l_orderkey,NEW.l_linenumber,NEW.l_extendedprice,
           NEW.l_discount,NEW.l_shipdate,seg,od,sp);
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
EOSQL
}

install_common(){
PSQL >/dev/null 2>&1 <<'EOSQL'
CREATE OR REPLACE FUNCTION sync_ord() RETURNS trigger AS $$
BEGIN
  IF NEW.o_orderdate IS DISTINCT FROM OLD.o_orderdate
     OR NEW.o_shippriority IS DISTINCT FROM OLD.o_shippriority THEN
    UPDATE lineitem_denorm SET o_orderdate=NEW.o_orderdate, o_shippriority=NEW.o_shippriority
     WHERE l_orderkey=NEW.o_orderkey;
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
}

trg(){ if [ "$1" = on ]; then A=ENABLE; else A=DISABLE; fi
  sql "ALTER TABLE lineitem $A TRIGGER t_sync_li; ALTER TABLE orders $A TRIGGER t_sync_ord;
       ALTER TABLE customer $A TRIGGER t_sync_cust;" >/dev/null 2>&1; }

drift(){ sql "WITH truth AS (
   SELECT l.l_orderkey,l.l_linenumber,l.l_extendedprice,l.l_discount,l.l_shipdate,
          c.c_mktsegment,o.o_orderdate,o.o_shippriority
   FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                   JOIN customer c ON o.o_custkey=c.c_custkey)
 SELECT (SELECT count(*) FROM (SELECT * FROM truth EXCEPT SELECT * FROM lineitem_denorm) x)
      + (SELECT count(*) FROM (SELECT * FROM lineitem_denorm EXCEPT SELECT * FROM truth) y)"; }

# pgbench 워크로드
cat > /tmp/t9_concurrent.sql <<'EOF'
\set cust random(1, 150)
\set ord  random(1, 600)
\set lnum random(90, 99)
\set seg  random(0, 4)
BEGIN;
UPDATE customer SET c_mktsegment = 'SEG' || :seg WHERE c_custkey = :cust;
UPDATE orders   SET o_shippriority = :seg WHERE o_orderkey = :ord;
INSERT INTO lineitem (l_orderkey,l_partkey,l_suppkey,l_linenumber,l_quantity,l_extendedprice,
                      l_discount,l_tax,l_returnflag,l_linestatus,l_shipdate,l_commitdate,
                      l_receiptdate,l_shipinstruct,l_shipmode,l_comment)
SELECT :ord,1,1,:lnum,1,100.00,0.05,0.05,'N','O',
       DATE '1995-01-01',DATE '1995-01-01',DATE '1995-01-01','DELIVER','AIR','c'
 WHERE EXISTS (SELECT 1 FROM orders WHERE o_orderkey = :ord)
ON CONFLICT DO NOTHING;
END;
EOF

bench(){ pgbench -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -f /tmp/t9_concurrent.sql \
           -c "$CLIENTS" -j 4 -T "$SECS" -n 2>&1 | grep -E "^tps|latency average"; }

echo "§T-9 동시성 — ${CLIENTS} clients / ${SECS}초"
echo
rebuild_denorm; install_naive; install_common

# ── 1) 처리량 비교 ────────────────────────────────────────────────────
DL0=$(sql "SELECT deadlocks FROM pg_stat_database WHERE datname='tpch'")
echo "── [A] 트리거 OFF (기준선) ──"; trg off; bench
rebuild_denorm
echo; echo "── [B] 트리거 ON (소박한 구현) ──"; trg on; bench
echo "  워크로드 후 드리프트: $(drift)"
DL1=$(sql "SELECT deadlocks FROM pg_stat_database WHERE datname='tpch'")
echo "  데드락: $((DL1-DL0))"
echo
echo "  ⚠️ 드리프트 0이 나와도 안전하다는 뜻이 아니다."
echo "     워크로드가 cust/ord 를 독립적으로 뽑아서, T2가 고른 주문이 하필 T1이 지금"
echo "     고치는 고객의 것인 경우가 거의 안 생겼을 뿐이다. 겨냥해서 다시 만들어 본다."
echo

# ── 2) 겨냥 실험: 해저드 재현 ─────────────────────────────────────────
hazard_test(){  # $1 = 라벨, $2 = 세팅할 등급값
  local ORD LN=$3
  ORD=$(sql "SELECT o_orderkey FROM orders WHERE o_custkey=1 LIMIT 1")
  sql "DELETE FROM lineitem WHERE l_orderkey=$ORD AND l_linenumber=$LN;" >/dev/null 2>&1
  ( PSQL >/dev/null 2>&1 <<EOF
BEGIN;
UPDATE customer SET c_mktsegment='$2' WHERE c_custkey=1;
SELECT pg_sleep(4);
COMMIT;
EOF
  ) &
  sleep 1.5
  sql "INSERT INTO lineitem (l_orderkey,l_partkey,l_suppkey,l_linenumber,l_quantity,l_extendedprice,
       l_discount,l_tax,l_returnflag,l_linestatus,l_shipdate,l_commitdate,l_receiptdate,
       l_shipinstruct,l_shipmode,l_comment)
       VALUES ($ORD,1,1,$LN,1,100.00,0.05,0.05,'N','O',DATE '1995-01-01',DATE '1995-01-01',
               DATE '1995-01-01','DELIVER','AIR','hz');" >/dev/null 2>&1
  wait
  PSQL -c "SELECT '$1' AS 구현, d.c_mktsegment AS denorm기록, c.c_mktsegment AS 실제등급,
             (d.c_mktsegment IS DISTINCT FROM c.c_mktsegment) AS 드리프트
      FROM lineitem_denorm d JOIN orders o ON d.l_orderkey=o.o_orderkey
                             JOIN customer c ON o.o_custkey=c.c_custkey
     WHERE d.l_orderkey=$ORD AND d.l_linenumber=$LN;"
  sql "DELETE FROM lineitem WHERE l_orderkey=$ORD AND l_linenumber=$LN;" >/dev/null 2>&1
}

echo "── 겨냥 실험 ──"
echo "  A: BEGIN; UPDATE customer(고객1) ...  (미커밋 — 트리거가 기존 행들 갱신)"
echo "  B:        INSERT lineitem(고객1의 주문에 새 행)  (트리거가 상위를 읽음)"
echo "  A: COMMIT;"
echo
trg on
hazard_test "소박한 구현" HAZARD 77
echo
install_fixed
hazard_test "FOR SHARE 수정본" FIXED 78

# ── 3) 수정본 처리량 ──────────────────────────────────────────────────
echo
rebuild_denorm
DL2=$(sql "SELECT deadlocks FROM pg_stat_database WHERE datname='tpch'")
echo "── [C] 트리거 ON + FOR SHARE ──"; bench
echo "  워크로드 후 드리프트: $(drift)"
DL3=$(sql "SELECT deadlocks FROM pg_stat_database WHERE datname='tpch'")
echo "  데드락: $((DL3-DL2))"
echo
echo "해석:"
echo "  소박한 트리거는 단일 세션에서 완벽했지만 동시성에서는 조용히 어긋난다."
echo "  더 나쁜 것은 무작위 부하로는 그 사실이 드러나지도 않았다는 점이다."
echo "  → 정합성 결함은 부하 테스트가 아니라 트랜잭션 겹침을 손으로 따져서 찾아야 한다."
echo "  → 반정규화 비용에 '설계 난이도'가 하나 더 붙는다."
echo
echo "주의: 이 스크립트는 원본 테이블을 커밋 변경한다. 끝나면 재적재를 권한다:"
echo "  ./gradlew :tpch:bootRun --args=\"schema --db=postgres\""
echo "  ./gradlew :tpch:bootRun --args=\"load --db=postgres\""
echo "  ./gradlew :tpch:bootRun --args=\"index --db=postgres\"   ← 빼먹지 말 것"
