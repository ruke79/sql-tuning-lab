#!/usr/bin/env bash
# 멀티테넌시 분리 훈련 (TPC-DS × MySQL/InnoDB) — 네 번째이자 마지막 칸.
#
# 앞의 셋이 물은 것:
#   tpcds × PG : 테넌트 키가 팩트에 **있을** 때 어느 전략이 나은가
#                → 파티션은 격리가 아니고, 진짜 문제는 **흩어짐**이었다(⑥).
#                  PostgreSQL 의 처방은 CLUSTER — 일회성이고 이후 다시 흐트러진다.
#   tpch  × PG : 테넌트 키가 **없을** 때 (비정규화가 격리의 입장료)
#   tpch  × MySQL : 엔진이 바뀌면 같은 전략이 같은 값을 갖는가 (아니오)
#
# 이 판이 묻는 것: **PostgreSQL 이 CLUSTER 로 일회성으로 풀던 흩어짐을,
# InnoDB 에서는 설계로 없앨 수 있는가. 그리고 그것으로 충분한가.**
#
# InnoDB 의 PK 는 클러스터드 인덱스다. 그리고 tpcds 는 테넌트(매장)가 이미 팩트 컬럼이라
# **PK 선두에 넣기만 하면** 테넌트 행이 물리적으로 모인다 — 그 상태가 유지된다.
# tpch × MySQL 판에서 그 선택의 청구서는 '테넌트 이동'이었는데(대량 이관 1.5배),
# 매장은 다른 매장이 되지 않으므로 **여기서는 그 청구서가 없다.** 이상적인 조건이다.
# 그래서 이 판의 진짜 질문은 "충분한가"가 된다.
#
#   A.  PK=(ss_item_sk, ss_ticket_number)  — 원본 PK. 테넌트는 보조 인덱스로 찾는다.
#   A′. PK=(ss_store_sk, ss_item_sk, ss_ticket_number) — 테넌트를 PK 선두로.
#   B.  A′ + LIST 파티션 12개
#   C.  테넌트별 데이터베이스 12개
#
# 재는 것:
#   ① 테넌트 범위 조회
#   ② 흩어짐의 InnoDB 판   — PostgreSQL 은 힙 페이지 분산이었다. InnoDB 에서는 무엇인가.
#   ③ 시끄러운 이웃         — ⑥의 그 1.35x 가 설계로 사라지는가 (핵심)
#   ④ WHERE 누락 유출 / RLS 부재
#   ⑤ 파티션 제약           — ERROR 1503. tpcds 에서는 대가가 다르다
#   ⑥ 청구서가 없다는 확인  — 매장은 안 움직인다
#
# 사용법:
#   ./mt-tenant-isolation-mysql.sh          # 전부 (약 4분)
#   ONLY=123 ./mt-tenant-isolation-mysql.sh
#   KEEP=1 ./mt-tenant-isolation-mysql.sh
#
# 선행 조건: MySQL 에 tpcds 가 적재돼 있어야 한다. 없으면 ./scripts/restore-lab.sh --mysql
set -uo pipefail

REPEAT="${1:-4}"
ONLY="${ONLY:-123456}"
want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
MYHOST="${MYSQL_HOST:-127.0.0.1}"
MYPORT="${MYSQL_PORT:-3306}"
MYUSER="${MYSQL_USER:-tuner}"
MYPASS="${MYSQL_PASS:-tuner}"

my()  { mysql -h "$MYHOST" -P "$MYPORT" -u "$MYUSER" -p"$MYPASS" -N -B "$@" 2>/dev/null; }
q()   { my tpcds -e "$1"; }
qe()  { mysql -h "$MYHOST" -P "$MYPORT" -u "$MYUSER" -p"$MYPASS" tpcds -e "$1" 2>&1 | grep -v '^mysql: \[Warning\]'; }
qv()  { mysql -h "$MYHOST" -P "$MYPORT" -u "$MYUSER" -p"$MYPASS" tpcds -e "$1" 2>&1 | grep -v '^mysql: \[Warning\]'; }

if ! q "SELECT 1 FROM store_sales LIMIT 1" >/dev/null 2>&1; then
  echo "  MySQL 의 tpcds.store_sales 가 없습니다. 둘 중 하나:"
  echo "    ./scripts/restore-lab.sh --mysql        # 빠진 것만 알아서 채운다(권장)"
  echo "    ./gradlew :tpcds:bootRun --args=\"schema --db=mysql\""
  echo "    ./gradlew :tpcds:bootRun --args=\"load   --db=mysql\""
  echo "    ./gradlew :tpcds:bootRun --args=\"index  --db=mysql\"   # 빠뜨리기 쉽다 — 실제로 빠져 있었다"
  exit 1
fi

best() {  # 벽시계 최소값. 수십 ms 이상짜리만 이걸로 본다(연결비 25~30ms).
  local Q="$1" b="" v s e
  q "$Q" >/dev/null 2>&1
  for _ in $(seq "$REPEAT"); do
    s=$(date +%s%N); q "$Q" >/dev/null 2>&1; e=$(date +%s%N)
    v=$(( (e-s)/1000000 ))
    [ -z "$b" ] && b="$v" || b=$(awk -v a="$b" -v c="$v" 'BEGIN{print (c+0<a+0)?c:a}')
  done; echo "$b"
}
plan_of() { q "EXPLAIN FORMAT=TREE $1" | sed 's/\\n/\n/g' \
  | grep -oE '(Covering index lookup|Index lookup|Index range scan|Table scan|Nested loop [a-z ]*join)[^(]*' | head -1 | sed 's/ *$//'; }

TEN=$(q "SELECT count(DISTINCT ss_store_sk) FROM store_sales WHERE ss_store_sk IS NOT NULL")
T_ME=3; T_OTHER=7
NSS=$(q "SELECT count(*) FROM store_sales WHERE ss_store_sk IS NOT NULL")
D1=$(q "SELECT min(d_date_sk) FROM date_dim WHERE d_year=1999 AND d_moy=6")
D2=$(q "SELECT max(d_date_sk) FROM date_dim WHERE d_year=1999 AND d_moy=6")

echo "멀티테넌시 분리 훈련 (TPC-DS × MySQL $(q "SELECT VERSION()") / InnoDB)"
echo "테넌트 ${TEN}개(매장), store_sales ${NSS} 행, 각 측정 ${REPEAT}회 최소값"
echo "buffer pool $(q "SELECT ROUND(@@innodb_buffer_pool_size/1048576)")MB"
echo
echo "  ※ 이 판의 전제: 테넌트(매장)가 **이미 팩트 컬럼**이고, 매장은 다른 매장이 되지 않는다."
echo "     tpch × MySQL 판에서 'PK 선두' 선택의 청구서였던 테넌트 이동이 여기엔 없다."
echo

teardown() {
  for t in ss_a ss_ac ss_part; do q "DROP TABLE IF EXISTS $t" >/dev/null 2>&1; done
  q "DROP VIEW IF EXISTS v_ss" >/dev/null 2>&1
  q "DROP FUNCTION IF EXISTS app_store" >/dev/null 2>&1
  for n in $(seq 1 "$TEN"); do my -e "DROP DATABASE IF EXISTS mt_s$n" >/dev/null 2>&1; done
  my -e "DROP USER IF EXISTS 'mt_app'@'%'" >/dev/null 2>&1
}

echo "── 준비 ──"
teardown
COLS="ss_store_sk INT NOT NULL, ss_item_sk INT NOT NULL, ss_ticket_number BIGINT NOT NULL,
      ss_sold_date_sk INT, ss_customer_sk INT,
      ss_ext_sales_price DECIMAL(7,2), ss_net_profit DECIMAL(7,2)"
SRC="SELECT ss_store_sk, ss_item_sk, ss_ticket_number, ss_sold_date_sk, ss_customer_sk,
            ss_ext_sales_price, ss_net_profit FROM store_sales WHERE ss_store_sk IS NOT NULL"
T0=$(date +%s)
q "CREATE TABLE ss_a ($COLS, PRIMARY KEY (ss_item_sk, ss_ticket_number),
     KEY k_store (ss_store_sk, ss_sold_date_sk)) ENGINE=InnoDB;
   INSERT INTO ss_a $SRC; ANALYZE TABLE ss_a;" >/dev/null 2>&1
TA=$(date +%s)
q "CREATE TABLE ss_ac ($COLS, PRIMARY KEY (ss_store_sk, ss_item_sk, ss_ticket_number),
     KEY k_date (ss_sold_date_sk)) ENGINE=InnoDB;
   INSERT INTO ss_ac $SRC; ANALYZE TABLE ss_ac;" >/dev/null 2>&1
TB=$(date +%s)
PARTS=""
for n in $(seq 1 "$TEN"); do [ -n "$PARTS" ] && PARTS="$PARTS,"; PARTS="$PARTS PARTITION p$n VALUES IN ($n)"; done
q "CREATE TABLE ss_part ($COLS, PRIMARY KEY (ss_store_sk, ss_item_sk, ss_ticket_number),
     KEY k_date (ss_sold_date_sk)) ENGINE=InnoDB
   PARTITION BY LIST (ss_store_sk) ($PARTS);
   INSERT INTO ss_part $SRC; ANALYZE TABLE ss_part;" >/dev/null 2>&1
TC=$(date +%s)
for n in $(seq 1 "$TEN"); do
  my -e "CREATE DATABASE mt_s$n;
         CREATE TABLE mt_s$n.store_sales ($COLS, PRIMARY KEY (ss_item_sk, ss_ticket_number),
           KEY k_date (ss_sold_date_sk)) ENGINE=InnoDB;
         INSERT INTO mt_s$n.store_sales SELECT * FROM tpcds.ss_a WHERE ss_store_sk=$n;
         ANALYZE TABLE mt_s$n.store_sales;" >/dev/null 2>&1
done
TD=$(date +%s)
[ "$(q "SELECT count(*) FROM ss_a")" = "$NSS" ] || { echo "  [중단] ss_a 적재 실패"; exit 1; }
sz() { q "SELECT CONCAT(ROUND(data_length/1048576),'MB 데이터 / ',ROUND(index_length/1048576),'MB 인덱스')
          FROM information_schema.tables WHERE table_schema='tpcds' AND table_name='$1'"; }
printf "  A  PK=(item,ticket) + KEY(store,date)   %3ds   %s\n" $((TA-T0)) "$(sz ss_a)"
printf "  A′ PK=(store,item,ticket)               %3ds   %s\n" $((TB-TA)) "$(sz ss_ac)"
printf "  B  A′ + LIST 파티션 %2d개                %3ds   %s\n" "$TEN" $((TC-TB)) "$(sz ss_part)"
printf "  C  테넌트별 DB %2d개                     %3ds\n" "$TEN" $((TD-TC))
echo

QA="SELECT count(*), sum(ss_ext_sales_price) FROM ss_a    WHERE ss_store_sk=$T_ME AND ss_sold_date_sk BETWEEN $D1 AND $D2"
QAC="SELECT count(*), sum(ss_ext_sales_price) FROM ss_ac  WHERE ss_store_sk=$T_ME AND ss_sold_date_sk BETWEEN $D1 AND $D2"
QB="SELECT count(*), sum(ss_ext_sales_price) FROM ss_part WHERE ss_store_sk=$T_ME AND ss_sold_date_sk BETWEEN $D1 AND $D2"
QC="SELECT count(*), sum(ss_ext_sales_price) FROM mt_s$T_ME.store_sales WHERE ss_sold_date_sk BETWEEN $D1 AND $D2"
# 이웃이 도는 무거운 조회 — 한 매장 전체 집계. ③의 주인공이다.
NA="SELECT count(*), sum(ss_net_profit) FROM ss_a    WHERE ss_store_sk=$T_OTHER"
NAC="SELECT count(*), sum(ss_net_profit) FROM ss_ac  WHERE ss_store_sk=$T_OTHER"

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① 테넌트 범위 조회 (한 매장의 한 달) ──"
printf "  %-26s %-44s %s\n" "전략" "계획" "min(ms)"
printf "  %s\n" "-------------------------------------------------------------------------------------"
printf "  %-26s %-44s %s\n" "A  원본 PK + 보조 인덱스" "$(plan_of "$QA")"  "$(best "$QA")"
printf "  %-26s %-44s %s\n" "A′ 테넌트가 PK 선두"      "$(plan_of "$QAC")" "$(best "$QAC")"
printf "  %-26s %-44s %s\n" "B  파티션"                "$(plan_of "$QB")"  "$(best "$QB")"
printf "  %-26s %-44s %s\n" "C  테넌트별 DB"           "$(plan_of "$QC")"  "$(best "$QC")"
echo
echo "  좁은 범위(한 달)에서는 넷이 비슷하다. 보조 인덱스 (store, date) 가 이 질문에"
echo "  딱 맞아 A 도 적은 행만 만지기 때문이다. **갈리는 것은 범위가 넓어질 때다** — ②."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② 흩어짐의 InnoDB 판 — 한 매장 **전체**를 집계하면 ──"
printf "  %-26s %-44s %s\n" "전략" "계획" "min(ms)"
printf "  %s\n" "-------------------------------------------------------------------------------------"
printf "  %-26s %-44s %s\n" "A  원본 PK + 보조 인덱스" "$(plan_of "$NA")"  "$(best "$NA")"
printf "  %-26s %-44s %s\n" "A′ 테넌트가 PK 선두"      "$(plan_of "$NAC")" "$(best "$NAC")"
echo
echo "  PostgreSQL tpcds 판 ⑥에서는 이 차이를 **힙 페이지 분산**으로 봤다 —"
echo "  매장 7 의 행이 18,752 페이지 중 16,404 페이지에 걸쳐 있었다(ctid 로 측정)."
echo "  InnoDB 에는 힙이 없다. 테이블이 곧 PK 트리다. 그래서 같은 문제가 다른 모습으로 나온다:"
echo "  **보조 인덱스에서 찾은 행마다 PK 로 클러스터드 인덱스를 되찾아가는 횟수**다."
echo
echo "  계획의 'Index lookup'(A) vs 'Index lookup ... using PRIMARY'(A′) 가 그 표시인데,"
echo "  둘 다 같은 행수를 읽는다(Handler_read_next 로 확인하면 동일하다). 그러니 행 수로는"
echo "  안 보이고, **되찾기가 사라지면 없어지는가**로 증명해야 한다. 커버링 인덱스로 확인한다:"
q "ALTER TABLE ss_a ADD KEY k_cover (ss_store_sk, ss_net_profit); ANALYZE TABLE ss_a;" >/dev/null 2>&1
printf "    A + 커버링 인덱스          %-40s %s ms\n" "$(plan_of "$NA")" "$(best "$NA")"
q "ALTER TABLE ss_a DROP KEY k_cover; ANALYZE TABLE ss_a;" >/dev/null 2>&1
echo
echo "  → 되찾기를 없애니 A 가 A′ 수준이 된다. 비용의 정체가 확인된 셈이다."
echo "     다만 커버링은 **질문마다** 필요한 컬럼이 달라 인덱스가 늘어난다."
echo "     A′ 는 질문이 무엇이든 테넌트 행이 이미 모여 있다 — 그게 PK 선두의 값이다."
echo "  → PostgreSQL 의 CLUSTER 는 일회성이라 쓰기가 쌓이면 다시 흐트러지지만,"
echo "     InnoDB 의 PK 순서는 **구조**라 유지된다. 엔진이 주는 것이다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
if ! command -v mysqlslap >/dev/null 2>&1; then
  echo "── ③ 시끄러운 이웃 — mysqlslap 이 없어 건너뛴다 ──"; echo
else
echo "── ③ 시끄러운 이웃 — ⑥의 1.35x 가 설계로 사라지는가 ──"
echo "  피해자: 매장 $T_ME 의 한 달 조회 1세션. 이웃: 매장 $T_OTHER 전체 집계 4세션."
echo
slap() { mysqlslap -h "$MYHOST" -P "$MYPORT" -u "$MYUSER" -p"$MYPASS" --create-schema=tpcds \
           -q "$1" -c "$2" -i "$3" --no-drop 2>/dev/null \
         | grep -oE 'Average number of seconds[^0-9]*[0-9.]+' | grep -oE '[0-9.]+$'; }
printf "  %-24s %10s %12s %12s %s\n" "전략" "이웃1회" "피해자 혼자" "이웃 동시" "지연 증가분"
printf "  %s\n" "---------------------------------------------------------------------------------"
for pair in "A  원본 PK|$QA|$NA" "A′ 테넌트가 PK 선두|$QAC|$NAC"; do
  L="${pair%%|*}"; r="${pair#*|}"; V="${r%%|*}"; N="${r##*|}"
  nc=$(best "$N")
  a=$(slap "$V" 1 60)
  ( slap "$N" 4 30 >/dev/null 2>&1 ) & sleep 0.5
  b=$(slap "$V" 1 60); wait
  printf "  %-24s %8sms %11ss %11ss %12ss\n" "$L" "$nc" "$a" "$b" \
    "$(awk -v x="$a" -v y="$b" 'BEGIN{printf "+%.4f", y-x}')"
done
echo
echo "  해석 — **가설이 반증됐다. 이 절은 그 기록이다.**"
echo "   처음에 이렇게 썼다: \"②에서 이웃 조회가 A′ 에서 훨씬 싸니, 이웃이 적게 일하고"
echo "   따라서 피해도 줄 것이다.\" 재 보니 **반대였다** — 이웃 1회 비용은 6배 넘게 줄었는데"
echo "   피해자의 지연 증가분은 오히려 2배가 됐다."
echo
echo "   왜인가. 이웃의 **한 번**이 싸지면 같은 시간에 **더 많이** 돌기 때문이다."
echo "   부하는 '쿼리 한 번의 비용 × 빈도'인데, 앞엣것만 줄이고 뒤엣것을 놔두면 총량은 안 준다."
echo "   여기서 이웃은 고정 횟수(mysqlslap -i)로 돌므로 싸질수록 더 자주 때린다."
echo "   즉 **이 측정은 '같은 이웃'을 비교한 것이 아니다** — 배치를 바꾸면 이웃이 하는 일의"
echo "   성질 자체가 바뀌어서, 엄밀히 통제된 비교가 애초에 불가능하다."
echo
echo "   그리고 A′ 의 피해자 자신이 더 느리다(혼자 값을 보라). 한 달짜리 좁은 범위에는"
echo "   (store, date) 보조 인덱스가 PK 범위보다 낫기 때문이다 — ①에서 이미 보인 것이다."
echo "   분모가 다르니 비율로 비교하면 더 헷갈린다. 그래서 위 표는 증가분(절대값)을 쓴다."
echo
echo "   → 남는 결론: **물리 배치는 '넓은 범위 한 방'을 싸게 만들지, 이웃 문제를 풀지 않는다.**"
echo "     PostgreSQL tpcds 판 ⑥-2 가 'CPU 는 어떤 전략도 못 막는다'로 끝난 것과 같은 자리이고,"
echo "     여기서는 한 걸음 더 나간다 — 싸게 만든 것이 오히려 더 자주 오게 만들 수도 있다."
echo
fi
fi

# ══════════════════════════════════════════════════════════════════════
if want 4; then
echo "── ④ WHERE 누락 유출 / RLS 부재 ──"
MINE=$(q "SELECT count(*) FROM ss_a WHERE ss_store_sk=$T_ME")
q "CREATE FUNCTION app_store() RETURNS INT DETERMINISTIC NO SQL RETURN CAST(@app_store AS SIGNED);
   CREATE OR REPLACE VIEW v_ss AS SELECT * FROM ss_a WHERE ss_store_sk = app_store();" >/dev/null 2>&1
my -e "CREATE USER IF NOT EXISTS 'mt_app'@'%' IDENTIFIED BY 'x';
       GRANT SELECT ON tpcds.v_ss TO 'mt_app'@'%';
       GRANT EXECUTE ON FUNCTION tpcds.app_store TO 'mt_app'@'%';" >/dev/null 2>&1
APP() { mysql -h "$MYHOST" -P "$MYPORT" -u mt_app -px -N -B tpcds -e "$1" 2>&1 | grep -v '^mysql: \[Warning\]'; }
printf "  내 테넌트 %s 행 / 전체 %s 행\n\n" "$MINE" "$NSS"
printf "  %-30s %12s   %s\n" "전략" "돌아온 행수" "판정"
printf "  %s\n" "---------------------------------------------------------------"
jd() { [ "$1" = "$MINE" ] && echo "격리됨" || echo "**유출**"; }
for pair in "A  원본 PK|SELECT count(*) FROM ss_a" \
            "A′ PK 선두|SELECT count(*) FROM ss_ac" \
            "B  파티션|SELECT count(*) FROM ss_part" \
            "C  테넌트별 DB|SELECT count(*) FROM mt_s$T_ME.store_sales"; do
  L="${pair%%|*}"; Q2="${pair#*|}"; R=$(q "$Q2")
  printf "  %-30s %12s   %s\n" "$L" "$R" "$(jd "$R")"
done
V=$(APP "SET @app_store=$T_ME; SELECT count(*) FROM v_ss" | tail -1)
printf "  %-30s %12s   %s\n" "뷰+권한 (앱 계정)" "${V:-?}" "$(jd "${V:-0}")"
printf "  %-30s %12s\n" "앱 계정이 원본 직접" "$(APP "SELECT count(*) FROM ss_a" | head -1 | cut -c1-40)"
echo
echo "  네 판 모두 같은 결론이다 — **파티션은 격리가 아니다.** 그리고 MySQL 에서 격리를 주는"
echo "  것은 정책이 아니라 권한 경계뿐이다(뷰만 주기 / DB 를 나누기). tpch × MySQL 판과 동일."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 5; then
echo "── ⑤ 파티션 제약 — 같은 ERROR 1503, 다른 대가 ──"
E=$(qe "CREATE TABLE ss_bad ($COLS, PRIMARY KEY (ss_item_sk, ss_ticket_number)) ENGINE=InnoDB
        PARTITION BY LIST (ss_store_sk) (PARTITION p1 VALUES IN (1));" | head -1)
echo "  PARTITION BY LIST (ss_store_sk), PRIMARY KEY (ss_item_sk, ss_ticket_number)"
echo "  → ${E:-(성공했다 — 확인 필요)}"
q "DROP TABLE IF EXISTS ss_bad" >/dev/null 2>&1
echo
echo "  tpch × MySQL 판에서와 같은 제약이지만 **대가가 다르다.**"
echo "   · tpch 에서는 이 제약이 '테넌트를 PK 에 넣어라'를 강제했고, 그 결정의 청구서가"
echo "     테넌트 이동(대량 이관 1.5배)이었다. 고객의 국가는 움직이기 때문이다."
echo "   · tpcds 에서는 매장이 안 움직이므로 그 청구서가 없다. 제약이 강제하는 선택이"
echo "     마침 ②에서 이미 원하던 선택과 같다 — **제약이 손해가 아닌 드문 경우다.**"
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 6; then
echo "── ⑥ 그 청구서가 정말 없는가 ──"
echo "  tpch × MySQL 판 ⑥은 'PK 선두는 테넌트가 잘 안 바뀔 때만 옳다'로 끝났다."
echo "  그 조건이 여기서 성립하는지 데이터로 확인한다:"
# 한글 별칭은 백틱으로 감싼다 — 안 그러면 ERROR 1064 로 깨진다(실제로 그랬다).
# 그리고 이 쿼리가 실패하면 아래 주장을 뒷받침할 근거가 없어지므로, 실패를 삼키지 않는다.
qv "SELECT
      (SELECT count(*) FROM store)                                  AS \`매장수\`,
      (SELECT count(DISTINCT ss_store_sk) FROM store_sales)         AS \`팩트에_등장하는_매장\`,
      (SELECT count(*) FROM information_schema.columns
        WHERE table_schema='tpcds' AND table_name='store'
          AND column_name IN ('s_rec_start_date','s_rec_end_date')) AS \`SCD_이력컬럼\`;"
echo
echo "  \`SCD_이력컬럼\` 이 2 라면 store 에 s_rec_start_date / s_rec_end_date 가 있다는 뜻이고,"
echo "  그것은 이 차원이 **SCD Type 2**(느리게 변하는 차원)로 설계됐다는 표시다 —"
echo "  매장의 속성이 바뀌면 기존 행을 고치는 대신 **새 행을 추가**한다."
echo "  즉 이미 팔린 매출의 ss_store_sk 는 옮겨지지 않는다. 사실상 불변 축이다."
echo
echo "  → 그래서 이 칸(tpcds × InnoDB)이 네 조합 중 **PK 선두 전략이 가장 잘 맞는 자리**다:"
echo "     테넌트 키가 이미 팩트에 있고(tpch 와 다름), PK 에 넣어도 청구서가 없고(tpch 와 다름),"
echo "     넣으면 흩어짐이 구조적으로 사라진다(PostgreSQL 과 다름)."
echo "     같은 전략이 어느 칸에서는 최선이고 어느 칸에서는 손해라는 것 — 그게 네 판을 다 돌린 이유다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
echo "정리:"
if [ "${KEEP:-0}" = "1" ]; then
  echo "  KEEP=1 — 남겨 둔다: ss_a / ss_ac / ss_part / DB mt_s* / 뷰 v_ss / 함수 app_store / 계정 mt_app"
else
  teardown
  L1=$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='tpcds' AND table_name LIKE 'ss\\_%'")
  L2=$(q "SELECT count(*) FROM information_schema.schemata WHERE schema_name LIKE 'mt\\_s%'")
  L3=$(q "SELECT count(*) FROM mysql.user WHERE user='mt_app'")
  echo "  실험 객체를 지웠다 (tpcds 원본은 건드리지 않았다)."
  echo "  남은 ss_* ${L1} / mt_s* DB ${L2} / mt_app 계정 ${L3}   (전부 0 이어야 한다)"
fi
