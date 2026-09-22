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
# **래퍼를 거쳐야 한다.** 여기만 psql 을 직접 불렀다가, 호스트에 클라이언트가 없는
# 환경에서 `psql: command not found` 로 즉시 끝났다. 2>&1 >/dev/null 로 삼켜져서
# ②의 경합 측정이 "3ms / 2ms — 안 막혔다"로 찍혔다. **실행이 안 된 것을 결과로 읽을 뻔했다.**
# 바깥 `timeout` 대신 **서버의 statement_timeout** 을 쓴다. 함수는 bash -c 하위 셸에
# 안 보이므로 timeout 과 래퍼를 같이 쓸 수 없고, 어차피 여기서 재려는 것은
# '락을 얼마나 기다리는가'라 서버 쪽에서 끊는 게 맞다(전송 경로와 무관해진다).
tsql(){ PSQL -tAc "SET statement_timeout='$1s'; $2" 2>/dev/null; }

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
# setsize() 가 orders.o_custkey 를 통째로 재배치한다 — 되돌리려면 원본이 있어야 한다.
# (t9-change-queue·t9-queue-tuning 은 이 백업을 갖고 있었는데 여기만 없어서,
#  이 스크립트를 돌리면 재적재 말고는 복구할 방법이 없었다.)
sql "DROP TABLE IF EXISTS orders_cust_bak;
     CREATE TABLE orders_cust_bak AS SELECT o_orderkey, o_custkey FROM orders;
     ALTER TABLE orders_cust_bak ADD PRIMARY KEY (o_orderkey);" >/dev/null 2>&1

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
# **표본 크기를 같이 본다.** 12초 고정이라 tps 가 낮은 조건(=적중률 100%)에서는
# 트랜잭션이 1,000건도 안 돼 비율이 크게 흔들린다. 실제로 같은 조건 5회에서 100% 열이
# 0.50~2.47 로 4.9배 벌어졌다(1% 열은 0.94~1.01 로 안정). 그래서 tps 뿐 아니라
# '이 값이 몇 건에서 나왔는지'를 기억해 두고, 적으면 그렇게 말한다.
SECS_T=12
run(){ PGBENCH -f "$(pg_stage /tmp/t9_skew.sql)" \
         -c 8 -j 4 -T "$SECS_T" -n tpch 2>&1 | grep -oP 'tps = \K[0-9.]+' | head -1; }
# 표본 크기는 **부모 셸에서** 센다. run() 안에서 변수에 담으면 $(run) 이 서브셸이라
# 값이 부모로 안 넘어오고, set -u 아래에서 unbound variable 로 죽는다(실제로 그랬다).
tx_of(){ awk -v t="${1:-0}" -v s="$SECS_T" 'BEGIN{printf "%.0f", t*s}'; }
printf "  %-10s %-9s %13s %13s %8s\n" "주문수" "적중률" "naive tps" "FOR SHARE" "손해"
declare -A LOSS NAIVE TX
for N in 50 500 5000; do
  setsize $N
  for T in sync_cust_naive sync_cust_fs; do
    usetrg $T; r=$(run); [ "$T" = "sync_cust_naive" ] && A=$r || B=$r
  done
  LOSS[$N]=$(awk -v x="$A" -v y="$B" 'BEGIN{ if (y+0>0) printf "%.2f", x/y; else print "0" }')
  NAIVE[$N]="$A"; TX[$N]="$(tx_of "$A")"
  printf "  %-10s %-9s %13s %13s %7s배\n" "$N" "$(awk -v n=$N 'BEGIN{printf "%.0f%%",n/5000*100}')" \
         "$A" "$B" "${LOSS[$N]}"
done
echo
# **해석을 박아 두지 않는다.** 문서 실측(SF=0.5)에서는 손해가 1% 0.95배 → 100% 2.47배로
# 적중률을 따라 올랐다. 그런데 SF=10 에서는 1% 1.23배 → 100% 0.99배로 **방향이 뒤집혔다.**
# 100% 에서는 naive 도 FOR SHARE 도 같은 지점에서 직렬화돼(팬아웃 자체가 병목) 락이
# 더 보탤 것이 없기 때문이다. 그런데도 옛 문장이 그대로 찍혀 표와 어긋났다.
echo "해석:"
echo "  이번 실행의 손해: 1% ${LOSS[50]}배 / 10% ${LOSS[500]}배 / 100% ${LOSS[5000]}배"
# 100% 조건은 tps 가 낮아 12초에 담기는 트랜잭션이 적다 — 비율을 단정하면 안 된다.
if [ "${TX[5000]:-0}" -lt 2000 ]; then
  echo "  ⚠️ **100% 열의 배수는 믿지 말 것.** 이 조건은 ${SECS_T}초에 약 ${TX[5000]}건밖에"
  echo "     못 돌아(1% 조건은 약 ${TX[50]}건) 표본이 작다. 같은 조건 5회 반복에서 이 열이"
  echo "     **0.50~2.47배로 4.9배 벌어졌다** — 1% 열은 0.94~1.01 로 안정적이었다."
  echo "     더 재려면 시간을 늘린다: SECS_T 를 키우거나 여러 번 돌려 중앙값을 본다."
fi
echo "  안정적으로 재현되는 것은 손해 배수가 아니라 **naive 열의 절대값**이다:"
echo "     1% ${NAIVE[50]} → 10% ${NAIVE[500]} → 100% ${NAIVE[5000]} tps."
echo "  **락을 아예 안 써도** 편중이 생기면 처리량이 무너진다 — 주된 피해는 락이 아니라"
echo "  팬아웃 자체(등급 1건 변경 = denorm 2만 행 갱신)다. 락을 빼는 것은 해법이 아니다."
echo "  → 정합성 락의 비용은 '무엇을 잠그느냐'가 아니라 '누가 그걸 건드리느냐'다."
echo "  → 판단 기준은 락 범위의 크기가 아니라 그 범위가 쓰기 트래픽과 겹치는 비율이며,"
echo "     이건 스키마가 아니라 워크로드를 봐야 안다."
echo "  → 대형 계정에 쓰기가 몰리는 시스템이라면 행 락 대신 변경 큐 + 비동기 전파 +"
echo "     정합성 배치를 검토하거나, 애초에 그 컬럼을 반정규화하지 않는 쪽을 봐야 한다."
echo

# ── 정리 ──────────────────────────────────────────────────────────────
# **명령을 찍기만 하면 안 된다.** 이 스크립트가 다는 트리거는 원본 테이블의 모든 쓰기에
# 발화하고, 남은 denorm/큐 테이블은 다음 실습의 숫자를 조용히 바꾼다. 실제로
# t9-preaggregation 이 남긴 매트뷰 때문에 재적재가 통째로 막힌 적이 있다.
# 되돌릴 수 있는 것은 되돌리고, 못 되돌리는 것은 **무엇이 남았는지 정확히 말한다.**
echo "정리:"
if [ "${KEEP:-0}" = "1" ]; then
  echo "  KEEP=1 — 남겨 둔다. ⚠️ t_sync_cust 는 customer 의 모든 UPDATE 에 발화하고,"
  echo "     orders.o_custkey 는 인위적 분포 그대로다. 다음 측정 전에 지울 것."
else
  sql "UPDATE orders o SET o_custkey=b.o_custkey FROM orders_cust_bak b
       WHERE o.o_orderkey=b.o_orderkey AND o.o_custkey IS DISTINCT FROM b.o_custkey;" >/dev/null 2>&1
  sql "DROP TRIGGER IF EXISTS t_sync_cust ON customer;
       DROP TABLE IF EXISTS lineitem_denorm;
       DROP TABLE IF EXISTS orders_cust_bak;
       DROP SEQUENCE IF EXISTS seg_seq;" >/dev/null 2>&1
  LT=$(sql "SELECT count(*) FROM pg_trigger WHERE tgname LIKE 't\\_sync%'")
  LD=$(sql "SELECT count(*) FROM pg_tables WHERE tablename IN ('lineitem_denorm','orders_cust_bak')")
  echo "  트리거·denorm·백업을 지우고 orders.o_custkey 를 원래 분포로 되돌렸다."
  echo "  남은 t_sync% ${LT} / 실험 테이블 ${LD}   (둘 다 0 이어야 한다)"
  echo "  ※ customer.c_mktsegment 는 측정 중 바뀐 채다(값만 다르고 행수는 그대로)."
  echo "    문서 실측과 맞춰야 하면 ./scripts/restore-lab.sh --force-tpch 로 재적재한다."
fi
