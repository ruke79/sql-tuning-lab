#!/usr/bin/env bash
# §T-9 확장: 변경 큐 + 비동기 전파는 동기 트리거보다 싼가.
#
# 지금까지의 흐름
#   t9-trigger-sync.sh  : 동기 트리거는 단일 세션에서 드리프트 0 → "안전해 보인다"
#   t9-concurrency.sh   : 동시성에서 드리프트 재현 → FOR SHARE 로 수정
#   t9-lock-range.sh    : FOR SHARE 는 대형 계정 + 높은 적중률에서 처리량 2.21배 손해
#   이 스크립트          : 그럼 락을 쓰지 않는 세 번째 길은 얼마짜리인가
#
# 비교 대상 (같은 워크로드, 같은 데이터)
#   A. 트리거 없음            — 기준선. 파생 테이블을 갱신하지 않음(= 정합성 포기)
#   B. 동기 트리거 naive      — 즉시 전파, 락 없음        → 드리프트 있음
#   C. 동기 트리거 FOR SHARE  — 즉시 전파, 행 락          → 강한 정합성, 경합 비쌈
#   D. 변경 큐 (워커 OFF)     — 큐에 키만 INSERT          → 쓰기 경로만의 비용
#   E. 변경 큐 (워커 ON)      — D + 백그라운드 전파       → 시스템 전체 비용
#
# 큐 설계에서 중요한 것 두 가지
#   1) 큐에는 **값이 아니라 키만** 넣는다. 워커가 적용 시점에 진실을 다시 읽는다.
#      → 멱등하고 순서에 무관해진다. 같은 키를 열 번 처리해도 결과가 같고,
#        한 배치 안에서 같은 키가 반복되면 한 번만 일한다(합침/coalescing).
#   2) 원본 변경과 큐 INSERT 가 **같은 트랜잭션**에서 커밋된다.
#      → 워커가 큐 항목을 볼 수 있다는 것은 그 변경도 이미 볼 수 있다는 뜻이다.
#        그래서 워커는 절대 낡은 값을 읽지 않는다. 경쟁이 지연으로 바뀐다.
#
# 사용법:
#   ./t9-change-queue.sh            # 8 clients / 15초
#   ./t9-change-queue.sh 16 30
#
# 선행 조건: schema → load → index 완료
# 주의: orders.o_custkey / customer.c_mktsegment / lineitem 을 변형한다. 끝나면 재적재 권장.
set -uo pipefail

CLIENTS="${1:-8}"
SECS="${2:-15}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
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


# PGPASSWORD 은 export 한다. pgbench 도 이 환경변수를 쓰고, timeout 으로 감쌀 psql 도
# 셸 함수가 아니라 실제 명령이어야 하기 때문이다(아래 tsql 주석 참고).
export PGPASSWORD=tuner
# 클라이언트가 호스트에 있을 수도, 컨테이너 안에만 있을 수도 있다. 없다고 그냥 두면
# psql 호출이 전부 빈 값을 돌려주고, 그 빈 값이 **다른 진단으로 둔갑한다** —
# 실제로 "psql: command not found" 뒤에 "lineitem 에 인덱스가 없습니다"가 찍혀,
# 사용자가 멀쩡한 DB 에 index 를 다시 돌렸다. 그래서 여기서 갈라 두고,
# 아래 pg_precheck 이 '클라이언트 없음'과 '접속 불가'와 '인덱스 없음'을 구분해 말한다.
CONTAINER="${CONTAINER:-tuninglab-postgres}"
if command -v psql >/dev/null 2>&1; then
  PG_VIA=host
else
  PG_VIA=docker
fi
if [ "$PG_VIA" = host ]; then
  PSQL(){ psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q "$@"; }
  PGBENCH(){ pgbench -h "$PGHOST_" -p "$PGPORT_" -U tuner "$@"; }
else
  PSQL(){ docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="${PGOPTIONS:-}" "$CONTAINER" psql -U tuner -d tpch -X -q "$@"; }
  PGBENCH(){ docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="${PGOPTIONS:-}" "$CONTAINER" pgbench -U tuner "$@"; }
fi
# 진단을 섞지 않는다 — 원인마다 다른 문장을 준다.
pg_precheck() {
  if [ "$PG_VIA" = docker ] && ! command -v docker >/dev/null 2>&1; then
    echo "  [중단] psql 도 docker 도 없습니다. 둘 중 하나:"
    echo "         sudo apt install postgresql-client"
    echo "         docker compose -f docker/docker-compose.yml up -d postgres"
    exit 1
  fi
  # 이 시점에 sql() 은 아직 정의 전일 수 있다(스크립트마다 순서가 다르다).
  # 정의돼 있는 쪽을 골라 직접 찔러 본다.
  local ok=""
  if declare -f PSQL >/dev/null 2>&1; then ok=$(PSQL -tAc "SELECT 1" 2>/dev/null)
  elif declare -f q >/dev/null 2>&1;    then ok=$(q "SELECT 1" 2>/dev/null); fi
  if ! printf %s "$ok" | grep -q 1; then
    echo "  [중단] PostgreSQL 에 접속할 수 없습니다 (경로: $PG_VIA)."
    [ "$PG_VIA" = docker ] && echo "         docker start $CONTAINER   # 컨테이너 이름이 다르면 CONTAINER=... 로 준다"
    echo "         ./scripts/restore-lab.sh --check"
    exit 1
  fi
}
# 컨테이너 경로에서는 -f 로 줄 파일이 **컨테이너 안에** 있어야 한다. 경로를 바꿔 준다.
pg_stage() {
  if [ "$PG_VIA" = host ]; then printf %s "$1"; return; fi
  docker cp "$1" "$CONTAINER:/tmp/$(basename "$1")" >/dev/null 2>&1
  printf %s "/tmp/$(basename "$1")"
}
pg_precheck

sql(){ PSQL -tAc "$1"; }
# timeout 은 외부 바이너리라 **셸 함수를 실행할 수 없다.**
#   timeout 20 sql "..."  →  "failed to run command 'sql'" 로 즉시 실패한다(정정 목록 10번).
tsql(){ timeout "$1" psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q -tAc "$2"; }

NIDX=$(sql "SELECT count(*) FROM pg_indexes WHERE tablename='lineitem'")
[ "${NIDX:-0}" -lt 2 ] && { echo "  [중단] index 를 먼저 실행하세요."; exit 1; }

echo "§T-9 변경 큐 + 비동기 전파 — ${CLIENTS} clients / ${SECS}초 / $(nproc) CPU"
echo

# ── 스키마 ────────────────────────────────────────────────────────────
PSQL >/dev/null 2>&1 <<'EOSQL'
SET client_min_messages=warning;
DROP TABLE IF EXISTS lineitem_denorm CASCADE;
CREATE TABLE lineitem_denorm (
  l_orderkey BIGINT NOT NULL, l_linenumber INTEGER NOT NULL,
  l_extendedprice DECIMAL(15,2) NOT NULL, l_discount DECIMAL(15,2) NOT NULL,
  l_shipdate DATE NOT NULL, c_mktsegment CHAR(10) NOT NULL,
  o_orderdate DATE NOT NULL, o_shippriority INTEGER NOT NULL,
  CONSTRAINT pk_ld PRIMARY KEY (l_orderkey, l_linenumber));
CREATE INDEX ix_ld_ord ON lineitem_denorm(l_orderkey);

DROP TABLE IF EXISTS denorm_queue;
CREATE TABLE denorm_queue (
  id BIGSERIAL PRIMARY KEY, kind TEXT NOT NULL, k1 BIGINT NOT NULL, k2 INTEGER,
  enq_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp());
DROP TABLE IF EXISTS denorm_stat;
CREATE TABLE denorm_stat(t TIMESTAMPTZ DEFAULT clock_timestamp(), applied INT,
                         distinct_keys INT, lag_ms NUMERIC);
-- ①의 등급값을 매번 확실히 다르게 만들기 위한 시퀀스.
-- random() 을 쓰면 새 값이 옛 값과 같아 트리거가 no-op 이 되는 경우가 섞이고,
-- 최소값을 취하는 순간 **그 no-op 만 골라내게 된다**(실제로 겪었다, 정정 목록 11번).
DROP SEQUENCE IF EXISTS seg_seq; CREATE SEQUENCE seg_seq;

-- 원본 고객 분포를 보관한다. setsize() 가 o_custkey 를 뭉개므로 복원 수단이 필요하다.
DROP TABLE IF EXISTS orders_cust_bak;
CREATE TABLE orders_cust_bak AS SELECT o_orderkey, o_custkey FROM orders;
ALTER TABLE orders_cust_bak ADD PRIMARY KEY (o_orderkey);

-- ── 동기 트리거: 완전 naive(락 없음) ──
CREATE OR REPLACE FUNCTION sync_cust_naive() RETURNS trigger AS $$
BEGIN
  IF NEW.c_mktsegment IS DISTINCT FROM OLD.c_mktsegment THEN
    UPDATE lineitem_denorm SET c_mktsegment=NEW.c_mktsegment
     WHERE l_orderkey IN (SELECT o_orderkey FROM orders WHERE o_custkey=NEW.c_custkey);
  END IF; RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION sync_ord_naive() RETURNS trigger AS $$
DECLARE seg CHAR(10);
BEGIN
  SELECT c_mktsegment INTO seg FROM customer WHERE c_custkey=NEW.o_custkey;
  UPDATE lineitem_denorm SET c_mktsegment=seg, o_orderdate=NEW.o_orderdate,
         o_shippriority=NEW.o_shippriority WHERE l_orderkey=NEW.o_orderkey;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION sync_li_naive() RETURNS trigger AS $$
BEGIN
  INSERT INTO lineitem_denorm
  SELECT NEW.l_orderkey,NEW.l_linenumber,NEW.l_extendedprice,NEW.l_discount,NEW.l_shipdate,
         c.c_mktsegment,o.o_orderdate,o.o_shippriority
    FROM orders o JOIN customer c ON o.o_custkey=c.c_custkey
   WHERE o.o_orderkey=NEW.l_orderkey
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

-- ── 동기 트리거: 3경로 FOR SHARE 수정본 (t9-concurrency.sh 의 결론) ──
CREATE OR REPLACE FUNCTION sync_cust_fs() RETURNS trigger AS $$
BEGIN
  IF NEW.c_mktsegment IS DISTINCT FROM OLD.c_mktsegment THEN
    UPDATE lineitem_denorm SET c_mktsegment=NEW.c_mktsegment
     WHERE l_orderkey IN (SELECT o_orderkey FROM orders WHERE o_custkey=NEW.c_custkey FOR SHARE);
  END IF; RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION sync_ord_fs() RETURNS trigger AS $$
DECLARE seg CHAR(10);
BEGIN
  SELECT c_mktsegment INTO seg FROM customer WHERE c_custkey=NEW.o_custkey FOR SHARE;
  UPDATE lineitem_denorm SET c_mktsegment=seg, o_orderdate=NEW.o_orderdate,
         o_shippriority=NEW.o_shippriority WHERE l_orderkey=NEW.o_orderkey;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION sync_li_fs() RETURNS trigger AS $$
BEGIN
  INSERT INTO lineitem_denorm
  SELECT NEW.l_orderkey,NEW.l_linenumber,NEW.l_extendedprice,NEW.l_discount,NEW.l_shipdate,
         c.c_mktsegment,o.o_orderdate,o.o_shippriority
    FROM orders o JOIN customer c ON o.o_custkey=c.c_custkey
   WHERE o.o_orderkey=NEW.l_orderkey FOR SHARE OF o, c
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

-- ── 큐 적재 트리거: 값이 아니라 키만 넣는다 ──
CREATE OR REPLACE FUNCTION enq_cust() RETURNS trigger AS $$
BEGIN
  IF NEW.c_mktsegment IS DISTINCT FROM OLD.c_mktsegment THEN
    INSERT INTO denorm_queue(kind,k1) VALUES ('cust', NEW.c_custkey);
  END IF; RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION enq_ord() RETURNS trigger AS $$
BEGIN
  IF NEW.o_custkey IS DISTINCT FROM OLD.o_custkey
     OR NEW.o_shippriority IS DISTINCT FROM OLD.o_shippriority
     OR NEW.o_orderdate IS DISTINCT FROM OLD.o_orderdate THEN
    INSERT INTO denorm_queue(kind,k1) VALUES ('ord', NEW.o_orderkey);
  END IF; RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION enq_line() RETURNS trigger AS $$
BEGIN
  INSERT INTO denorm_queue(kind,k1,k2) VALUES ('line', NEW.l_orderkey, NEW.l_linenumber);
  RETURN NEW;
END $$ LANGUAGE plpgsql;

-- ── 워커: 배치를 claim 해서 진실을 다시 읽어 덮어쓴다 ──
CREATE OR REPLACE FUNCTION denorm_drain(batch INT DEFAULT 500) RETURNS INT AS $$
DECLARE ck BIGINT[]; ok BIGINT[]; lk BIGINT[]; ln INT[]; n INT; dk INT; lag NUMERIC;
BEGIN
  WITH claimed AS (
    DELETE FROM denorm_queue WHERE id IN (
      SELECT id FROM denorm_queue ORDER BY id LIMIT batch FOR UPDATE SKIP LOCKED)
    RETURNING kind,k1,k2,enq_at)
  SELECT count(*), count(DISTINCT (kind,k1,k2)),
         max(EXTRACT(epoch FROM clock_timestamp()-enq_at))*1000,
         array_agg(DISTINCT k1) FILTER (WHERE kind='cust'),
         array_agg(DISTINCT k1) FILTER (WHERE kind='ord'),
         array_agg(k1) FILTER (WHERE kind='line'), array_agg(k2) FILTER (WHERE kind='line')
    INTO n, dk, lag, ck, ok, lk, ln FROM claimed;
  IF n = 0 THEN RETURN 0; END IF;

  IF ck IS NOT NULL THEN
    UPDATE lineitem_denorm d SET c_mktsegment = cu.c_mktsegment
      FROM orders o JOIN customer cu ON o.o_custkey = cu.c_custkey
     WHERE d.l_orderkey = o.o_orderkey AND cu.c_custkey = ANY(ck)
       AND d.c_mktsegment IS DISTINCT FROM cu.c_mktsegment;
  END IF;
  IF ok IS NOT NULL THEN
    UPDATE lineitem_denorm d
       SET c_mktsegment=cu.c_mktsegment, o_orderdate=o.o_orderdate, o_shippriority=o.o_shippriority
      FROM orders o JOIN customer cu ON o.o_custkey = cu.c_custkey
     WHERE d.l_orderkey = o.o_orderkey AND o.o_orderkey = ANY(ok)
       AND (d.c_mktsegment,d.o_orderdate,d.o_shippriority)
           IS DISTINCT FROM (cu.c_mktsegment,o.o_orderdate,o.o_shippriority);
  END IF;
  IF lk IS NOT NULL THEN
    INSERT INTO lineitem_denorm
    SELECT DISTINCT ON (l.l_orderkey,l.l_linenumber)
           l.l_orderkey,l.l_linenumber,l.l_extendedprice,l.l_discount,l.l_shipdate,
           cu.c_mktsegment,o.o_orderdate,o.o_shippriority
      FROM unnest(lk,ln) AS q(qk,qn)
      JOIN lineitem l ON l.l_orderkey=q.qk AND l.l_linenumber=q.qn
      JOIN orders o ON o.o_orderkey=l.l_orderkey
      JOIN customer cu ON cu.c_custkey=o.o_custkey
    ON CONFLICT (l_orderkey,l_linenumber) DO UPDATE
      SET c_mktsegment=EXCLUDED.c_mktsegment, o_orderdate=EXCLUDED.o_orderdate,
          o_shippriority=EXCLUDED.o_shippriority;
  END IF;
  INSERT INTO denorm_stat(applied,distinct_keys,lag_ms) VALUES (n,dk,lag);
  RETURN n;
END $$ LANGUAGE plpgsql;

-- 프로시저여야 루프 안에서 COMMIT 할 수 있다. 함수로 만들면 전체가 한 트랜잭션이 되어
-- "비동기 점진 반영"이라는 성질 자체가 사라진다.
CREATE OR REPLACE PROCEDURE denorm_worker(secs NUMERIC, batch INT DEFAULT 500) AS $$
DECLARE dl TIMESTAMPTZ := clock_timestamp() + (secs||' seconds')::interval; n INT;
BEGIN
  LOOP
    EXIT WHEN clock_timestamp() > dl;
    n := denorm_drain(batch);
    COMMIT;
    IF n = 0 THEN PERFORM pg_sleep(0.02); END IF;
  END LOOP;
END $$ LANGUAGE plpgsql;
EOSQL

# ── 헬퍼 ──────────────────────────────────────────────────────────────
mode(){   # off | naive | fs | queue
  sql "DROP TRIGGER IF EXISTS t_sync_cust ON customer; DROP TRIGGER IF EXISTS t_sync_ord ON orders;
       DROP TRIGGER IF EXISTS t_sync_li ON lineitem;   DROP TRIGGER IF EXISTS t_enq_cust ON customer;
       DROP TRIGGER IF EXISTS t_enq_ord ON orders;     DROP TRIGGER IF EXISTS t_enq_line ON lineitem;" >/dev/null 2>&1
  case "$1" in
    naive|fs)
      local s=naive; [ "$1" = fs ] && s=fs
      sql "CREATE TRIGGER t_sync_cust AFTER UPDATE ON customer FOR EACH ROW EXECUTE FUNCTION sync_cust_$s();
           CREATE TRIGGER t_sync_ord  AFTER UPDATE ON orders   FOR EACH ROW EXECUTE FUNCTION sync_ord_$s();
           CREATE TRIGGER t_sync_li   AFTER INSERT ON lineitem FOR EACH ROW EXECUTE FUNCTION sync_li_$s();" >/dev/null 2>&1;;
    queue)
      sql "CREATE TRIGGER t_enq_cust AFTER UPDATE ON customer FOR EACH ROW EXECUTE FUNCTION enq_cust();
           CREATE TRIGGER t_enq_ord  AFTER UPDATE ON orders   FOR EACH ROW EXECUTE FUNCTION enq_ord();
           CREATE TRIGGER t_enq_line AFTER INSERT ON lineitem FOR EACH ROW EXECUTE FUNCTION enq_line();" >/dev/null 2>&1;;
  esac
}
# 벤치가 넣은 합성 라인(l_linenumber>=90)을 치운다. TPC-H 원본은 최대 7이다.
clean_synth(){ sql "DELETE FROM lineitem WHERE l_linenumber >= 90;" >/dev/null 2>&1; }
refill(){ sql "TRUNCATE lineitem_denorm; TRUNCATE denorm_queue; TRUNCATE denorm_stat;
  INSERT INTO lineitem_denorm SELECT l.l_orderkey,l.l_linenumber,l.l_extendedprice,l.l_discount,
         l.l_shipdate,c.c_mktsegment,o.o_orderdate,o.o_shippriority
  FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                  JOIN customer c ON o.o_custkey=c.c_custkey; ANALYZE lineitem_denorm;" >/dev/null 2>&1; }
natural(){ sql "UPDATE orders o SET o_custkey=b.o_custkey FROM orders_cust_bak b
                 WHERE o.o_orderkey=b.o_orderkey AND o.o_custkey IS DISTINCT FROM b.o_custkey;" >/dev/null 2>&1; }
setsize(){ natural; sql "UPDATE orders SET o_custkey=1 WHERE o_orderkey <= $1;" >/dev/null 2>&1; }
drift(){ sql "WITH truth AS (SELECT l.l_orderkey,l.l_linenumber,c.c_mktsegment,o.o_orderdate,o.o_shippriority
              FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                              JOIN customer c ON o.o_custkey=c.c_custkey),
              d AS (SELECT l_orderkey,l_linenumber,c_mktsegment,o_orderdate,o_shippriority FROM lineitem_denorm)
   SELECT (SELECT count(*) FROM (SELECT * FROM truth EXCEPT SELECT * FROM d) x)
        + (SELECT count(*) FROM (SELECT * FROM d EXCEPT SELECT * FROM truth) y)"; }
mn(){ echo "$1"|tr ' ' '\n'|grep -v '^$'|sort -g|head -1; }

# ── ① 단일 세션 쓰기 지연 ─────────────────────────────────────────────
echo "── ① 쓰기 경로 지연: 고객 등급 1건 변경에 걸리는 시간 (5회 최소값) ──"
one(){ PSQL -c "\timing on" -c "BEGIN; UPDATE customer SET c_mktsegment='S'||nextval('seg_seq')
                                WHERE c_custkey=1; ROLLBACK;" 2>/dev/null \
        | grep -m1 "^Time:" | grep -oE "[0-9]+\.[0-9]+"; }
printf "  %-9s %-10s %10s %11s %9s %10s\n" "주문수" "denorm행" "naive" "FOR SHARE" "큐(ms)" "큐/naive"
for N in 10 100 1000 5000; do
  setsize $N; refill
  LD=$(sql "SELECT count(*) FROM lineitem_denorm d JOIN orders o ON d.l_orderkey=o.o_orderkey WHERE o.o_custkey=1")
  R=()
  for M in naive fs queue; do
    mode $M; one >/dev/null; X=""
    for i in 1 2 3 4 5; do X="$X $(one)"; done
    R+=("$(mn "$X")")
  done
  printf "  %-9s %-10s %10s %11s %9s %10s\n" "$N" "$LD" "${R[0]}" "${R[1]}" "${R[2]}" \
    "$(awk -v x=${R[0]} -v y=${R[2]} 'BEGIN{printf "%.2f배",y/x}')"
done
echo "  → 동기 트리거는 팬아웃에 비례해 커진다. 큐는 행 1개 INSERT 라 **크기와 무관하게 상수**다."
echo "  ※ 단, 이 시점에 파생 테이블은 아직 안 고쳐졌다. 일이 사라진 게 아니라 미뤄졌을 뿐이다."
echo

# ── ② 경합 비용 ───────────────────────────────────────────────────────
echo "── ② 경합: 대형 고객(5,000주문) 등급 변경 트랜잭션이 열려 있는 동안 무관한 UPDATE orders ──"
setsize 5000; refill
V=$(sql "SELECT o_orderkey FROM orders WHERE o_custkey=1 ORDER BY o_orderkey LIMIT 1")
for M in naive fs queue; do
  mode $M
  ( sql "BEGIN; UPDATE customer SET c_mktsegment='L'||nextval('seg_seq') WHERE c_custkey=1;
         SELECT pg_sleep(5); ROLLBACK;" >/dev/null 2>&1 ) &
  sleep 2.5
  s=$(date +%s%N); tsql 20 "UPDATE orders SET o_shippriority=7 WHERE o_orderkey=$V;" >/dev/null 2>&1; e=$(date +%s%N)
  printf "  %-10s 피해자 소요: %6d ms\n" "$M" $(( (e-s)/1000000 ))
  wait
done
echo "  → naive 도 막힌다. lineitem_denorm 행을 갱신하며 잡은 행 락이 sync_ord 경로와 겹치기 때문에,"
echo "     FOR SHARE 를 안 써도 대형 고객에서는 어차피 막힌다."
echo "  ※ 큐도 0 은 아니다. 앞선 트랜잭션이 customer 행을 잡고 있고 enq_ord 가 그 행을 읽지는"
echo "     않지만, 큐 테이블 자체와 공용 자원에서 약간의 경합이 남는다. 그래도 한 자릿수 배 차이다."
echo

# ── ③ 처리량 ──────────────────────────────────────────────────────────
declare -A TPS
bench(){ PGBENCH -f "$(pg_stage "$1")" \
           -c "$CLIENTS" -j 4 -T "$SECS" -n tpch 2>&1 | grep -oP 'tps = \K[0-9.]+' | head -1; }
label(){ case $1 in off) echo "A. 트리거 없음";; naive) echo "B. 동기 naive";;
                     fs) echo "C. 동기 FOR SHARE";; queue) echo "D. 큐 (워커 OFF)";;
                     queue_w) echo "E. 큐 (워커 ON)";; esac; }
throughput(){   # $1 = 워크로드 파일
  printf "  %-20s %12s %8s %10s %10s\n" "구성" "tps" "대비" "큐잔량" "드리프트"
  for M in off naive fs queue queue_w; do
    clean_synth; refill
    [ "$M" = queue_w ] && mode queue || mode $M
    WPID=""
    if [ "$M" = queue_w ]; then
      ( sql "CALL denorm_worker($((SECS+20)), 1000);" >/dev/null 2>&1 ) & WPID=$!
      sleep 0.3
    fi
    T=$(bench "$1"); TPS[$M]=$T
    if [ -n "$WPID" ]; then   # 워커가 큐를 비울 때까지 최대 60초 기다린 뒤 최종 상태를 본다
      QW=0; until [ "$(sql "SELECT count(*) FROM denorm_queue")" -eq 0 ] || [ $QW -ge 600 ]; do
        sleep 0.1; QW=$((QW+1)); done
      kill $WPID 2>/dev/null; wait $WPID 2>/dev/null
    fi
    Q=$(sql "SELECT count(*) FROM denorm_queue")
    printf "  %-20s %12s %8s %10s %10s\n" "$(label $M)" "$T" \
      "$(awk -v a=${TPS[off]} -v b=$T 'BEGIN{printf "%.2f배",a/b}')" "$Q" "$(drift)"
  done
}

cat > /tmp/t9_q_nat.sql <<'EOF'
\set cust random(1, 150)
\set ord  random(1, 600)
\set lnum random(90, 99)
\set seg  random(0, 100000)
BEGIN;
UPDATE customer SET c_mktsegment = 'S' || :seg WHERE c_custkey = :cust;
UPDATE orders   SET o_shippriority = :seg % 7 WHERE o_orderkey = :ord;
INSERT INTO lineitem (l_orderkey,l_partkey,l_suppkey,l_linenumber,l_quantity,l_extendedprice,
                      l_discount,l_tax,l_returnflag,l_linestatus,l_shipdate,l_commitdate,
                      l_receiptdate,l_shipinstruct,l_shipmode,l_comment)
SELECT :ord,1,1,:lnum,1,100.00,0.05,0.05,'N','O',
       DATE '1995-01-01',DATE '1995-01-01',DATE '1995-01-01','DELIVER','AIR','q'
 WHERE EXISTS (SELECT 1 FROM orders WHERE o_orderkey = :ord)
ON CONFLICT DO NOTHING;
END;
EOF
cat > /tmp/t9_q_skew.sql <<'EOF'
\set r    random(1, 100)
\set ord  random(1, 5000)
\set lnum random(90, 99)
\set seg  random(0, 100000)
BEGIN;
\if :r <= 5
  UPDATE customer SET c_mktsegment = 'S' || :seg WHERE c_custkey = 1;
\endif
UPDATE orders SET o_shippriority = :seg % 7 WHERE o_orderkey = :ord;
INSERT INTO lineitem (l_orderkey,l_partkey,l_suppkey,l_linenumber,l_quantity,l_extendedprice,
                      l_discount,l_tax,l_returnflag,l_linestatus,l_shipdate,l_commitdate,
                      l_receiptdate,l_shipinstruct,l_shipmode,l_comment)
SELECT :ord,1,1,:lnum,1,100.00,0.05,0.05,'N','O',
       DATE '1995-01-01',DATE '1995-01-01',DATE '1995-01-01','DELIVER','AIR','q'
ON CONFLICT DO NOTHING;
END;
EOF

echo "── ③-a 처리량: 자연 분포 (TPC-H 원본, 고객당 평균 10주문) ──"
clean_synth; natural
throughput /tmp/t9_q_nat.sql
echo

echo "── ③-b 처리량: 편중 (주문 1~5,000 전부 고객1 소유, 5% 트랜잭션이 그 고객 등급 변경) ──"
clean_synth; setsize 5000
throughput /tmp/t9_q_skew.sql
echo

# ── ④ 미뤄진 일은 어디로 갔나 ─────────────────────────────────────────
echo "── ④ 미뤄진 일의 행방: 지연창 · 큐 적체 · 합침 효과 (편중 워크로드) ──"
clean_synth; setsize 5000; refill; mode queue
( sql "CALL denorm_worker($((SECS+40)), 1000);" >/dev/null 2>&1 ) & WPID=$!
sleep 0.3
bench /tmp/t9_q_skew.sql >/dev/null
Q1=$(sql "SELECT count(*) FROM denorm_queue")
s=$(date +%s%N)
QW=0; until [ "$(sql "SELECT count(*) FROM denorm_queue")" -eq 0 ] || [ $QW -ge 600 ]; do sleep 0.1; QW=$((QW+1)); done
e=$(date +%s%N)
kill $WPID 2>/dev/null; wait $WPID 2>/dev/null
PSQL -c "SELECT count(*) AS 배치수, sum(applied) AS 큐항목, sum(distinct_keys) AS 실작업키,
                round(100.0*(1-sum(distinct_keys)::numeric/nullif(sum(applied),0)),1) AS 합침절감pct,
                round(avg(lag_ms)) AS 평균지연ms, round(max(lag_ms)) AS 최대지연ms
           FROM denorm_stat;"
echo "  부하 종료 시점 큐 잔량: $Q1 건 → 소진까지 $(( (e-s)/1000000 )) ms"
echo "  최종 드리프트: $(drift)"
echo "  → 큐는 비용을 없앤 게 아니라 **임계 경로 밖으로 옮겼다.** 총 일의 양은 그대로다."
echo "     바뀐 것은 (a) 사용자가 기다리지 않는다 (b) 락을 오래 잡지 않는다 (c) 배치로 합쳐 덜 일한다."
echo "  ※ 합침절감pct 는 **큐 항목 수 기준**이라 낮게 나온다(ord/line 키는 대부분 서로 다르다)."
echo "     실제 절감은 cust 경로에 몰려 있다. 한 배치의 cust 항목 수십 건이 배열 원소 1개로 접히고,"
echo "     그 1건이 2만 행짜리 UPDATE 를 한 번만 돌게 만든다 — 동기 트리거였다면 수십 번 돌 일이다."
echo

# ── ⑤ 정합성: 겨냥한 경쟁에서 수렴하는가 ──────────────────────────────
echo "── ⑤ 정합성: t9-concurrency.sh 가 잡아낸 H1 경쟁을 큐에서 재현 ──"
clean_synth; setsize 5000; refill; mode queue
ORD=$(sql "SELECT o_orderkey FROM orders WHERE o_custkey=1 ORDER BY o_orderkey LIMIT 1")
( sql "BEGIN; UPDATE customer SET c_mktsegment='R'||nextval('seg_seq') WHERE c_custkey=1;
       SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 ) &
sleep 0.7
sql "UPDATE orders SET o_shippriority=9 WHERE o_orderkey=$ORD;" >/dev/null 2>&1
wait
echo "  전파 전 드리프트: $(drift)   (큐 잔량 $(sql "SELECT count(*) FROM denorm_queue"))"
sql "SELECT denorm_drain(5000); SELECT denorm_drain(5000);" >/dev/null 2>&1
echo "  전파 후 드리프트: $(drift)"
echo "  → 큐 항목이 보인다는 것은 그 변경이 이미 커밋되어 보인다는 뜻이므로, 워커는 낡은 값을"
echo "     읽을 수 없다. naive 동기 트리거의 경쟁(정합성 문제)이 큐에서는 지연(가시성 문제)이 된다."
echo

# ── ⑥ 워커가 죽으면: 정합성 배치 비용 ─────────────────────────────────
echo "── ⑥ 워커가 죽으면 드리프트는 무한정 남는다 → 정합성 배치가 필수 ──"
sql "UPDATE customer SET c_mktsegment='LOST' WHERE c_custkey BETWEEN 1 AND 50;" >/dev/null 2>&1
sql "TRUNCATE denorm_queue;" >/dev/null 2>&1     # 큐/워커 유실 시뮬레이션
echo "  큐 유실 후 드리프트: $(drift)  ← 큐가 비었으므로 워커는 영원히 못 고친다"
RC=""
for i in 1 2 3; do
  s=$(date +%s%N)
  sql "WITH truth AS (SELECT l.l_orderkey,l.l_linenumber,c.c_mktsegment,o.o_orderdate,o.o_shippriority
       FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                       JOIN customer c ON o.o_custkey=c.c_custkey)
       UPDATE lineitem_denorm d SET c_mktsegment=t.c_mktsegment, o_orderdate=t.o_orderdate,
              o_shippriority=t.o_shippriority
         FROM truth t WHERE d.l_orderkey=t.l_orderkey AND d.l_linenumber=t.l_linenumber
          AND (d.c_mktsegment,d.o_orderdate,d.o_shippriority)
              IS DISTINCT FROM (t.c_mktsegment,t.o_orderdate,t.o_shippriority);" >/dev/null 2>&1
  e=$(date +%s%N); RC="$RC $(( (e-s)/1000000 ))"
done
echo "  전량 대사(reconciliation) 소요: $(mn "$RC") ms (3회 최소값, 300만 행 풀스캔)"
echo "  대사 후 드리프트: $(drift)"
echo

echo "해석:"
echo "  · 큐가 산 것: 쓰기 지연의 상수화(팬아웃 무관), 피해 반경 축소, 편중 하에서의 처리량 유지"
echo "  · 자연 분포에서는 큐(E)와 FOR SHARE(C)의 처리량이 거의 같다. 큐의 이득은 처리량이 아니라"
echo "    **쓰기 지연과 피해 반경**이다. 처리량 차이는 편중이 생겨야 벌어진다."
echo "  · 큐가 판 것: 지연창, 큐/워커라는 운영 대상, 대사 배치의 상시 운영,"
echo "                그리고 '읽는 쪽이 낡은 값을 견딜 수 있는가'라는 새 요구사항"
echo "  · 총 일의 양은 줄지 않는다. 옮겨졌을 뿐이다 — 임계 경로 밖으로, 그리고 배치로."
echo "  · 팬아웃 자체가 감당 불가면 큐도 못 구한다. 지연이 무한정 늘 뿐이다."
echo "  → 선택 기준은 '정합성이 중요한가'가 아니라 '읽는 쪽의 지연 예산이 얼마인가'다."
echo

# ── 정리 ──────────────────────────────────────────────────────────────
# 명령을 찍기만 하면 안 된다 — 트리거는 원본의 모든 쓰기에 발화하고, 남은 큐/denorm
# 테이블은 다음 실습의 숫자를 조용히 바꾼다. 되돌릴 수 있는 것은 되돌리고,
# 못 되돌리는 것은 무엇이 남았는지 정확히 말한다.
echo "정리:"
if [ "${KEEP:-0}" = "1" ]; then
  echo "  KEEP=1 — 남겨 둔다. ⚠️ 트리거가 남으면 이후 모든 쓰기에 발화한다."
else
  sql "UPDATE orders o SET o_custkey=b.o_custkey FROM orders_cust_bak b
       WHERE o.o_orderkey=b.o_orderkey AND o.o_custkey IS DISTINCT FROM b.o_custkey;" >/dev/null 2>&1
  sql "DELETE FROM lineitem WHERE l_linenumber >= 90;" >/dev/null 2>&1
  sql "DROP TRIGGER IF EXISTS t_sync_cust ON customer;
        DROP TRIGGER IF EXISTS t_sync_ord ON orders;
        DROP TRIGGER IF EXISTS t_sync_li ON lineitem;
        DROP TABLE IF EXISTS lineitem_denorm, denorm_queue, denorm_stat, orders_cust_bak;" >/dev/null 2>&1
  LT=$(sql "SELECT count(*) FROM pg_trigger WHERE tgname LIKE 't\\_sync%' OR tgname LIKE 't\\_enq%'")
  LR=$(sql "SELECT count(*) FROM lineitem WHERE l_linenumber >= 90")
  echo "  트리거·실험 테이블·합성 행을 지우고 orders.o_custkey 를 되돌렸다."
  echo "  남은 트리거 ${LT} / 합성 lineitem 행 ${LR}   (둘 다 0 이어야 한다)"
  echo "  ※ customer.c_mktsegment 는 측정 중 바뀐 채다. 문서 실측과 맞추려면"
  echo "    ./scripts/restore-lab.sh --force-tpch 로 재적재한다."
fi
