#!/usr/bin/env bash
# 멀티테넌시 분리 훈련 — 같은 데이터를 세 가지 격리 전략으로 놓고 **무엇이 갈리는지 잰다.**
#
# 테넌트 = 매장(ss_store_sk). store_sales 200만 행이 12개 테넌트로 나뉜다.
#
#   A. 공유 테이블 + tenant_id 컬럼   (풀 모델)      격리: WHERE 절 / 선택적으로 RLS
#   B. 공유 테이블 + LIST 파티션      (풀 모델 변형) 격리: 없음 — 파티션은 성능 장치다
#   C. 테넌트별 스키마                 (브리지 모델)   격리: search_path
#   (D. 테넌트별 DB/인스턴스는 이 스크립트 범위 밖이다 — 같은 인스턴스 안에서는 CPU 를
#       나눠 쓸 수밖에 없다는 것이 ⑥의 결론이고, 그것이 D 가 필요한 이유다.)
#
# 재는 것:
#   ① 테넌트 범위 조회          — 세 전략 + RLS 가 같은 질문에 내는 계획과 시간
#   ② RLS 오버헤드              — 정책 조건이 인덱스를 살리는가, 얼마나 붙는가
#   ③ WHERE 누락 유출           — 조건을 빼먹은 조회가 남의 테넌트를 보여주는가
#   ④ 교차 테넌트 집계          — "전 매장 합계"가 전략마다 얼마나 다른 모양이 되는가
#   ⑤ DDL 팬아웃                — 인덱스 하나 추가가 몇 번의 DDL 이 되는가
#   ⑥ 시끄러운 이웃             — 옆 테넌트의 부하가 내 조회를 얼마나 늦추는가 (물리 배치 vs CPU 를 분리해서)
#
# verify-lab 의 DB-13(RowLevelSecurityCase)은 4행짜리 표로 RLS 의 **정확성**을 검증한다.
# 여기서는 200만 행에서 **성능과 운영 비용**을 잰다 — 같은 주제의 다른 질문이다.
#
# 사용법:
#   ./mt-tenant-isolation.sh            # 전부, 각 측정 4회 최소값
#   ./mt-tenant-isolation.sh 6          # 6회
#   ONLY=13 ./mt-tenant-isolation.sh    # ①③만
#   KEEP=1 ./mt-tenant-isolation.sh     # 실험 객체를 남겨 둔다 (psql 로 직접 볼 때)
#
# 선행 조건: tpcds schema → load → index (§0-4). pgbench 가 PATH 에 있어야 ⑥이 돈다.
set -uo pipefail

REPEAT="${1:-4}"
ONLY="${ONLY:-123456}"
want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

# work_mem — 이 스크립트가 여는 세션에만 건다(PGOPTIONS). 서버 기본값은 건드리지 않는다.
# 상한이지 예약이 아니라서 넘칠 일이 없으면 올려도 그대로다. t7 주석 참고.
WORK_MEM="${WORK_MEM:-4096MB}"
export PGOPTIONS="-c work_mem=$WORK_MEM"
export PGPASSWORD=tuner          # pgbench 도 같은 자격증명을 쓴다

# psql 은 폴백이 있었는데 **pgbench 는 맨 호출이었다.** docker 경로에서 pgbench 가
# 호스트 경로의 -f 파일을 못 찾아 조용히 빈 값을 냈다(같은 함정을 t9-isolation-levels
# 에서 먼저 맞았다 — 표가 통째로 0 으로 찍혔다). 둘을 같이 갈라 둔다.
if command -v psql >/dev/null 2>&1; then
  PG_VIA=host
  sql()  { psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -X -q -tAc "$1"; }
  sqlv() { psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -X -q -c "$1"; }
  sqlf() { psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -X -q -f "$1"; }
  PGBENCH(){ pgbench -h "$PGHOST_" -p "$PGPORT_" -U tuner "$@"; }
else
  PG_VIA=docker
  sql()  { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -X -q -tAc "$1"; }
  sqlv() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -X -q -c "$1"; }
  sqlf() { docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -X -q < "$1"; }
  PGBENCH(){ docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" pgbench -U tuner "$@"; }
fi
# -f 로 주는 파일은 컨테이너 안에 있어야 한다.
pg_stage() {
  if [ "$PG_VIA" = host ]; then printf %s "$1"; return; fi
  docker cp "$1" "$CONTAINER:/tmp/$(basename "$1")" >/dev/null 2>&1
  printf %s "/tmp/$(basename "$1")"
}

if ! sql "SELECT 1 FROM store_sales LIMIT 1" >/dev/null 2>&1; then
  echo "  store_sales 가 없습니다. §0-4 의 tpcds 준비 명령을 먼저 실행하세요."; exit 1
fi

ms_of() { echo "$1" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+'; }
# 반복 최소값. $1 = 세션 준비 SQL(SET 등, 비어도 됨), $2 = 쿼리
best_ms() {
  local pre="$1" Q="$2" b="" v
  sql "$pre EXPLAIN (ANALYZE) $Q" >/dev/null 2>&1
  for _ in $(seq "$REPEAT"); do
    v=$(ms_of "$(sql "$pre EXPLAIN (ANALYZE) $Q")")
    [ -z "$v" ] && continue
    [ -z "$b" ] && b="$v" || b=$(awk -v a="$b" -v c="$v" 'BEGIN{print (c+0<a+0)?c:a}')
  done
  echo "${b:-?}"
}
scan_of() { sql "$1 EXPLAIN (COSTS OFF) $2" | grep -oE '(Parallel )?(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan) (using [a-z0-9_]+ )?on [a-z0-9_.]+' | head -1; }
# **hit=0 이면 PostgreSQL 이 그 항목을 아예 생략한다.** 그래서 'shared hit=' 로 긁으면
# top 노드 줄을 건너뛰고 더 깊은 노드 값을 집는다 — 테이블이 shared_buffers 보다 크면
# (SF=10 등) 늘 그렇게 되고, buffers 열이 시간과 전혀 안 맞는 작은 값으로 찍힌다.
# 첫 'Buffers: shared' 줄을 잡고 두 항목을 각각 0 기본값으로 읽는다.
# **시간과 같은 캐시 상태에서 재야 한다.** best_ms 는 워밍업 뒤 4회 최소값인데
# bufs_of 가 워밍업 없이 한 번만 돌면(그리고 printf 인자 순서상 먼저 돌면) buffers 는
# 가장 차가운 실행이 된다 — SF=10 에서 A·B·C 가 전부 hit=0 으로 찍힌 것이 그 증상이다.
# 한 번 버리고 두 번째를 읽어 두 열의 조건을 맞춘다.
bufs_of() { sql "$1 EXPLAIN (ANALYZE, BUFFERS) $2" >/dev/null 2>&1
            sql "$1 EXPLAIN (ANALYZE, BUFFERS) $2" | awk '/Buffers: shared/{h=0;r=0; if (match($0,/hit=[0-9]+/)) h=substr($0,RSTART+4,RLENGTH-4); if (match($0,/read=[0-9]+/)) r=substr($0,RSTART+5,RLENGTH-5); printf "hit=%d read=%d", h, r; exit}'; }

TENANTS=$(sql "SELECT string_agg(s_store_sk::text, ' ' ORDER BY s_store_sk) FROM store")
NT=$(echo "$TENANTS" | wc -w)
T_ME=3; T_OTHER=7          # 내 테넌트 / 이웃 테넌트
D1=$(sql "SELECT min(d_date_sk) FROM date_dim WHERE d_year=1999 AND d_moy=6")
D2=$(sql "SELECT max(d_date_sk) FROM date_dim WHERE d_year=1999 AND d_moy=6")

echo "멀티테넌시 분리 훈련 — 테넌트 ${NT}개(매장), store_sales $(sql "SELECT count(*) FROM store_sales") 행, 각 측정 ${REPEAT}회 최소값"
echo "질문: \"테넌트 ${T_ME} 의 1999년 6월 매출\"  (ss_sold_date_sk ${D1}~${D2})"
echo

# ══════════════════════════════════════════════════════════════════════
# 준비 — 세 전략을 같은 데이터·같은 인덱스 정책으로 만든다
# ══════════════════════════════════════════════════════════════════════
echo "── 준비: 세 전략의 사본을 만든다 (각 200만 행) ──"
T0=$(date +%s)
# 정리 — 문장을 **따로** 보낸다. 한 -c 에 몰아 넣으면 한 트랜잭션이라, DROP ROLE 이
# "권한이 남아 있다"로 실패하는 순간 앞의 DROP TABLE 까지 전부 롤백된다.
# 실제로 그렇게 만들었다가 정리가 한 번도 안 되고 있었다 — 두 번째 실행이 첫 실행의
# 테이블을 그대로 재사용했고, ⑤가 "인덱스가 이미 있다"로 41ms 만에 끝나는 것으로 드러났다.
# 롤의 권한은 DROP OWNED BY 로 먼저 걷어내야 DROP ROLE 이 통과한다.
teardown() {
  sql "SET client_min_messages=warning; DROP TABLE IF EXISTS mt_shared CASCADE" >/dev/null 2>&1
  sql "SET client_min_messages=warning; DROP TABLE IF EXISTS mt_part CASCADE" >/dev/null 2>&1
  sql "DO \$\$ DECLARE s text; BEGIN
         FOR s IN SELECT nspname FROM pg_namespace WHERE nspname LIKE 'mt_t%' LOOP
           EXECUTE 'DROP SCHEMA '||quote_ident(s)||' CASCADE'; END LOOP; END \$\$" >/dev/null 2>&1
  sql "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mt_app') THEN
         EXECUTE 'DROP OWNED BY mt_app'; EXECUTE 'DROP ROLE mt_app'; END IF; END \$\$" >/dev/null 2>&1
}
teardown

# A. 공유 테이블. 테넌트 선두 복합 인덱스 — 풀 모델에서 '사실상 필수'라는 그 인덱스
sql "CREATE TABLE mt_shared AS SELECT ss_store_sk AS tenant_id, ss_sold_date_sk, ss_item_sk, ss_ticket_number,
       ss_customer_sk, ss_quantity, ss_ext_sales_price, ss_net_profit FROM store_sales;
     CREATE INDEX ON mt_shared (tenant_id, ss_sold_date_sk);
     ANALYZE mt_shared;" >/dev/null 2>&1
TA=$(date +%s)

# B. LIST 파티션. 파티션 로컬 인덱스는 날짜만 — 테넌트는 프루닝이 대신한다
PARTS=""
for t in $TENANTS; do PARTS="$PARTS CREATE TABLE mt_part_$t PARTITION OF mt_part FOR VALUES IN ($t);"; done
sql "CREATE TABLE mt_part (LIKE mt_shared) PARTITION BY LIST (tenant_id);
     $PARTS
     INSERT INTO mt_part SELECT * FROM mt_shared;
     CREATE INDEX ON mt_part (ss_sold_date_sk);
     ANALYZE mt_part;" >/dev/null 2>&1
TB=$(date +%s)

# C. 테넌트별 스키마. 각 스키마에 같은 이름의 테이블 — 애플리케이션은 search_path 만 바꾼다
SCH=""
for t in $TENANTS; do
  SCH="$SCH CREATE SCHEMA mt_t$t;
       CREATE TABLE mt_t$t.store_sales AS SELECT * FROM mt_shared WHERE tenant_id=$t;
       CREATE INDEX ON mt_t$t.store_sales (ss_sold_date_sk);
       ANALYZE mt_t$t.store_sales;"
done
sql "$SCH" >/dev/null 2>&1
TC=$(date +%s)

# RLS 용 일반 롤. 슈퍼유저·소유자는 RLS 를 우회하므로 SET ROLE 로 내려가서 잰다.
sql "CREATE ROLE mt_app NOLOGIN;
     GRANT USAGE ON SCHEMA public TO mt_app;
     GRANT SELECT ON mt_shared, mt_part TO mt_app;
     ALTER TABLE mt_shared ENABLE ROW LEVEL SECURITY;
     ALTER TABLE mt_shared FORCE  ROW LEVEL SECURITY;
     CREATE POLICY tenant_only ON mt_shared
       USING (tenant_id = current_setting('app.tenant', true)::int);" >/dev/null 2>&1
# 소유자(tuner)가 정책 없이 조회하면 FORCE 때문에 0행이 된다 → 소유자용 통과 정책
sql "CREATE POLICY owner_all ON mt_shared TO tuner USING (true);" >/dev/null 2>&1

[ "$(sql "SELECT count(*) FROM mt_shared")" = "$(sql "SELECT count(*) FROM store_sales")" ] || { echo "  [중단] mt_shared 가 제대로 만들어지지 않았다 (이전 실행의 잔여물?). teardown 후 재시도:"; echo "         KEEP=0 ONLY= ./mt-tenant-isolation.sh"; exit 1; }
printf "  A 공유 테이블+인덱스   %3ds   %s\n" $((TA-T0)) "$(sql "SELECT pg_size_pretty(pg_total_relation_size('mt_shared'))")"
printf "  B LIST 파티션 %2d개     %3ds   %s\n" "$NT" $((TB-TA)) "$(sql "SELECT pg_size_pretty(sum(pg_total_relation_size(inhrelid))) FROM pg_inherits WHERE inhparent='mt_part'::regclass")"
printf "  C 스키마 %2d개          %3ds   %s\n" "$NT" $((TC-TB)) "$(sql "SELECT pg_size_pretty(sum(pg_total_relation_size(c.oid))) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname LIKE 'mt_t%' AND c.relkind='r'")"
echo

QA="SELECT sum(ss_ext_sales_price) FROM mt_shared WHERE tenant_id=$T_ME AND ss_sold_date_sk BETWEEN $D1 AND $D2"
QB="SELECT sum(ss_ext_sales_price) FROM mt_part   WHERE tenant_id=$T_ME AND ss_sold_date_sk BETWEEN $D1 AND $D2"
QC="SELECT sum(ss_ext_sales_price) FROM store_sales WHERE ss_sold_date_sk BETWEEN $D1 AND $D2"
PRE_C="SET search_path = mt_t$T_ME;"
PRE_RLS="SET ROLE mt_app; SET app.tenant = '$T_ME';"

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① 테넌트 범위 조회 — 같은 질문, 네 가지 경로 ──"
printf "  %-26s %-58s %-18s %s\n" "전략" "스캔" "buffers" "min(ms)"
printf "  %s\n" "----------------------------------------------------------------------------------------------------------------"
printf "  %-26s %-58s %-18s %s\n" "A 공유+복합인덱스"     "$(scan_of '' "$QA")"        "$(bufs_of '' "$QA")"        "$(best_ms '' "$QA")"
printf "  %-26s %-58s %-18s %s\n" "A + RLS (mt_app)"      "$(scan_of "$PRE_RLS" "$QA")" "$(bufs_of "$PRE_RLS" "$QA")" "$(best_ms "$PRE_RLS" "$QA")"
printf "  %-26s %-58s %-18s %s\n" "B 파티션(프루닝)"      "$(scan_of '' "$QB")"        "$(bufs_of '' "$QB")"        "$(best_ms '' "$QB")"
printf "  %-26s %-58s %-18s %s\n" "C 스키마(search_path)" "$(scan_of "$PRE_C" "$QC")"  "$(bufs_of "$PRE_C" "$QC")"  "$(best_ms "$PRE_C" "$QC")"
echo
echo "  B 가 실제로 파티션 하나만 열었는지:"
sql "EXPLAIN (COSTS OFF) $QB" | grep -E 'mt_part_|Subplans Removed|Append' | sed 's/^ */    /' | head -4
echo
echo "  해석: 세 전략 모두 결국 '날짜 인덱스로 이 테넌트의 6월 범위'를 읽는다."
echo "        A 는 복합 인덱스의 선두 컬럼이, B 는 프루닝이, C 는 스키마가 테넌트를 골라낸다."
echo "        B·C 의 buffers 가 조금 적은 것은 인덱스가 테넌트 몫만 담아 작기 때문이다(A 는 12배 큰 인덱스를 탄다)."
echo "        여기서 차이가 크지 않다면 **격리 전략은 단일 테넌트 조회 성능으로 고르는 게 아니다** — 아래 ③~⑥이 갈리는 곳이다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② RLS 오버헤드 — 정책이 인덱스를 죽이지는 않는가 ──"
# 정책 조건 tenant_id = current_setting(...)::int 는 상수로 접히지 않고 실행 시 평가된다.
# 그래도 인덱스 선두 컬럼과 등호라 Index Cond 로 들어가야 정상이다. 들어가는지 본다.
sql "$PRE_RLS EXPLAIN (COSTS OFF) $QA" | grep -E 'Index Cond|Filter' | sed 's/^ */    /' | head -3
A0=$(best_ms '' "$QA"); A1=$(best_ms "$PRE_RLS" "$QA")
printf "  RLS 없음 %s ms → RLS 적용 %s ms  (%sx)\n" "$A0" "$A1" "$(awk -v a="$A0" -v b="$A1" 'BEGIN{printf "%.2f", b/a}')"
echo
echo "  더 중요한 것 — **정책은 조건을 빼먹은 쿼리에도 붙는다.** 그것이 RLS 의 존재 이유다:"
QA_NO="SELECT count(*) FROM mt_shared WHERE ss_sold_date_sk BETWEEN $D1 AND $D2"
sql "$PRE_RLS EXPLAIN (COSTS OFF) $QA_NO" | grep -E 'Index Cond|Filter|Scan' | sed 's/^ */    /' | head -3
echo "    ↑ tenant_id 를 안 썼는데 정책이 tenant_id 조건을 넣었고, 그래서 복합 인덱스를 탄다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
echo "── ③ WHERE 누락 유출 — 테넌트 조건을 빼먹은 조회는 몇 행을 돌려주는가 ──"
MINE=$(sql "SELECT count(*) FROM mt_shared WHERE tenant_id=$T_ME")
ALL=$(sql "SELECT count(*) FROM mt_shared")
L_A=$(sql "SELECT count(*) FROM mt_shared")
L_R=$(sql "$PRE_RLS SELECT count(*) FROM mt_shared")
L_B=$(sql "SELECT count(*) FROM mt_part")
L_C=$(sql "$PRE_C SELECT count(*) FROM store_sales")
printf "  내 테넌트 %s 행 / 전체 %s 행\n\n" "$MINE" "$ALL"
printf "  %-26s %12s   %s\n" "전략" "돌아온 행수" "판정"
printf "  %s\n" "-----------------------------------------------------------"
jd() { [ "$1" = "$MINE" ] && echo "격리됨" || echo "**유출 — 전 테넌트 노출**"; }
printf "  %-26s %12s   %s\n" "A 공유 테이블"          "$L_A" "$(jd "$L_A")"
printf "  %-26s %12s   %s\n" "A + RLS"               "$L_R" "$(jd "$L_R")"
printf "  %-26s %12s   %s\n" "B 파티션"               "$L_B" "$(jd "$L_B")"
printf "  %-26s %12s   %s\n" "C 스키마(search_path)"  "$L_C" "$(jd "$L_C")"
echo
echo "  해석: **파티션은 격리가 아니다.** 프루닝은 조건이 있을 때만 일어나고, 조건이 없으면"
echo "        전 파티션을 훑는다 — 성능 장치이지 보안 장치가 아니다."
echo "        격리를 주는 것은 RLS(정책이 강제로 붙는다)와 스키마(다른 테넌트 테이블이 이름에 없다) 뿐이다."
echo "        단 C 도 'mt_t7.store_sales' 처럼 스키마를 명시하면 뚫린다 — 권한(GRANT)까지 나눠야 완성된다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 4; then
echo "── ④ 교차 테넌트 집계 — '전 매장 6월 매출 상위' 는 전략마다 다른 쿼리가 된다 ──"
XA="SELECT tenant_id, sum(ss_ext_sales_price) FROM mt_shared WHERE ss_sold_date_sk BETWEEN $D1 AND $D2 GROUP BY 1 ORDER BY 2 DESC"
XB="SELECT tenant_id, sum(ss_ext_sales_price) FROM mt_part   WHERE ss_sold_date_sk BETWEEN $D1 AND $D2 GROUP BY 1 ORDER BY 2 DESC"
XC=""; for t in $TENANTS; do
  [ -n "$XC" ] && XC="$XC UNION ALL "
  XC="$XC SELECT $t AS tenant_id, sum(ss_ext_sales_price) FROM mt_t$t.store_sales WHERE ss_sold_date_sk BETWEEN $D1 AND $D2"
done
XC="SELECT * FROM ($XC) u ORDER BY 2 DESC"
printf "  %-22s %8s %-16s %-36s %s\n" "전략" "min(ms)" "buffers" "스캔" "쿼리 길이"
printf "  %s\n" "----------------------------------------------------------------------------------------------------"
printf "  %-22s %8s %-16s %-36s %s자\n" "A 공유 테이블"  "$(best_ms '' "$XA")" "$(bufs_of '' "$XA")" "$(scan_of '' "$XA" | cut -c1-36)" "${#XA}"
printf "  %-22s %8s %-16s %-36s %s자\n" "B 파티션"       "$(best_ms '' "$XB")" "$(bufs_of '' "$XB")" "$(scan_of '' "$XB" | cut -c1-36)" "${#XB}"
printf "  %-22s %8s %-16s %-36s %s자 (UNION ALL ×%s)\n" "C 스키마" "$(best_ms '' "$XC")" "$(bufs_of '' "$XC")" "$(scan_of '' "$XC" | cut -c1-36)" "${#XC}" "$NT"
echo
echo "  A 가 제일 느린 이유 — (tenant_id, 날짜) 복합 인덱스는 **날짜만 있는 조건을 못 탄다**"
echo "  (선두 컬럼이 빠지면 PostgreSQL 16 은 인덱스를 건너뛰며 못 읽는다). 그래서 풀스캔이다."
echo "  A 에 날짜 인덱스를 **하나 더** 주면 어떻게 되는가:"
sql "CREATE INDEX mt_shared_date ON mt_shared (ss_sold_date_sk); ANALYZE mt_shared;" >/dev/null 2>&1
printf "    A + 날짜 인덱스        %8s %-16s %s\n" "$(best_ms '' "$XA")" "$(bufs_of '' "$XA")" "$(scan_of '' "$XA" | cut -c1-36)"
echo
echo "  그 대가 — 전략별 **인덱스 총량** (같은 두 질문을 다 빠르게 하는 데 드는 값):"
printf "    A (복합 + 날짜)   %s\n" "$(sql "SELECT pg_size_pretty(pg_indexes_size('mt_shared'))")"
printf "    B (파티션 로컬)   %s\n" "$(sql "SELECT pg_size_pretty(sum(pg_indexes_size(inhrelid))) FROM pg_inherits WHERE inhparent='mt_part'::regclass")"
printf "    C (스키마별)      %s\n" "$(sql "SELECT pg_size_pretty(sum(pg_indexes_size(c.oid))) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname LIKE 'mt_t%' AND c.relkind='r'")"
sql "DROP INDEX mt_shared_date" >/dev/null 2>&1
echo
echo "  해석: 풀 모델의 '테넌트 선두 복합 인덱스'는 단일 테넌트 조회를 위한 것이고, 테넌트를"
echo "        가로지르는 질문에는 **없는 것과 같다.** 두 질문을 다 받으려면 인덱스가 둘 필요하다."
echo "        B·C 는 날짜 인덱스 하나로 두 질문을 다 받는다 — 테넌트 축은 물리 배치가 대신하기 때문이다."
echo "        대신 C 는 테넌트가 늘 때마다 쿼리가 길어지고, 새 테넌트를 빠뜨리면 조용히 틀린 답이 나온다."
echo "        '테넌트를 가로지르는 질문이 얼마나 자주, 누가 쓰는가'가 C 를 고를지 정하는 첫 기준이다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 5; then
echo "── ⑤ DDL 팬아웃 — 인덱스 하나를 더하는 데 DDL 몇 번, 몇 초인가 ──"
t0=$(date +%s%N); sql "CREATE INDEX mt_shared_cust ON mt_shared (tenant_id, ss_customer_sk)" >/dev/null 2>&1; tA=$(( ($(date +%s%N)-t0)/1000000 ))
t0=$(date +%s%N); sql "CREATE INDEX mt_part_cust ON mt_part (ss_customer_sk)" >/dev/null 2>&1;             tB=$(( ($(date +%s%N)-t0)/1000000 ))
t0=$(date +%s%N); n=0
for t in $TENANTS; do sql "CREATE INDEX ON mt_t$t.store_sales (ss_customer_sk)" >/dev/null 2>&1; n=$((n+1)); done
tC=$(( ($(date +%s%N)-t0)/1000000 ))
printf "  %-22s %6s개 DDL  %7s ms\n" "A 공유 테이블" 1 "$tA"
printf "  %-22s %6s개 DDL  %7s ms   (파티션 %s개에 자동 전파)\n" "B 파티션" 1 "$tB" "$NT"
printf "  %-22s %6s개 DDL  %7s ms   (연결 %s회 포함)\n" "C 스키마" "$n" "$tC" "$n"
echo
echo "  해석: 시간보다 **횟수**를 봐야 한다. C 는 테넌트 수만큼 반복해야 하고, 하나라도"
echo "        빠지면 그 테넌트만 느린 채로 남아 '간헐적' 성능 문제로 나타난다."
echo "        B 는 부모에 한 번 만들면 파티션에 자동 전파된다 — C 의 운영 부담 없이 C 의 물리 분리를 얻는다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 6; then
if ! command -v pgbench >/dev/null 2>&1; then
  echo "── ⑥ 시끄러운 이웃 — pgbench 가 없어 건너뛴다 ──"; echo
else
echo "── ⑥ 시끄러운 이웃 — 옆 테넌트의 부하가 내 조회를 얼마나 늦추는가 (측정 8초씩) ──"
SD="${TMPDIR:-/tmp}/mt-tenant-$$"; mkdir -p "$SD"
# 피해자: 내 테넌트의 좁은 조회(한 달), 1세션.  이웃: 2세션이 쉬지 않고 돌린다.
cat > "$SD/v_a.sql" <<EOF
SELECT sum(ss_ext_sales_price) FROM mt_shared WHERE tenant_id=$T_ME AND ss_sold_date_sk BETWEEN $D1 AND $D2;
EOF
cat > "$SD/v_b.sql" <<EOF
SELECT sum(ss_ext_sales_price) FROM mt_part WHERE tenant_id=$T_ME AND ss_sold_date_sk BETWEEN $D1 AND $D2;
EOF
cat > "$SD/v_c.sql" <<EOF
SET search_path = mt_t$T_ME;
SELECT sum(ss_ext_sales_price) FROM store_sales WHERE ss_sold_date_sk BETWEEN $D1 AND $D2;
EOF
# ⑥-1 이웃: 자기 테넌트 **전체**를 집계한다 — 논리적으로 같은 일, 물리적으로는 전략마다 다른 일
cat > "$SD/n_a.sql" <<EOF
SELECT count(*), sum(ss_net_profit) FROM mt_shared WHERE tenant_id=$T_OTHER;
EOF
cat > "$SD/n_b.sql" <<EOF
SELECT count(*), sum(ss_net_profit) FROM mt_part WHERE tenant_id=$T_OTHER;
EOF
cat > "$SD/n_c.sql" <<EOF
SET search_path = mt_t$T_OTHER;
SELECT count(*), sum(ss_net_profit) FROM store_sales;
EOF
# ⑥-2 이웃: 테넌트 데이터를 아예 안 건드리는 순수 CPU 부하 — 전략과 무관하게 **같은** 부하.
# i*i 로 썼다가 int4 를 넘쳐 pgbench 가 조용히 죽었고(exit 2), '이웃 동시' 열이 이웃 없이
# 측정돼 "감소 없음"이라는 가짜 결과가 한 번 나왔다. bigint 로 올린다.
# 세션 수는 CPU 수와 같게 — 코어가 남으면 경합이 안 생겨 아무것도 못 본다.
NCPU=$(nproc 2>/dev/null || echo 4)
cat > "$SD/n_cpu.sql" <<EOF
SELECT sum(i::bigint * i) FROM generate_series(1, 2000000) i;
EOF
bench() {  # $1 = 스크립트, $2 = clients → "tps lat_avg"
  PGBENCH -n -c "$2" -T 8 -f "$(pg_stage "$1")" tpcds 2>/dev/null \
    | awk '/^tps/{t=$3} /latency average/{l=$4} END{printf "%s %s", t, l}'
}
noisy() {  # $1 = 라벨, $2 = 피해자 스크립트, $3 = 이웃 스크립트, $4 = 이웃 세션 수
  local t1 l1 t2 l2
  read -r t1 l1 <<<"$(bench "$2" 1)"
  # 빈 값을 그대로 표에 넣지 않는다 — 왜 비었는지 모르는 0 이 제일 나쁘다.
  [ -n "$t1" ] || { echo "    [중단] pgbench 가 결과를 안 냈다 ($2, 경로 $PG_VIA)."; return 1; }
  ( PGBENCH -n -c "$4" -T 9 -f "$(pg_stage "$3")" tpcds >/dev/null 2>&1
    [ $? -ne 0 ] && echo "    [경고] 이웃 pgbench 가 비정상 종료했다 — '이웃 동시' 열을 믿지 말 것" ) &
  sleep 0.5
  read -r t2 l2 <<<"$(bench "$2" 1)"
  wait
  printf "  %-14s %8.0f / %-6s %8.0f / %-6s %sx\n" "$1" "$t1" "$l1" "$t2" "$l2" "$(awk -v a="$t1" -v b="$t2" 'BEGIN{printf "%.2f", a/b}')"
}

echo "  ⑥-1 이웃이 **자기 테넌트 전체를 집계**할 때 (논리적으로 같은 일)"
echo "      먼저 그 이웃 조회 자체가 전략마다 얼마나 무거운지 — 페이지 수와 **프로세스 수**:"
nb() {  # $1 = 쿼리 → "buffers / 워커 수 / 스캔"
  local o; o=$(sql "EXPLAIN (ANALYZE, BUFFERS) $1")
  printf "%-22s 워커 %s개   %s" "$(echo "$o" | awk '/Buffers: shared/{h=0;r=0; if (match($0,/hit=[0-9]+/)) h=substr($0,RSTART+4,RLENGTH-4); if (match($0,/read=[0-9]+/)) r=substr($0,RSTART+5,RLENGTH-5); printf "hit=%d read=%d", h, r; exit}')" \
    "$(w=$(echo "$o" | grep -oE 'Workers Launched: [0-9]+' | grep -oE '[0-9]+' | head -1); echo "${w:-0}")" \
    "$(echo "$o" | grep -oE '(Parallel )?(Seq Scan|Bitmap Heap Scan|Index Scan) on [a-z_0-9.]+' | head -1)"
}
printf "        %-4s %s\n" "A" "$(nb "SELECT count(*), sum(ss_net_profit) FROM mt_shared WHERE tenant_id=$T_OTHER")"
printf "        %-4s %s\n" "B" "$(nb "SELECT count(*), sum(ss_net_profit) FROM mt_part WHERE tenant_id=$T_OTHER")"
printf "        %-4s %s\n" "C" "$(nb "SELECT count(*), sum(ss_net_profit) FROM mt_t$T_OTHER.store_sales")"
printf "        A 에서 테넌트 %s 의 행이 걸쳐 있는 힙 페이지: %s\n" "$T_OTHER" \
  "$(sql "SELECT count(DISTINCT (ctid::text::point)[0])||' / '||(SELECT relpages FROM pg_class WHERE relname='mt_shared') FROM mt_shared WHERE tenant_id=$T_OTHER")"
echo
printf "  %-14s %-17s %-17s %s\n" "전략" "혼자 (tps/ms)" "이웃 동시 (tps/ms)" "피해자 처리량 감소"
printf "  %s\n" "------------------------------------------------------------------------"
noisy "A 공유"   "$SD/v_a.sql" "$SD/n_a.sql" 2
noisy "B 파티션" "$SD/v_b.sql" "$SD/n_b.sql" 2
noisy "C 스키마" "$SD/v_c.sql" "$SD/n_c.sql" 2
echo
echo "  ⑥-2 이웃이 **순수 CPU 부하**(테넌트 데이터를 안 건드림)를 ${NCPU}세션(=CPU 수)으로 돌릴 때 — 전략과 무관하게 같은 부하"
printf "  %-14s %-17s %-17s %s\n" "전략" "혼자 (tps/ms)" "이웃 동시 (tps/ms)" "피해자 처리량 감소"
printf "  %s\n" "------------------------------------------------------------------------"
noisy "A 공유"   "$SD/v_a.sql" "$SD/n_cpu.sql" "$NCPU"
noisy "C 스키마" "$SD/v_c.sql" "$SD/n_cpu.sql" "$NCPU"
rm -rf "$SD"
echo
echo "  해석: 두 표를 같이 읽어야 한다."
echo "   · ⑥-2 — 이웃이 CPU 를 다 쓰면 A 도 C 도 느려진다. 둘의 감소폭 차이는 실행 간 편차 안이다"
echo "     (두 번 재서 한 번은 A 가, 한 번은 C 가 더 컸다). 같은 인스턴스 안에서는 어떤 전략도 CPU 를"
echo "     나눠 쓰는 것을 막지 못한다 — 격리는 이름공간의 격리이지 자원의 격리가 아니다."
echo "     자원 격리는 인스턴스를 나눠야(D) 얻는다."
echo "   · ⑥-1 — 같은 '자기 테넌트 전체 집계'인데 피해자가 겪는 정도가 전략마다 다르다. 위 표의"
echo "     페이지 수와 워커 수가 이유다:"
echo "       A: 그 테넌트의 행이 힙 전체에 흩어져 있어 **10배의 페이지**를 워커 여럿이 훑는다."
echo "       B: 페이지는 C 와 같은데 **병렬 계획**을 받아 워커를 띄운다 — 프로세스가 하나 더 CPU 를 쓴다."
echo "          (같은 크기의 C 는 직렬이다. 파티션의 성질이 아니라 비용 모델이 임계 근처에서 갈린 것이고,"
echo "           어느 쪽이 병렬을 받는지는 장비·설정의 값이다 — 이 결과를 규칙으로 옮기지 말 것.)"
echo "       C: 페이지도 적고 워커도 없다. 그래서 피해자가 거의 못 느낀다."
echo "   → 시끄러운 이웃의 크기는 '이웃이 무엇을 하는가'가 아니라 **이웃이 페이지 몇 장을 프로세스 몇 개로"
echo "     만지는가**로 정해진다. 풀 모델(A)의 진짜 문제는 CPU 가 아니라 흩어짐이다 — 테넌트 단위"
echo "     배치가 많다면 tenant_id 로 CLUSTER 하거나 B 로 간다(§T-2 의 클러스터링 실험과 같은 원리)."
echo
fi
fi

# ══════════════════════════════════════════════════════════════════════
echo "정리:"
if [ "${KEEP:-0}" = "1" ]; then
  echo "  KEEP=1 — 실험 객체를 남겨 둔다: mt_shared / mt_part / 스키마 mt_t* / 롤 mt_app"
  echo "  지우려면: psql -d tpcds -c 'DROP TABLE mt_shared, mt_part CASCADE;' 후 스키마·롤 삭제"
else
  teardown
  LEFT=$(sql "SELECT count(*) FROM pg_class WHERE relname LIKE 'mt\\_%'")
  echo "  실험 객체를 모두 지웠다 (store_sales 원본은 건드리지 않았다). 남은 mt_* 객체: ${LEFT}개"
fi
