#!/usr/bin/env bash
# §T-9 동시성 마무리편: **`FOR SHARE` 수정본은 상위 격리수준에서도 성립하는가.**
#
# t9-concurrency.sh 가 남긴 숙제다. 거기서 소박한 트리거의 드리프트를 `FOR SHARE` 로 고쳤는데,
# 그 검증은 전부 READ COMMITTED 에서였다. 인계노트에 이렇게 적어 뒀다 —
# "REPEATABLE READ / SERIALIZABLE 에서는 직렬화 실패로 재시도가 필요할 수 있다."
# 이 스크립트가 그걸 잰다.
#
# 결론부터: **상위 격리수준은 드리프트를 막아 주는 게 아니라 쓰기를 실패시킨다.**
# `FOR SHARE` 는 RC 에서 필요했던 장치인데, RR/SER 에서는 그 장치가 그대로 실패 지점이 된다.
# 그래서 이 절의 진짜 주제는 격리수준이 아니라 **재시도 정책**이다.
#
#   ① 겨냥 해저드를 세 격리수준에서 — 쓰기 성공 여부와 드리프트를 **따로** 본다.
#      (드리프트 0 이 안전을 뜻하지 않는다. 쓰기가 아예 안 일어났을 수도 있다.)
#   ② 부하에서 실패율과 재시도 비용 — pgbench 16 의 --max-tries / --failures-detailed.
#   ③ 실패한 뒤 파생 테이블이 깨지지 않았는지 확인.
#
# 사용법:
#   ./t9-isolation-levels.sh            # 전부 (약 3분)
#   SECS=20 CLIENTS=16 ./t9-isolation-levels.sh
#   ONLY=1 ./t9-isolation-levels.sh     # 겨냥 해저드만
#   KEEP=1 ./t9-isolation-levels.sh     # 트리거/파생 테이블을 남긴다
#
# 선행 조건: tpch 적재 + 인덱스. pgbench 16 이상(--max-tries 가 필요하다).
#
# **데이터를 원상복구한다.** 부하가 customer 1~50 의 등급을 바꾸므로 시작 전에 백업하고
# 끝에 되돌린다. lineitem 은 넣었다 지우는 트랜잭션이라 순변화가 없다.
set -uo pipefail

SECS="${SECS:-8}"
CLIENTS="${CLIENTS:-8}"
JOBS="${JOBS:-4}"
NCUST="${NCUST:-50}"
ONLY="${ONLY:-123}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
export PGPASSWORD="${PGPASSWORD:-tuner}"
PGUSER_="${PGUSER:-tuner}"
DB=tpch
TMPD="${TMPDIR:-/tmp}/t9iso.$$"

want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
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
  q()  { psql -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -d "$DB" -X -q -tAc "$1" 2>&1; }
  PGBENCH(){ pgbench -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" "$@"; }
else
  q()  { docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="${PGOPTIONS:-}" "$CONTAINER" psql -U "$PGUSER_" -d "$DB" -X -q -tAc "$1" 2>&1; }
  PGBENCH(){ docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="${PGOPTIONS:-}" "$CONTAINER" pgbench -U "$PGUSER_" "$@"; }
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

# ── 규모 가드 ── (sql 정의 뒤여야 한다 — 앞에 뒀다가 "sql: command not found" 를 냈다)
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/_scale-guard.inc"
# NLI 는 아래(130행)에서 정해지므로 여기서 직접 센다 — 앞에서 쓰면 unbound 다.
scale_guard "$(q "SELECT count(*) FROM lineitem")" 1 "$0"

pg_precheck

# -f 로 주는 파일은 컨테이너 경로에서 컨테이너 안에 있어야 한다 — pg_stage 가 옮긴다.
if [ "$PG_VIA" = host ]; then
  qf() { psql -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -d "$DB" -X -q -f "$1" 2>&1; }
else
  qf() { docker exec -i -e PGPASSWORD=tuner "$CONTAINER" psql -U "$PGUSER_" -d "$DB" -X -q -f "$(pg_stage "$1")" 2>&1; }
fi
qx() { local o; o=$(q "$1"); case "$o" in *ERROR*) echo "  [중단] 준비 실패: $1"; echo "  $o"; exit 1;; esac; }

dispw() { local b k; b=$(printf %s "$1" | wc -c); k=$(printf %s "$1" | LC_ALL=C tr -dc '\200-\277' | wc -c)
          echo $(( b - k / 2 )); }
padr()  { local n; n=$(dispw "$1"); printf "%s" "$1"; while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; }
padl()  { local n; n=$(dispw "$1"); while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; printf "%s" "$1"; }

# **버전 확인에는 PGBENCH 래퍼를 쓰면 안 된다.** 래퍼가 -U 를 앞에 끼워 넣는데,
# pgbench 는 다른 옵션이 앞서면 --version 을 거부한다:
#   pgbench --version          → pgbench (PostgreSQL) 16.13
#   pgbench -U tuner --version → unrecognized option '--version'
# 그래서 "pgbench 를 찾을 수 없습니다" 가 찍혔다 — 컨테이너에 멀쩡히 있는데도.
# 메타 옵션은 인자를 안 끼우고 그대로 부른다.
if [ "$PG_VIA" = host ]; then
  pgbench_ver(){ pgbench --version 2>&1; }
else
  pgbench_ver(){ docker exec -i "$CONTAINER" pgbench --version 2>&1; }
fi
PGBVRAW=$(pgbench_ver)
PGBV=$(printf %s "$PGBVRAW" | grep -oE "[0-9]+" | head -1)
if [ -z "$PGBV" ]; then
  echo "  [중단] pgbench 버전을 읽지 못했습니다 (경로: $PG_VIA)."
  echo "         받은 출력: ${PGBVRAW:-(없음)}"
  [ "$PG_VIA" = docker ] && echo "         확인: docker exec -i $CONTAINER pgbench --version"
  exit 1
fi
if [ "${PGBV:-0}" -lt 14 ]; then
  echo "  [중단] pgbench $PGBV 입니다. --max-tries 는 14 이상에서만 됩니다 — ②를 잴 수 없습니다."
  exit 1
fi
NLI=$(q "SELECT count(*) FROM lineitem"); case "$NLI" in ''|*[!0-9]*) echo "tpch 를 읽지 못했습니다: $NLI"; exit 1;; esac
[ "$NLI" -lt 100000 ] && { echo "  [중단] lineitem 이 ${NLI}행뿐입니다. 먼저 적재하세요."; exit 1; }

mkdir -p "$TMPD"
cleanup() {
  # 데이터 원복이 먼저다 — 실험이 실패해도 tpch 는 원래대로 돌려놓는다.
  q "UPDATE customer c SET c_mktsegment=b.c_mktsegment FROM t9_iso_bak b
      WHERE c.c_custkey=b.c_custkey AND c.c_mktsegment IS DISTINCT FROM b.c_mktsegment" >/dev/null 2>&1
  q "DELETE FROM lineitem WHERE l_comment='t9iso'" >/dev/null 2>&1
  if [ "${KEEP:-0}" != "1" ]; then
    q "DROP TRIGGER IF EXISTS t_sync_li ON lineitem;
       DROP TRIGGER IF EXISTS t_sync_ord ON orders;
       DROP TRIGGER IF EXISTS t_sync_cust ON customer;" >/dev/null 2>&1
    q "DROP FUNCTION IF EXISTS sync_li() CASCADE; DROP FUNCTION IF EXISTS sync_ord() CASCADE;
       DROP FUNCTION IF EXISTS sync_cust() CASCADE;" >/dev/null 2>&1
    q "DROP TABLE IF EXISTS lineitem_denorm" >/dev/null 2>&1
  fi
  q "DROP TABLE IF EXISTS t9_iso_bak" >/dev/null 2>&1
  rm -rf "$TMPD"
}
trap cleanup EXIT

echo "§T-9 동시성 마무리 — FOR SHARE 수정본의 격리수준별 검증"
echo "  lineitem ${NLI}행 / 클라이언트 ${CLIENTS} / 조건당 ${SECS}초 / pgbench $PGBV"
echo

echo "준비: 파생 테이블과 FOR SHARE 트리거를 올린다 (약 20초)"
qx "DROP TABLE IF EXISTS t9_iso_bak"
qx "CREATE TABLE t9_iso_bak AS SELECT c_custkey, c_mktsegment FROM customer WHERE c_custkey <= $NCUST"
q "SET client_min_messages=warning; DROP TABLE IF EXISTS lineitem_denorm CASCADE" >/dev/null
qx "CREATE TABLE lineitem_denorm (
      l_orderkey BIGINT NOT NULL, l_linenumber INTEGER NOT NULL,
      l_extendedprice DECIMAL(15,2) NOT NULL, l_discount DECIMAL(15,2) NOT NULL,
      l_shipdate DATE NOT NULL, c_mktsegment CHAR(10) NOT NULL,
      o_orderdate DATE NOT NULL, o_shippriority INTEGER NOT NULL,
      CONSTRAINT pk_ld PRIMARY KEY (l_orderkey, l_linenumber))"
qx "INSERT INTO lineitem_denorm
      SELECT l.l_orderkey,l.l_linenumber,l.l_extendedprice,l.l_discount,l.l_shipdate,
             c.c_mktsegment,o.o_orderdate,o.o_shippriority
        FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                        JOIN customer c ON o.o_custkey=c.c_custkey"
qx "ANALYZE lineitem_denorm"

cat > "$TMPD/trg.sql" <<'EOSQL'
-- t9-concurrency.sh 의 수정본과 같다: 세 경로 모두 상위 행을 FOR SHARE 로 잠그고 읽는다.
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
   WHERE o.o_orderkey=NEW.l_orderkey FOR SHARE OF o, c;
  IF FOUND THEN
    INSERT INTO lineitem_denorm VALUES (NEW.l_orderkey,NEW.l_linenumber,NEW.l_extendedprice,
           NEW.l_discount,NEW.l_shipdate,seg,od,sp);
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sync_ord() RETURNS trigger AS $$
DECLARE seg CHAR(10);
BEGIN
  IF NEW.o_orderdate IS DISTINCT FROM OLD.o_orderdate
     OR NEW.o_shippriority IS DISTINCT FROM OLD.o_shippriority THEN
    UPDATE lineitem_denorm SET o_orderdate=NEW.o_orderdate, o_shippriority=NEW.o_shippriority
     WHERE l_orderkey=NEW.o_orderkey;
  END IF;
  IF NEW.o_custkey IS DISTINCT FROM OLD.o_custkey THEN
    SELECT c_mktsegment INTO seg FROM customer WHERE c_custkey=NEW.o_custkey FOR SHARE;
    UPDATE lineitem_denorm SET c_mktsegment=seg WHERE l_orderkey=NEW.o_orderkey;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sync_cust() RETURNS trigger AS $$
BEGIN
  IF NEW.c_mktsegment IS DISTINCT FROM OLD.c_mktsegment THEN
    UPDATE lineitem_denorm SET c_mktsegment=NEW.c_mktsegment
     WHERE l_orderkey IN (SELECT o_orderkey FROM orders WHERE o_custkey=NEW.c_custkey FOR SHARE);
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
O=$(qf "$TMPD/trg.sql"); case "$O" in *ERROR*) echo "트리거 설치 실패: $O"; exit 1;; esac
echo "  완료 (파생 $(q "SELECT count(*) FROM lineitem_denorm")행)"
echo

LEVELS=('read\ committed:READ COMMITTED' 'repeatable\ read:REPEATABLE READ' 'serializable:SERIALIZABLE')

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① 겨냥 해저드 H1 — 세 격리수준에서 무엇이 달라지는가 ──"
echo
echo "  A: 고객1의 등급을 바꾸고 아직 커밋 안 함"
echo "  B: 그 사이 주문1을 고객1로 옮긴다 → 트리거가 customer 를 FOR SHARE 로 읽는다"
echo
OTHER=$(q "SELECT o_custkey FROM orders WHERE o_orderkey=1 AND o_custkey<>1
           UNION ALL SELECT o_custkey FROM orders WHERE o_custkey<>1 LIMIT 1")
printf "  %s%-12s %s\n" "$(padr 격리수준 18)" "B의 쓰기" "파생 테이블"
printf "  %s\n" "-------------------------------------------------------------------------"
for e in "${LEVELS[@]}"; do
  LBL="${e#*:}"
  q "UPDATE orders SET o_custkey=$OTHER WHERE o_orderkey=1" >/dev/null
  q "UPDATE customer SET c_mktsegment='MACHINERY' WHERE c_custkey=1" >/dev/null
  ( q "BEGIN; UPDATE customer SET c_mktsegment='H1X' WHERE c_custkey=1; SELECT pg_sleep(2); COMMIT;" >/dev/null ) &
  sleep 0.7
  OUT=$(q "BEGIN ISOLATION LEVEL $LBL; UPDATE orders SET o_custkey=1 WHERE o_orderkey=1; COMMIT;")
  wait
  case "$OUT" in
    *"could not serialize"*) VERD="**실패(40001)**";;
    *ERROR*)                 VERD="오류";;
    *)                       VERD="성공";;
  esac
  D=$(q "SELECT CASE WHEN d.c_mktsegment IS DISTINCT FROM c.c_mktsegment
                     THEN '드리프트 있음' ELSE '일치' END
           FROM lineitem_denorm d JOIN orders o ON d.l_orderkey=o.o_orderkey
           JOIN customer c ON o.o_custkey=c.c_custkey WHERE d.l_orderkey=1 LIMIT 1")
  printf "  %s%s %s\n" "$(padr "$LBL" 18)" "$(padr "$VERD" 20)" "$D"
done
q "UPDATE orders SET o_custkey=$OTHER WHERE o_orderkey=1" >/dev/null
echo
echo "  **오른쪽 열만 보면 셋 다 안전해 보인다. 가운데 열을 같이 봐야 한다.**"
echo "   · READ COMMITTED — B 가 성공한다. FOR SHARE 가 A 의 커밋을 기다렸다가 새 값을 읽는다."
echo "     t9-concurrency.sh 가 고친 것이 바로 이 경로다."
echo "   · REPEATABLE READ / SERIALIZABLE — B 가 **죽는다.** 스냅숏이 고정돼 있어 '내가 보던 행이"
echo "     그 사이 바뀌었다'가 되고, 재시도 말고는 방법이 없다."
echo "     드리프트가 없는 건 안전해서가 아니라 **쓰기가 아예 안 일어나서**다."
echo "   → 상위 격리수준은 이 문제를 풀어 주지 않는다. **옮긴다** — 정합성 문제에서 가용성 문제로."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② 부하에서 — 재시도 정책이 없으면 얼마나 잃는가 ──"
echo
cat > "$TMPD/wa.sql" <<EOF
\\set c random(1, $NCUST)
\\set s random(1, 5)
BEGIN;
UPDATE customer SET c_mktsegment =
  CASE :s WHEN 1 THEN 'BUILDING' WHEN 2 THEN 'AUTOMOBILE' WHEN 3 THEN 'MACHINERY'
          WHEN 4 THEN 'HOUSEHOLD' ELSE 'FURNITURE' END
 WHERE c_custkey = :c;
END;
EOF
cat > "$TMPD/wb.sql" <<EOF
\\set c random(1, $NCUST)
BEGIN;
INSERT INTO lineitem (l_orderkey,l_partkey,l_suppkey,l_linenumber,l_quantity,l_extendedprice,
  l_discount,l_tax,l_returnflag,l_linestatus,l_shipdate,l_commitdate,l_receiptdate,
  l_shipinstruct,l_shipmode,l_comment)
SELECT o_orderkey,1,1,90+:client_id,1,100.00,0.05,0.05,'N','O',
  DATE '1995-01-01',DATE '1995-01-01',DATE '1995-01-01','DELIVER','AIR','t9iso'
  FROM orders WHERE o_custkey = :c LIMIT 1;
DELETE FROM lineitem WHERE l_linenumber = 90+:client_id AND l_comment='t9iso';
END;
EOF
echo "  워크로드 절반은 고객 등급 변경(sync_cust), 절반은 lineitem 삽입(sync_li 의 FOR SHARE)."
echo "  고객 ${NCUST}명으로 좁혀 경합을 만든다. lineitem 은 넣고 바로 지워 순변화가 없다."
echo
printf "  %s%s %10s %10s %10s\n" "$(padr 격리수준 18)" "$(padr 재시도 20)" "$(padl TPS 10)" "$(padl 실패 10)" "$(padl 재시도수 10)"
printf "  %s\n" "-------------------------------------------------------------------------"
declare -A T1 FAIL1 NTX1
for e in "${LEVELS[@]}"; do
  LVL="${e%%:*}"; LBL="${e#*:}"
  for MT in 1 10; do
    # **-f 로 주는 파일은 컨테이너 안에 있어야 한다.** 다른 스크립트의 -f 는 pg_stage 로
    # 감쌌는데 여기만 놓쳤다 — docker 경로에서 pgbench 가 호스트 경로를 못 찾아 죽었고,
    # 표가 통째로 0 과 ? 로 찍혔다(TPS 0 / 실패 ? / 재시도 0). 그리고 ③이 그 위에서
    # "직렬화 실패를 수백 건 낸 뒤"라고 말했다 — 한 건도 안 났는데.
    R=$(PGOPTIONS="-c default_transaction_isolation=$LVL" \
        PGBENCH -d "$DB" -n \
          -f "$(pg_stage "$TMPD/wa.sql")" -f "$(pg_stage "$TMPD/wb.sql")" \
          -c "$CLIENTS" -j "$JOBS" -T "$SECS" \
          --max-tries=$MT --failures-detailed 2>&1)
    TPS=$(echo "$R" | grep -oE "^tps = [0-9.]+" | grep -oE "[0-9.]+" | head -1)
    # **빈 값을 0 으로 찍고 넘어가지 않는다.** 왜 비었는지를 보여 준다.
    if [ -z "$TPS" ]; then
      echo "  [중단] pgbench 가 결과를 안 냈습니다 (격리수준 $LVL, max-tries=$MT)."
      printf "%s\n" "$R" | sed 's/^/         /' | head -8
      exit 1
    fi
    FAIL=$(echo "$R" | grep -oE "number of failed transactions: [0-9]+" | grep -oE "[0-9]+" | head -1)
    RETR=$(echo "$R" | grep -oE "number of transactions retried: [0-9]+" | grep -oE "[0-9]+" | head -1)
    if [ "$MT" = 1 ]; then
      T1["$LBL"]="$TPS"; FAIL1["$LBL"]="${FAIL:-0}"
      # 표본 크기 = tps × 초. 실패 '건수'는 이것에 비례하므로, 건수만 보고
      # 배수를 말하면 규모가 다른 실행끼리 비교가 안 된다 — 비율로 바꿔 둔다.
      NTX1["$LBL"]=$(awk -v t="${TPS:-0}" -v s="$SECS" 'BEGIN{printf "%.0f", t*s}')
      RL="없음 (max-tries=1)"
    else RL="있음 (max-tries=10)"; fi
    printf "  %s%s %10s %10s %10s\n" "$(padr "$LBL" 18)" "$(padr "$RL" 20)" \
      "$(printf '%.0f' "${TPS:-0}")" "${FAIL:-?}" "${RETR:-0}"
  done
done
echo
echo "  읽는 법 — **실패 열이 이 절의 핵심이다.**"
echo "   · READ COMMITTED 는 실패가 0 이다. FOR SHARE 가 기다렸다 읽으므로 재시도할 일이 없다."
echo "   · REPEATABLE READ 는 실패가 생기지만 적고, 재시도하면 전부 복구되며 TPS 도 거의 안 준다."
# 배수를 박아 두지 않는다 — 재서 쓴다. 참고로 두 규모에서 8배 안팎으로 일관됐다
# (SF=0.5: 151/19 = 7.9배, SF=10: 17/2 = 8.5배). 그래도 '10배'라고 고정하지는 않는다.
# 키는 **표시용 라벨**이다(LEVELS 의 'serializable:SERIALIZABLE' 에서 오른쪽).
# 소문자 키로 읽었다가 set -u 아래에서 unbound variable 로 죽었다.
SERR=$(awk -v a="${FAIL1[SERIALIZABLE]:-0}" -v b="${FAIL1[REPEATABLE READ]:-0}" \
        'BEGIN{ if (b+0>0) printf "%.1f배", a/b; else print "(RR 실패 0 이라 계산 불가)" }')
echo "   · SERIALIZABLE 은 실패가 RR 의 **${SERR}** 다. RR 은 '내가 잠근 행이 바뀌었다'만 잡지만"
echo "     SER 은 **읽기-쓰기 의존성까지** 잡기 때문이다. 재시도를 붙이면 대부분 복구되는 대신"
echo "     그만큼 일을 두 번 하므로 TPS 가 떨어지고, 10번을 다 쓰고도 실패하는 것이 남을 수 있다."
echo "   → **재시도 정책이 없는 애플리케이션에 SERIALIZABLE 을 켜는 것은 설정이 아니라 사고다.**"
echo "     그리고 이 워크로드에서는 RC + FOR SHARE 가 이미 정합성을 주므로, 상위 격리수준으로"
echo "     올려서 새로 얻는 것이 없다 — 비용만 있다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
echo "── ③ 실패가 잔해를 남기는가 ──"
echo
DR=$(q "WITH truth AS (
   SELECT l.l_orderkey,l.l_linenumber,l.l_extendedprice,l.l_discount,l.l_shipdate,
          c.c_mktsegment,o.o_orderdate,o.o_shippriority
   FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                   JOIN customer c ON o.o_custkey=c.c_custkey)
 SELECT (SELECT count(*) FROM (SELECT * FROM truth EXCEPT SELECT * FROM lineitem_denorm) x)
      + (SELECT count(*) FROM (SELECT * FROM lineitem_denorm EXCEPT SELECT * FROM truth) y)")
LEFT=$(q "SELECT count(*) FROM lineitem WHERE l_comment='t9iso'")
# "수백 건"이 박혀 있었다. SF=10 에서는 19건이었다 — 규모가 바뀌면 건수도 바뀐다.
TOTF=$(( ${FAIL1[REPEATABLE READ]:-0} + ${FAIL1[SERIALIZABLE]:-0} ))
echo "  ②에서 직렬화 실패를 ${TOTF}건 낸 뒤의 상태:"
if [ "${NTX1[SERIALIZABLE]:-0}" -lt 300 ]; then
  echo "  ※ 이번 실행은 조건당 약 ${NTX1[SERIALIZABLE]}건밖에 못 돌았다(${SECS}초 × $(printf '%.0f' "${T1[SERIALIZABLE]:-0}") tps)."
  # SECS·CLIENTS 는 위치 인자가 아니라 환경변수다(스크립트 머리말 참고).
  echo "    시간을 늘리면 표본이 커진다: SECS=$(( SECS * 4 )) $0"
  echo "    실패 **건수**는 그만큼 작게 나온다 — 규모가 다른 실행과는 건수가 아니라"
  echo "    **비율**로 비교할 것(이번 SER 실패율 $(awk -v f="${FAIL1[SERIALIZABLE]:-0}" -v n="${NTX1[SERIALIZABLE]:-1}" 'BEGIN{printf "%.0f%%", f*100/n}'))."
fi
echo "    파생 테이블 불일치 행: $DR   (0 이어야 한다)"
echo "    남은 실험용 lineitem: $LEFT   (0 이어야 한다)"
echo
echo "  실패한 트랜잭션은 **통째로 롤백된다** — 트리거가 쓴 파생 행도 같이 사라진다."
echo "  그래서 상위 격리수준의 대가는 '깨진 데이터'가 아니라 **안 된 일**이다."
echo "  이건 좋은 소식이자 위험한 소식이다: 정합성 점검으로는 이 손실이 안 잡힌다."
echo "  → 재시도 정책의 유무는 데이터를 봐서는 알 수 없고, **실패율을 재야** 안다."
echo
fi

echo "정리: FOR SHARE 수정본은 세 격리수준 모두에서 파생 테이블을 깨뜨리지 않는다."
echo "  다만 RC 에서는 기다렸다 쓰고, RR/SER 에서는 실패하고 물러난다."
echo "  **격리수준을 올리는 것은 이 문제의 해법이 아니다.** 필요한 것은 재시도 정책이다."
echo
if [ "${KEEP:-0}" = "1" ]; then
  echo "  KEEP=1 — 트리거와 lineitem_denorm 을 남긴다."
else
  # 원복 확인은 백업 테이블을 지우기 **전에** 해야 한다.
  q "UPDATE customer c SET c_mktsegment=b.c_mktsegment FROM t9_iso_bak b
      WHERE c.c_custkey=b.c_custkey AND c.c_mktsegment IS DISTINCT FROM b.c_mktsegment" >/dev/null
  DIFF=$(q "SELECT count(*) FROM customer c JOIN t9_iso_bak b USING (c_custkey)
             WHERE c.c_mktsegment IS DISTINCT FROM b.c_mktsegment")
  cleanup; trap - EXIT
  echo "  정리했다 (tpch 원본은 원래대로 되돌렸다):"
  echo "    남은 트리거     $(q "SELECT count(*) FROM pg_trigger WHERE tgname LIKE 't\\_sync%'")"
  echo "    파생 테이블     $(q "SELECT count(*) FROM pg_tables WHERE tablename='lineitem_denorm'")"
  echo "    안 돌아온 등급  ${DIFF}"
  echo "    실험용 lineitem $(q "SELECT count(*) FROM lineitem WHERE l_comment='t9iso'")   (전부 0 이어야 한다)"
fi
