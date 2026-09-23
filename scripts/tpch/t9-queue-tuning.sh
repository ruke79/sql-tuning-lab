#!/usr/bin/env bash
# §T-9 확장: 큐의 지연창은 워커 수와 배치 크기로 어디까지 줄어드는가.
#
# t9-change-queue.sh 는 워커 1개 / 배치 1,000 에서 평균 4.4초 · 최대 6.7초를 쟀다.
# 그 값은 **설정 하나의 결과**이지 큐라는 방식의 성질이 아니다. 여기서 축을 하나씩 훑는다.
#
# 이 스크립트가 답하는 질문
#   ① 배치를 키우면 지연이 주는가?             → 준다. 정확히는 "따라잡는 구간"으로 옮겨준다
#   ② 워커를 늘리면 지연이 주는가?             → 아니다. 어느 분포에서도 도움이 안 됐다
#   ③ 핫키가 없으면 어떻게 되는가?             → 잔량이 0 으로 돌아온다. 단 지연 자릿수는 안 바뀐다
#   ④ 큰 배치는 저부하에서 손해 아닌가?        → 아니다. 배치 크기는 **상한**이지 목표가 아니다
#   ⑤ 따라잡지 못하면?                         → 지연이 수렴하지 않는다. 그건 지연창이 아니라 적체다
#
# 측정 설계에서 중요한 것 두 가지
#   · **지연창은 워커가 따라잡을 때만 의미가 있다.** 포화에서 잰 "평균 지연"은 시스템의 성질이
#     아니라 테스트 길이의 함수다. 그래서 ①~④는 -R 로 도착률을 묶고, ⑤만 일부러 포화시킨다.
#   · **조건은 라운드로 교차 측정한다**(§T-0 원칙 6). 한 조건을 연속 3회 재는 batch 방식은
#     그 사이의 시간대 드리프트를 조건 차이로 착각하게 만든다. 여기서는 라운드마다
#     전 조건을 한 번씩 돌고, 조건별 **중앙값**을 쓴다. 실제로 batch 방식 1회 측정에서는
#     워커 축이 완전히 뒤죽박죽으로 나왔다.
#
# 사용법:
#   ./t9-queue-tuning.sh              # 8 clients / 12초 / 목표 800 tps / 3 라운드
#   ./t9-queue-tuning.sh 8 12 800 3
#
# 선행 조건: schema → load → index 완료
# 주의: orders.o_custkey / customer / lineitem 을 변형한다. 끝나면 재적재 권장.
set -uo pipefail

CLIENTS="${1:-8}"
SECS="${2:-12}"
RATE="${3:-800}"
ROUNDS="${4:-3}"
DEEP=$(( ROUNDS + 2 ))   # 핵심 두 축(①②)은 라운드를 더 준다
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
# ── 규모 가드 ── (sql/q 정의 **뒤**여야 한다 — 앞에 뒀다가 "sql: command not found")
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/_scale-guard.inc"
scale_guard "$(sql "SELECT count(*) FROM lineitem")" 3 "$0"

NIDX=$(sql "SELECT count(*) FROM pg_indexes WHERE tablename='lineitem'")
[ "${NIDX:-0}" -lt 2 ] && { echo "  [중단] index 를 먼저 실행하세요."; exit 1; }

echo "§T-9 큐 튜닝 — 워커 수 × 배치 크기에 따른 지연창"
echo "   ${CLIENTS} clients / ${SECS}초 / $(nproc) CPU / 정상 부하 목표 ${RATE} tps / ${ROUNDS} 라운드 교차"
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
CREATE INDEX ix_ld_ln  ON lineitem_denorm(l_linenumber);   -- 합성행 정리용

DROP TABLE IF EXISTS denorm_queue;
CREATE TABLE denorm_queue (
  id BIGSERIAL PRIMARY KEY, kind TEXT NOT NULL, k1 BIGINT NOT NULL, k2 INTEGER,
  enq_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp());
DROP TABLE IF EXISTS denorm_stat;
-- 배치별로 항목 수 / 실제 작업 키 수 / 지연 평균·최대를 남긴다.
-- cust 경로는 따로 센다 — 합침 효과가 거기에 몰려 있기 때문이다.
CREATE TABLE denorm_stat(t TIMESTAMPTZ DEFAULT clock_timestamp(),
  applied INT, cust_items INT, cust_keys INT, avg_lag NUMERIC, max_lag NUMERIC);

DROP TABLE IF EXISTS orders_cust_bak;
CREATE TABLE orders_cust_bak AS SELECT o_orderkey, o_custkey FROM orders;
ALTER TABLE orders_cust_bak ADD PRIMARY KEY (o_orderkey);

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

-- 워커는 배치가 **채워지기를 기다리지 않는다.** LIMIT batch 로 "있는 만큼" 가져간다.
-- 그래서 batch 는 상한이지 목표가 아니고, 저부하에서 큰 batch 를 써도 지연이 늘지 않는다(④).
-- **다른 실습이 남긴 같은 이름의 함수를 먼저 지운다.**
-- t9-notify-vs-poll.sh 는 denorm_drain 을 (OUT applied, OUT depth) 로 정의한다 —
-- 반환형이 record 라서 여기 INT 버전이 CREATE OR REPLACE 로 **덮이지 않는다**:
--   ERROR: cannot change return type of existing function
-- 그런데 이 heredoc 은 2>/dev/null 이라 그 에러가 삼켜진다. 그러면 남의 함수가 그대로
-- 살아 있고, denorm_worker 가 n := denorm_drain(batch) 에서 런타임에 죽는다:
--   ERROR: invalid input syntax for type integer: "(0,0)"
-- 워커는 아무것도 못 비우고 **표는 전부 0ms 로 찍힌다** — 실패가 측정값으로 둔갑한다.
-- 실제로 notify-vs-poll 을 먼저 돌린 환경에서 그 상태가 나왔다.
DROP FUNCTION IF EXISTS denorm_drain(INT);
CREATE OR REPLACE FUNCTION denorm_drain(batch INT DEFAULT 500) RETURNS INT AS $$
DECLARE ck BIGINT[]; ok BIGINT[]; lk BIGINT[]; ln INT[];
        n INT; ci INT; cknt INT; al NUMERIC; ml NUMERIC;
BEGIN
  WITH claimed AS (
    DELETE FROM denorm_queue WHERE id IN (
      SELECT id FROM denorm_queue ORDER BY id LIMIT batch FOR UPDATE SKIP LOCKED)
    RETURNING kind,k1,k2,enq_at)
  SELECT count(*), count(*) FILTER (WHERE kind='cust'), count(DISTINCT k1) FILTER (WHERE kind='cust'),
         avg(EXTRACT(epoch FROM clock_timestamp()-enq_at))*1000,
         max(EXTRACT(epoch FROM clock_timestamp()-enq_at))*1000,
         array_agg(DISTINCT k1) FILTER (WHERE kind='cust'),
         array_agg(DISTINCT k1) FILTER (WHERE kind='ord'),
         array_agg(k1) FILTER (WHERE kind='line'), array_agg(k2) FILTER (WHERE kind='line')
    INTO n, ci, cknt, al, ml, ck, ok, lk, ln FROM claimed;
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
  INSERT INTO denorm_stat(applied,cust_items,cust_keys,avg_lag,max_lag) VALUES (n,ci,cknt,al,ml);
  RETURN n;
END $$ LANGUAGE plpgsql;

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

# ── 준비가 실제로 먹었는지 확인한다 ─────────────────────────────────
# **위 heredoc 은 2>/dev/null 이라 실패를 삼킨다.** 삼켜진 실패는 0ms 측정값으로
# 둔갑한다 — 워커가 못 도는데 표는 멀쩡히 찍히고 해석문이 그 0 을 서술한다.
# 실제로 t9-notify-vs-poll 이 남긴 record 반환 denorm_drain 때문에 그 상태가 나왔다.
# 그래서 만들어 놓고 **불러 본다.** 여기서 죽는 게 0ms 표를 믿는 것보다 낫다.
DRAIN_RET=$(sql "SELECT pg_get_function_result(oid) FROM pg_proc WHERE proname='denorm_drain'")
if [ "$DRAIN_RET" != "integer" ]; then
  echo "  [중단] denorm_drain 의 반환형이 'integer' 가 아니라 '${DRAIN_RET:-없음}' 이다."
  echo "         다른 실습(t9-notify-vs-poll)이 남긴 함수가 그대로 살아 있다는 뜻이다."
  echo "         CREATE OR REPLACE 는 반환형을 못 바꾸므로 조용히 덮이지 않았다."
  echo "         이 상태로 두면 워커가 런타임에 죽고 **표가 전부 0 으로 찍힌다.**"
  echo "         고치려면:  psql -U tuner -d tpch -c 'DROP FUNCTION IF EXISTS denorm_drain(INT)'"
  exit 1
fi
CALL_ERR=$(PSQL -tAc "CALL denorm_worker(0.1, 10);" 2>&1 | grep -i "^ERROR" | head -1)
if [ -n "$CALL_ERR" ]; then
  echo "  [중단] 워커를 불러 봤더니 실패한다: $CALL_ERR"
  echo "         준비 단계가 제대로 안 돌았다. 이 상태의 측정값은 전부 0 이 된다."
  exit 1
fi


sql "DROP TRIGGER IF EXISTS t_enq_cust ON customer; DROP TRIGGER IF EXISTS t_enq_ord ON orders;
     DROP TRIGGER IF EXISTS t_enq_line ON lineitem;
     CREATE TRIGGER t_enq_cust AFTER UPDATE ON customer FOR EACH ROW EXECUTE FUNCTION enq_cust();
     CREATE TRIGGER t_enq_ord  AFTER UPDATE ON orders   FOR EACH ROW EXECUTE FUNCTION enq_ord();
     CREATE TRIGGER t_enq_line AFTER INSERT ON lineitem FOR EACH ROW EXECUTE FUNCTION enq_line();" >/dev/null 2>&1

# ── 헬퍼 ──────────────────────────────────────────────────────────────
full_refill(){ sql "TRUNCATE lineitem_denorm;
  INSERT INTO lineitem_denorm SELECT l.l_orderkey,l.l_linenumber,l.l_extendedprice,l.l_discount,
         l.l_shipdate,c.c_mktsegment,o.o_orderdate,o.o_shippriority
  FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                  JOIN customer c ON o.o_custkey=c.c_custkey; ANALYZE lineitem_denorm;" >/dev/null 2>&1; }
# 조건 사이에는 30초짜리 전량 재적재 대신 가벼운 정리 + 대사만 한다.
light_reset(){ sql "DELETE FROM lineitem WHERE l_linenumber >= 90;
  DELETE FROM lineitem_denorm WHERE l_linenumber >= 90;
  TRUNCATE denorm_queue; TRUNCATE denorm_stat;
  WITH truth AS (SELECT l.l_orderkey,l.l_linenumber,c.c_mktsegment,o.o_orderdate,o.o_shippriority
                 FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                                 JOIN customer c ON o.o_custkey=c.c_custkey)
  UPDATE lineitem_denorm d SET c_mktsegment=t.c_mktsegment, o_orderdate=t.o_orderdate,
         o_shippriority=t.o_shippriority
    FROM truth t WHERE d.l_orderkey=t.l_orderkey AND d.l_linenumber=t.l_linenumber
     AND (d.c_mktsegment,d.o_orderdate,d.o_shippriority)
         IS DISTINCT FROM (t.c_mktsegment,t.o_orderdate,t.o_shippriority);" >/dev/null 2>&1
  # 조건마다 사표를 치운다. 반복 UPDATE/DELETE 로 dead tuple 이 쌓이면 뒤 조건이 불리해지고,
  # 그 누적 효과를 조건 차이로 착각하게 된다(라운드 교차만으로는 안 지워지는 편향이다).
  sql "VACUUM (ANALYZE) lineitem_denorm; VACUUM (ANALYZE) lineitem; VACUUM denorm_queue;" >/dev/null 2>&1; }
natural(){ sql "UPDATE orders o SET o_custkey=b.o_custkey FROM orders_cust_bak b
                 WHERE o.o_orderkey=b.o_orderkey AND o.o_custkey IS DISTINCT FROM b.o_custkey;" >/dev/null 2>&1; }
setsize(){ natural; sql "UPDATE orders SET o_custkey=1 WHERE o_orderkey <= $1;" >/dev/null 2>&1; }
# 짝수 개일 때 가운데 두 값의 평균을 쓴다. a[NR/2] 만 취하면 **둘 중 작은 쪽**이 나와
# 낙관적으로 편향된다 — 실제로 2라운드 측정에서 그 편향에 속았다(정정 목록 13번).
med(){ echo "$1"|tr ' ' '\n'|grep -v '^$'|sort -g|awk '{a[NR]=$1}
       END{if(NR%2) print a[(NR+1)/2]; else printf "%.0f\n",(a[NR/2]+a[NR/2+1])/2}'; }

cat > /tmp/t9t_skew.sql <<'EOF'
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
cat > /tmp/t9t_nat.sql <<'EOF'
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

WPIDS=()
start_workers(){ WPIDS=()
  for _ in $(seq 1 "$1"); do
    ( sql "CALL denorm_worker($((SECS+40)), $2);" >/dev/null 2>&1 ) & WPIDS+=($!)
  done; sleep 0.3; }
stop_workers(){ for p in "${WPIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
                for p in "${WPIDS[@]:-}"; do [ -n "$p" ] && wait "$p" 2>/dev/null; done; WPIDS=(); }

# 한 조건 1회 → "tps 평균지연 최대지연 합침배수 처리항목 잔량 소진ms"
run_case(){   # $1=워크로드 $2=워커수 $3=배치 $4=목표rate("" 면 무제한)
  light_reset
  start_workers "$2" "$3"
  local extra=""; [ -n "${4:-}" ] && extra="-R $4"
  local T; T=$(PGBENCH -f "$(pg_stage "$1")" -c "$CLIENTS" -j 4 \
                 -T "$SECS" -n $extra tpch 2>&1 | grep -oP 'tps = \K[0-9.]+' | head -1)
  local Q1; Q1=$(sql "SELECT count(*) FROM denorm_queue")
  local s e QW; s=$(date +%s%N); QW=0
  until [ "$(sql "SELECT count(*) FROM denorm_queue")" -eq 0 ] || [ $QW -ge 400 ]; do sleep 0.1; QW=$((QW+1)); done
  e=$(date +%s%N)
  stop_workers
  # 필드: 1=tps 2=평균지연 3=최대지연 4=합침배수 5=총처리항목 6=잔량 7=소진ms 8=배치횟수 9=배치당항목
  local ST; ST=$(sql "SELECT round(coalesce(sum(applied*avg_lag)/nullif(sum(applied),0),0))||' '||
                             round(coalesce(max(max_lag),0))||' '||
                             coalesce(round(sum(cust_items)::numeric/nullif(sum(cust_keys),0),1),0)||' '||
                             coalesce(sum(applied),0)  FROM denorm_stat")
  local BT; BT=$(sql "SELECT count(*)||' '||coalesce(round(avg(applied)),0) FROM denorm_stat")
  echo "${T%%.*} $ST $Q1 $(( (e-s)/1000000 )) $BT"
}

# 라운드 교차 실행기. CELLS 배열(문자열 "워커:배치")을 라운드마다 한 번씩 돈다.
declare -A ACC
sweep(){   # $1=워크로드 $2=rate $3=라운드수 $4...=셀들
  local wl="$1" rate="$2" rounds="$3"; shift 3
  local cells=("$@") c
  for c in "${cells[@]}"; do ACC[$c]=""; done
  for r in $(seq 1 "$rounds"); do
    for c in "${cells[@]}"; do
      local w="${c%%:*}" b="${c##*:}"
      ACC[$c]="${ACC[$c]}|$(run_case "$wl" "$w" "$b" "$rate")"
    done
  done
}
col(){ echo "${ACC[$1]}" | tr '|' '\n' | grep -v '^$' | awk -v n="$2" '{print $n}' | tr '\n' ' '; }
# 라운드 간 산포를 같이 낸다. 중앙값만 내면 "조건 차이"와 "그날의 운"을 구분할 수 없다.
rng(){ echo "$1"|tr ' ' '\n'|grep -v '^$'|sort -g|awk '{a[NR]=$1} END{print a[1]"~"a[NR]}'; }
show(){ # $1=셀 $2=라벨1 $3=라벨2
  printf "  %-7s %-7s %8s %10s %-14s %10s %8s %8s\n" "$2" "$3" \
    "$(med "$(col "$1" 1)")" "$(med "$(col "$1" 2)")" "$(rng "$(col "$1" 2)")" \
    "$(med "$(col "$1" 3)")" "$(med "$(col "$1" 4)")배" "$(med "$(col "$1" 6)")"; }
hdr(){ printf "  %-7s %-7s %8s %10s %-14s %10s %8s %8s\n" "$1" "$2" \
         "달성tps" "지연중앙" "지연범위(ms)" "최대지연ms" "합침" "잔량"; }
# **해석문에 숫자를 박아 두지 않는다.** sweep 이 셀 데이터를 덮어쓰므로, 각 절이 끝나는
# 자리에서 그 절의 값을 변수에 잡아 둔 뒤 해석에서 쓴다. 예전에는 옛 실행의 숫자
# (121ms · 1581ms · 81→182→601 · 합침 1.2배 …)가 그대로 박혀 있어, 표와 해설이
# 거의 전부 어긋났다 — 사용자 실행에서 ③ 표는 12/11/11ms 인데 해설은 81/182/601 을 말했다.
lat(){ med "$(col "$1" 2)"; }          # 지연 중앙값
rngo(){ rng "$(col "$1" 2)"; }         # 지연 범위 "a~b"
fold(){ med "$(col "$1" 4)"; }         # 합침 배수
qlen(){ med "$(col "$1" 6)"; }         # 잔량
width(){ awk -F'~' '{printf "%d", ($2+0)-($1+0)}' <<<"$1"; }   # 범위 폭

# ── ① 배치 스윕 (편중, 워커 1개 고정) ─────────────────────────────────
echo "── ① 배치 크기 스윕 · 편중 워크로드 · 워커 1개 · -R ${RATE} (${DEEP}라운드 중앙값) ──"
setsize 5000; full_refill
sweep /tmp/t9t_skew.sql "$RATE" "$DEEP" "1:100" "1:500" "1:2000"
hdr "워커" "배치"
for B in 100 500 2000; do show "1:$B" "1" "$B"; done
S1_100=$(lat 1:100); S1_2000=$(lat 1:2000)
G1_100=$(rngo 1:100); G1_2000=$(rngo 1:2000)
W1_100=$(width "$G1_100"); W1_2000=$(width "$G1_2000")
if awk -v a="$S1_100" -v b="$S1_2000" 'BEGIN{exit !(a>b*1.5)}'; then
  echo "  → 배치 2000 의 중앙값이 배치 100 보다 낮다(${S1_2000} vs ${S1_100}ms)."
else
  echo "  → 이번 실행에서는 **중앙값 자체는 배치를 키워도 안 낮아졌다**(100:${S1_100} / 2000:${S1_2000}ms)."
fi
if [ "${W1_2000:-0}" -lt "${W1_100:-0}" ]; then
  echo "     **달라진 것은 범위다** — 100 은 ${G1_100}, 2000 은 ${G1_2000} (폭 ${W1_100} → ${W1_2000}ms)."
  echo "     넓은 범위는 '느리다'가 아니라 **따라잡기가 불안정하다**는 뜻이다."
else
  echo "     범위도 좁아지지 않았다(100: ${G1_100} / 2000: ${G1_2000}) — 이 실행에서는 배치 효과가 안 보인다."
fi
echo "     따라잡으면 수백 ms, 한 번 밀리면 적체가 자기 자신을 키워 수천 ms 로 간다 — 쌍봉 분포다."
echo "     즉 배치 크기가 정하는 것은 평균 지연이 아니라 **안정 구간에 있느냐**다."
echo "     (다만 포화 부하에서는 이 이득도 사라진다. ⑤ 참조)"
echo

# ── ② 워커 스윕 (편중, 배치 2000 고정) ────────────────────────────────
echo "── ② 워커 수 스윕 · 편중 워크로드 · 배치 2000 · -R ${RATE} (${DEEP}라운드 중앙값) ──"
sweep /tmp/t9t_skew.sql "$RATE" "$DEEP" "1:2000" "2:2000" "4:2000"
hdr "워커" "배치"
for W in 1 2 4; do show "$W:2000" "$W" "2000"; done
S2_1=$(lat 1:2000); S2_2=$(lat 2:2000); S2_4=$(lat 4:2000)
echo "  → 워커 수별 지연 중앙값: 1개 ${S2_1} / 2개 ${S2_2} / 4개 ${S2_4}ms."
if awk -v a="$S2_1" -v b="$S2_4" 'BEGIN{exit !(b>a*1.2)}'; then
  echo "     **늘려서 얻는 것이 없다** — 4개가 오히려 나쁘다."
else
  echo "     **늘려서 얻는 것이 없다** — 서로 구분되지 않는다."
fi
echo "     워커들이 전부 같은 고객1의 denorm 행을 갱신하려 하므로 서로를 기다리고,"
echo "     4 CPU 짜리 장비에서 8개 클라이언트와 CPU 도 나눠 갖는다."
echo

# ── ③ 대조: 핫키가 없으면 ─────────────────────────────────────────────
echo "── ③ 대조 · 자연 분포(핫키 없음) · 배치 2000 · -R ${RATE} ──"
natural; full_refill
sweep /tmp/t9t_nat.sql "$RATE" "$ROUNDS" "1:2000" "2:2000" "4:2000"
hdr "워커" "배치"
for W in 1 2 4; do show "$W:2000" "$W" "2000"; done
N3_1=$(lat 1:2000); N3_2=$(lat 2:2000); N3_4=$(lat 4:2000)
echo "  → 워커 1개에서 잔량 $(qlen 1:2000), 합침배수 $(fold 1:2000)배 — 접을 것이 없다는 뜻이다."
if awk -v a="$N3_1" -v b="$N3_4" 'BEGIN{exit !(b>a*1.3)}'; then
  echo "  ※ 그런데 여기서도 워커를 늘리면 **지연이 는다**(${N3_1} → ${N3_2} → ${N3_4}ms). 핫키가 없으니"
  echo "     행 경합은 아니다. CPU 를 클라이언트와 나눠 쓰는 비용이다."
  echo "     즉 '워커를 늘리면 빨라진다'는 어느 분포에서도 성립하지 않았다."
else
  echo "  ※ 이번 실행에서는 워커 수가 지연을 거의 안 바꿨다(${N3_1} → ${N3_2} → ${N3_4}ms)."
  echo "     늘려서 **나빠지지는 않았지만 좋아지지도 않았다** — 접을 것이 없으니 당연하다."
fi
echo "  ※ 한편 W1 기준 지연은 편중(①의 ${S1_2000}ms, ②의 ${S2_1}ms)과 비교해 볼 것."
echo "     워크로드가 자릿수를 바꾸는 건 **따라잡지 못하게 될 때**이지, 편중 그 자체가 아니다."
echo

# ── ④ 큰 배치는 저부하에서 손해인가 ───────────────────────────────────
echo "── ④ 배치는 상한인가 목표인가 · 자연 분포 · 저부하 -R 200 · 워커 1개 ──"
sweep /tmp/t9t_nat.sql 200 "$ROUNDS" "1:100" "1:2000"
hdr "워커" "배치"
for B in 100 2000; do show "1:$B" "1" "$B"; done
echo "  → 두 값이 사실상 같다. 워커는 배치가 채워지기를 기다리지 않고 'LIMIT batch 로 있는 만큼'"
echo "     가져가기 때문이다. 즉 **batch 는 상한이지 목표가 아니고, 큰 값으로 두어 손해가 없다.**"
echo "     (배치가 찰 때까지 기다리는 설계였다면 여기서 큰 배치가 훨씬 불리하게 나왔을 것이다.)"
echo

# ── ⑤ 포화: 배치를 키우면 용량이 느는가 ───────────────────────────────
echo "── ⑤ 포화 부하(무제한) · 편중 · 워커 1개 · 배치 스윕 (${ROUNDS}라운드 중앙값) ──"
setsize 5000; full_refill
sweep /tmp/t9t_skew.sql "" "$ROUNDS" "1:100" "1:500" "1:2000"
printf "  %-8s %8s %11s %9s %11s %11s %9s\n" "배치" "부하tps" "평균지연ms" "배치횟수" "배치당항목" "총처리항목" "적체"
for B in 100 500 2000; do
  NB=$(med "$(col "1:$B" 8)"); PB=$(med "$(col "1:$B" 9)")
  printf "  %-8s %8s %11s %9s %11s %11s %9s\n" "$B" \
    "$(med "$(col "1:$B" 1)")" "$(med "$(col "1:$B" 2)")" "$NB" "$PB" \
    "$(awk -v a=$NB -v b=$PB 'BEGIN{printf "%d",a*b}')" "$(med "$(col "1:$B" 6)")"
done
D5_100=$(lat 1:100); D5_2000=$(lat 1:2000); Q5_100=$(qlen 1:100); Q5_2000=$(qlen 1:2000)
echo "  → 배치를 8배 키우면 배치당 항목은 늘지만 배치 횟수가 그만큼 준다."
echo "     **총 처리항목은 거의 변하지 않는다** — 포화에서 배치 크기는 용량을 사주지 않는다."
echo "     여기서의 '평균지연'도 시스템의 성질이 아니라 적체가 자라는 속도의 함수일 뿐이다."
echo

echo "해석:"
echo "  · 지연창은 연속적으로 변하는 값이 아니다. **따라잡느냐 아니냐**가 자릿수를 정한다."
echo "    - ①의 배치 2000: 중앙 ${S1_2000}ms, 범위 ${G1_2000}"
echo "    - ①의 배치 100 : 중앙 ${S1_100}ms, 범위 ${G1_100}   ← 범위 폭이 ${W1_100}ms 로 넓다면 그게 불안정 신호다"
echo "    - ⑤ 포화: 평균지연 100:${D5_100} / 2000:${D5_2000}ms, 적체 ${Q5_100} / ${Q5_2000}"
echo "      적체가 0 으로 안 돌아오면 그건 지연창이 아니라 **적체**다 — 지연 수치의 뜻이 달라진다."
echo "    같은 설정에서도 라운드마다 두 구간을 오가므로 **범위를 같이 봐야** 판단이 선다."
echo "  · 배치 크기가 하는 일은 지연을 줄이는 게 아니라 **그 경계를 옮기는 것**이다."
echo "    'LIMIT batch' 설계라 저부하 손해가 없으니(④) 넉넉히 잡는 쪽이 기본값이다."
echo "    단 포화에서는 총 처리항목이 거의 같다(⑤) — 경계를 옮길 뿐 용량을 사주지는 않는다."
echo "  · 워커 수는 **어느 분포에서도 도움이 안 됐다.** 편중에서는 같은 행을 두고 직렬화하고(②),"
echo "    자연 분포에서도 좋아지지 않았다(③: ${N3_1} → ${N3_2} → ${N3_4}ms)."
echo "    워커를 늘리는 것은 전파 경로가 CPU 여유가 있고 키가 흩어져 있을 때만 의미가 있다."
echo "  → 튜닝 순서: (1) 지금 따라잡고 있는지부터 본다(잔량이 0 으로 돌아오는가)"
echo "     (2) 아니면 배치를 키워 경계를 옮긴다  (3) 그래도 안 되면 워커가 아니라 **모델**을 본다 —"
echo "     그 컬럼을 반정규화하지 않거나, 핫 계정을 쪼개 팬아웃 자체를 줄여야 한다."
echo
echo "  ※ 비교는 **같은 스윕 안에서만** 유효하다. ①의 (워커1·배치2000)은 ${S1_2000}ms, ②의 같은"
echo "     조건은 ${S2_1}ms 로 $(awk -v a="$S1_2000" -v b="$S2_1" 'BEGIN{x=(a>b)?a/b:b/a; printf "%.1f", x}')배 차이가 났다 —"
echo "     같은 설정인데도 그렇다. 라운드 교차는 스윕 **내부**의 드리프트만 지운다."
echo "     스윕끼리의 절대값 비교는 하지 말 것."
echo
# 명령을 찍기만 하면 안 된다 — 트리거는 원본의 모든 쓰기에 발화한다. 직접 되돌린다.
echo "정리:"
if [ "${KEEP:-0}" = "1" ]; then
  echo "  KEEP=1 — 남겨 둔다. ⚠️ t_enq% 트리거가 남으면 이후 모든 쓰기에 발화한다."
else
  sql "UPDATE orders o SET o_custkey=b.o_custkey FROM orders_cust_bak b
       WHERE o.o_orderkey=b.o_orderkey AND o.o_custkey IS DISTINCT FROM b.o_custkey;" >/dev/null 2>&1
  sql "DELETE FROM lineitem WHERE l_linenumber >= 90;" >/dev/null 2>&1
  sql "DROP TRIGGER IF EXISTS t_enq_cust ON customer;
       DROP TRIGGER IF EXISTS t_enq_ord ON orders;
       DROP TRIGGER IF EXISTS t_enq_line ON lineitem;   # 이름을 t_enq_li 로 잘못 적어 안 지워지고 있었다
       DROP TABLE IF EXISTS lineitem_denorm, denorm_queue, denorm_stat, orders_cust_bak;" >/dev/null 2>&1
  LT=$(sql "SELECT count(*) FROM pg_trigger WHERE tgname LIKE 't\\_sync%' OR tgname LIKE 't\\_enq%'")
  LR=$(sql "SELECT count(*) FROM lineitem WHERE l_linenumber >= 90")
  echo "  트리거·큐/denorm 테이블·합성 행을 지우고 orders.o_custkey 를 되돌렸다."
  echo "  남은 트리거 ${LT} / 합성 lineitem 행 ${LR}   (둘 다 0 이어야 한다)"
  echo "  ※ customer.c_mktsegment 는 측정 중 바뀐 채다. 문서 실측과 맞추려면"
  echo "    ./scripts/restore-lab.sh --force-tpch 로 재적재한다."
fi
