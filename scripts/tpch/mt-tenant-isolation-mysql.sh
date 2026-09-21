#!/usr/bin/env bash
# 멀티테넌시 분리 훈련 (MySQL / InnoDB 판) — 같은 질문을 엔진을 바꿔서 묻는다.
#
# PostgreSQL 판 두 개가 "테넌트 키가 팩트에 있는가"를 물었다면(§X-1), 이 판은
# **"엔진이 바뀌면 같은 전략이 같은 값을 갖는가"** 를 묻는다. 답은 아니오다.
# MySQL 에서 달라지는 것이 넷 있고, 넷 다 PostgreSQL 실습에서는 나올 수 없는 것들이다.
#
#   1. RLS 가 **없다.** 뷰 + 저장 함수 + 권한으로 흉내내야 하고, 그러면 격리의 출처가
#      '테이블에 붙은 정책'이 아니라 '**권한**'이 된다 — 성질이 다른 방어다.
#   2. InnoDB 의 PK 는 **클러스터드 인덱스다.** 테넌트를 PK 선두에 두면 테넌트 행이
#      물리적으로 모인다 — PostgreSQL 이 CLUSTER 로 일회성으로 하던 일이 구조가 된다.
#   3. 파티션 키는 **모든 유니크 키에 포함돼야 한다**(ERROR 1503). 즉 테넌트로 파티션하려면
#      테넌트를 PK 에 넣어야만 하고, InnoDB 에서 그것은 곧 물리 배치를 바꾸는 일이다.
#   4. MySQL 에서 스키마 = 데이터베이스다. 그래서 '테넌트별 스키마'와 '테넌트별 DB'의
#      경계가 PostgreSQL 만큼 뚜렷하지 않다.
#
# 테넌트 = 국가(nation, 25개). PostgreSQL tpch 판과 같은 축·같은 데이터(lineitem 300만).
#
#   N.  정규화 그대로 (lineitem → orders → customer, 2조인)
#   A.  비정규화, PK 는 원본대로 (l_orderkey, l_linenumber) + 테넌트 보조 인덱스
#   A′. 비정규화, **테넌트를 PK 선두로** (l_nationkey, l_orderkey, l_linenumber)
#   B.  A′ + LIST 파티션 25개   (파티션하려면 어차피 A′ 여야 한다 — 제약 3)
#   C.  테넌트별 데이터베이스 25개
#
# 재는 것:
#   ① 테넌트 범위 조회      — 다섯 배치가 같은 질문에 내는 계획과 시간
#   ② 클러스터드 PK 의 값   — A vs A′ 가 전부다. 그리고 그 대가(세컨더리 인덱스 폭)
#   ③ RLS 대체              — 뷰+함수+권한이 어디까지 막고 어디서 뚫리는가
#   ④ WHERE 누락 유출
#   ⑤ 파티션 제약           — ERROR 1503 을 실제로 받아 본다
#   ⑥ 테넌트 이동           — PK 를 바꾸는 UPDATE 는 InnoDB 에서 행 이동이다
#
# 사용법:
#   ./mt-tenant-isolation-mysql.sh          # 전부, 각 측정 4회 최소값
#   ./mt-tenant-isolation-mysql.sh 6
#   ONLY=125 ./mt-tenant-isolation-mysql.sh
#   KEEP=1 ./mt-tenant-isolation-mysql.sh   # 실험 객체를 남겨 둔다
#
# 선행 조건: MySQL 에 tpch 가 적재돼 있어야 한다. 없으면 ./scripts/restore-lab.sh --mysql
set -uo pipefail

REPEAT="${1:-4}"
ONLY="${ONLY:-123456}"
want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
MYHOST="${MYSQL_HOST:-127.0.0.1}"
MYPORT="${MYSQL_PORT:-3306}"
MYUSER="${MYSQL_USER:-tuner}"
MYPASS="${MYSQL_PASS:-tuner}"

my()  { mysql -h "$MYHOST" -P "$MYPORT" -u "$MYUSER" -p"$MYPASS" -N -B "$@" 2>/dev/null; }
myv() { mysql -h "$MYHOST" -P "$MYPORT" -u "$MYUSER" -p"$MYPASS" "$@" 2>&1 | grep -v '^mysql: \[Warning\]'; }
q()   { my tpch -e "$1"; }
qe()  { mysql -h "$MYHOST" -P "$MYPORT" -u "$MYUSER" -p"$MYPASS" tpch -e "$1" 2>&1 | grep -v '^mysql: \[Warning\]'; }

if ! q "SELECT 1 FROM lineitem LIMIT 1" >/dev/null 2>&1; then
  echo "  MySQL 의 tpch.lineitem 이 없습니다. 둘 중 하나:"
  echo "    ./scripts/restore-lab.sh --mysql        # 빠진 것만 알아서 채운다(권장)"
  echo "    ./gradlew :tpch:bootRun --args=\"schema --db=mysql\""
  echo "    ./gradlew :tpch:bootRun --args=\"load   --db=mysql --dir=./data/tpch\""
  echo "    ./gradlew :tpch:bootRun --args=\"index  --db=mysql\"   # 빠뜨리기 쉽다 — InnoDB 는 PK 가 물리 배치다"
  exit 1
fi

# 벽시계로 잰다. MySQL 클라이언트는 연결 오버헤드가 psql 보다 작지만, 그래도
# 수 ms 짜리 비교에는 못 쓴다 — 그런 비교는 EXPLAIN ANALYZE 의 actual time 을 본다.
best() {
  local Q="$1" b="" v s e
  q "$Q" >/dev/null 2>&1
  for _ in $(seq "$REPEAT"); do
    s=$(date +%s%N); q "$Q" >/dev/null 2>&1; e=$(date +%s%N)
    v=$(( (e-s)/1000000 ))
    [ -z "$b" ] && b="$v" || b=$(awk -v a="$b" -v c="$v" 'BEGIN{print (c+0<a+0)?c:a}')
  done; echo "$b"
}
# EXPLAIN ANALYZE 의 최상위 actual time (서버가 실제로 쓴 시간)
srv_ms() { q "EXPLAIN ANALYZE $1" | grep -oE 'actual time=[0-9.]+\.\.[0-9.]+' | head -1 | sed 's/.*\.\.//'; }
plan_of() { q "EXPLAIN FORMAT=TREE $1" | sed 's/\\n/\n/g' | grep -oE '(Index lookup|Index range scan|Table scan|Covering index lookup|Filter|Nested loop|Hash join)[^(]*' | head -1 | sed 's/ *$//'; }

TEN=$(q "SELECT count(*) FROM nation")
T_ME=3; T_OTHER=7
NLI=$(q "SELECT count(*) FROM lineitem")

echo "멀티테넌시 분리 훈련 (MySQL $(q "SELECT VERSION()") / InnoDB)"
echo "테넌트 ${TEN}개(국가), lineitem ${NLI} 행, 각 측정 ${REPEAT}회 최소값"
echo "buffer pool $(q "SELECT ROUND(@@innodb_buffer_pool_size/1024/1024)")MB  (PostgreSQL 판의 shared_buffers 1GB 와 맞춘 값)"
echo

teardown() {
  q "DROP TABLE IF EXISTS li_a" >/dev/null 2>&1
  q "DROP TABLE IF EXISTS li_ac" >/dev/null 2>&1
  q "DROP TABLE IF EXISTS li_part" >/dev/null 2>&1
  q "DROP VIEW IF EXISTS v_li" >/dev/null 2>&1
  q "DROP FUNCTION IF EXISTS app_tenant" >/dev/null 2>&1
  for n in $(seq 0 $((TEN-1))); do my -e "DROP DATABASE IF EXISTS mt_n$n" >/dev/null 2>&1; done
  my -e "DROP USER IF EXISTS 'mt_app'@'%'" >/dev/null 2>&1
}

# ══════════════════════════════════════════════════════════════════════
echo "── 준비 ──"
teardown
SRC="SELECT c.c_nationkey AS l_nationkey, l.l_orderkey, l.l_linenumber, o.o_custkey,
            l.l_extendedprice, l.l_shipdate
     FROM lineitem l JOIN orders o ON l.l_orderkey=o.o_orderkey
                     JOIN customer c ON o.o_custkey=c.c_custkey"
COLS="l_nationkey INT NOT NULL, l_orderkey BIGINT NOT NULL, l_linenumber INT NOT NULL,
      o_custkey INT NOT NULL, l_extendedprice DECIMAL(15,2), l_shipdate DATE"

T0=$(date +%s)
# A — PK 는 원본대로. 테넌트는 보조 인덱스로 찾는다.
q "CREATE TABLE li_a ($COLS, PRIMARY KEY (l_orderkey, l_linenumber),
     KEY k_ten (l_nationkey, l_shipdate), KEY k_cust (o_custkey)) ENGINE=InnoDB;
   INSERT INTO li_a $SRC; ANALYZE TABLE li_a;" >/dev/null 2>&1
TA=$(date +%s)
# A′ — 테넌트를 PK 선두로. InnoDB 에서 이것은 물리 배치를 바꾸는 일이다.
q "CREATE TABLE li_ac ($COLS, PRIMARY KEY (l_nationkey, l_orderkey, l_linenumber),
     KEY k_cust (o_custkey)) ENGINE=InnoDB;
   INSERT INTO li_ac $SRC; ANALYZE TABLE li_ac;" >/dev/null 2>&1
TB=$(date +%s)
# B — LIST 파티션. PK 에 테넌트가 들어가 있어야만 가능하다(⑤에서 확인).
PARTS=""
for n in $(seq 0 $((TEN-1))); do
  [ -n "$PARTS" ] && PARTS="$PARTS,"
  PARTS="$PARTS PARTITION p$n VALUES IN ($n)"
done
q "CREATE TABLE li_part ($COLS, PRIMARY KEY (l_nationkey, l_orderkey, l_linenumber),
     KEY k_cust (o_custkey)) ENGINE=InnoDB
   PARTITION BY LIST (l_nationkey) ($PARTS);
   INSERT INTO li_part $SRC; ANALYZE TABLE li_part;" >/dev/null 2>&1
TC=$(date +%s)
# C — 테넌트별 데이터베이스
for n in $(seq 0 $((TEN-1))); do
  my -e "CREATE DATABASE mt_n$n;
         CREATE TABLE mt_n$n.lineitem ($COLS, PRIMARY KEY (l_orderkey, l_linenumber),
           KEY k_ship (l_shipdate)) ENGINE=InnoDB;
         INSERT INTO mt_n$n.lineitem SELECT * FROM tpch.li_a WHERE l_nationkey=$n;
         ANALYZE TABLE mt_n$n.lineitem;" >/dev/null 2>&1
done
TD=$(date +%s)

[ "$(q "SELECT count(*) FROM li_a")" = "$NLI" ] || { echo "  [중단] li_a 적재 실패"; exit 1; }
sz() { q "SELECT CONCAT(ROUND(SUM(data_length)/1048576),'MB 데이터 / ',ROUND(SUM(index_length)/1048576),'MB 인덱스')
          FROM information_schema.tables WHERE table_schema='tpch' AND table_name='$1'"; }
printf "  A  비정규화, PK=(orderkey,linenumber)      %3ds   %s\n" $((TA-T0)) "$(sz li_a)"
printf "  A′ 비정규화, PK=(nationkey,...)            %3ds   %s\n" $((TB-TA)) "$(sz li_ac)"
printf "  B  A′ + LIST 파티션 %2d개                   %3ds   %s\n" "$TEN" $((TC-TB)) "$(sz li_part)"
printf "  C  테넌트별 DB %2d개                        %3ds   %s\n" "$TEN" $((TD-TC)) \
  "$(q "SELECT CONCAT(ROUND(SUM(data_length)/1048576),'MB 데이터 / ',ROUND(SUM(index_length)/1048576),'MB 인덱스') FROM information_schema.tables WHERE table_schema LIKE 'mt\\_n%'")"
echo

QN="SELECT count(*), sum(l.l_extendedprice) FROM lineitem l
      JOIN orders o ON l.l_orderkey=o.o_orderkey
      JOIN customer c ON o.o_custkey=c.c_custkey WHERE c.c_nationkey=$T_ME"
QA="SELECT count(*), sum(l_extendedprice) FROM li_a    WHERE l_nationkey=$T_ME"
QAC="SELECT count(*), sum(l_extendedprice) FROM li_ac  WHERE l_nationkey=$T_ME"
QB="SELECT count(*), sum(l_extendedprice) FROM li_part WHERE l_nationkey=$T_ME"
QC="SELECT count(*), sum(l_extendedprice) FROM mt_n$T_ME.lineitem"

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① 테넌트 범위 조회 ──"
printf "  %-34s %-42s %s\n" "전략" "계획" "min(ms)"
printf "  %s\n" "-------------------------------------------------------------------------------------------"
printf "  %-34s %-42s %s\n" "N  정규화 (2조인)"          "$(plan_of "$QN")"  "$(best "$QN")"
printf "  %-34s %-42s %s\n" "A  비정규화 (보조 인덱스)"  "$(plan_of "$QA")"  "$(best "$QA")"
printf "  %-34s %-42s %s\n" "A′ 테넌트가 PK 선두"        "$(plan_of "$QAC")" "$(best "$QAC")"
printf "  %-34s %-42s %s\n" "B  파티션"                  "$(plan_of "$QB")"  "$(best "$QB")"
printf "  %-34s %-42s %s\n" "C  테넌트별 DB"             "$(plan_of "$QC")"  "$(best "$QC")"
echo
echo "  B 가 파티션 하나만 열었는지:"
q "EXPLAIN FORMAT=TRADITIONAL $QB" | awk '{print "    partitions = "$4}' | head -1
echo
echo "  해석 — **PostgreSQL 판과 순서가 다르다.** 거기서는 N(2조인)이 제일 느렸는데"
echo "  여기서는 N 이 A 를 이긴다. 비정규화를 하고도 더 느려진 것이다."
echo "  이유는 ②에 있다 — A 의 보조 인덱스 조회는 테넌트 행 12만 개를 찾은 뒤 **PK 로"
echo "  클러스터드 인덱스를 12만 번 되찾아간다.** 그 랜덤 접근이 조인 두 번보다 비싸다."
echo "  A′ 처럼 테넌트를 PK 선두에 두면 그제야 비정규화가 값을 한다."
echo "  → '비정규화하면 빨라진다'가 InnoDB 에서는 **PK 를 어떻게 잡느냐에 달려 있다.**"
echo "     PostgreSQL 힙 테이블에서는 나올 수 없는 역전이다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② InnoDB 의 PK 는 클러스터드 인덱스다 — A vs A′ 가 전부다 ──"
echo "  같은 데이터·같은 질문인데 PK 배치만 다르다:"
printf "    A  PK=(l_orderkey,l_linenumber) + KEY(l_nationkey,...)   %6s ms\n" "$(best "$QA")"
printf "    A′ PK=(l_nationkey,l_orderkey,l_linenumber)              %6s ms\n" "$(best "$QAC")"
echo
echo "  A 는 보조 인덱스에서 테넌트 행을 찾은 뒤 **PK 로 클러스터드 인덱스를 다시 찾아간다**"
echo "  (InnoDB 의 보조 인덱스는 행 위치가 아니라 PK 값을 담는다). 테넌트 행이 클러스터드"
echo "  인덱스 전체에 흩어져 있으므로 그 되찾기가 랜덤 접근이 된다."
echo "  A′ 는 테넌트가 PK 선두라 **범위 스캔 한 번**으로 끝난다 — 흩어짐이 원천적으로 없다."
echo
echo "  → tpcds 판 ⑥에서 '풀 모델의 진짜 문제는 CPU 가 아니라 흩어짐'이라고 했고,"
echo "     PostgreSQL 에서는 그 해법이 CLUSTER(일회성, 이후 다시 흐트러짐)였다."
echo "     InnoDB 에서는 PK 설계가 곧 물리 배치라 **그 상태가 유지된다.** 이게 엔진 차이다."
echo
echo "  대가 — 보조 인덱스가 PK 를 담으므로 PK 가 넓어지면 보조 인덱스도 넓어진다:"
myv tpch -e "SELECT table_name AS '테이블',
       ROUND(data_length/1048576) AS '데이터MB', ROUND(index_length/1048576) AS '인덱스MB'
     FROM information_schema.tables WHERE table_schema='tpch' AND table_name IN ('li_a','li_ac');"
echo "  (두 표의 인덱스 개수가 달라 총량을 그대로 비교하면 안 된다 — A 에는 테넌트 보조"
echo "   인덱스가 하나 더 있다. 요점은 A′ 의 k_cust 한 개가 담는 PK 가 12바이트로 넓어졌다는 것이다.)"
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
echo "── ③ RLS 가 없다 — 뷰 + 저장 함수 + 권한으로 흉내낸다 ──"
echo "  먼저 뷰에 세션 변수를 직접 쓸 수 있는지:"
E1=$(qe "CREATE OR REPLACE VIEW v_bad AS SELECT * FROM li_a WHERE l_nationkey = @app_tenant;" | head -1)
echo "    CREATE VIEW ... WHERE l_nationkey = @app_tenant"
echo "    → ${E1:-(성공했다 — 확인 필요)}"
echo
echo "  그래서 저장 함수를 한 겹 끼운다:"
q "CREATE FUNCTION app_tenant() RETURNS INT DETERMINISTIC NO SQL RETURN CAST(@app_tenant AS SIGNED);
   CREATE OR REPLACE VIEW v_li AS SELECT * FROM li_a WHERE l_nationkey = app_tenant();" >/dev/null 2>&1
my -e "CREATE USER IF NOT EXISTS 'mt_app'@'%' IDENTIFIED BY 'x';
       GRANT SELECT ON tpch.v_li TO 'mt_app'@'%';
       GRANT EXECUTE ON FUNCTION tpch.app_tenant TO 'mt_app'@'%';" >/dev/null 2>&1
APPQ() { mysql -h "$MYHOST" -P "$MYPORT" -u mt_app -px -N -B tpch -e "$1" 2>&1 | grep -v '^mysql: \[Warning\]'; }
printf "    앱 계정이 뷰로 본 행수 (tenant=%s): %s\n" "$T_ME" "$(APPQ "SET @app_tenant=$T_ME; SELECT count(*) FROM v_li")"
printf "    앱 계정이 뷰로 본 행수 (tenant=%s): %s\n" "$T_OTHER" "$(APPQ "SET @app_tenant=$T_OTHER; SELECT count(*) FROM v_li")"
printf "    앱 계정이 **원본 테이블** 직접: %s\n" "$(APPQ "SELECT count(*) FROM li_a" | head -1)"
echo
echo "  → 격리가 **뷰가 아니라 권한에서** 나온다는 것이 핵심이다. PostgreSQL 의 RLS 는"
echo "     테이블에 붙어서 누가 어떻게 오든 적용되지만, 여기서는 앱 계정이 원본 테이블에"
echo "     SELECT 권한을 갖는 순간 방어가 통째로 사라진다. 그리고 그 권한은 흔히"
echo "     '마이그레이션 때문에' 또는 '배치 때문에' 주어진다."
echo "  → 또 하나 — 테넌트를 세션 변수로 나르므로 **커넥션 풀에서 이전 값이 남는다.**"
echo "     PostgreSQL 판에서 current_setting 을 쓸 때와 같은 규율이 필요하다(빌릴 때 SET)."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 4; then
echo "── ④ WHERE 누락 유출 ──"
MINE=$(q "SELECT count(*) FROM li_a WHERE l_nationkey=$T_ME")
printf "  내 테넌트 %s 행 / 전체 %s 행\n\n" "$MINE" "$NLI"
printf "  %-30s %12s   %s\n" "전략" "돌아온 행수" "판정"
printf "  %s\n" "---------------------------------------------------------------"
jd() { [ "$1" = "$MINE" ] && echo "격리됨" || echo "**유출**"; }
for pair in "N  정규화|SELECT count(*) FROM lineitem" \
            "A  비정규화|SELECT count(*) FROM li_a" \
            "A′ PK 선두|SELECT count(*) FROM li_ac" \
            "B  파티션|SELECT count(*) FROM li_part" \
            "C  테넌트별 DB|SELECT count(*) FROM mt_n$T_ME.lineitem"; do
  L="${pair%%|*}"; Q="${pair#*|}"; R=$(q "$Q")
  printf "  %-30s %12s   %s\n" "$L" "$R" "$(jd "$R")"
done
V=$(APPQ2() { mysql -h "$MYHOST" -P "$MYPORT" -u mt_app -px -N -B tpch -e "$1" 2>/dev/null; }; APPQ2 "SET @app_tenant=$T_ME; SELECT count(*) FROM v_li")
printf "  %-30s %12s   %s\n" "뷰+권한 (앱 계정)" "${V:-?}" "$(jd "${V:-0}")"
echo
echo "  PostgreSQL 판과 같은 결론이다 — 파티션은 격리가 아니다. 다만 MySQL 에서 격리를 주는"
echo "  것은 '정책'이 아니라 **권한 경계**(뷰만 주기 / DB 를 나누기)뿐이다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 5; then
echo "── ⑤ 파티션 제약 — PostgreSQL 에는 없는 규칙 ──"
echo "  테넌트로 파티션하면서 PK 는 원본대로 두려고 하면:"
E2=$(qe "CREATE TABLE li_bad ($COLS, PRIMARY KEY (l_orderkey, l_linenumber)) ENGINE=InnoDB
         PARTITION BY LIST (l_nationkey) (PARTITION p0 VALUES IN (0));" | head -1)
echo "    PARTITION BY LIST (l_nationkey), PRIMARY KEY (l_orderkey, l_linenumber)"
echo "    → ${E2:-(성공했다 — 확인 필요)}"
q "DROP TABLE IF EXISTS li_bad" >/dev/null 2>&1
echo
echo "  → **파티션 키는 모든 유니크 키에 포함돼야 한다.** 그래서 MySQL 에서 '테넌트로"
echo "     파티션한다'는 결정은 자동으로 '테넌트를 PK 에 넣는다'는 결정이고, InnoDB 에서"
echo "     그것은 곧 ②의 물리 배치 변경이다. 세 결정이 하나로 묶여 있다."
echo "     PostgreSQL 에서는 이 셋이 서로 독립이었다 — 파티션하면서 PK 를 그대로 둘 수 있다."
echo "  → 그래서 이 스크립트의 B 는 A′ 위에만 만들 수 있었다. 선택지가 엔진에 의해 줄었다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 6; then
echo "── ⑥ 테넌트 이동 — PK 를 바꾸는 UPDATE 는 InnoDB 에서 행 이동이다 ──"
CUST=$(q "SELECT o_custkey FROM li_a GROUP BY o_custkey ORDER BY count(*) DESC LIMIT 1")
CN=$(q "SELECT l_nationkey FROM li_a WHERE o_custkey=$CUST LIMIT 1")
CROWS=$(q "SELECT count(*) FROM li_a WHERE o_custkey=$CUST")
echo "  대상: 고객 $CUST (국가 $CN → $T_OTHER), 옮길 lineitem ${CROWS} 행"
echo
# 벽시계로 한 번씩 재면 안 된다 — mysql 클라이언트 연결 비용이 약 25~30ms 라
# 4ms 짜리 작업이 통째로 묻힌다(실제로 그렇게 재서 네 전략이 29~37ms 로 다 같아 보였다).
# EXPLAIN ANALYZE 는 8.0 에서 UPDATE 를 지원하지 않는다(<not executable by iterator executor>).
# 그래서 **한 연결 안에서 N회 반복하고 서버 시각으로 나눈다** — 연결비가 상각된다.
amort_ms() {  # $1 = UPDATE 문, $2 = 반복 횟수 → 회당 ms
  local U="$1" N="$2" f
  f=$(mktemp); { echo "SET @s=NOW(6);"
    for _ in $(seq "$N"); do echo "START TRANSACTION; $U; ROLLBACK;"; done
    echo "SELECT ROUND(TIMESTAMPDIFF(MICROSECOND,@s,NOW(6))/$N/1000,2);"; } > "$f"
  my tpch < "$f" 2>/dev/null | tail -1; rm -f "$f"
}
echo "  (가) 점 이동 — 고객 한 명 (${CROWS}행). 한 연결에서 30회 반복해 회당 시간을 낸다:"
printf "    %-44s %8s ms\n" "N  정규화 — customer 1행만"          "$(amort_ms "UPDATE customer SET c_nationkey=$T_OTHER WHERE c_custkey=$CUST" 30)"
printf "    %-44s %8s ms\n" "A  비정규화 — 보조 인덱스만 갱신"    "$(amort_ms "UPDATE li_a    SET l_nationkey=$T_OTHER WHERE o_custkey=$CUST" 30)"
printf "    %-44s %8s ms\n" "A′ PK 선두 — PK 를 바꾼다"           "$(amort_ms "UPDATE li_ac   SET l_nationkey=$T_OTHER WHERE o_custkey=$CUST" 30)"
printf "    %-44s %8s ms\n" "B  파티션 — 파티션을 넘는다"         "$(amort_ms "UPDATE li_part SET l_nationkey=$T_OTHER WHERE o_custkey=$CUST" 30)"
echo
BULKN=$(q "SELECT count(*) FROM li_a WHERE l_nationkey=$CN")
echo "  (나) 대량 이관 — 국가 $CN 전체(${BULKN}행)를 $T_OTHER 로. 테넌트 통합·이관 시나리오:"
printf "    %-44s %8s ms  (보조 인덱스 %s개)\n" "A  비정규화" \
  "$(amort_ms "UPDATE li_a SET l_nationkey=$T_OTHER WHERE l_nationkey=$CN" 3)" \
  "$(q "SELECT count(DISTINCT index_name)-1 FROM information_schema.statistics WHERE table_schema='tpch' AND table_name='li_a'")"
printf "    %-44s %8s ms  (보조 인덱스 %s개)\n" "A′ PK 선두" \
  "$(amort_ms "UPDATE li_ac SET l_nationkey=$T_OTHER WHERE l_nationkey=$CN" 3)" \
  "$(q "SELECT count(DISTINCT index_name)-1 FROM information_schema.statistics WHERE table_schema='tpch' AND table_name='li_ac'")"
printf "    %-44s %8s ms  (보조 인덱스 %s개)\n" "B  파티션" \
  "$(amort_ms "UPDATE li_part SET l_nationkey=$T_OTHER WHERE l_nationkey=$CN" 3)" \
  "$(q "SELECT count(DISTINCT index_name)-1 FROM information_schema.statistics WHERE table_schema='tpch' AND table_name='li_part'")"
echo
echo "  행이 실제로 파티션을 넘는가:"
q "START TRANSACTION;
   UPDATE li_part SET l_nationkey=$T_OTHER WHERE o_custkey=$CUST;
   SELECT CONCAT('    p$T_OTHER 에 도착한 행: ', count(*)) FROM li_part PARTITION (p$T_OTHER) WHERE o_custkey=$CUST;
   ROLLBACK;"
echo
echo "  해석 — ②에서 A′ 가 이긴 그 결정의 청구서가 여기 있다. 단 **규모에 따라 다르다.**"
echo "   · (가) 점 이동에서는 네 전략이 사실상 같다. 100여 행짜리 작업에서는 PK 를 바꾸든"
echo "     보조 인덱스를 바꾸든 눈에 띄는 차이가 안 난다 — 여기서 과장하면 안 된다."
echo "   · (나) 대량 이관에서 갈린다. A′ 가 A 보다 느린데, **보조 인덱스가 하나 더 적은데도**"
echo "     그렇다는 것이 핵심이다. InnoDB 에서 PK 를 바꾸는 UPDATE 는 제자리 수정이 아니라"
echo "     클러스터드 인덱스에서 지우고 다시 넣는 일이고, 그 행을 가리키던 보조 인덱스"
echo "     엔트리도 새 PK 값으로 고쳐야 한다. 인덱스 수로 설명되지 않는 몫이 그것이다."
echo "   → 조회를 위해 테넌트를 PK 선두에 놓는 결정은 **테넌트가 잘 안 바뀔 때** 옳다."
echo "     tpcds 의 매장이라면 좋은 선택이고, 고객의 국가처럼 움직이는 축이라면"
echo "     ②의 이득(6배)과 (나)의 비용을 워크로드 비율로 저울질해야 한다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
echo "정리:"
if [ "${KEEP:-0}" = "1" ]; then
  echo "  KEEP=1 — 남겨 둔다: li_a / li_ac / li_part / DB mt_n* / 뷰 v_li / 함수 app_tenant / 롤 mt_app"
else
  teardown
  L1=$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='tpch' AND table_name LIKE 'li\\_%'")
  L2=$(q "SELECT count(*) FROM information_schema.schemata WHERE schema_name LIKE 'mt\\_n%'")
  L3=$(q "SELECT count(*) FROM mysql.user WHERE user='mt_app'")
  echo "  실험 객체를 지웠다 (tpch 원본은 건드리지 않았다)."
  echo "  남은 li_* ${L1} / mt_n* DB ${L2} / mt_app 계정 ${L3}   (전부 0 이어야 한다)"
fi
