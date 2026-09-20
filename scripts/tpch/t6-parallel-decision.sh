#!/usr/bin/env bash
# §T-6 확장: **옵티마이저가 병렬을 고르는 / 못 고르는 지점**
#
# Dan Tow 6장은 "어느 테이블로 들어가느냐(구동 테이블)가 계획을 결정한다"고 한다.
# 2003년의 그 규칙이 병렬 실행에도 그대로 적용된다 — 다만 축이 하나 더 붙는다.
# 이 실습은 세 가지를 잰다. 셋 다 "행을 더 읽어서" 느린 게 아니라
# **프로세스를 어떻게 나눌지 판정하는 데서** 느려진 경우다.
#
#   ① q13 — 병렬 경로는 존재한다. 거절한 것은 비용이다.
#            범인은 parallel_tuple_cost 하나다(나머지 손잡이로는 안 뒤집힌다).
#   ② q05 — lineitem 을 만지는데 워커가 1개다.
#            워커 수를 정한 건 제일 큰 테이블이 아니라 **구동 스캔**이다.
#   ③ q18 — 하위 집계가 프로세스마다 **통째로 재실행**된다(loops=N).
#            병렬이 붙었는데도 일이 N배가 된다.
#   ④ 그래서 work_mem 이 답이 아닌 이유 — 그룹당 바이트를 재서 환산한다.
#   ⑤ 처방: 하위 집계를 한 번만 계산하면 어떻게 되는가.
#
# 왜 이게 한 스크립트인가: 셋 다 "병렬도는 계획이 정한다"의 서로 다른 얼굴이다.
# ①은 Gather 를 통과하는 **행 수**가, ②는 **구동 테이블 크기**가, ③은 노드가
# 병렬 구역 안의 **비병렬 쪽**에 놓였는가가 정한다. 행 수·인덱스로는 셋 다 안 보인다.
#
# 사용법:
#   ./t6-parallel-decision.sh              # 전부 (SF=0.5 에서 약 20초, SF=10 이면 수 분)
#   ONLY=13 ./t6-parallel-decision.sh      # ①③만
#   ROUNDS=5 ./t6-parallel-decision.sh     # 측정 반복 횟수(기본 3, 최소값을 쓴다)
#   WORK_MEM=512MB ./t6-parallel-decision.sh
#
# 규모가 클수록 ①③의 격차가 벌어진다. SF=0.5 는 **방향만** 보이는 규모이므로,
# 각 절이 그 판정에 쓴 지표(Gather 통과 행 수 / 구동 테이블 크기 / loops)를
# 같이 찍는다 — 수치가 작아도 그 지표로 자기 환경을 판정할 수 있게 하기 위해서다.
#
# 선행 조건: tpch 적재 + ANALYZE. 인덱스 유무는 이 실습의 결론을 바꾸지 않는다
# (셋 다 풀스캔 경로의 병렬도 문제다).
set -uo pipefail

ROUNDS="${ROUNDS:-3}"
ONLY="${ONLY:-12345}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"
WORK_MEM="${WORK_MEM:-4096MB}"
export PGOPTIONS="-c work_mem=$WORK_MEM"

want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }

HERE="$(cd "$(dirname "$0")" && pwd)"
QDIR=""
for CAND in "$HERE/../../tpch/src/main/resources/queries" "./tpch/src/main/resources/queries"; do
  [ -d "$CAND" ] && QDIR="$CAND" && break
done
if [ -z "$QDIR" ]; then echo "queries 디렉터리를 찾을 수 없습니다."; exit 1; fi
qfile() { grep -v '^\s*--' "$QDIR/$1.sql" | sed 's/;\s*$//' | tr '\n' ' '; }
Q13=$(qfile q13); Q05=$(qfile q05); Q18=$(qfile q18)

if command -v psql >/dev/null 2>&1 &&
   PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -tAc "SELECT 1" >/dev/null 2>&1; then
  run_sql() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q -tAc "$1" 2>&1; }
  psql_in()  { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -X -q -tA 2>&1; }
elif command -v docker >/dev/null 2>&1 &&
     docker exec -e PGPASSWORD=tuner "$CONTAINER" psql -U tuner -d tpch -X -tAc "SELECT 1" >/dev/null 2>&1; then
  run_sql() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -X -q -tAc "$1" 2>&1; }
  psql_in()  { docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpch -X -q -tA 2>&1; }
else
  echo "PostgreSQL(tpch) 에 붙지 못했습니다. 서버가 떠 있는지 확인하세요:"
  echo "  docker compose -f docker/docker-compose.yml up -d postgres"
  echo "  (호스트 설치판이면) ./scripts/restore-lab.sh"
  exit 1
fi

# 사전 점검 — 빈 DB 에서 "차이 없음"을 결과로 적지 않기 위해서다(정정 8번).
NLI=$(run_sql "SELECT count(*) FROM lineitem" | tr -d ' ')
case "$NLI" in ''|*[!0-9]*) echo "lineitem 을 읽지 못했습니다: $NLI"; exit 1;; esac
if [ "$NLI" -lt 100000 ]; then
  echo "  [중단] lineitem 이 ${NLI}행뿐입니다. 먼저 적재하세요:"
  echo "         ./gradlew :tpch:bootRun --args=\"load --db=postgres\""
  exit 1
fi

# 측정: 서버가 보고한 Execution Time 의 N회 최소값.
# psql 호출마다 새 연결이라 SET 이 다음 측정으로 새지 않는다 — RESET ALL 이 필요 없는 구조다.
one() { run_sql "$1 EXPLAIN (ANALYZE, TIMING OFF) $2" | grep -oE "Execution Time: [0-9.]+" | grep -oE "[0-9.]+"; }
best() {
  local b="" t
  for _ in $(seq 1 "$ROUNDS"); do
    t=$(one "$1" "$2")
    case "$t" in ''|*[!0-9.]*) continue;; esac
    [ -z "$b" ] && b="$t"
    awk -v a="$t" -v c="$b" 'BEGIN{exit !(a<c)}' && b="$t"
  done
  echo "${b:-?}"
}
# printf 의 %-Ns 는 글자 수로 세지만 터미널은 한글을 두 칸으로 그린다 — 표가 어긋난다.
# 한글이 섞인 라벨은 표시 폭을 직접 계산해 채운다.
# 로케일이 UTF-8 이 아니면 ${#s} 도 printf 의 %-Ns 도 **바이트**를 센다(이 랩 컨테이너가 그렇다).
# 그래서 로케일에 기대지 않고 바이트만으로 표시 폭을 구한다:
#   한글 1자 = 3바이트(선두 1 + 이어지는 2) = 화면 2칸  →  폭 = 바이트수 − 이어지는바이트수/2
dispw() { local b k; b=$(printf %s "$1" | wc -c); k=$(printf %s "$1" | LC_ALL=C tr -dc '\200-\277' | wc -c)
          echo $(( b - k / 2 )); }
padr()  { local n; n=$(dispw "$1"); printf "%s" "$1"; while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; }
padl()  { local n; n=$(dispw "$1"); while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; printf "%s" "$1"; }

plan()    { run_sql "$1 EXPLAIN $2"; }
workers() { plan "$1" "$2" | grep -oE "Workers Planned: [0-9]+" | grep -oE "[0-9]+" | head -1; }
topcost() { plan "$1" "$2" | grep -oE "cost=[0-9.]+\.\.[0-9.]+" | head -1 | sed 's/.*\.\.//'; }

SB=$(run_sql "SHOW shared_buffers"); HM=$(run_sql "SHOW hash_mem_multiplier")
echo "§T-6 확장 — 옵티마이저가 병렬을 고르는 / 못 고르는 지점"
echo "  lineitem ${NLI}행 / work_mem=$WORK_MEM / shared_buffers=$SB / ${ROUNDS}회 최소값"
echo

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① q13 — 병렬 경로는 존재한다. 거절한 것은 비용이다 ──"
echo
printf "  %s%s %12s\n" "$(padr 설정 38)" "$(padl 워커 8)" "총비용"
printf "  %s\n" "------------------------------------------------------------"
for pair in "기본|" \
            "parallel_setup_cost=0|SET parallel_setup_cost=0;" \
            "min_parallel_table_scan_size=0|SET min_parallel_table_scan_size=0;" \
            "parallel_tuple_cost=0|SET parallel_tuple_cost=0;"; do
  L="${pair%%|*}"; S="${pair#*|}"
  W=$(workers "$S" "$Q13")
  printf "  %s%s %12s\n" "$(padr "$L" 38)" "$(padl "${W:-직렬}" 8)" "$(topcost "$S" "$Q13")"
done
echo
echo "  손잡이를 **하나씩** 켰다. 한꺼번에 켜면 어느 것이 범인인지 알 수 없다(§T-2 심화 1)."
echo "  setup_cost 도 테이블 크기 하한도 아니다 — parallel_tuple_cost 단독으로 뒤집힌다."
echo
# 왜 tuple_cost 인가: 부분 집계가 줄여 주지 못하는 그룹 수가 그대로 Gather 를 통과한다.
NCUST=$(run_sql "SELECT count(*) FROM customer" | tr -d ' ')
GW=$(workers "SET parallel_tuple_cost=0;" "$Q13")
SERIAL_COST=$(topcost "" "$Q13")
echo "  왜 tuple_cost 인가 —"
echo "    c_custkey 그룹이 ${NCUST}개다. 고객이 워커 청크에 흩어져 있어 부분 집계가 줄여 주지 못하므로,"
echo "    워커마다 **전체 그룹**을 만들어 Gather 로 올린다: ${NCUST} × ${GW:-4} ≈ $(awk -v a="$NCUST" -v b="${GW:-4}" 'BEGIN{printf "%d", a*b}')행."
echo "    기본 parallel_tuple_cost=0.1 이면 그것만 $(awk -v a="$NCUST" -v b="${GW:-4}" 'BEGIN{printf "%.0f", a*b*0.1}') — 직렬 계획 전체(${SERIAL_COST})와 맞먹는다."
echo "    **그룹 수는 규모에 비례하므로, 데이터를 더 넣어도 저절로 병렬이 되지 않는다.**"
echo
S1=$(best "" "$Q13"); P1=$(best "SET parallel_tuple_cost=0;" "$Q13")
printf "  %s%10s ms\n" "$(padr "기본 (직렬)" 38)" "$S1"
printf "  %s%10s ms\n" "$(padr "parallel_tuple_cost=0 (병렬)" 38)" "$P1"
awk -v s="$S1" -v p="$P1" 'BEGIN{ if (s+0>0 && p+0>0) printf "  → 병렬이 %.2f배 빠르다. 플래너의 판정이 틀렸다.\n", s/p }'
echo
echo "  운영에서 parallel_tuple_cost 를 전역으로 낮추는 건 위험하다(모든 쿼리의 판정이 움직인다)."
echo "  이런 모양(고카디널리티 GROUP BY)을 만났을 때 **세션 단위로** 낮추는 것이 안전한 쓰임이다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② q05 — lineitem 을 만지는데 워커 수를 정한 건 구동 스캔이다 ──"
echo
BASEW=$(workers "" "$Q05")
echo "  기본 워커 수: ${BASEW:-직렬}"
echo
# 짐작하지 않는다. 계획에 나오는 병렬 스캔 대상마다 parallel_workers 를 박아 보고,
# **어느 테이블이 전체 병렬도를 움직이는지** 실제로 확인한다.
CANDS=$(plan "" "$Q05" | grep -oE "Parallel Seq Scan on [a-z_]+" | awk '{print $NF}' | sort -u)
printf "  %s%s %s %s\n" "$(padr 테이블 14)" "$(padl 크기 10)" "$(padl 자체워커 10)" "$(padl "이걸 4로 박으면" 16)"
printf "  %s\n" "----------------------------------------------------------"
DRIVER=""
for t in $CANDS; do
  SZ=$(run_sql "SELECT pg_size_pretty(pg_relation_size('$t'))")
  # PostgreSQL 의 규칙: 8MB→1, 24MB→2, 72MB→3 … (min_parallel_table_scan_size × 3^n)
  # min_parallel_table_scan_size 는 '8MB' 같은 문자열로 돌아온다 — pg_size_bytes 로 바꿔야 한다.
  OWN=$(run_sql "SELECT count(*) FROM generate_series(0,9) g
                  WHERE pg_relation_size('$t')
                        >= pg_size_bytes(current_setting('min_parallel_table_scan_size')) * power(3,g)")
  run_sql "ALTER TABLE $t SET (parallel_workers=4)" >/dev/null
  NW=$(workers "" "$Q05")
  run_sql "ALTER TABLE $t RESET (parallel_workers)" >/dev/null
  MARK=""
  if [ -n "$NW" ] && [ -n "$BASEW" ] && [ "$NW" -gt "$BASEW" ]; then MARK="  ← 구동"; DRIVER="$t"; fi
  printf "  %s%s %s %s%s\n" "$(padr "$t" 14)" "$(padl "$SZ" 10)" "$(padl "${OWN:-?}" 10)" "$(padl "${NW:-직렬}" 16)" "$MARK"
done
echo
if [ -n "$DRIVER" ]; then
  B2=$(best "" "$Q05")
  run_sql "ALTER TABLE $DRIVER SET (parallel_workers=4)" >/dev/null
  A2=$(best "" "$Q05")
  run_sql "ALTER TABLE $DRIVER RESET (parallel_workers)" >/dev/null
  printf "  %s워커 %-3s %10s ms\n" "$(padr "기본" 38)" "${BASEW:-0}" "$B2"
  printf "  %s워커 %-3s %10s ms\n" "$(padr "$DRIVER 에 parallel_workers=4" 38)" "4" "$A2"
  awk -v s="$B2" -v p="$A2" 'BEGIN{ if (s+0>0 && p+0>0) printf "  → %.2f배\n", s/p }'
  echo
  echo "  해시 조인의 병렬도는 **구동(바깥) 경로에서 상속**된다. 그래서 조인 트리에 lineitem 이"
  echo "  들어 있어도, 맨 바깥 스캔이 작은 테이블이면 그 크기가 전체 병렬도의 상한이 된다."
  echo "  ${DRIVER} 하나에 박은 값이 계획 전체를 움직인 것이 그 증거다."
  echo "  → Tow 6장의 '어느 테이블로 들어가는가'가 병렬 시대에는 '몇 명이 들어가는가'까지 정한다."
else
  echo "  이 환경에서는 어느 테이블을 바꿔도 병렬도가 안 움직였다."
  echo "  (이미 최대치이거나 max_parallel_workers_per_gather 에 걸린 경우다. 아래를 확인:"
  echo "   max_parallel_workers_per_gather=$(run_sql 'SHOW max_parallel_workers_per_gather'))"
fi
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
echo "── ③ q18 — 하위 집계가 프로세스마다 통째로 재실행된다 ──"
echo
P18=$(run_sql "EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) $Q18")
SUBLINE=$(echo "$P18" | grep -E "Seq Scan on lineitem lineitem_1" | head -1)
[ -z "$SUBLINE" ] && SUBLINE=$(echo "$P18" | grep -E "  Seq Scan on lineitem" | grep -v Parallel | head -1)
LOOPS=$(echo "$SUBLINE" | grep -oE "loops=[0-9]+" | grep -oE "[0-9]+")
SROWS=$(echo "$SUBLINE" | grep -oE "rows=[0-9]+" | tail -1 | grep -oE "[0-9]+")
echo "  하위 집계(`o_orderkey IN (... GROUP BY l_orderkey HAVING ...)`)의 스캔 노드:"
echo "    ${SUBLINE:-(찾지 못했다 — 계획 모양이 다르다)}" | sed 's/^ *//;s/^/    /'
echo
if [ -n "$LOOPS" ] && [ "$LOOPS" -gt 1 ]; then
  echo "  **Parallel Seq Scan 이 아니고 loops=${LOOPS} 다.**"
  echo "  리더와 워커가 각각 ${SROWS}행을 통째로 훑고 각자 해시 집계를 만든다 —"
  echo "  총 $(awk -v a="${SROWS:-0}" -v b="$LOOPS" 'BEGIN{printf "%d", a*b}')행. 병렬이 붙었는데 일이 ${LOOPS}배가 됐다."
else
  echo "  (이 환경에서는 loops=1 이다 — 계획이 달라 중복이 없다. 아래 ④는 그래도 유효하다.)"
fi
echo
echo "$P18" | grep -E "Batches: [0-9]+|Disk Usage|temp read=" | sed 's/^ *//;s/^/    /' | sort -u | head -5
echo
echo "  왜 병렬이 안 되나 — GROUP BY l_orderkey 는 **감소율이 거의 없다**:"
NGRP=$(run_sql "SELECT count(DISTINCT l_orderkey) FROM lineitem" | tr -d ' ')
awk -v r="$NLI" -v g="$NGRP" 'BEGIN{printf "    %d행 → %d그룹 (%.1f:1)\n", r, g, r/g}'
echo "    부분 집계를 해도 줄어드는 게 없으니 Gather 로 올릴 이득이 없고(①과 같은 산수),"
echo "    그래서 이 노드는 병렬 구역 안의 **비병렬 해시 쪽**에 놓여 프로세스마다 재실행된다."
echo "    → 인덱스로도 work_mem 으로도 안 보이는 비용이다. loops 로만 보인다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 4; then
echo "── ④ 그래서 work_mem 이 이번엔 답이 아니다 — 그룹당 바이트를 잰다 ──"
echo
SUBQ="SELECT l_orderkey FROM lineitem GROUP BY l_orderkey HAVING sum(l_quantity) > 300"
MEMKB=$(run_sql "SET max_parallel_workers_per_gather=0;
                 EXPLAIN (ANALYZE, TIMING OFF) $SUBQ" \
        | grep -oE "Memory Usage: [0-9]+kB" | grep -oE "[0-9]+" | head -1)
NGRP=${NGRP:-$(run_sql "SELECT count(DISTINCT l_orderkey) FROM lineitem" | tr -d ' ')}
BPG=$(awk -v m="${MEMKB:-0}" -v g="$NGRP" 'BEGIN{ if(g>0) printf "%.0f", m*1024/g }')
RATIO=$(awk -v r="$NLI" -v g="$NGRP" 'BEGIN{printf "%.2f", r/g}')
echo "  실측: ${NGRP}그룹에 ${MEMKB}kB → **그룹당 ${BPG} 바이트**"
echo "        (numeric 합계 + 해시 엔트리 오버헤드. 키 8바이트만 생각하면 크게 틀린다.)"
echo
echo "  해시 집계가 쓸 수 있는 메모리는 work_mem × hash_mem_multiplier(=$HM) 다."
echo "  지금 설정이면 프로세스당 $(run_sql "SELECT pg_size_pretty((pg_size_bytes('$WORK_MEM')*$HM)::bigint)") 까지."
echo
printf "  %14s %14s %14s %16s\n" "lineitem 행수" "그룹 수" "프로세스당" "×프로세스 수"
printf "  %s\n" "--------------------------------------------------------------------"
for mult in 1 2 10 20; do
  awk -v n="$NLI" -v m="$mult" -v ratio="$RATIO" -v bpg="$BPG" -v lp="${LOOPS:-5}" 'BEGIN{
    rows=n*m; grp=rows/ratio; per=grp*bpg;
    printf "  %14d %14d %11.2f GB %13.2f GB\n", rows, grp, per/1073741824, per*lp/1073741824
  }'
done
echo
echo "  ③에서 본 대로 이 집계는 **프로세스마다** 만들어지므로 오른쪽 열이 실제 요구량이다."
echo "  work_mem 을 올려서 맞추는 건 어느 지점부터 불가능해진다 — t7-complex-sql.sh 에서"
echo "  4GB 가 몇 시간을 몇 분으로 바꾼 것과는 **성격이 다른 병**이다."
echo "  거기서는 한 노드가 한 번 넘친 거였고, 여기서는 같은 일을 N번 하는 것이다."
echo "  → 고칠 것은 메모리가 아니라 **중복**이다(⑤)."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 5; then
echo "── ⑤ 처방: 하위 집계를 한 번만 계산한다 ──"
echo
Q18R="select c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice, sum(l_quantity) as total_qty
      from customer, orders, lineitem
      where o_orderkey in (select l_orderkey from big_orders)
        and c_custkey = o_custkey and o_orderkey = l_orderkey
      group by c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice
      order by o_totalprice desc, o_orderdate limit 100"
B18=$(best "" "$Q18")
# 임시 테이블은 세션에 매여 있으므로 **한 연결 안에서** 만들고 재야 한다.
# 준비 단계도 실제로 돌아갈 설정 그대로 잰다(④의 직렬 강제를 여기 끌고 오면 안 된다).
# ANALYZE 도 반드시 한다 — 통계 없는 임시 테이블은 플래너가 기본값으로 때려 맞춘다(§T-1).
OUT=$(psql_in <<EOF
\\echo ---PREP---
EXPLAIN (ANALYZE, TIMING OFF) CREATE TEMP TABLE big_orders AS
  SELECT l_orderkey FROM lineitem GROUP BY l_orderkey HAVING sum(l_quantity) > 300;
DROP TABLE big_orders;
\\echo ---PREP2---
SET parallel_tuple_cost=0;
EXPLAIN (ANALYZE, TIMING OFF) CREATE TEMP TABLE big_orders AS
  SELECT l_orderkey FROM lineitem GROUP BY l_orderkey HAVING sum(l_quantity) > 300;
RESET parallel_tuple_cost;
ANALYZE big_orders;
\\echo ---NBIG---
SELECT count(*) FROM big_orders;
\\echo ---PLAN---
EXPLAIN (COSTS OFF) $Q18R;
\\echo ---MAIN---
$(for _ in $(seq 1 "$ROUNDS"); do echo "EXPLAIN (ANALYZE, TIMING OFF) $Q18R;"; done)
EOF
)
sec() { echo "$OUT" | sed -n "/---$1---/,/---$2---/p"; }
PREP=$(sec PREP PREP2 | grep -oE "Execution Time: [0-9.]+" | grep -oE "[0-9.]+" | head -1)
PREP2=$(sec PREP2 NBIG | grep -oE "Execution Time: [0-9.]+" | grep -oE "[0-9.]+" | head -1)
NBIG=$(sec NBIG PLAN | grep -oE "^[0-9]+$" | head -1)
A18=$(echo "$OUT" | sed -n '/---MAIN---/,$p' | grep -oE "Execution Time: [0-9.]+" | grep -oE "[0-9.]+" \
      | sort -g | head -1)
printf "  %s%10s ms\n" "$(padr "원본 q18 (하위 집계 ${LOOPS:-N}중 실행)" 46)" "$B18"
printf "  %s%10s ms\n" "$(padr "  하위 집계를 한 번만 (임시 테이블 ${NBIG:-?}행)" 46)" "${PREP:-?}"
printf "  %s%10s ms\n" "$(padr "  같은 것 + parallel_tuple_cost=0 (①)" 46)" "${PREP2:-?}"
printf "  %s%10s ms\n" "$(padr "  + 그걸 조인하는 본 쿼리" 46)" "${A18:-?}"
sumline() { printf "  %s%10.1f ms  (%s배)\n" "$(padr "$1" 46)" "$2" \
              "$(awk -v b="$B18" -v t="$2" 'BEGIN{printf "%.2f", b/t}')"; }
T1=$(awk -v p="${PREP:-0}" -v a="${A18:-0}" 'BEGIN{printf "%.1f", p+a}')
T2=$(awk -v q="${PREP2:-0}" -v a="${A18:-0}" 'BEGIN{printf "%.1f", q+a}')
sumline "합계" "$T1"
sumline "합계 (①의 손잡이까지 쓰면)" "$T2"
echo
echo "  ①과 ③이 만나는 자리다 — 떼어 낸 하위 집계도 고카디널리티 GROUP BY 라서"
echo "  그대로 두면 **직렬로** 돈다. 즉 ③의 처방이 남긴 비용은 ①의 그 문제다."
echo
# 본 쿼리가 눈에 띄게 싸졌다면 그건 단순히 중복이 사라져서가 아니다 —
# 계획 자체가 바뀌었을 수 있으므로 반드시 같이 보여 준다(수치만 적으면 오해한다).
echo "  바뀐 본 쿼리의 계획:"
sec PLAN MAIN | grep -E "Scan|Join|Nested|Gather|Aggregate" | sed 's/^ *//;s/^/    /' | head -10
echo
echo "  해석 — 이득은 두 갈래로 온다."
echo "   (가) 중복이 사라진다 — ③의 loops 배수만큼. 넘치는 규모에서는 이게 지배적이다."
echo "   (나) **계획이 바뀐다** — 하위 집계 결과가 테이블이 되면 옵티마이저가 그 행수를 안다."
echo "        ${NBIG:-?}행뿐이라는 걸 알면 lineitem 을 훑는 대신 인덱스로 찔러 들어갈 수 있다."
echo "        위 계획에 Index Scan / Nested Loop 가 보이면 (나)가 일어난 것이다."
echo "        추정치로 때려 맞추던 서브쿼리가 실측치가 된 것 — §T-1 의 '통계가 인덱스보다'와 같은 자리다."
echo
echo "   주의: 하위 집계가 메모리에 들어가는 규모라면 (가)는 작다 — 여기서도 그렇다."
echo "   **중복은 넘치기 전까지 병렬에 가려진다.** N개가 동시에 하니 벽시계로는 1배처럼 보인다."
echo "   넘치는 순간 N개가 디스크 대역폭을 나눠 쓰면서 한꺼번에 드러난다(그래서 계단처럼 뛴다)."
echo "   ③의 Batches/Disk Usage 와 ④의 표로 **자기 규모가 어느 구간인지** 먼저 판정할 것."
echo "   그리고 임시 테이블은 세션에 매인다 — 반복 조회라면 실제 파생 테이블(§T-9)의 문제가 된다."
echo
fi

echo "정리: 세 경우 모두 '행을 더 읽어서' 느린 게 아니었다."
echo "  ① Gather 를 통과하는 행 수가 병렬을 비싸게 만들었고(고카디널리티 GROUP BY),"
echo "  ② 구동 스캔의 크기가 조인 트리 전체의 병렬도를 정했고,"
echo "  ③ 비병렬 노드가 병렬 구역에 놓여 일이 프로세스 수만큼 늘었다."
echo "  EXPLAIN 에서 볼 자리: Workers Planned / Parallel 접두사 / loops= / Batches."
echo
# ②가 ALTER TABLE 로 테이블 옵션을 건드렸다. 되돌렸는지 확인한다 —
# 남으면 다른 실습의 병렬도가 조용히 바뀌어 원인 모를 수치 차이가 된다(정정 8번의 교훈).
LEFT=$(run_sql "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                 WHERE n.nspname='public' AND array_to_string(c.reloptions,',') LIKE '%parallel_workers%'")
echo "  남은 parallel_workers 설정: ${LEFT:-?}   (0 이어야 한다)"
