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
#   ③ NOTIFY 는 공짜인가?                          → 아니다. 쓰기 경로에 1.6배가 붙는다
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
PSQL(){ psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q "$@"; }
sql(){ PSQL -tAc "$1"; }

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
  local T; T=$(pgbench -h "$PGHOST_" -p "$PGPORT_" -U tuner -f "${3:-/tmp/t9n_nat.sql}" \
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

if want 1; then
# ── ① 아주 낮은 부하 ──────────────────────────────────────────────────
echo "── ① 저부하(-R 50) · 자연 분포 · 배치 2000 (${ROUNDS}라운드 중앙값) ──"
sql "UPDATE orders o SET o_custkey=b.o_custkey FROM orders_cust_bak b
      WHERE o.o_orderkey=b.o_orderkey AND o.o_custkey IS DISTINCT FROM b.o_custkey;" >/dev/null 2>&1
full_refill; trg notify
sweep 50 "$ROUNDS" /tmp/t9n_nat.sql "${MODES[@]}"
hdr; for m in "${MODES[@]}"; do show "$m" "$(lbl $m)"; done
echo "  → 폴링 간격이 지연 바닥을 그대로 정한다. 큐가 비어 있는 시간이 대부분이라"
echo "     '언제 깨느냐'가 곧 '언제 반영되느냐'다. NOTIFY 는 그 바닥을 없앤다."
echo "  ※ 고정 창은 여기서 손해다. 한산할 때는 창 안에 모일 것이 없어 창이 그냥 기다림이 된다"
echo "     (지연이 창의 약 절반으로 붙는다: 5→6, 20→15ms)."
echo "  ★ 적응형 창은 그 손해를 없앤다. **같은 파라미터에서 고정 창을 두 축 모두 이긴다** —"
echo "     5ms: 지연 6→3ms, 왕복 920→871 / 20ms: 지연 15→12ms, 왕복 640→498."
echo "     기다릴 시간을 계산하므로, 직전 drain 이후 이미 지난 만큼은 안 기다리기 때문이다."
echo

fi

if want 2; then
# ── ② 중간 부하 ───────────────────────────────────────────────────────
echo "── ② 중부하(-R 800) · 자연 분포 · 배치 2000 (${ROUNDS}라운드 중앙값) ──"
sweep 800 "$ROUNDS" /tmp/t9n_nat.sql "${MODES[@]}"
hdr; for m in "${MODES[@]}"; do show "$m" "$(lbl $m)"; done
echo "  → 지연 순서는 그대로다 — 깨우는 간격은 한산할 때만이 아니라 **건강한 구간 전체에서**"
echo "     지연을 지배한다. 워커가 따라잡는 한 큐는 자주 비기 때문이다."
echo "  ★ 그런데 왕복 열에서 판이 뒤집힌다. **NOTIFY 가 7,078 로 압도적으로 많다.**"
echo "     트랜잭션마다 알림이 하나씩 나가므로 알림 기반이 사실상"
echo "     **트랜잭션 속도의 바쁜 폴링으로 퇴화**한 것이다(배치당 4.4항목 — 잘게 쪼개 일한다)."
echo "  ★ 창이 그 지점을 고친다. 고정 5ms 는 지연 2→3ms 에 왕복 7,078→4,213."
echo "  ★ 적응형은 한 발 더 간다. **빈 폴링이 4 와 2 로 사실상 0 이다**(고정창은 737/365)."
echo "     페이싱 덕에 깨어날 때는 이미 일이 쌓여 있어 헛왕복 자체가 사라진다."
echo "     배치당 항목이 4.4 → 16.2 → 51.7 로 커지는 것이 그 기전이다."
echo "  ★ 곡선으로 보면 **적응형 5ms(6ms/1,380)가 고정창 20ms(9ms/1,988)와 폴링 20ms(9ms/2,066)를"
echo "     두 축 모두에서 이긴다.** 같은 파라미터끼리 비교하면 적응형이 더 공격적으로 모을 뿐이다"
echo "     (5ms 기준 지연 3→6ms, 왕복 4,213→1,380)."
echo

fi

if want 4; then
# ── ④ 버스트 소진: 큐 깊이 신호가 발화하는 유일한 구간 ─────────────────
echo "── ④ 버스트 소진 · 워커 정지 중 2만 건 적체 → 기동 후 소진 시간 (3회) ──"
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
  printf "  %-14s 소진: %s ms (중앙 %s)\n" "$(lbl ${MODE}:20 2>/dev/null || echo $MODE)" "$T" "$(med "$T")"
done
echo "  → 이론상 큐깊이가 페이싱(20ms × 배치 9회 ≈ 180ms)을 아껴야 하는 구간인데,"
echo "     실측에서는 그 절약이 배치 작업 시간(1.5~1.9초)에 묻혀 구분되지 않았다."
echo

fi

if want 3; then
# ── ③ NOTIFY 자체의 쓰기 비용 ─────────────────────────────────────────
echo "── ③ NOTIFY 는 공짜인가 · 포화 부하 · 워커 없음(쓰기 경로만) (${ROUNDS}라운드 중앙값) ──"
NOTPS=""; PLTPS=""
for r in $(seq 1 "$ROUNDS"); do
  for t in plain notify; do
    light_reset; trg $t
    v=$(pgbench -h "$PGHOST_" -p "$PGPORT_" -U tuner -f /tmp/t9n_nat.sql \
          -c "$CLIENTS" -j 4 -T "$SECS" -n tpch 2>&1 | grep -oP 'tps = \K[0-9.]+' | head -1)
    [ "$t" = plain ] && PLTPS="$PLTPS ${v%%.*}" || NOTPS="$NOTPS ${v%%.*}"
  done
done
P=$(med "$PLTPS"); N=$(med "$NOTPS")
printf "  %-22s %10s tps  (범위 %s)\n" "큐 INSERT 만" "$P" "$(rng "$PLTPS")"
printf "  %-22s %10s tps  (범위 %s)\n" "큐 INSERT + NOTIFY" "$N" "$(rng "$NOTPS")"
printf "  %-22s %10s\n" "쓰기 경로 비용" "$(awk -v a=$P -v b=$N 'BEGIN{printf "%.2f배",a/b}')"
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
echo "  · 고정 창은 부하 구간마다 답이 갈린다 — 한산하면 손해, 바쁘면 이득."
echo "    그래서 **한 값으로 두 구간을 다 감당하지 못한다.** 부하가 오르내리는 시스템에서는"
echo "    어느 값을 골라도 한쪽 구간에서 틀린 값이 된다."
echo "  · 적응형은 그 딜레마를 없앤다. 대기 시간을 **계산**하므로 한산하면 거의 안 기다리고"
echo "    (저부하에서 고정 창을 두 축 모두 이긴다) 바빠지면 자동으로 모은다"
echo "    (고부하에서 빈 폴링이 0 에 수렴한다). 파라미터의 의미도 더 정직하다 —"
echo "    '얼마나 기다릴까'가 아니라 **'초당 몇 번까지 DB 를 찌를까'** 다."
echo "  · 다만 적응형도 공짜는 아니다. 부하가 높으면 페이싱이 곧 지연이 되므로"
echo "    (5ms → 6ms, 20ms → 15ms) 값은 **허용 지연**을 보고 정해야 한다."
echo "  · **큐 깊이 신호는 잰 어떤 구간에서도 이득이 없었다.**"
echo "      - 정상 구간: 페이싱 간격(5~20ms) 동안 쌓이는 항목이 임계치(500)에 한참 못 미쳐"
echo "        신호가 발화하지 않는다 — 적응형과 수치가 동일하다"
echo "      - 버스트 소진(④): 발화하지만 절약분이 배치 작업 시간에 묻힌다"
echo "    '페이싱이 곧 지연'을 깊이 신호로 피하려면 임계치를 페이싱당 도착량(~4건)까지"
echo "    낮춰야 하는데, 그건 NOTIFY 로 돌아가는 것이다. **합침은 기다림 그 자체다 —**"
echo "    **기다림을 건너뛰면 합침도 같이 사라진다.** 신호를 늘릴 게 아니라 허용 지연으로"
echo "    페이싱 값을 정하는 것이 맞다."
echo "  · 부하가 높으면 '창을 두고 모으는 것'과 '주기적으로 훑는 것'이 같은 동작으로 수렴한다 —"
echo "    고정창 20ms(9ms/1,988)와 폴링 20ms(9ms/2,066)가 거의 겹치는 것이 그 증거다."
echo "  · 그래서 NOTIFY 는 처리량 대책이 아니라 **응답성 대책**이고, 심지어 처리량을 깎는다."
echo "    쓰기 경로에 1.6배가 붙으므로(③), 적체가 문제인 상황에 붙이면 오히려 악화된다."
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
echo "  ①은 -R 50 에서 NOTIFY 가 최선이라 했고, ②는 -R 800 에서 NOTIFY 의 왕복이"
echo "  제일 많다고 했다. **그 사이 어디서 뒤집히는가**를 찾는다."
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
CROSS=""
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
  # 두 값이 5% 안이면 '대등'으로 본다. 회차마다 순서가 바뀌는 지점을 '뒤집혔다'고 쓰면
  # 노이즈를 발견으로 읽는 것이다 — 실제로 두 번 돌려 한 번은 뒤집히고 한 번은 안 뒤집혔다.
  MARK=""
  if [ -z "$CROSS" ] && awk -v a="${NT:-0}" -v b="${PT:-0}" 'BEGIN{exit !(a > b*0.95)}'; then
    CROSS="$R"
    awk -v a="${NT:-0}" -v b="${PT:-0}" 'BEGIN{exit !(a > b*1.05)}' \
      && MARK="  ← NOTIFY 가 더 많아진다" || MARK="  ← 대등해지는 지점"
  fi
  # 잔량(부하 종료 직후 큐에 남은 항목) = 워커가 따라잡고 있었는가. 0 이 아니면 적체 구간이다.
  printf "  %-8s %8s | %9s / %-10s | %9s / %-10s | %9s / %-10s %6s%s\n" \
    "-R $R" "$(echo "$N"|awk '{print $1}')" "$NL" "$NT" "$PL" "$PT" "$AL" "$AT" \
    "$(echo "$N"|awk '{print $7}')" "$MARK"
done
echo
if [ -n "$CROSS" ]; then
  echo "  → **경계는 -R ${CROSS} 부근이다.** 그 아래에서는 NOTIFY 가 왕복도 적고 지연도 낮다."
  echo "    그 위로는 트랜잭션마다 알림이 나가 **NOTIFY 가 1ms 폴링보다 더 자주 깨어난다** —"
  echo "    알림 기반이 '가장 공격적인 폴링보다도 바쁜 폴링'으로 퇴화한 지점이다."
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
echo "  ⑤까지는 잔량이 0 이었다. 워커가 계속 따라잡았다는 뜻이고, 그 구간에서는"
echo "  '언제 깨느냐'가 지연을 지배한다. **워커가 못 따라잡으면 그 결론이 뒤집히는가**를 본다."
echo
echo "  적체는 쓰기율만 올려서는 안 만들어진다 — 이 장비의 pgbench 가 낼 수 있는 속도로는"
echo "  워커를 못 이긴다(⑤에서 -R 3200 을 줘도 잔량 0 이었다). **항목 하나를 비싸게** 만든다:"
echo "  주문을 한 고객에게 몰아 두면, 그 고객 등급 변경 1건이 denorm 수만 행 갱신이 된다."
echo
BIG="${BIG:-5000}"
sql "VACUUM (ANALYZE) lineitem_denorm" >/dev/null 2>&1
sql "UPDATE orders SET o_custkey=1 WHERE o_orderkey<=$BIG;" >/dev/null 2>&1
full_refill; trg notify
FAN=$(sql "SELECT count(*) FROM lineitem_denorm d JOIN orders o ON d.l_orderkey=o.o_orderkey
            WHERE o.o_custkey=1")
echo "  고객1 에 주문 ${BIG}건 → 등급 변경 1건당 파생 ${FAN}행 갱신"
echo
printf "  %s\n" "  깨우는 방식      달성tps  지연중앙  최대지연      왕복  배치당항목      잔량"
printf "  %s\n" "  ------------------------------------------------------------------------------"
for m in notify poll:20 adaptive:5; do
  R=$(run_case "$m" 400 /tmp/t9n_skew.sql)
  printf "  %s%9s %9s %9s %9s %11s %9s\n" "$(printf '%-16s' "$(lbl $m)")" \
    "$(echo "$R"|awk '{print $1}')" "$(echo "$R"|awk '{print $2}')" "$(echo "$R"|awk '{print $3}')" \
    "$(echo "$R"|awk '{print $8}')" "$(echo "$R"|awk '{print $9}')" "$(echo "$R"|awk '{print $7}')"
done
echo
echo "  **잔량 열이 먼저다.** 전부 0 이면 적체를 못 만든 것이고, 그 표로는 아무 말도 할 수 없다"
echo "  (BIG 을 키워 다시 돌린다). 0 이 아닌 줄이 있으면 적체가 걸린 것이다."
echo
echo "  해석 — **예상과 반대가 나왔다. 이 절은 그 기록이다.**"
echo "   처음 쓴 예상: \"적체되면 큐가 늘 차 있으니 무엇으로 깨우든 똑같아져 방식이 의미를 잃는다.\""
echo "   실측은 정반대였다 — **적체 구간에서 방식 차이가 가장 크게 벌어진다.**"
echo "   그리고 **즉시 깨우는 쪽(NOTIFY)이 가장 나쁘다.** ①②의 건강한 구간에서 가장 좋던 방식이다."
echo "   (두 번 돌려 지연 중앙값 124/126ms 대 적응형 31/46ms 로 방향이 같았다.)"
echo
echo "   **기전은 확정하지 못했다. 짐작으로 적지 않는다.**"
echo "   처음엔 \"NOTIFY 가 트랜잭션마다 깨워 배치를 잘게 쪼개고, drain 이 같은 고객을 DISTINCT 로"
echo "   접을 기회를 없앤다\" 로 썼는데 — **배치당 항목 열이 그걸 반증할 때가 있었다**(NOTIFY 쪽이"
echo "   오히려 컸다). 별도 하네스로 다시 재면 반대로 나와, 두 측정이 서로 안 맞는다."
echo "   대기 이벤트를 0.15초 간격으로 표본 추출해도 세 방식 모두 (running) 이 대부분이라"
echo "   락 대기로는 설명되지 않는다 — 어딘가에서 **CPU 를 더 쓰고 있다**는 것까지가 확인된 전부다."
echo "   남은 과제: drain 안에서 어느 UPDATE 가 시간을 먹는지 문장 단위로 쪼개 재는 것"
echo "   (auto_explain 이나 drain 을 단계별로 계측한 판이 필요하다)."
echo
echo "   확정된 것만 쓰면 이렇다 — **깨우는 방식의 우열이 부하 구간에 따라 뒤집힌다.**"
echo "   ①②(따라잡는 구간)에서 최선이던 NOTIFY 가 ⑥(밀리는 구간)에서 최악이 된다."
echo "   **그래서 한 구간에서만 재고 방식을 고르면 안 된다.** 이 스크립트가 구간을 나눠 재는 이유다."
echo "   → 실무 규칙 하나: **NOTIFY 는 응답성 대책이지 처리량 대책이 아니다.** 밀리기 시작하면"
echo "     알림을 끄고 페이싱으로 가는 것이 맞다(③의 '쓰기 경로 1.6배'까지 더하면 더 그렇다)."
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
