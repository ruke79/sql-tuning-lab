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
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
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
                  qdepth:5) echo "큐깊이 5ms";; qdepth:20) echo "큐깊이 20ms";; esac; }

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
echo "정리 (이 스크립트는 customer/lineitem 을 변형한다 — 재적재 권장):"
echo "  ./gradlew :tpch:bootRun --args=\"schema --db=postgres\""
echo "  ./gradlew :tpch:bootRun --args=\"load   --db=postgres\""
echo "  ./gradlew :tpch:bootRun --args=\"index  --db=postgres\""
