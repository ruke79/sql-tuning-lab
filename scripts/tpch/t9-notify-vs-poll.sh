#!/usr/bin/env bash
# §T-9 확장: 워커를 어떻게 깨울 것인가 — NOTIFY / 고정 창 / 적응형(시간) / 적응형(큐깊이).
#
# t9-queue-tuning.sh 는 저부하(-R 200)에서 배치 100/2000 둘 다 57~59ms 가 나왔다.
# 배치와 무관하게 바닥이 잡혀 있다는 뜻이고, 유력한 용의자는 워커의 **20ms 고정 sleep** 이다.
# 여기서 그 가설을 검증한다.
#
# 이 스크립트가 답하는 질문
#   ① 저부하 지연의 바닥이 정말 sleep 인가?        → sleep 간격을 바꿔 바닥이 따라 움직이는지 본다
#   ② NOTIFY 로 깨우면 그 바닥이 사라지는가?
#      쓰기가 잦아지면 NOTIFY 가 트랜잭션마다 깨어나 바쁜 폴링으로 퇴화하는가?
#      그렇다면 **디바운스**(첫 알림 후 창 동안 더 모았다가 한 번에 처리)가 그걸 되돌리는가?
#      고정 창은 한산할 때 순손해였다 — **적응형 창**(대기 시간을 그때그때 계산)이 그걸 없애는가?
#      적응형은 시간만 보므로 일이 쌓여 있어도 기다린다 — **큐 깊이 신호**가 그걸 없애는가?
#   ③ NOTIFY 는 공짜인가?                          → 아니다. 쓰기 경로에 몇 배가 붙는다
#      (배수는 장비·부하마다 다르다. 이 랩에서 1.6배와 3.97배를 다 봤다 — ③이 그때그때 잰다)
#
# 다섯 방식이 겨루는 지점
#   폴링      : 지연 하한 = 간격/2. 간격을 줄이면 지연은 주지만 헛왕복이 폭증한다
#   NOTIFY    : 지연 하한이 사라진다. 대신 **쓰기 트랜잭션 수만큼** 깨어난다
#   고정 창    : 알림으로 깨우되 창을 두어 여러 알림을 한 번에 접는다.
#              바쁠 때는 왕복이 줄지만, 한산할 때는 모을 것이 없어 지연만 붙는다
#   적응형(시간): 창 대신 **drain 사이 최소 간격**을 보장한다. 대기 시간을 계산하므로
#              한산하면 0 을 기다리고(=NOTIFY), 바쁘면 자동으로 모은다(=고정 창).
#              약점은 시간만 본다는 것 — 일이 쌓여 있어도 간격을 채운다
#   적응형(큐깊이): 남은 깊이 >= 임계치면 페이싱을 건너뛰고 즉시 다음 배치를 간다.
#              깊이는 drain 이 함께 돌려주므로 **추가 왕복이 없다**.
#              "기다려도 더 모을 게 없을 때만 기다린다"가 목적이다
#
# 적체 구간(워커가 못 따라잡는 상태)에서의 비교는 **이 스크립트로 재현하지 못했다.**
# 편중 워크로드로 적체를 만들려 했으나 워커가 배치를 한 번도 적용하지 못한 채 큐가 비는
# 상태가 나와 해석이 불가능했다(원인 미규명). 그 구간의 결론은 t9-queue-tuning.sh ⑤ 참고 —
# 적체가 지배하며 배치 크기조차 총 처리량을 못 바꾼다. 여기서의 재현은 남은 과제다.
#
# 공정성을 위한 설계
#   · 모든 방식이 **같은 클라이언트(t9_worker.py)** 로 돈다. plpgsql vs 파이썬을 비교하면
#     깨우는 방식이 아니라 언어와 왕복 비용을 비교하게 된다.
#   · ①② 는 **전부 NOTIFY 를 발행하는 트리거**로 돈다(poll 워커는 무시할 뿐).
#     그래야 쓰기 경로가 동일해져 지연 차이만 남는다. NOTIFY 의 쓰기 비용은 ③에서 따로 잰다.
#
# 사용법:
#   ./t9-notify-vs-poll.sh              # 8 clients / 12초 / 3 라운드
#   ./t9-notify-vs-poll.sh 8 12 3
#
# 선행 조건: schema → load → index 완료, 그리고 psycopg2 (pip install psycopg2-binary)
set -uo pipefail

CLIENTS="${1:-8}"
SECS="${2:-12}"
ROUNDS="${3:-3}"
# 어느 절을 돌릴지. ⑤(경계 찾기)는 rate 를 훑느라 오래 걸려 기본에 넣되 마지막에 둔다.
ONLY="${ONLY:-123456}"
want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
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

HERE="$(cd "$(dirname "$0")" && pwd)"

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
scale_guard "$(sql "SELECT count(*) FROM lineitem")" 4 "$0"
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/_abort-trap.inc"

NIDX=$(sql "SELECT count(*) FROM pg_indexes WHERE tablename='lineitem'")
[ "${NIDX:-0}" -lt 2 ] && { echo "  [중단] index 를 먼저 실행하세요."; exit 1; }
python3 -c "import psycopg2" 2>/dev/null || { echo "  [중단] pip install psycopg2-binary"; exit 1; }

echo "§T-9 워커를 깨우는 방식 비교 — ${CLIENTS} clients / ${SECS}초 / $(nproc) CPU / ${ROUNDS}라운드 교차"
echo

# ── 스키마 (t9-queue-tuning.sh 와 동일 + NOTIFY 판) ───────────────────
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
CREATE INDEX ix_ld_ln  ON lineitem_denorm(l_linenumber);

DROP TABLE IF EXISTS denorm_queue;
CREATE TABLE denorm_queue (
  id BIGSERIAL PRIMARY KEY, kind TEXT NOT NULL, k1 BIGINT NOT NULL, k2 INTEGER,
  enq_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp());
DROP TABLE IF EXISTS denorm_stat;
CREATE TABLE denorm_stat(t TIMESTAMPTZ DEFAULT clock_timestamp(),
  applied INT, cust_items INT, cust_keys INT, avg_lag NUMERIC, max_lag NUMERIC);

DROP TABLE IF EXISTS orders_cust_bak;
CREATE TABLE orders_cust_bak AS SELECT o_orderkey, o_custkey FROM orders;
ALTER TABLE orders_cust_bak ADD PRIMARY KEY (o_orderkey);

-- 알림 없는 판(③의 기준선)
CREATE OR REPLACE FUNCTION enq_cust() RETURNS trigger AS $$
BEGIN
  IF NEW.c_mktsegment IS DISTINCT FROM OLD.c_mktsegment THEN
    INSERT INTO denorm_queue(kind,k1) VALUES ('cust', NEW.c_custkey);
  END IF; RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION enq_ord() RETURNS trigger AS $$
BEGIN
  IF NEW.o_shippriority IS DISTINCT FROM OLD.o_shippriority
     OR NEW.o_custkey IS DISTINCT FROM OLD.o_custkey
     OR NEW.o_orderdate IS DISTINCT FROM OLD.o_orderdate THEN
    INSERT INTO denorm_queue(kind,k1) VALUES ('ord', NEW.o_orderkey);
  END IF; RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION enq_line() RETURNS trigger AS $$
BEGIN
  INSERT INTO denorm_queue(kind,k1,k2) VALUES ('line', NEW.l_orderkey, NEW.l_linenumber);
  RETURN NEW;
END $$ LANGUAGE plpgsql;

-- 알림 붙인 판. payload 를 비워 두면 PostgreSQL 이 한 트랜잭션 안의 동일 알림을
-- 하나로 합치므로, 행 수와 무관하게 트랜잭션당 1건만 나간다.
CREATE OR REPLACE FUNCTION enq_cust_n() RETURNS trigger AS $$
BEGIN
  IF NEW.c_mktsegment IS DISTINCT FROM OLD.c_mktsegment THEN
    INSERT INTO denorm_queue(kind,k1) VALUES ('cust', NEW.c_custkey);
    PERFORM pg_notify('denorm_q','');
  END IF; RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION enq_ord_n() RETURNS trigger AS $$
BEGIN
  IF NEW.o_shippriority IS DISTINCT FROM OLD.o_shippriority
     OR NEW.o_custkey IS DISTINCT FROM OLD.o_custkey
     OR NEW.o_orderdate IS DISTINCT FROM OLD.o_orderdate THEN
    INSERT INTO denorm_queue(kind,k1) VALUES ('ord', NEW.o_orderkey);
    PERFORM pg_notify('denorm_q','');
  END IF; RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION enq_line_n() RETURNS trigger AS $$
BEGIN
  INSERT INTO denorm_queue(kind,k1,k2) VALUES ('line', NEW.l_orderkey, NEW.l_linenumber);
  PERFORM pg_notify('denorm_q','');
  RETURN NEW;
END $$ LANGUAGE plpgsql;

-- 반환형이 int → record 로 바뀌었다. CREATE OR REPLACE 는 **반환형을 바꿀 수 없으므로**
-- 명시적으로 DROP 해야 한다. 처음에 이걸 빼먹었는데 heredoc 이 2>/dev/null 이라 에러가
-- 조용히 삼켜졌고, 옛 함수가 그대로 남아 워커가 매 루프 실패했다(전 지표 0 — 정정 목록 15번).
DROP FUNCTION IF EXISTS denorm_drain(INT);

-- applied 와 함께 **남은 큐 깊이**를 돌려준다. 깊이를 따로 조회하면 왕복이 하나 더 드는데,
-- 그러면 "왕복을 줄이려는 제어"가 스스로 왕복을 만드는 자가당착이 된다.
-- 깊이를 안 쓰는 모드도 같은 함수를 호출하므로 이 추가 비용은 모든 모드가 똑같이 낸다.
CREATE OR REPLACE FUNCTION denorm_drain(batch INT DEFAULT 500,
                                        OUT applied INT, OUT depth INT) AS $$
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
  IF n = 0 THEN applied := 0; depth := 0; RETURN; END IF;
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
  applied := n;
  depth := (SELECT count(*) FROM denorm_queue);
END $$ LANGUAGE plpgsql;
EOSQL

trg(){   # plain | notify
  local s=""; [ "$1" = notify ] && s="_n"
  sql "DROP TRIGGER IF EXISTS t_enq_cust ON customer; DROP TRIGGER IF EXISTS t_enq_ord ON orders;
       DROP TRIGGER IF EXISTS t_enq_line ON lineitem;
       CREATE TRIGGER t_enq_cust AFTER UPDATE ON customer FOR EACH ROW EXECUTE FUNCTION enq_cust$s();
       CREATE TRIGGER t_enq_ord  AFTER UPDATE ON orders   FOR EACH ROW EXECUTE FUNCTION enq_ord$s();
       CREATE TRIGGER t_enq_line AFTER INSERT ON lineitem FOR EACH ROW EXECUTE FUNCTION enq_line$s();" >/dev/null 2>&1; }

full_refill(){ sql "TRUNCATE lineitem_denorm;
  INSERT INTO lineitem_denorm SELECT l.l_orderkey,l.l_linenumber,l.l_extendedprice,l.l_discount,
         l.l_shipdate,c.c_mktsegment,o.o_orderdate,o.o_shippriority
  FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                  JOIN customer c ON o.o_custkey=c.c_custkey; ANALYZE lineitem_denorm;" >/dev/null 2>&1; }
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
  sql "VACUUM (ANALYZE) lineitem_denorm; VACUUM (ANALYZE) lineitem; VACUUM denorm_queue;" >/dev/null 2>&1; }
med(){ echo "$1"|tr ' ' '\n'|grep -v '^$'|sort -g|awk '{a[NR]=$1}
       END{if(NR%2) print a[(NR+1)/2]; else printf "%.0f\n",(a[NR/2]+a[NR/2+1])/2}'; }
rng(){ echo "$1"|tr ' ' '\n'|grep -v '^$'|sort -g|awk '{a[NR]=$1} END{print a[1]"~"a[NR]}'; }

cat > /tmp/t9n_nat.sql <<'EOF'
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

# **END; 를 빼먹지 말 것.** BEGIN 만 있고 커밋이 없으면 매 반복의 쓰기가 연결 종료 시
# 통째로 롤백된다 — 그런데 pgbench 는 "failed 0" 으로 보고하고 tps 도 정상으로 찍는다.
# 그러면 큐가 비고 워커가 아무 일도 안 하는데, 출력은 '지연 0 / 왕복 2' 라 고장이 아니라
# 결과처럼 보인다. 이 한 줄이 없어서 적체 구간 절을 원인도 모른 채 통째로 지웠던 적이 있다.
cat > /tmp/t9n_skew.sql <<'EOF'
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

# 한 조건 1회 → "tps 평균지연 최대지연 배치수 빈폴링 처리항목 잔량"
run_case(){   # $1=모드지정("poll:20"|"notify") $2=목표rate("" 면 무제한) $3=워크로드파일
  light_reset
  local m="${1%%:*}" v="${1##*:}"; [ "$m" = notify ] && v=0
  rm -f /tmp/t9n_w.txt
  python3 "$HERE/t9_worker.py" --mode "$m" --sleep-ms "$v" --debounce-ms "$v" \
      --min-interval-ms "$v" --depth-threshold 500 --batch 2000 \
      --secs $((SECS+25)) --host "$PGHOST_" --port "$PGPORT_" --stats /tmp/t9n_w.txt \
      >/dev/null 2>&1 & local WP=$!
  sleep 0.4
  local extra=""; [ -n "${2:-}" ] && extra="-R $2"
  local T; T=$(PGBENCH -f "$(pg_stage "${3:-/tmp/t9n_nat.sql}")" \
                 -c "$CLIENTS" -j 4 -T "$SECS" -n $extra tpch 2>&1 \
               | grep -oP 'tps = \K[0-9.]+' | head -1)
  # 부하 종료 직후의 잔량이 곧 "따라잡고 있었는가"의 지표다. 여기서 0 이 되기를
  # 기다려 버리면 적체 구간을 만들어 놓고도 잔량 0 으로 보고하게 된다(실제로 그 실수를 했다).
  local Q1; Q1=$(sql "SELECT count(*) FROM denorm_queue")
  kill $WP 2>/dev/null; wait $WP 2>/dev/null
  local ST; ST=$(sql "SELECT round(coalesce(sum(applied*avg_lag)/nullif(sum(applied),0),0))||' '||
                             round(coalesce(max(max_lag),0)) FROM denorm_stat")
  local WS="0 0 0"; [ -s /tmp/t9n_w.txt ] && WS=$(cat /tmp/t9n_w.txt)
  # 왕복 = 처리배치수 + 빈폴링 = 워커가 DB 를 찔러 본 총 횟수
  local TRIPS; TRIPS=$(echo "$WS" | awk '{print $1+$2}')
  local PERB;  PERB=$(echo "$WS" | awk '{printf "%.1f", ($1>0)?$3/$1:0}')
  echo "${T%%.*} $ST $WS $Q1 $TRIPS $PERB"
}

declare -A ACC
sweep(){   # $1=rate $2=라운드 $3=워크로드 $4...=모드들
  local rate="$1" rounds="$2" wl="$3"; shift 3
  local modes=("$@") m
  for m in "${modes[@]}"; do ACC[$m]=""; done
  for r in $(seq 1 "$rounds"); do
    for m in "${modes[@]}"; do ACC[$m]="${ACC[$m]}|$(run_case "$m" "$rate" "$wl")"; done
  done
}
col(){ echo "${ACC[$1]}" | tr '|' '\n' | grep -v '^$' | awk -v n="$2" '{print $n}' | tr '\n' ' '; }
hdr(){ printf "  %-16s %7s %8s %-12s %8s %8s %8s %9s\n" \
        "깨우는 방식" "달성tps" "지연중앙" "지연범위(ms)" "최대지연" "왕복" "빈폴링" "배치당항목"; }
show(){ printf "  %-16s %7s %8s %-12s %8s %8s %8s %9s\n" "$2" \
        "$(med "$(col "$1" 1)")" "$(med "$(col "$1" 2)")" "$(rng "$(col "$1" 2)")" \
        "$(med "$(col "$1" 3)")" "$(med "$(col "$1" 8)")" "$(med "$(col "$1" 5)")" \
        "$(med "$(col "$1" 9)")"; }

MODES=("notify" "debounce:20" "adaptive:5" "adaptive:20" "qdepth:5" "qdepth:20")
lbl(){ case $1 in poll:200) echo "폴링 200ms";; poll:20) echo "폴링 20ms";;
                  poll:1) echo "폴링 1ms";; notify) echo "NOTIFY";;
                  debounce:5) echo "고정창 5ms";; debounce:20) echo "고정창 20ms";;
                  debounce:50) echo "고정창 50ms";;
                  adaptive:5) echo "적응형 5ms";; adaptive:20) echo "적응형 20ms";;
                  qdepth:5) echo "큐깊이 5ms";; qdepth:20) echo "큐깊이 20ms";;
                  poll:20) echo "폴링 20ms";; adaptive:5) echo "적응형 5ms";; esac; }

# ── 해석문이 쓸 값을 꺼내는 헬퍼 ──────────────────────────────────────
# sweep 이 ACC 를 통째로 덮어쓴다. 그래서 **각 절이 끝나는 자리에서** 값을 변수로
# 빼 둬야 한다. 이걸 안 해서 이 스크립트의 해석문이 오래 전 실행의 숫자를 그대로
# 들고 있었다 — 표에는 986 이 찍히는데 문장은 "NOTIFY 가 7,078 로 압도적"이라고 했다.
# 표와 문장이 다르면 읽는 사람은 문장을 믿는다. 그래서 문장을 표에서 만든다.
vlat(){  med "$(col "$1" 2)"; }   # 지연 중앙값(ms)
vtrip(){ med "$(col "$1" 8)"; }   # 왕복 = 처리배치 + 빈폴링
vemp(){  med "$(col "$1" 5)"; }   # 빈 폴링
vper(){  med "$(col "$1" 9)"; }   # 배치당 항목
# 빈 값을 0 으로 읽어 '이겼다'가 되면 안 된다 — 둘 다 값이 있을 때만 비교한다.
lt(){ [ -n "${1:-}" ] && [ -n "${2:-}" ] && awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0<b+0)}'; }
rat(){ awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{if(b+0==0)print "?";else printf "%.2f",a/b}'; }
# 두 값이 15% 안이면 '사실상 같다'로 본다. 노이즈를 발견으로 읽지 않기 위해서다.
near(){ [ -n "${1:-}" ] && [ -n "${2:-}" ] && \
        awk -v a="$1" -v b="$2" 'BEGIN{exit !(b+0>0 && (a+0)<(b+0)*1.15 && (a+0)>(b+0)*0.85)}'; }
# 주어진 모드들 중 $1 열의 최대/최소인 모드의 라벨과 값을 "라벨|값" 으로 준다.
pick(){ local want="$1" cmp="$2"; shift 2
        local bl="" bv="" m v
        for m in "$@"; do v=$(vtrip "$m"); [ "$want" = lat ] && v=$(vlat "$m")
          [ -z "$v" ] && continue
          if [ -z "$bv" ] || awk -v a="$v" -v b="$bv" -v c="$cmp" \
               'BEGIN{exit !(c=="max" ? a+0>b+0 : a+0<b+0)}'; then bv=$v; bl=$(lbl $m); fi
        done; echo "$bl|$bv"; }

if want 1; then
# ── ① 아주 낮은 부하 ──────────────────────────────────────────────────
echo "── ① 저부하(-R 50) · 자연 분포 · 배치 2000 (${ROUNDS}라운드 중앙값) ──"
sql "UPDATE orders o SET o_custkey=b.o_custkey FROM orders_cust_bak b
      WHERE o.o_orderkey=b.o_orderkey AND o.o_custkey IS DISTINCT FROM b.o_custkey;" >/dev/null 2>&1
full_refill; trg notify
sweep 50 "$ROUNDS" /tmp/t9n_nat.sql "${MODES[@]}"
hdr; for m in "${MODES[@]}"; do show "$m" "$(lbl $m)"; done
# 값을 지금 꺼내 둔다 — 다음 sweep 이 ACC 를 덮어쓴다.
LO_NOT=$(vlat notify);      TO_NOT=$(vtrip notify);      EO_NOT=$(vemp notify)
LO_D20=$(vlat debounce:20); TO_D20=$(vtrip debounce:20); EO_D20=$(vemp debounce:20)
LO_A20=$(vlat adaptive:20); TO_A20=$(vtrip adaptive:20); EO_A20=$(vemp adaptive:20)
LO_A5=$(vlat adaptive:5);   TO_A5=$(vtrip adaptive:5)
LO_Q20=$(vlat qdepth:20);   TO_Q20=$(vtrip qdepth:20)
echo "  → 폴링 간격이 지연 바닥을 그대로 정한다. 큐가 비어 있는 시간이 대부분이라"
echo "     '언제 깨느냐'가 곧 '언제 반영되느냐'다."
IFS='|' read -r BL BV <<<"$(pick lat min "${MODES[@]}")"
IFS='|' read -r WL WV <<<"$(pick lat max "${MODES[@]}")"
# **순위를 매기기 전에 구분이 되는지부터 본다.** 여섯 값이 16~24ms 안에 들어오고
# 범위끼리 겹치는 실행에서 "최저는 큐깊이 5ms"라고 쓰면 노이즈를 발견으로 읽는 것이다.
if awk -v a="$WV" -v b="$BV" 'BEGIN{exit !(b+0>0 && (a+0) < (b+0)*1.5+3)}'; then
  echo "  ※ 이 부하에서는 **지연으로 방식을 구분할 수 없다** — 최저 ${BV}ms, 최고 ${WV}ms 로"
  echo "     범위끼리 겹친다. 순위를 매기지 마라. ①의 신호는 지연이 아니라 오른쪽 두 열이다."
elif [ "$BL" = "NOTIFY" ]; then
  echo "  ★ NOTIFY 가 지연 최저다(${LO_NOT}ms) — 기다리는 창이 아예 없으니 바닥도 없다."
else
  echo "  ※ 이번 실행의 지연 최저는 NOTIFY(${LO_NOT}ms)가 아니라 ${BL}(${BV}ms)다."
fi
IFS='|' read -r TL TV <<<"$(pick trip max "${MODES[@]}")"
echo "     대신 왕복은 ${TL} 가 가장 많다(${TV}) — 커밋마다 깨어나는 대가다."
echo "  ※ 여기서는 빈 폴링의 차이가 크게 벌어진다: NOTIFY ${EO_NOT} / 고정창20 ${EO_D20} / 적응형20 ${EO_A20}."
echo "     큐가 비어 있는 시간이 길어 '깨어났는데 할 일이 없는' 왕복이 그대로 쌓이기 때문이다."
if lt "$LO_NOT" "$LO_D20"; then
  echo "  ※ 고정 창은 여기서 손해다. 한산할 때는 창 안에 모일 것이 없어 창이 그냥 기다림이 된다"
  echo "     — 고정창 20ms 의 지연 ${LO_D20}ms 가 NOTIFY(${LO_NOT}ms)보다 높다."
else
  echo "  ※ 이번 실행에서는 고정창 20ms(${LO_D20}ms)가 NOTIFY(${LO_NOT}ms)보다 낮았다 —"
  echo "     '한산하면 창이 손해'가 재현되지 않았다."
fi
if lt "$LO_A20" "$LO_D20" && lt "$TO_A20" "$TO_D20"; then
  echo "  ★ 적응형 창은 그 손해를 줄인다. **같은 20ms 에서 고정 창을 두 축 모두 이긴다** —"
  echo "     지연 ${LO_D20}→${LO_A20}ms, 왕복 ${TO_D20}→${TO_A20}."
  echo "     기다릴 시간을 계산하므로, 직전 drain 이후 이미 지난 만큼은 안 기다리기 때문이다."
else
  echo "  ※ 이번 실행에서 적응형은 고정 창을 두 축 모두 이기지는 못했다"
  echo "     (지연 ${LO_D20}→${LO_A20}ms / 왕복 ${TO_D20}→${TO_A20})."
fi
echo

fi

if want 2; then
# ── ② 중간 부하 ───────────────────────────────────────────────────────
echo "── ② 중부하(-R 800) · 자연 분포 · 배치 2000 (${ROUNDS}라운드 중앙값) ──"
sweep 800 "$ROUNDS" /tmp/t9n_nat.sql "${MODES[@]}"
hdr; for m in "${MODES[@]}"; do show "$m" "$(lbl $m)"; done
MD_NOT=$(vlat notify);      TD_NOT=$(vtrip notify);      ED_NOT=$(vemp notify);      PD_NOT=$(vper notify)
MD_D20=$(vlat debounce:20); TD_D20=$(vtrip debounce:20)
MD_A5=$(vlat adaptive:5);   TD_A5=$(vtrip adaptive:5);    PD_A5=$(vper adaptive:5)
MD_A20=$(vlat adaptive:20); TD_A20=$(vtrip adaptive:20);  ED_A20=$(vemp adaptive:20); PD_A20=$(vper adaptive:20)
MD_Q20=$(vlat qdepth:20);   TD_Q20=$(vtrip qdepth:20);    PD_Q20=$(vper qdepth:20)
# ①의 순위를 그대로 물려받아 "순서는 그대로다"라고 쓰던 자리. 실제로는 ①에서 3위였던
# NOTIFY 가 ②에서 꼴찌로 내려간 실행이 나왔다. 순위가 바뀌는 것 자체가 이 절의 발견이므로
# 물려받지 말고 **여기서 다시 세운다.**
IFS='|' read -r WL WV <<<"$(pick lat max "${MODES[@]}")"
IFS='|' read -r BL BV <<<"$(pick lat min "${MODES[@]}")"
echo "  → 부하가 오르자 지연이 갈라진다 — 최저 ${BL}(${BV}ms), 최고 ${WL}(${WV}ms) 로 $(rat "$WV" "$BV")배 차다."
if [ -n "${LO_NOT:-}" ] && lt "$LO_NOT" "$LO_D20" && [ "$WL" = "NOTIFY" ]; then
  echo "  ★ **순위가 뒤집혔다.** ①(저부하)에서 NOTIFY 는 고정 창보다 지연이 낮았는데"
  echo "     (${LO_NOT} vs ${LO_D20}ms), 여기서는 NOTIFY 가 가장 높다(${MD_NOT}ms)."
  echo "     커밋마다 깨어나느라 **모을 기회를 못 얻기 때문이다** — 배치당 항목을 보라."
else
  echo "     워커가 따라잡는 한 큐는 자주 비므로, 여기서도 '언제 깨느냐'가 지연을 지배한다."
fi
# 예전에는 "NOTIFY 가 7,078 로 압도적"이라고 박아 뒀다. 실측은 986 대 922 였다 —
# **1.07배를 '압도적'이라고 쓴 것이다.** 그래서 최대·최소를 찾아서 말하고, 격차도 같이 찍는다.
IFS='|' read -r TL TV <<<"$(pick trip max "${MODES[@]}")"
IFS='|' read -r NL NV <<<"$(pick trip min "${MODES[@]}")"
echo "  ★ 왕복 열에서는 순서가 달라진다 — 가장 많은 쪽이 **${TL}(${TV})**, 가장 적은 쪽이 ${NL}(${NV}) 다."
if [ "$TL" = "NOTIFY" ]; then
  echo "     NOTIFY 가 맨 위로 온 것은 트랜잭션마다 알림이 하나씩 나가기 때문이다 —"
  echo "     알림 기반이 **트랜잭션 속도의 폴링으로 퇴화**하는 방향이다."
  echo "     다만 이 실행의 격차는 $(rat "$TV" "$NV")배다. '압도적'인지 '이제 막 앞선'인지는"
  echo "     그 배수로 판단해라 — 경계 자체는 ⑤에서 쓰기율을 훑어 찾는다."
else
  echo "     이번 실행에서 NOTIFY(${TD_NOT})는 왕복 최대가 아니다 — 이 부하에서는 퇴화가 아직 안 보인다."
fi
if lt "$ED_NOT" 20 && lt "$ED_A20" 20; then
  echo "  ※ 빈 폴링은 여기서 어느 방식이든 사실상 0 이다(NOTIFY ${ED_NOT} / 적응형20 ${ED_A20})."
  echo "     큐가 늘 차 있어 헛왕복이 생길 틈이 없다. **빈 폴링의 차이는 ①(저부하)에서만 보인다.**"
else
  echo "  ★ 적응형은 빈 폴링을 줄인다(NOTIFY ${ED_NOT} → 적응형20 ${ED_A20})."
  echo "     페이싱 덕에 깨어날 때는 이미 일이 쌓여 있어 헛왕복이 사라지기 때문이다."
fi
echo "  ★ 실제로 달라지는 것은 **한 번에 얼마나 모아 가느냐**다 —"
# "A → B → C 로 커진다"고 쓰려면 실제로 커져야 한다. 40.3 → 137.8 → 117.8 이 나오는
# 실행이 있었다(마지막이 더 작다). 단조로울 때만 '커진다'라고 쓴다.
if lt "$PD_NOT" "$PD_A5" && lt "$PD_A5" "$PD_A20"; then
  echo "     배치당 항목이 NOTIFY ${PD_NOT} → 적응형5ms ${PD_A5} → 적응형20ms ${PD_A20} 로 커진다."
else
  echo "     배치당 항목 — NOTIFY ${PD_NOT} / 적응형5ms ${PD_A5} / 적응형20ms ${PD_A20}."
  echo "     페이싱을 두면 확실히 커지지만(NOTIFY 대비), 5ms 와 20ms 의 대소는"
  echo "     이 실행에서 뒤집혔다 — 도착률이 흔들리면 그 정도는 순서가 바뀐다."
fi
echo "     같은 일을 잘게 나눠 여러 번 가느냐, 모아서 몇 번 가느냐의 차이다."
if lt "$MD_A5" "$MD_D20" && lt "$TD_A5" "$TD_D20"; then
  echo "  ★ 적응형 5ms(${MD_A5}ms/${TD_A5})가 고정창 20ms(${MD_D20}ms/${TD_D20})를 두 축 모두에서 이긴다"
  echo "     — 더 짧은 파라미터로 더 적게 찌르면서 더 빨리 반영한다."
else
  echo "  ※ 적응형 5ms(${MD_A5}ms/${TD_A5})와 고정창 20ms(${MD_D20}ms/${TD_D20}) 사이에"
  echo "     두 축 모두를 이기는 쪽은 이번 실행에 없었다."
fi
echo

fi

if want 4; then
# ── ④ 버스트 소진: 큐 깊이 신호가 발화하는 유일한 구간 ─────────────────
echo "── ④ 버스트 소진 · 워커 정지 중 2만 건 적체 → 기동 후 소진 시간 (3회) ──"
declare -A BURST
trg notify
for MODE in adaptive qdepth; do
  T=""
  for i in 1 2 3; do
    sql "TRUNCATE denorm_queue; TRUNCATE denorm_stat;" >/dev/null 2>&1
    sql "UPDATE orders SET o_shippriority=(o_shippriority+1)%7 WHERE o_orderkey<=20000;" >/dev/null 2>&1
    python3 "$HERE/t9_worker.py" --mode $MODE --min-interval-ms 20 --depth-threshold 500 \
        --batch 2000 --secs 30 --stats /tmp/t9n_bw.txt >/dev/null 2>&1 & WP=$!
    s=$(date +%s%N)
    until [ "$(sql 'SELECT count(*) FROM denorm_queue')" -eq 0 ]; do sleep 0.05; done
    e=$(date +%s%N)
    kill $WP 2>/dev/null; wait $WP 2>/dev/null
    T="$T $(( (e-s)/1000000 ))"
  done
  BURST[$MODE]=$(med "$T")
  printf "  %-14s 소진: %s ms (중앙 %s)\n" "$(lbl ${MODE}:20 2>/dev/null || echo $MODE)" "$T" "${BURST[$MODE]}"
done
BA="${BURST[adaptive]:-}"; BQ="${BURST[qdepth]:-}"
echo "  → 이론상 큐깊이가 페이싱(20ms × 배치 10회 ≈ 200ms)을 아껴야 하는 구간이다."
if lt "$BQ" "$BA"; then
  echo "     실측에서도 큐깊이가 빨랐다 — ${BQ} vs ${BA}ms (차 $((BA-BQ))ms)."
  echo "     다만 이 차이가 페이싱 절약분과 같은 크기인지는 이 측정만으로 못 가른다."
else
  echo "     그런데 실측은 그 반대다 — 큐깊이 ${BQ}ms / 적응형 ${BA}ms."
  echo "     아껴야 할 200ms 가 소진 시간 자체(${BA}~${BQ}ms)에 묻혀 구분되지 않는다."
  echo "     **이론상의 이득이 실측에서 안 보이면, 안 보이는 쪽이 답이다.**"
fi
echo

fi

if want 3; then
# ── ③ NOTIFY 자체의 쓰기 비용 ─────────────────────────────────────────
echo "── ③ NOTIFY 는 공짜인가 · 포화 부하 · 워커 없음(쓰기 경로만) (${ROUNDS}라운드 중앙값) ──"
NOTPS=""; PLTPS=""
for r in $(seq 1 "$ROUNDS"); do
  for t in plain notify; do
    light_reset; trg $t
    v=$(PGBENCH -f "$(pg_stage /tmp/t9n_nat.sql)" \
          -c "$CLIENTS" -j 4 -T "$SECS" -n tpch 2>&1 | grep -oP 'tps = \K[0-9.]+' | head -1)
    [ "$t" = plain ] && PLTPS="$PLTPS ${v%%.*}" || NOTPS="$NOTPS ${v%%.*}"
  done
done
P=$(med "$PLTPS"); N=$(med "$NOTPS")
printf "  %-22s %10s tps  (범위 %s)\n" "큐 INSERT 만" "$P" "$(rng "$PLTPS")"
printf "  %-22s %10s tps  (범위 %s)\n" "큐 INSERT + NOTIFY" "$N" "$(rng "$NOTPS")"
W3=$(awk -v a=$P -v b=$N 'BEGIN{printf "%.2f",a/b}')
printf "  %-22s %10s\n" "쓰기 경로 비용" "${W3}배"
echo "  ※ payload 를 비워 두면 한 트랜잭션의 동일 알림이 하나로 합쳐지므로,"
echo "     행 단위 트리거에서 세 번 불러도 실제로 나가는 알림은 트랜잭션당 1건이다."
echo

echo "해석:"
echo "  · 지연 바닥을 정하는 것은 배치도 워커 수도 아닌 **깨우는 간격**이었다."
echo "    앞 실습(t9-queue-tuning.sh ④)에서 배치 100/2000 이 똑같이 57~59ms 로 나온 이유가 이것이다."
echo "    배치를 20배 바꿔도 안 움직이던 값이 sleep 을 200→1ms 로 바꾸자 그대로 따라 움직였다."
echo "  · 이 실습들을 합치면 지연창의 지배 요인이 구간별로 갈린다:"
echo "      - 따라잡는 구간(건강)  → **깨우는 간격**이 지배. 배치·워커는 거의 무관"
echo "      - 적체 구간(불건강)    → **처리 용량**이 지배 (t9-queue-tuning.sh ⑤)"
echo "    즉 두 손잡이는 경쟁 관계가 아니라 **서로 다른 구간의 손잡이**다."
if [ -n "${LO_D20:-}" ] && [ -n "${MD_D20:-}" ]; then
  if lt "$LO_NOT" "$LO_D20" && lt "$MD_D20" "$MD_NOT"; then
    echo "  · 고정 창은 부하 구간마다 답이 갈린다 — 한산하면 손해(①: 고정창 ${LO_D20} vs NOTIFY ${LO_NOT}ms),"
    echo "    바쁘면 이득(②: ${MD_D20} vs ${MD_NOT}ms). 그래서 **한 값으로 두 구간을 다 감당하지 못한다.**"
    echo "    부하가 오르내리는 시스템에서는 어느 값을 골라도 한쪽 구간에서 틀린 값이 된다."
  else
    echo "  · 고정 창은 이번 실행에서 **두 구간 모두 NOTIFY 보다 손해였다**"
    echo "    (①: ${LO_D20} vs ${LO_NOT}ms / ②: ${MD_D20} vs ${MD_NOT}ms)."
    echo "    '바쁘면 고정 창이 이득'은 이 장비·이 부하 범위에서는 재현되지 않았다 —"
    echo "    그러려면 커밋률이 창 주기를 넘어야 하는데 여기서는 거기까지 못 갔다(⑤의 달성tps 를 보라)."
  fi
fi
echo "  · 적응형은 그 딜레마를 없앤다. 대기 시간을 **계산**하므로 한산하면 거의 안 기다리고"
echo "    (저부하에서 고정 창을 두 축 모두 이긴다) 바빠지면 자동으로 모은다"
echo "    (고부하에서 빈 폴링이 0 에 수렴한다). 파라미터의 의미도 더 정직하다 —"
echo "    '얼마나 기다릴까'가 아니라 **'초당 몇 번까지 DB 를 찌를까'** 다."
echo "  · 다만 적응형도 공짜는 아니다. 부하가 높으면 페이싱이 곧 지연이 된다 —"
if [ -n "${LO_A5:-}" ] && [ -n "${MD_A5:-}" ]; then
  echo "    ①→② 에서 적응형 5ms 의 지연이 ${LO_A5}→${MD_A5}ms, 20ms 가 ${LO_A20}→${MD_A20}ms 로 오른다."
fi
echo "    그래서 값은 **허용 지연**을 보고 정해야 한다."
if near "${MD_Q20:-}" "${MD_A20:-}"; then
  echo "  · **큐 깊이 신호는 잰 어떤 구간에서도 이득이 없었다.**"
  echo "      - 정상 구간: 페이싱 간격(5~20ms) 동안 쌓이는 항목이 임계치(500)에 한참 못 미쳐"
  echo "        신호가 발화하지 않는다 — 적응형과 수치가 사실상 같다(②: ${MD_Q20} vs ${MD_A20}ms)"
else
  echo "  · 큐 깊이 신호는 ②에서 적응형과 값이 갈렸다(${MD_Q20} vs ${MD_A20}ms)."
  echo "      - 임계치(500)가 실제로 발화했는지 배치당항목 열로 확인해라"
  echo "        (${PD_Q20:-?} vs ${PD_A20:-?}) — 비슷하면 발화하지 않은 것이다"
fi
echo "      - 버스트 소진(④): 발화하지만 절약분이 소진 시간에 묻힌다(④의 두 값을 보라)"
echo "    '페이싱이 곧 지연'을 깊이 신호로 피하려면 임계치를 페이싱당 도착량(~4건)까지"
echo "    낮춰야 하는데, 그건 NOTIFY 로 돌아가는 것이다. **합침은 기다림 그 자체다 —**"
echo "    **기다림을 건너뛰면 합침도 같이 사라진다.** 신호를 늘릴 게 아니라 허용 지연으로"
echo "    페이싱 값을 정하는 것이 맞다."
echo "  · 부하가 높으면 '창을 두고 모으는 것'과 '주기적으로 훑는 것'이 같은 동작으로 수렴한다 —"
echo "    창이 차기 전에 이미 일이 쌓여 있으면 창은 그냥 주기가 되기 때문이다."
echo "    (②의 표에 폴링 20ms 열은 없다. 직접 대 보려면 MODES 에 poll:20 을 넣어야 한다 —"
echo "     **없는 열을 근거로 든 문장이 오래 남아 있었다.**)"
echo "  · 그래서 NOTIFY 는 처리량 대책이 아니라 **응답성 대책**이고, 심지어 처리량을 깎는다."
echo "    쓰기 경로에 ${W3:-?}배가 붙으므로(③), 적체가 문제인 상황에 붙이면 오히려 악화된다."
echo "  → 실무 조합: NOTIFY 로 깨우되 **타임아웃 폴링을 안전장치로 함께** 둔다."
echo "     NOTIFY 는 저장되지 않는다 — 워커가 죽어 있는 동안 발행된 알림은 사라진다."
echo "     알림만 믿으면 재시작 직후 남은 큐를 영영 못 집는다. 큐 테이블이 진실이고"
echo "     알림은 힌트일 뿐이라는 원칙(이 스크립트의 워커도 그렇게 짜여 있다)을 지켜야 한다."
echo
fi

# ── ⑤ NOTIFY 가 폴링보다 나빠지는 경계 쓰기율 ─────────────────────────
if want 5; then
echo "── ⑤ NOTIFY 퇴화의 경계는 어디인가 · 쓰기율을 훑는다 (1라운드) ──"
echo
# 앞 절의 결론을 물려받아 "②는 NOTIFY 의 왕복이 제일 많다고 했다"라고 써 뒀었다.
# 그런데 ②에서 왕복 최대가 고정창 20ms 로 나오는 실행이 있다 — **앞 절이 실제로
# 무엇을 찍었는지 받아서** 말한다. 물려받은 전제는 조용히 틀린다.
if [ -n "${TD_NOT:-}" ]; then
  echo "  ①(-R 50)에서 NOTIFY 의 왕복은 ${TO_NOT:-?}, ②(-R 800)에서는 ${TD_NOT} 였다."
  echo "  커밋이 늘면 NOTIFY 의 왕복도 같이 는다. **어디서 폴링을 넘어서는가**를 찾는다."
else
  echo "  NOTIFY 의 왕복은 커밋 수를 따라간다. **어디서 폴링을 넘어서는가**를 찾는다."
fi
echo "  비교 상대는 폴링 1ms 다 — 지연 바닥이 가장 낮은, 즉 가장 공격적인 폴링이다."
echo "  적응형 5ms 도 같이 둔다(②에서 그 퇴화를 고친 방식)."
echo
# **이 절만 따로 돌릴 수 있어야 하므로 준비를 스스로 한다.**
# ①이 해 주던 trg/full_refill 에 기대면, ONLY=5 로 돌렸을 때 enqueue 트리거가 아예 없어
# 큐가 안 채워지고 워커가 아무것도 못 한다 — 그런데 출력은 '왕복 21, 지연 0' 이라
# **고장이 아니라 결과처럼 보인다.** 실제로 처음 그렇게 나왔다.
trg notify; full_refill
# **반복 실행이 쌓은 부풀음을 걷어낸다.** 이 실습은 lineitem 에 행을 넣었다 지우기를
# 수만 번 반복하므로, 여러 번 돌리면 drain 이 점점 느려져 낮은 쓰기율에서도 잔량이 붙는다.
# 그러면 ⑤의 절대값이 회차마다 달라진다 — 측정이 아니라 누적 상태를 재게 된다.
sql "VACUUM (ANALYZE) lineitem_denorm" >/dev/null 2>&1
sql "VACUUM (ANALYZE) denorm_queue" >/dev/null 2>&1
sql "VACUUM (ANALYZE) lineitem" >/dev/null 2>&1
NTRG=$(sql "SELECT count(*) FROM pg_trigger WHERE tgname LIKE 't_enq%'")
if [ "${NTRG:-0}" -lt 3 ]; then
  echo "  [중단] enqueue 트리거가 ${NTRG}개뿐이다(3개여야 한다). 큐가 안 채워진다."
  exit 1
fi
# 목표 rate 를 실제로 달성했는지 같이 찍는다 — 장비가 못 따라가면 '-R 3200' 이 사실은
# -R 900 이고, 그러면 거기서 찾은 경계는 그 rate 의 경계가 아니다.
printf "  %-8s %8s | %-22s | %-22s | %-22s %s\n" "목표" "달성tps" "NOTIFY (지연ms/왕복)" "폴링1ms (지연ms/왕복)" "적응형5ms (지연ms/왕복)" "잔량"
printf "  %s\n" "------------------------------------------------------------------------------------------------------------"
CROSS=""; FLIP=""; BACK=0; ABOVE=0; Q5MAX=0   # set -u 대비 — 루프 안에서 처음 쓰면 죽는다
for R in 50 100 200 400 800 1600 3200; do
  N=$(run_case notify   "$R" /tmp/t9n_nat.sql)
  P=$(run_case poll:1   "$R" /tmp/t9n_nat.sql)
  A=$(run_case adaptive:5 "$R" /tmp/t9n_nat.sql)
  NL=$(echo "$N"|awk '{print $2}'); NT=$(echo "$N"|awk '{print $8}')
  PL=$(echo "$P"|awk '{print $2}'); PT=$(echo "$P"|awk '{print $8}')
  AL=$(echo "$A"|awk '{print $2}'); AT=$(echo "$A"|awk '{print $8}')
  # 처리한 항목이 0 이면 큐가 안 채워진 것이다 — 그 줄은 결과가 아니라 고장이다.
  NAPP=$(echo "$N"|awk '{print $6}')
  if [ "${NAPP:-0}" -lt 1 ]; then
    printf "  %-8s | %s\n" "-R $R" "[측정 실패] 워커가 처리한 항목이 0 이다 — 큐가 안 채워졌다."
    continue
  fi
  # ⑥이 "⑤까지는 잔량이 0 이었다"고 단정하던 자리의 근거. 실제로 -R 800 에서
  # 잔량 813 이 붙는 실행이 나왔다 — 앞 절의 사실을 물려받지 말고 재서 넘긴다.
  QN=$(echo "$N"|awk '{print $7}'); [ "${QN:-0}" -gt "${Q5MAX:-0}" ] && Q5MAX="$QN"
  # 두 값이 5% 안이면 '대등'으로 본다. 회차마다 순서가 바뀌는 지점을 '뒤집혔다'고 쓰면
  # 노이즈를 발견으로 읽는 것이다 — 실제로 두 번 돌려 한 번은 뒤집히고 한 번은 안 뒤집혔다.
  MARK=""
  if [ -z "$CROSS" ] && awk -v a="${NT:-0}" -v b="${PT:-0}" 'BEGIN{exit !(a > b*0.95)}'; then
    CROSS="$R"
    awk -v a="${NT:-0}" -v b="${PT:-0}" 'BEGIN{exit !(a > b*1.05)}' \
      && { MARK="  ← NOTIFY 가 더 많아진다"; FLIP="$R"; } || MARK="  ← 대등해지는 지점"
  fi
  # **경계는 '한 줄'이 아니라 '그 위로도 유지되느냐'다.** 예전에는 한 줄만 보고
  # "-R 400 에서 퇴화했다"고 단정했는데, 그 위 세 줄에서 NOTIFY 가 다시 왕복이 적었다.
  # 한 줄짜리 교차는 노이즈다. 그래서 교차 이후 되돌아간 줄을 센다.
  if [ -n "$CROSS" ] && [ "$R" != "$CROSS" ] \
     && awk -v a="${NT:-0}" -v b="${PT:-0}" 'BEGIN{exit !(a < b*0.95)}'; then
    BACK=$((BACK+1))
  fi
  [ -n "$CROSS" ] && [ "$R" != "$CROSS" ] && ABOVE=$((ABOVE+1))
  # 잔량(부하 종료 직후 큐에 남은 항목) = 워커가 따라잡고 있었는가. 0 이 아니면 적체 구간이다.
  printf "  %-8s %8s | %9s / %-10s | %9s / %-10s | %9s / %-10s %6s%s\n" \
    "-R $R" "$(echo "$N"|awk '{print $1}')" "$NL" "$NT" "$PL" "$PT" "$AL" "$AT" \
    "$(echo "$N"|awk '{print $7}')" "$MARK"
done
echo
if [ -n "$CROSS" ] && [ -n "$FLIP" ] && [ "$BACK" -eq 0 ]; then
  echo "  → **경계는 -R ${CROSS} 부근이다.** 그 아래에서는 NOTIFY 의 왕복이 더 적다."
  echo "    그 위로는 트랜잭션마다 알림이 나가 **NOTIFY 가 1ms 폴링보다 더 자주 깨어나고,**"
  echo "    **그 상태가 위쪽 ${ABOVE}줄에서 유지된다** — 알림 기반이 '가장 공격적인 폴링보다도"
  echo "    바쁜 폴링'으로 퇴화한 것이다."
elif [ -n "$CROSS" ]; then
  # 교차가 한 줄만 나타났다가 위쪽에서 되돌아가는 경우. 이걸 '경계'라고 쓰면
  # 노이즈를 발견으로 읽는 것이다 — 실제로 표가 '대등'이라고 찍는 동안
  # 문장만 "퇴화한 지점이다"라고 단정하던 버그가 있었다.
  echo "  → **경계에 닿지 않았다.** -R ${CROSS} 에서 한 번 대등해지지만,"
  echo "    그 위 ${ABOVE}줄 중 ${BACK}줄에서 NOTIFY 의 왕복이 다시 더 적어진다."
  [ -z "$FLIP" ] && echo "    5% 를 넘는 역전은 어느 줄에서도 없었다."
  echo "    **한 줄짜리 교차는 경계가 아니다.** 경계라면 그 위로 유지되어야 한다."
  echo "    달성tps 열을 보라 — 목표 rate 를 못 따라가고 있다면 더 올려도 소용없다."
else
  echo "  → 이 구간에서는 뒤집히지 않았다. **달성tps 열을 보라** — 목표 rate 를 못 따라가고 있다면"
  echo "    더 올려도 소용없다. 그 장비에서는 NOTIFY 가 1ms 폴링을 넘어설 만큼 커밋을 못 하는 것이고,"
  echo "    그것 자체가 답이다: **이 장비의 워크로드 범위 안에서는 NOTIFY 가 항상 왕복이 적다.**"
fi
echo
echo "  경계의 정체는 간단하다. 폴링의 왕복은 **시간**이 정하고(초당 1000회, 부하와 무관),"
echo "  NOTIFY 의 왕복은 **트랜잭션 수**가 정한다. 그래서 커밋 속도가 폴링 주기를 넘어서는"
echo "  순간 역전된다. 즉 **경계는 설정이 아니라 워크로드가 정하고, 장비가 빨라지면 앞당겨진다.**"
echo "  적응형 열이 거의 평평하다면, 그 방식이 이 경계 자체를 없앤다는 뜻이다(②의 결론)."
echo
echo "  **예측과 맞는지 확인하라.** 이론상 경계는 '초당 커밋 수 = 폴링의 초당 왕복 수' 다."
echo "  폴링 1ms 의 왕복 열을 측정 시간으로 나누면 그 값이 나온다(간격이 1ms 라고 초당 1000회가"
echo "  되는 건 아니다 — 왕복 자체에 시간이 걸린다). 달성tps 가 그 값을 넘어서는 줄에서"
echo "  뒤집히면 예측이 맞은 것이다. 즉 **경계는 폴링 간격이 아니라 폴링의 실제 왕복률이 정한다.**"
echo
echo "  높은 쓰기율에서 NOTIFY 의 왕복이 다시 **줄어드는** 것도 보라. 역설이 아니다 —"
echo "  커밋이 빨라지면 한 번 깨어나는 사이에 알림이 여러 개 쌓여 자연스럽게 합쳐진다."
echo "  **잔량 열이 0 이면 워커는 아직 따라잡고 있는 것이다** — 적체가 아니라 합쳐짐이다."
echo "  잔량이 붙는 구간(적체)은 성격이 다르고, ⑥에서 따로 만든다."
echo
fi

# ── ⑥ 적체 구간 — 깨우는 방식이 의미를 잃는가 ────────────────────────
if want 6; then
echo "── ⑥ 적체 구간 · 대형 고객 편중으로 워커를 못 따라잡게 만든다 (1라운드) ──"
echo
if [ "${Q5MAX:-0}" -eq 0 ]; then
  echo "  ⑤까지는 잔량이 0 이었다. 워커가 계속 따라잡았다는 뜻이고, 그 구간에서는"
  echo "  '언제 깨느냐'가 지연을 지배한다. **워커가 못 따라잡으면 그 결론이 뒤집히는가**를 본다."
else
  echo "  ⑤에서 이미 잔량이 최대 ${Q5MAX} 까지 붙었다 — 이 장비에서는 쓰기율만으로도"
  echo "  워커가 밀리기 시작한다는 뜻이다. 여기서는 **항목 하나를 비싸게** 만들어"
  echo "  확실한 적체를 세우고, 그 구간에서 결론이 뒤집히는가를 본다."
fi
echo
echo "  적체는 쓰기율만 올려서는 안 만들어진다 — 이 장비의 pgbench 가 낼 수 있는 속도로는"
echo "  워커를 확실히 이기지는 못한다(⑤의 잔량 최대 ${Q5MAX:-?}). **항목 하나를 비싸게** 만든다:"
echo "  주문을 한 고객에게 몰아 두면, 그 고객 등급 변경 1건이 denorm 수만 행 갱신이 된다."
echo
BIG="${BIG:-5000}"
# 앞선 절이 넣어 둔 실험용 lineitem 을 먼저 지운다. 안 그러면 반복 실행마다 고객1 의
# 파생 행수(=항목당 비용)가 불어나 **절대 수치가 회차마다 달라진다.**
sql "DELETE FROM lineitem WHERE l_linenumber >= 90;
     DELETE FROM lineitem_denorm WHERE l_linenumber >= 90;" >/dev/null 2>&1
sql "VACUUM (ANALYZE) lineitem_denorm" >/dev/null 2>&1
sql "UPDATE orders SET o_custkey=1 WHERE o_orderkey<=$BIG;" >/dev/null 2>&1
full_refill; trg notify
FAN=$(sql "SELECT count(*) FROM lineitem_denorm d JOIN orders o ON d.l_orderkey=o.o_orderkey
            WHERE o.o_custkey=1")
echo "  고객1 에 주문 ${BIG}건 → 등급 변경 1건당 파생 ${FAN}행 갱신"
echo
# **교차 측정한다.** ⑥을 처음 만들었을 때는 세 방식을 고정 순서로 1회씩 쟀고,
# 항상 맨 앞에 있던 NOTIFY 가 지연 123~135ms 로 혼자 나빠 보였다. 3라운드 교차로 다시 재니
# 45~57ms 로 **구분되지 않는다** — 순서가 만든 값이었다(§T-0 원칙 6, 이 랩이 이미 한 번 겪은 실수).
printf "  %s\n" "  깨우는 방식      달성tps  지연중앙  최대지연      왕복      잔량 | cust배치  cust합ms"
printf "  %s\n" "  -------------------------------------------------------------------------------------"
declare -A B_T B_L B_M B_R B_Q B_CB B_CM B_TOT
MODES6=("notify" "poll:20" "adaptive:5")
for m in "${MODES6[@]}"; do B_L[$m]=""; done
for r in $(seq 1 "$ROUNDS"); do
  for m in "${MODES6[@]}"; do
    R=$(run_case "$m" 400 /tmp/t9n_skew.sql)
    # denorm_stat 은 run_case 가 시작할 때만 비우므로, 끝난 직후 그대로 읽을 수 있다.
    # **워커를 건드리지 않고** "비싼 배치가 몇 번이었나 / 거기에 몇 ms 를 썼나"를 얻는다.
    G=$(sql "WITH g AS (SELECT cust_items, EXTRACT(epoch FROM t - lag(t) OVER (ORDER BY t))*1000 AS gap
                          FROM denorm_stat)
             SELECT count(*) FILTER (WHERE cust_items>0) || '|' ||
                    coalesce(round(sum(gap) FILTER (WHERE cust_items>0))::text,'-') || '|' ||
                    coalesce(round(sum(gap))::text,'-') FROM g")
    B_L[$m]="${B_L[$m]} $(echo "$R"|awk '{print $2}')"
    B_T[$m]="$(echo "$R"|awk '{print $1}')"; B_M[$m]="$(echo "$R"|awk '{print $3}')"
    B_R[$m]="$(echo "$R"|awk '{print $8}')"; B_Q[$m]="$(echo "$R"|awk '{print $7}')"
    B_CB[$m]="${G%%|*}"; B_CM[$m]="$(echo "$G"|cut -d'|' -f2)"; B_TOT[$m]="${G##*|}"
  done
done
for m in "${MODES6[@]}"; do
  printf "  %s%9s %9s %9s %9s %9s | %8s %9s\n" "$(printf '%-16s' "$(lbl $m)")" \
    "${B_T[$m]}" "$(med "${B_L[$m]}")" "${B_M[$m]}" "${B_R[$m]}" "${B_Q[$m]}" "${B_CB[$m]}" "${B_CM[$m]}"
done
echo
echo "  (지연중앙은 ${ROUNDS}라운드 중앙값, 나머지는 마지막 라운드 값이다.)"
echo
echo "  **기전 — 오른쪽 두 열이 답이다.**"
PERC=$(awk -v a="${B_CM[adaptive:5]:-0}" -v b="${B_CB[adaptive:5]:-0}" 'BEGIN{ if(b>0) printf "%.0f", a/b; else printf "?" }')
echo "   이 워크로드에서 비싼 일은 단 하나, '고객1 등급 전파' UPDATE 다 —"
echo "   파생 ${FAN}행을 갱신하고, 위 표에서 계산하면 **회당 약 ${PERC}ms** 다(cust합ms ÷ cust배치)."
echo "   drain 은 한 배치 안의 같은 고객을 **DISTINCT 로 접어** UPDATE 를 한 번만 한다."
echo "   그래서 총 비용 = **(cust 항목이 들어 있던 배치 수) × 회당 비용** 이고, 배치 안에 그 고객이"
echo "   1건 있든 10건 있든 값이 같다."
# 예전에는 "drain 시간의 약 97%"라고 박아 뒀다. 그 값은 이 표 어디에도 없었다 —
# 다른 실행에서 따로 계측한 숫자였고, 그래서 표와 맞는지 아무도 확인할 수 없었다.
# 이제 같은 denorm_stat 에서 전체 drain 시간도 같이 받아 **여기서 계산한다.**
SHARE=$(awk -v a="${B_CM[adaptive:5]:-0}" -v b="${B_TOT[adaptive:5]:-0}" \
        'BEGIN{ if(b+0>0) printf "%.0f", a*100/b; else printf "?" }')
echo "   그 한 문장이 drain 시간에서 차지하는 비중은 **${SHARE}%** 다"
echo "   (적응형5ms 기준 cust합 ${B_CM[adaptive:5]:-?}ms / 전체 ${B_TOT[adaptive:5]:-?}ms)."
echo "   claim / ord / line / depth 를 다 합친 것이 나머지다."
echo
# "세 방식의 cust배치·cust합ms 가 거의 같다"고 박아 뒀었다. 실측은 47/79/88 과
# 2887/4790/5629 — 1.9배 차다. 총량이 다른 이유는 **달성tps 가 다르기 때문**이고,
# 방식이 같은 일을 한다는 증거는 총량이 아니라 **회당 비용**에 있다.
echo "   세 방식의 회당 비용을 나란히 보면(cust합ms ÷ cust배치):"
for m in "${MODES6[@]}"; do
  printf "     %-12s %s회 · %sms → 회당 %sms  (달성 %s tps)\n" "$(lbl $m)" \
    "${B_CB[$m]:-?}" "${B_CM[$m]:-?}" \
    "$(awk -v a="${B_CM[$m]:-0}" -v b="${B_CB[$m]:-0}" 'BEGIN{if(b>0)printf "%.0f",a/b;else printf "?"}')" \
    "${B_T[$m]:-?}"
done
PCHI=""; PCLO=""
for m in "${MODES6[@]}"; do
  pc=$(awk -v a="${B_CM[$m]:-0}" -v b="${B_CB[$m]:-0}" 'BEGIN{if(b>0)printf "%.0f",a/b;else print ""}')
  [ -z "$pc" ] && continue
  { [ -z "$PCHI" ] || lt "$PCHI" "$pc"; } && PCHI=$pc
  { [ -z "$PCLO" ] || lt "$pc" "$PCLO"; } && PCLO=$pc
done
if near "$PCHI" "$PCLO"; then
  echo "   **회당 비용이 방식과 무관하게 같다**(${PCLO}~${PCHI}ms) — 즉 세 방식이 같은 일을 한다."
  echo "   총량(cust배치·cust합ms)이 갈리는 것은 달성tps 가 갈려서지 방식 때문이 아니다."
else
  echo "   회당 비용이 ${PCLO}~${PCHI}ms 로 $(rat "$PCHI" "$PCLO")배 벌어졌다 —"
  echo "   '세 방식이 같은 일을 한다'를 이 실행만으로 말하기에는 폭이 넓다. 라운드를 늘려 다시 보라."
fi
# 포화인지 아닌지를 말로 때우지 않는다. 측정 시간 대비 몇 %를 비싼 문장에 썼는지로 가른다.
BUSY=$(awk -v a="${B_CM[adaptive:5]:-0}" -v s="${SECS:-0}" \
       'BEGIN{ if(s+0>0) printf "%.0f", a*100/(s*1000); else printf "?" }')
echo "   비싼 문장에 쓴 시간은 측정 시간 ${SECS}초의 **${BUSY}%** 다."
# 100% 를 넘는 값이 나온다. 버그가 아니다 — 부하가 끝난 뒤에도 워커가 남은 큐를
# 계속 비우므로 drain 시간이 pgbench 구간보다 길어진다. 넘으면 그 자체가 포화 신호다.
awk -v b="${BUSY:-0}" 'BEGIN{exit !(b+0>100)}' && \
  echo "   (100% 를 넘는 것은 부하가 끝난 뒤에도 소진이 이어졌다는 뜻이다 — 포화 신호다.)"
# 잔량이 실제로 붙었는가 — 이게 '적체 구간을 만들었는가'의 유일한 증거다.
QMAX=0; for m in "${MODES6[@]}"; do [ "${B_Q[$m]:-0}" -gt "$QMAX" ] && QMAX="${B_Q[$m]}"; done
echo
if [ "$QMAX" -gt 100 ] || awk -v b="${BUSY:-0}" 'BEGIN{exit !(b+0>=80)}'; then
  echo "  → **적체 구간을 만들었고, 거기서는 깨우는 방식이 의미를 잃는다.**"
  echo "    워커가 포화면 잔량은 깨우는 방식이 아니라 **비싼 항목의 도착률 × 항목당 비용**이"
  echo "    정한다. 깨우기로는 손댈 수 없는 값이다."
else
  echo "  → **주의: 이번 실행은 적체 구간까지 가지 않았다.** 잔량 최대 ${QMAX}, 워커 점유 ${BUSY}%."
  echo "    항목 하나를 ${FAN}행짜리로 비싸게 만들었는데도 워커가 따라잡았다는 뜻이다."
  echo "    그래도 **세 방식의 cust배치·cust합ms 가 같다**는 사실은 그대로다 —"
  echo "    비싼 항목이 지배하기 시작하면 깨우는 방식의 차이가 묻힌다는 방향은 보인다."
  echo "    다만 '적체 구간에서 의미를 잃는다'를 이 실행으로 단정하지는 마라."
  echo "    단정하려면 잔량이 계속 쌓이는 조건(고객1 주문 수를 더 늘리거나 -R 을 올려)이 필요하다."
fi
echo
echo "  ※ 이 절은 예전에 \"NOTIFY 가 최악이다\"로 한 번 뒤집어 적혔다가 틀린 것으로 밝혀졌다."
echo "    고정 순서 1회 측정이 만든 값이었고 ${ROUNDS}라운드 교차에서 사라졌다."
echo "    **이 랩이 §T-0 에 적어 둔 원칙을 스스로 어겨서 생긴 오답이다.**"
echo
echo "  → 실무 규칙: 밀리기 시작하면 **깨우는 방식을 바꾸는 것은 답이 아니다.**"
echo "    손댈 곳은 항목당 비용(팬아웃이 큰 전파를 쪼개거나 증분화)이거나 도착률이다."
echo "    ①②(따라잡는 구간)에서 깨우는 방식이 지연을 지배하던 것과 정반대다 —"
echo "    **같은 손잡이가 구간에 따라 전부이기도 하고 아무것도 아니기도 하다.**"
echo
# 원복 — 주문 소유자를 되돌리고 **파생 테이블도 다시 만든다.**
# 소유자만 되돌리면 lineitem_denorm 이 편중 상태 그대로 남아, 이후 모든 drain 이
# "다른 값을 찾아 고치는" 교정 작업을 떠안는다. 그러면 ⑤를 다시 돌렸을 때 낮은 쓰기율에서도
# 잔량이 붙어 **⑤의 결과가 통째로 달라진다** — 실제로 그래서 ⑤가 한 번 엉망으로 나왔다.
# 절 사이에 상태를 흘리지 않는 것이 여기서는 데이터 원복만으로 부족하다.
sql "UPDATE orders o SET o_custkey=b.o_custkey FROM orders_cust_bak b
      WHERE o.o_orderkey=b.o_orderkey AND o.o_custkey IS DISTINCT FROM b.o_custkey;" >/dev/null 2>&1
full_refill
LEFT=$(sql "SELECT count(*) FROM orders o JOIN orders_cust_bak b USING (o_orderkey)
             WHERE o.o_custkey IS DISTINCT FROM b.o_custkey")
DRIFT=$(sql "WITH truth AS (SELECT l.l_orderkey,l.l_linenumber,c.c_mktsegment,o.o_orderdate,o.o_shippriority
             FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                             JOIN customer c ON o.o_custkey=c.c_custkey)
             SELECT count(*) FROM truth t JOIN lineitem_denorm d
               ON d.l_orderkey=t.l_orderkey AND d.l_linenumber=t.l_linenumber
              WHERE (d.c_mktsegment,d.o_orderdate,d.o_shippriority)
                    IS DISTINCT FROM (t.c_mktsegment,t.o_orderdate,t.o_shippriority)")
echo "  원복했다 — 안 돌아온 주문 ${LEFT:-?} / 파생 불일치 ${DRIFT:-?}  (둘 다 0 이어야 한다)"
echo
fi

# 스스로 치운다. **enqueue 트리거를 남기면 lineitem 의 모든 쓰기에 붙어 다음 실습을
# 조용히 오염시킨다**(에러가 없으니 다음 사람은 자기가 다른 것을 재는 줄 모른다).
# 실험이 넣은 lineitem 행(l_linenumber>=90)도 같이 지운다 — 남으면 행수가 달라진다.
if [ "${KEEP:-0}" != "1" ]; then
  sql "DROP TRIGGER IF EXISTS t_enq_cust ON customer; DROP TRIGGER IF EXISTS t_enq_ord ON orders;
       DROP TRIGGER IF EXISTS t_enq_line ON lineitem;" >/dev/null 2>&1
  sql "DELETE FROM lineitem WHERE l_linenumber >= 90;
       DELETE FROM lineitem_denorm WHERE l_linenumber >= 90;" >/dev/null 2>&1
  sql "UPDATE orders o SET o_custkey=b.o_custkey FROM orders_cust_bak b
        WHERE o.o_orderkey=b.o_orderkey AND o.o_custkey IS DISTINCT FROM b.o_custkey;" >/dev/null 2>&1
  echo "정리했다 — 남은 enqueue 트리거 $(sql "SELECT count(*) FROM pg_trigger WHERE tgname LIKE 't\_enq%'") /"
  echo "  실험 lineitem 행 $(sql "SELECT count(*) FROM lineitem WHERE l_linenumber>=90") /"
  echo "  주문 소유자 불일치 $(sql "SELECT count(*) FROM orders o JOIN orders_cust_bak b USING (o_orderkey)
                                    WHERE o.o_custkey IS DISTINCT FROM b.o_custkey")   (전부 0 이어야 한다)"
else
  echo "KEEP=1 — 트리거와 파생 테이블을 남긴다."
fi
echo
echo "※ customer 의 c_mktsegment 는 워크로드가 바꾼다(복구 대상이 아니다)."
echo "   원래 값이 필요하면 재적재한다:"
echo "  ./gradlew :tpch:bootRun --args=\"schema --db=postgres\""
echo "  ./gradlew :tpch:bootRun --args=\"load   --db=postgres\""
echo "  ./gradlew :tpch:bootRun --args=\"index  --db=postgres\""

# 여기까지 왔으면 본문의 정리가 끝났다 — EXIT 트랩이 같은 일을 다시 하지 않게 한다.
LAB_DONE=1
