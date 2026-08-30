#!/usr/bin/env bash
# §T-7 실습 (TPC-DS 판) — 복잡한 SQL 의 세 가지 함정을 **실제로 밟아 본다.**
#
# Dan Tow 7장이 다루는 것은 "느린 쿼리"가 아니라 **틀린 쿼리**다.
# 셋 다 문법 오류가 없고, 셋 다 아무 경고 없이 조용히 다른 답을 내거나 낭비한다.
#
#   ① 아우터 조인의 필터 위치 : ON → WHERE 로 옮기면 LEFT JOIN 이 INNER JOIN 이 된다
#   ② NOT IN 의 NULL 함정      : NULL 한 건이 답을 전부 지운다 + Anti Join 을 못 쓴다
#   ③ UNION vs UNION ALL       : 중복이 없는데도 중복 제거를 시킨다
#
# tpch 판(§T-7 문서의 SQL)과 다른 점: 스타 스키마에서는 팩트가 크고 차원이 작아
# ②의 계획 차이(hashed SubPlan vs Anti Join)가 훨씬 크게 벌어진다.
#
# 사용법:
#   ./t7-complex-sql.sh          # 기본 3회 측정
#   ./t7-complex-sql.sh 5
#   ONLY=2 ./t7-complex-sql.sh      # ②만 실행 (절끼리 독립이다)
#   ONLY=13 ./t7-complex-sql.sh 1   # ①③만, 반복 1회
#   WORK_MEM=512MB ./t7-complex-sql.sh   # work_mem 낮춰 잡기 (기본 4096MB)
#   DIAG=1 ./t7-complex-sql.sh           # 규모 진단만 (측정 없이 work_mem 적정치 확인)
#
# 병렬로 돌려 빠르게 하고 싶을 수 있는데 — 하면 안 된다. 절들을 동시에 실행하면
# 서로 CPU·버퍼를 다투어 **측정값 자체가 오염된다**(§T-0 원칙 ⑥ 계열).
# 빠르게 하려면 병렬이 아니라 ONLY 로 범위를 줄이거나 REPEAT 을 낮춘다.
#
# 선행 조건: tpcds schema → load → index (§0-4)
set -uo pipefail

REPEAT="${1:-3}"
ONLY="${ONLY:-123}"        # 예: ONLY=2 ./t7-complex-sql.sh  → ②만 실행
want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }

# work_mem — ②의 NOT IN 해시와 ③의 HashAggregate 가 디스크로 넘치지 않게 한다.
# 서버 기본값을 고치는 대신 **이 스크립트가 여는 세션에만** 건다(PGOPTIONS).
# 다른 실습의 측정 조건을 건드리지 않기 위해서다.
#
# 주의 1: work_mem 은 세션당이 아니라 **연산 노드당, 그리고 병렬 워커당** 붙는다.
# 정렬·해시 노드가 여럿인 계획을 워커 4개로 돌리면 이 값의 몇 배를 잡을 수 있다.
# 팩트가 크고 RAM 이 작은 장비에서는 낮춰 잡아야 한다:  WORK_MEM=512MB ./t7-complex-sql.sh
#
# 주의 2: **200만 행에서는** 올려도 아무 일도 안 일어난다. ③의 HashAggregate 가
# 64MB 든 4GB 든 똑같이 Batches: 1 / Memory Usage: 28689kB 로 끝나기 때문이다.
# 하지만 그건 이 규모 한정이고, **조금만 커지면 급격히 중요해진다.**
#
# work_mem 을 낮춰 가며 넘치는 지점을 실측했다(200만 행, 같은 ③ 쿼리):
#   64MB → Batches: 1   Memory Usage: 28689kB              347 ms
#   32MB → Batches: 1   Memory Usage: 26641kB              321 ms
#   16MB → Batches: 1   Memory Usage: 25617kB              322 ms
#    8MB → Batches: 5   Memory Usage: 20529kB  Disk 7072kB 511 ms   ← 넘치기 시작
#    4MB → HashAggregate 를 포기하고 Sort+Unique(external merge)로 계획이 바뀐다  375 ms
#
# 즉 ③은 팩트 200만 행당 약 28.7MB 를 쓴다. 기본값 64MB 를 넘기는 지점은 약 457만 행이다.
#
# 주의 3: **그런데 진짜 위험한 것은 ③이 아니라 ②다.** ③의 유출은 2배쯤 느려지는 일이지만,
# ②는 work_mem 이 모자라면 **계획 자체가 무너진다.**
#   work_mem ≥ 32MB → `hashed SubPlan`  : 해시 한 번 만들고 끝    (2M행에서 약 1초)
#   work_mem ≤ 30MB → `SubPlan`         : **바깥 행마다 재실행**  (2M행에서 180초 초과)
# 디스크로 흘리는 게 아니라 재실행이라 비용이 곱셈으로 뛴다. 실측 전환점은
# 서브쿼리 **추정 행수** 기준 약 **17바이트/행** 이다(2,000,091행에서 30MB 부족 / 32MB 충분).
#
#   필요 work_mem ≈ 팩트 추정 행수 × 17B
#     200만 행    →   32MB   (기본 64MB 로 충분)
#     2,880만 행  →  490MB   ← 기본 64MB 로는 7.6배 부족 → SubPlan 으로 붕괴
#     2.88억 행   →  4.9GB   ← **4096MB 로도 부족하다. 6GB 이상으로 잡을 것**
#
# 실제로 2,880만 행에서 이 스크립트가 몇 시간 걸리던 것이 4GB 로 올리자 몇 분에 끝났다.
# 위 표가 그 이유다 — 4GB 가 490MB 요구를 넘겨서 hashed SubPlan 을 되찾은 것이다.
# 규모를 바꿨다면 `DIAG=1 ./t7-complex-sql.sh` 로 먼저 확인할 것.
WORK_MEM="${WORK_MEM:-4096MB}"
export PGOPTIONS="-c work_mem=$WORK_MEM"

PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

if command -v psql >/dev/null 2>&1; then
  sql() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -X -q -tAc "$1"; }
else
  sql() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -X -q -tAc "$1"; }
fi

if ! sql "SELECT 1 FROM store_sales LIMIT 1" >/dev/null 2>&1; then
  echo "  store_sales 가 없습니다. §0-4 의 tpcds 준비 명령을 먼저 실행하세요."
  exit 1
fi

ms_of() { echo "$1" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+'; }

# best_ms 는 실행시간과 **결과 행수를 함께** 얻는다.
# 행수를 따로 SELECT count(*) 로 재면 같은 스캔을 한 번 더 도는 셈인데,
# EXPLAIN (ANALYZE) 의 최상위 노드 actual rows 가 이미 그 값이다.
# (③에서 이 중복이 full scan 4회였다 — 측정과 무관한 순수 낭비였다.)
#
# 주의: 전역 변수에 담아 돌려주면 안 된다. 호출부가 $(best_ms ...) 라 **서브셸**에서
# 실행되므로 대입이 부모에 안 남는다(실제로 그렇게 만들었다가 행수가 빈칸으로 나왔다).
# 그래서 "시간|행수" 한 줄로 돌려주고 호출부에서 자른다.
best_ms2() {
  local Q="$1" b="" v out rows
  sql "EXPLAIN (ANALYZE) $Q" >/dev/null 2>&1          # 워밍업
  for _ in $(seq "$REPEAT"); do
    out=$(sql "EXPLAIN (ANALYZE) $Q")
    v=$(ms_of "$out")
    [ -z "$b" ] && b="$v" || b=$(awk -v a="$b" -v c="$v" 'BEGIN{print (c+0<a+0)?c:a}')
  done
  # 최상위 노드의 actual rows = 결과 행수
  rows=$(echo "$out" | grep -oE 'rows=[0-9]+ loops=' | head -1 | grep -oE '[0-9]+')
  echo "${b}|${rows}"
}
best_ms() { best_ms2 "$1" | cut -d'|' -f1; }
node_of() { sql "EXPLAIN (COSTS OFF) $1" | grep -oE '(Parallel )?(Hash|Nested Loop|Merge) (Right |Left |Anti |Right Anti )?(Join|Anti Join)?' | head -1; }

echo "§T-7 복잡한 SQL 의 함정 — TPC-DS"

# ── 규모 진단 모드 (DIAG=1) ───────────────────────────────────────────
# "지금 넘치는가, 10배 키우면 넘치는가"를 **추정이 아니라 실측으로** 답한다.
#
# 왜 필요한가: work_mem 을 얼마로 잡아야 하는지는 팩트 행수만으로 못 정한다.
# ③이 훑는 것은 팩트 전체가 아니라 **매장 2곳의 몫**인데, 그 비율이 데이터 생성기에
# 따라 다르기 때문이다 — 이 프로젝트 생성기는 store 를 12개로 고정하지만(2곳 = 약 17%),
# 공식 dsdgen 은 스케일과 함께 store 도 늘린다(SF10 = 102개 → 2곳 = 약 2%).
# 같은 팩트 행수라도 해시 크기가 8배 넘게 차이 난다. 그래서 재 봐야 한다.
if [ "${DIAG:-0}" = "1" ]; then
  NST=$(sql "SELECT count(*) FROM store")
  NSS=$(sql "SELECT count(*) FROM store_sales")
  N12=$(sql "SELECT count(*) FROM store_sales WHERE ss_store_sk IN (1,2)")
  PCT=$(sql "SELECT round(100.0*$N12/$NSS,2)")
  echo "── 규모 진단 ──"
  printf "  store_sales %s 행 / store %s 개\n" "$NSS" "$NST"
  printf "  ③ 이 훑는 2개 매장 = %s 행 (%s%%)\n" "$N12" "$PCT"
  printf "  현재 work_mem = %s\n\n" "$(sql "SHOW work_mem")"

  # 세 절의 무거운 쿼리를 각각 한 번씩 돌려 **어디가 넘치는지** 짚는다.
  # 'temp read=/written=' 은 노드 종류를 가리지 않는 디스크 유출 지표다
  # (HashAggregate 는 Disk Usage 도 같이 내지만, hashed SubPlan 은 안 낸다).
  NI_DIAG="SELECT count(*) FROM customer c
           WHERE c.c_customer_sk NOT IN (SELECT ss_customer_sk FROM store_sales)"

  # ── 가장 중요한 점검: ②가 hashed SubPlan 을 받았는가 ──────────────
  # 이건 "디스크로 흘렀다"(느려짐)와 **차원이 다른 문제**다.
  # work_mem 이 모자라면 PostgreSQL 은 hashed SubPlan 을 **아예 포기하고**
  # 평범한 SubPlan 으로 떨어진다 = 바깥 행마다 서브쿼리를 다시 실행한다.
  # 해시를 디스크로 흘리는 게 아니라 **재실행**이라 비용이 곱셈으로 뛴다.
  # 200만 행에서도 1초 → 180초 초과였다. 팩트가 커지면 시간 단위가 된다.
  SP=$(sql "EXPLAIN $NI_DIAG" | grep -oE '(hashed SubPlan|SubPlan)' | head -1)
  echo "  ② NOT IN 의 서브플랜 형태: ${SP:-?}"
  if [ "$SP" = "hashed SubPlan" ]; then
    echo "    ✓ 해시로 한 번에 처리한다 (정상)"
  else
    echo "    ✗ **평범한 SubPlan 이다 — 바깥 행마다 재실행한다.**"
    echo "      work_mem 이 모자라 hashed 를 포기한 것이다. 올리면 즉시 해결된다."
  fi
  # 필요량 = 서브쿼리 **추정 행수** × 약 17바이트 (2,000,091행에서 30MB 부족 / 32MB 충분 실측)
  ERows=$(sql "EXPLAIN SELECT ss_customer_sk FROM store_sales" | grep -oE 'rows=[0-9]+' | head -1 | grep -oE '[0-9]+')
  sql "SELECT '    필요 work_mem ≈ '||pg_size_pretty((${ERows:-0}::bigint*17))||
              '  (추정 행수 '||${ERows:-0}||' × 17B)   10배 규모면 ≈ '||
              pg_size_pretty((${ERows:-0}::bigint*170))"
  echo

  echo "  절별 디스크 유출 점검 (temp = work_mem 을 넘겨 디스크로 흘린 양):"
  diag_one() {  # $1 = 라벨, $2 = 쿼리
    local o t s
    o=$(sql "EXPLAIN (ANALYZE, BUFFERS) $2")
    t=$(echo "$o" | grep -oE 'temp read=[0-9]+ written=[0-9]+' | head -1)
    s=$(echo "$o" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+')
    printf "    %-26s %10s ms   %s\n" "$1" "$s" "${t:-temp 없음 (넘치지 않음)}"
  }
  diag_one "① 아우터 조인" \
    "SELECT count(*) FROM customer c LEFT JOIN store_sales s
       ON c.c_customer_sk = s.ss_customer_sk AND s.ss_net_profit > 0"
  diag_one "② NOT IN" \
    "SELECT count(*) FROM customer c
      WHERE c.c_customer_sk NOT IN (SELECT ss_customer_sk FROM store_sales)"
  diag_one "③ UNION (서로소)" \
    "SELECT ss_item_sk, ss_ticket_number FROM store_sales WHERE ss_store_sk=1
     UNION SELECT ss_item_sk, ss_ticket_number FROM store_sales WHERE ss_store_sk=2"
  echo

  DQ="SELECT ss_item_sk, ss_ticket_number FROM store_sales WHERE ss_store_sk=1
      UNION SELECT ss_item_sk, ss_ticket_number FROM store_sales WHERE ss_store_sk=2"
  DOUT=$(sql "EXPLAIN (ANALYZE) $DQ")
  ST=$(echo "$DOUT" | grep -oE 'Batches: [0-9]+  Memory Usage: [0-9]+kB( +Disk Usage: [0-9]+kB)?' | head -1)
  KB=$(echo "$ST" | grep -oE 'Memory Usage: [0-9]+' | grep -oE '[0-9]+')
  BAT=$(echo "$ST" | grep -oE 'Batches: [0-9]+' | grep -oE '[0-9]+')
  echo "  ③ 의 중복 제거 노드 상세:"
  echo "    ${ST:-(HashAggregate 가 아니라 Sort+Unique 로 계획이 잡혔다 — 이미 넘쳤다는 뜻)}"
  if [ -n "$KB" ]; then
    # 이 노드가 실제로 처리한 행당 비용으로만 외삽한다. 팩트 행수가 아니라
    # **이 노드를 통과한 행수**가 기준이라야 store 수 변화에 속지 않는다.
    echo
    echo "  10배 규모 예측 (store 수가 그대로일 때):"
    sql "SELECT '    필요 메모리 ≈ '||pg_size_pretty(($KB*10)::bigint*1024)||
                '   → 현재 work_mem 으로 '||
                CASE WHEN ($KB*10)::bigint*1024 < pg_size_bytes(current_setting('work_mem'))
                     THEN '충분' ELSE '부족 (올려야 한다)' END"
    echo "    ※ store 수가 함께 늘어나면(공식 dsdgen) 이 값은 그만큼 줄어든다."
    echo "       스케일을 바꾼 뒤에는 DIAG=1 로 다시 재는 것이 정확하다."
    [ "${BAT:-1}" -gt 1 ] && echo "    ※ 지금 이미 Batches>1 이다 — 현재 규모에서 벌써 넘치고 있다."
  fi
  echo
  echo "  (측정은 건너뛴다. 본 실습은 DIAG 없이 실행할 것)"
  exit 0
fi

# ── 규모 경고 ────────────────────────────────────────────────────────
# ②의 NOT IN 은 ss_customer_sk 전량으로 해시를 만든다. 그게 이 실습의 요점이지만
# (그래서 느리다는 것이 결론이다), 팩트가 커지면 work_mem 을 넘겨 디스크로 흘러
# 실행시간이 행수보다 가파르게 는다. 재보기 전에 규모를 알려 준다.
NROWS=$(sql "SELECT count(*) FROM store_sales" | tr -d ' ')
WMEM=$(sql "SHOW work_mem" | tr -d ' ')
printf "store_sales %s 행 / work_mem %s (이 세션만) / 조건당 %s회 측정\n" "$NROWS" "$WMEM" "$REPEAT"
# 문자열로 비교하면 안 된다 — SHOW 는 '4GB' 로 정규화해 돌려주므로 '4096MB' 와 안 맞는다.
# 바이트로 환산해 비교한다.
if [ "$(sql "SELECT pg_size_bytes(current_setting('work_mem')) = pg_size_bytes('$WORK_MEM')")" != "t" ]; then
  printf "  [경고] work_mem 이 요청한 %s 로 안 잡혔다(실제 %s). PGOPTIONS 가 서버에 전달됐는지 확인할 것.\n" \
         "$WORK_MEM" "$WMEM"
fi
if [ "${NROWS:-0}" -gt 20000000 ]; then
  cat <<WARN

  [규모 경고] store_sales 가 2천만 행을 넘는다.
  ②의 NOT IN 은 ss_customer_sk **전량**으로 해시를 만든다 — 이 실습의 요점이
  "NOT IN 은 Anti Join 이 안 돼서 느리다"이므로 그 비용을 실제로 치러야 한다.
  다만 해시가 work_mem(${WMEM}) 을 넘기면 디스크로 흘러 **행수보다 가파르게** 느려진다.
  이 스크립트는 ②를 $((REPEAT + 1))회(워밍업 1 + 측정 ${REPEAT}) 돌린다.

  work_mem 은 이 스크립트가 이미 ${WMEM} 로 잡아 두었다(PGOPTIONS, 이 세션만).
  그래도 넘친다면 EXPLAIN 에 'Batches: N(N>1)' 이나 'Disk' 가 뜬다 — 그때 더 올린다.

  권장:
    ./t7-complex-sql.sh 1                 # 반복을 1회로 (총 2회 실행)
    ONLY=2 ./t7-complex-sql.sh 1          # 느린 절만 따로
    WORK_MEM=512MB ./t7-complex-sql.sh    # RAM 이 부족한 장비면 낮춘다
  ③의 UNION 도 두 매장의 행을 전부 모아 중복 제거하므로 같은 성질을 갖는다.
  ①과 NULL 주입 실험은 규모와 거의 무관하다(아래 참고).

WARN
fi
echo

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① 아우터 조인의 필터 위치: ON 절 vs WHERE 절 ──"
echo "   \"매출이 있으면 이익 나는 건만, 없으면 없는 대로\" 를 뜻하는 질문이다."
echo

A="SELECT count(*) FROM customer c
     LEFT JOIN store_sales s ON c.c_customer_sk = s.ss_customer_sk AND s.ss_net_profit > 0"
B="SELECT count(*) FROM customer c
     LEFT JOIN store_sales s ON c.c_customer_sk = s.ss_customer_sk
    WHERE s.ss_net_profit > 0"

RA=$(sql "$A"); RB=$(sql "$B")
printf "  (a) 필터가 ON 절   결과 %10s 행   계획: %s\n" "$RA" "$(node_of "$A")"
printf "  (b) 필터가 WHERE   결과 %10s 행   계획: %s\n" "$RB" "$(node_of "$B")"
LOST=$(awk -v a="$RA" -v b="$RB" 'BEGIN{print a-b}')
echo
echo "  차이 ${LOST} 행 — 이만큼의 고객이 결과에서 조용히 사라졌다."
echo "  누가 사라졌는지 직접 본다:"
sql "SELECT '  · 매출 자체가 없는 고객: '||count(*) FROM customer c
     WHERE NOT EXISTS (SELECT 1 FROM store_sales s WHERE s.ss_customer_sk=c.c_customer_sk)"
sql "SELECT '  · 매출은 있으나 전부 이익 <= 0 인 고객: '||count(*) FROM customer c
     WHERE EXISTS (SELECT 1 FROM store_sales s WHERE s.ss_customer_sk=c.c_customer_sk)
       AND NOT EXISTS (SELECT 1 FROM store_sales s WHERE s.ss_customer_sk=c.c_customer_sk AND s.ss_net_profit>0)"
echo
echo "  핵심은 시간이 아니라 **계획 노드 이름**이다:"
echo "    (a) Hash Right Join  ← 아우터가 보존됨"
echo "    (b) Hash Join        ← 이너 조인으로 변질됨"
echo "  WHERE 절의 s.ss_net_profit > 0 은 NULL 로 채워진 행을 전부 탈락시킨다."
echo "  옵티마이저는 그것을 알고 아우터 조인 자체를 이너로 되돌린다(join strength reduction)."
echo "  → 에러도 경고도 없다. 행수를 세어 보지 않으면 영원히 모른다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② NOT IN vs NOT EXISTS ──"
echo

NI="SELECT count(*) FROM customer c WHERE c.c_customer_sk NOT IN (SELECT ss_customer_sk FROM store_sales)"
NE="SELECT count(*) FROM customer c WHERE NOT EXISTS (SELECT 1 FROM store_sales s WHERE s.ss_customer_sk = c.c_customer_sk)"

PNI=$(sql "EXPLAIN (COSTS OFF) $NI" | grep -oE '(hashed SubPlan|Anti Join|SubPlan)' | head -1)
PNE=$(sql "EXPLAIN (COSTS OFF) $NE" | grep -oE '(Nested Loop Anti Join|Hash Anti Join|Merge Anti Join)' | head -1)
TNI=$(best_ms "$NI"); TNE=$(best_ms "$NE")
printf "  %-14s %-26s %10s ms\n" "NOT IN"     "${PNI:-?}" "$TNI"
printf "  %-14s %-26s %10s ms\n" "NOT EXISTS" "${PNE:-?}" "$TNE"
printf "  → %sx 차이\n" "$(awk -v a="$TNE" -v b="$TNI" 'BEGIN{printf "%.1f", b/a}')"
echo
echo "  NOT IN 은 Anti Join 으로 변환되지 못한다. 이유는 성능이 아니라 **의미론**이다:"
echo "  서브쿼리에 NULL 이 한 건이라도 있으면 NOT IN 은 전체를 UNKNOWN 으로 만들어야 한다."
echo "  옵티마이저는 컬럼이 nullable 인 이상 그 가능성을 배제할 수 없어 안전한(느린) 길을 택한다."
echo
echo "  실제로 그런지 NULL 을 한 건 넣어 본다:"
# DISTINCT 로 뜬다. NOT IN 은 서브쿼리를 **집합**으로 보므로 중복을 지워도 답이 같고
# (세 결과가 전량 복사본과 일치하는 것을 확인했다), 크기는 팩트 행수가 아니라
# 고객 수로 묶인다 — 200만 행에서 70MB → 2.5MB, 2억 행이면 7GB 를 안 쓰고 끝난다.
sql "SET client_min_messages=warning;
     DROP TABLE IF EXISTS ss_probe;
     CREATE TABLE ss_probe AS SELECT DISTINCT ss_customer_sk FROM store_sales;" >/dev/null 2>&1
NPROBE=$(sql "SELECT count(*) FROM ss_probe")
N0=$(sql "SELECT count(*) FROM customer c WHERE c.c_customer_sk NOT IN (SELECT ss_customer_sk FROM ss_probe)")
sql "INSERT INTO ss_probe VALUES (NULL)" >/dev/null 2>&1
N1=$(sql "SELECT count(*) FROM customer c WHERE c.c_customer_sk NOT IN (SELECT ss_customer_sk FROM ss_probe)")
N2=$(sql "SELECT count(*) FROM customer c WHERE NOT EXISTS (SELECT 1 FROM ss_probe p WHERE p.ss_customer_sk = c.c_customer_sk)")
sql "SET client_min_messages=warning; DROP TABLE IF EXISTS ss_probe;" >/dev/null 2>&1
printf "    NULL 0건  NOT IN     → %s 행\n" "$N0"
printf "    NULL 1건  NOT IN     → %s 행   ← %s개 값 중 단 1건의 NULL 이 답을 지웠다\n" "$N1" "$NPROBE"
printf "    NULL 1건  NOT EXISTS → %s 행   ← 영향 없음\n" "$N2"
echo
echo "  → NOT IN 은 느린 게 문제가 아니라 **틀릴 수 있는 것**이 문제다."
echo "     느린 것은 그 위험을 감수하느라 치르는 대가일 뿐이다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
echo "── ③ UNION vs UNION ALL ──"
echo
echo "   (가) 두 가지가 겹치는 경우 — 답이 다르므로 바꿔 쓰면 안 된다"
O1="SELECT ss_customer_sk FROM store_sales WHERE ss_store_sk=1"
O2="SELECT ss_customer_sk FROM store_sales WHERE ss_store_sk=2"
R=$(best_ms2 "$O1 UNION $O2");     TUO=${R%|*}; UO=${R#*|}
R=$(best_ms2 "$O1 UNION ALL $O2"); TAO=${R%|*}; AO=${R#*|}
printf "     UNION     %10s 행  %9s ms\n" "$UO" "$TUO"
printf "     UNION ALL %10s 행  %9s ms   ← 행수가 다르다\n" "$AO" "$TAO"
echo
echo "   (나) 두 가지가 겹치지 않는 경우 — 답이 같은데 중복 제거만 한다"
D1="SELECT ss_item_sk, ss_ticket_number FROM store_sales WHERE ss_store_sk=1"
D2="SELECT ss_item_sk, ss_ticket_number FROM store_sales WHERE ss_store_sk=2"
R=$(best_ms2 "$D1 UNION $D2");     TUD=${R%|*}; UD=${R#*|}
R=$(best_ms2 "$D1 UNION ALL $D2"); TAD=${R%|*}; AD=${R#*|}
printf "     UNION     %10s 행  %9s ms   (%s)\n" "$UD" "$TUD" "$(sql "EXPLAIN (COSTS OFF) $D1 UNION $D2" | head -1 | sed 's/^ *//')"
printf "     UNION ALL %10s 행  %9s ms   (%s)\n" "$AD" "$TAD" "$(sql "EXPLAIN (COSTS OFF) $D1 UNION ALL $D2" | head -1 | sed 's/^ *//')"
if [ "$UD" = "$AD" ]; then
  printf "     → 행수 동일. 중복 제거는 순수한 낭비이고 그 값이 %sx 다.\n" \
         "$(awk -v a="$TAD" -v b="$TUD" 'BEGIN{printf "%.2f", b/a}')"
fi
echo
echo "  해석:"
echo "    UNION → UNION ALL 은 **무조건 하는 치환이 아니다.** (가)에서는 답이 바뀐다."
echo "    쓸 수 있는 조건은 '분기들이 서로소임을 사람이 알고 있을 때' 뿐이고,"
echo "    옵티마이저는 그것을 알 방법이 없어 (나)에서도 성실하게 HashAggregate 를 돌린다."
echo "    Millsap 12장의 6.5시간 → 10.9초 사례가 정확히 (나) 유형이다 —"
echo "    분기가 서로소인 것을 개발자만 알고 있었고, DB 는 매번 전체를 정렬하고 있었다."
echo
fi
echo "정리: 이 스크립트는 임시 테이블(ss_probe)을 만들고 스스로 지운다. 남는 것은 없다."
