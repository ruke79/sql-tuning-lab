#!/usr/bin/env bash
# §T-2 / §T-4 확장: **인덱스를 만들었더니 느려진 두 쿼리**를 해부한다.
#
# SF=10(lineitem 6,000만) 에서 `index` 명령 전후를 비교했더니 둘이 뒤집혔다:
#   q06  1,077ms → 2,477ms  (2.3배 악화)
#   q13 11,489ms → 27,865ms (2.4배 악화)
# 나머지는 같거나 좋아졌다(q09 13배, q05 1.8배, q18 1.7배 개선).
#
# "인덱스를 만들면 빨라진다"가 깨지는 방식이 **둘 다 다르다.** 그게 이 실습의 주제다.
#
#   ① q06 — 선택도가 전환점 너머인데 옵티마이저가 인덱스를 골랐다.
#            그리고 비트맵이 work_mem 을 넘겨 **lossy** 로 떨어져 재검사가 폭증했다.
#            → 갈림길이 둘이다: "인덱스를 쓰지 마라" vs "인덱스를 제대로 쓰게 하라".
#              둘은 다른 처방이므로 **둘 다 재야** 어느 쪽인지 안다.
#   ② q13 — 인덱스가 조인 방식을 Hash → Merge 로 갈아치웠다.
#            정렬을 공짜로 얻는 대신 orders 의 99% 를 **인덱스 순서로** 읽는다.
#            buffers 가 30만 → 1,500만(48배). 규모를 키울수록 더 나빠진다.
#   ③ 왜 거기인가 — 선택도와 접근량을 직접 계산해 표와 대조한다.
#
# **이 실습은 규모가 있어야 재현된다.** SF=0.5 에서는 lossy 비트맵도, 1,500만 buffers 도
# 나오지 않는다. 그래서 스크립트는 시간뿐 아니라 **판정에 쓴 지표**(lossy 블록 수,
# 재검사 행수, buffers, 계획 모양)를 같이 찍는다 — 자기 환경이 어느 구간인지 알 수 있게.
#
# 사용법:
#   ./t2-index-regression.sh              # 전부 (SF=0.5 약 1분, SF=10 은 수 분)
#   ONLY=1 ./t2-index-regression.sh       # q06 만
#   ROUNDS=5 ./t2-index-regression.sh     # 반복 횟수(기본 3, 최소값을 쓴다)
#   DROP=1 ./t2-index-regression.sh       # ②에서 idx_orders_custkey 를 실제로 지웠다 만든다
#                                         #   (SF=10 이면 재생성에 수십 초 걸린다)
#
# 선행 조건: tpch 적재 + **index 명령까지** 완료. 인덱스가 없으면 이 실습은 성립하지 않는다.
set -uo pipefail

ROUNDS="${ROUNDS:-3}"
ONLY="${ONLY:-123}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
export PGPASSWORD="${PGPASSWORD:-tuner}"
PGUSER_="${PGUSER:-tuner}"
DB=tpch

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
pg_precheck


dispw() { local b k; b=$(printf %s "$1" | wc -c); k=$(printf %s "$1" | LC_ALL=C tr -dc '\200-\277' | wc -c)
          echo $(( b - k / 2 )); }
padr()  { local n; n=$(dispw "$1"); printf "%s" "$1"; while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; }
padl()  { local n; n=$(dispw "$1"); while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; printf "%s" "$1"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
QDIR=""
for CAND in "$HERE/../../tpch/src/main/resources/queries" "./tpch/src/main/resources/queries"; do
  [ -d "$CAND" ] && QDIR="$CAND" && break
done
[ -z "$QDIR" ] && { echo "queries 디렉터리를 찾을 수 없습니다."; exit 1; }
qfile() { grep -v '^\s*--' "$QDIR/$1.sql" | sed 's/;\s*$//' | tr '\n' ' '; }
Q06=$(qfile q06); Q13=$(qfile q13)

NLI=$(q "SELECT count(*) FROM lineitem")
case "$NLI" in ''|*[!0-9]*) echo "tpch 를 읽지 못했습니다: $NLI"; exit 1;; esac
[ "$NLI" -lt 100000 ] && { echo "  [중단] lineitem 이 ${NLI}행뿐입니다. 먼저 적재하세요."; exit 1; }

# 이 실습은 **인덱스가 있어야** 성립한다. 없으면 '인덱스 때문에 느려졌다'를 잴 수 없다.
HAS_SD=$(q "SELECT count(*) FROM pg_indexes WHERE indexname='idx_lineitem_shipdate'")
HAS_CK=$(q "SELECT count(*) FROM pg_indexes WHERE indexname='idx_orders_custkey'")
if [ "${HAS_SD:-0}" = "0" ] || [ "${HAS_CK:-0}" = "0" ]; then
  echo "  [중단] 인덱스가 없습니다 (shipdate=${HAS_SD:-0} / orders_custkey=${HAS_CK:-0})."
  echo "         ./gradlew :tpch:bootRun --args=\"index --db=postgres\""
  exit 1
fi

# 측정: 서버가 보고한 Execution Time 의 N회 최소값. psql 호출마다 새 연결이라 SET 이 안 샌다.
plan() { q "$1 EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) $2"; }
best() {
  local b="" t
  for _ in $(seq 1 "$ROUNDS"); do
    t=$(plan "$1" "$2" | grep -oE "Execution Time: [0-9.]+" | grep -oE "[0-9.]+")
    case "$t" in ''|*[!0-9.]*) continue;; esac
    [ -z "$b" ] && b="$t"
    awk -v a="$t" -v c="$b" 'BEGIN{exit !(a<c)}' && b="$t"
  done
  echo "${b:-?}"
}
# 계획에서 판정 지표를 뽑는다
node()   { echo "$1" | grep -oE "(Parallel )?(Bitmap Heap Scan|Seq Scan|Index Scan|Index Only Scan|Merge [A-Za-z]* ?Join|Hash [A-Za-z]* ?Join|Nested Loop)[^(]*" | head -1 | sed 's/ *$//'; }
lossy()  { echo "$1" | grep -oE "lossy=[0-9]+" | grep -oE "[0-9]+" | head -1; }
exactb() { echo "$1" | grep -oE "exact=[0-9]+" | grep -oE "[0-9]+" | head -1; }
recheck(){ echo "$1" | grep -oE "Rows Removed by Index Recheck: [0-9]+" | grep -oE "[0-9]+" | head -1; }
wrk()    { local w; w=$(echo "$1" | grep -oE "Workers Planned: [0-9]+" | grep -oE "[0-9]+" | head -1); echo "${w:-직렬}"; }
bufs()   { echo "$1" | awk '/Buffers: shared/{h=0;r=0;
             if (match($0,/hit=[0-9]+/)) h=substr($0,RSTART+4,RLENGTH-4);
             if (match($0,/read=[0-9]+/)) r=substr($0,RSTART+5,RLENGTH-5);
             print h+r; exit}'; }

WM=$(q "SHOW work_mem")
echo "§T-2/T-4 확장 — 인덱스를 만들었더니 느려진 두 쿼리"
echo "  lineitem ${NLI}행 / work_mem=$WM / ${ROUNDS}회 최소값"
echo

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① q06 — 전환점 너머인데 인덱스를 골랐다, 그리고 비트맵이 lossy 로 떨어졌다 ──"
echo
SEL=$(q "SELECT round(100.0*count(*) FILTER (WHERE l_shipdate >= DATE '1994-01-01'
                                               AND l_shipdate <  DATE '1995-01-01')/count(*),2)
          FROM lineitem")
echo "  l_shipdate 1994년 범위의 선택도: ${SEL}%   (이게 전환점 안인지 밖인지가 ①의 전부다)"
echo
printf "  %s%10s %12s %12s %12s %s\n" "$(padr 조건 30)" "$(padl 시간ms 10)" "$(padl buffers 12)" \
   "$(padl "lossy 블록" 12)" "$(padl 재검사행 12)" "  스캔 방식"
printf "  %s\n" "---------------------------------------------------------------------------------------------------"
for c in "기본 (그대로)|" \
         "enable_bitmapscan=off|SET enable_bitmapscan=off;" \
         "work_mem=1GB (lossy 제거 시도)|SET work_mem='1GB';" \
         "둘 다|SET enable_bitmapscan=off; SET work_mem='1GB';"; do
  L="${c%%|*}"; S="${c#*|}"
  P=$(plan "$S" "$Q06")
  printf "  %s%10s %12s %12s %12s  %s\n" "$(padr "$L" 30)" "$(best "$S" "$Q06")" \
    "$(bufs "$P")" "$(L=$(lossy "$P"); echo "${L:--}")" "$(R=$(recheck "$P"); echo "${R:--}")" "$(node "$P")"
done
echo
echo "  읽는 법 — **갈림길이 둘이고 처방이 다르다.**"
echo "   (가) 'enable_bitmapscan=off' 가 제일 빠르다 → 이 선택도에서는 **인덱스를 쓰면 안 된다.**"
echo "       전환점 밖인데 옵티마이저가 잘못 고른 것이고, 손댈 곳은 random_page_cost 나 통계다."
echo "   (나) 'work_mem=1GB' 가 제일 빠르다 → 인덱스 자체는 맞는데 **비트맵이 메모리를 넘긴** 것이다."
echo "       lossy 열이 0 이 되고 재검사 행이 사라졌는지 확인하라 — 그게 근거다."
echo "   둘 다 안 되면 셋째 답이다: 이 쿼리는 그냥 풀스캔이 정답이고 인덱스는 다른 쿼리용이다."
echo
echo "  lossy 가 왜 생기나 — 비트맵은 조건에 맞는 **행 위치(TID)** 를 모아 두는데, 그게 work_mem 을"
echo "  넘으면 PostgreSQL 이 페이지 단위로 뭉갠다('이 페이지 어딘가에 있다'). 그러면 힙에서 그 페이지를"
echo "  통째로 읽어 **다시 검사**해야 하고, 그 몫이 'Rows Removed by Index Recheck' 다."
echo "  SF=10 실측에서는 exact=138,270 / lossy=123,836 으로 블록의 절반이 뭉개졌고 재검사가 429만 행이었다."
echo "  **lossy 열이 '-' 로 비어 있으면 그 규모에서는 비트맵이 메모리에 다 들어간 것이다** —"
echo "  그러면 ①은 순수한 전환점 문제이고, (나) 갈림길은 애초에 존재하지 않는다."
echo "  선택도는 규모와 무관하므로(SF=0.5 도 SF=10 도 약 15%) **전환점 문제는 작은 규모에서도 재현된다.**"
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② q13 — 인덱스가 조인 방식을 갈아치웠다 ──"
echo
# **손잡이가 둘이고 서로 독립이다.**
#   A. 계획을 되돌린다        — 인덱스가 고른 Merge/Index 경로를 막는다
#   B. 병렬을 얻는다          — q13 은 인덱스가 있든 없든 **직렬**이다(§T-6 확장 ①).
#                               고카디널리티 GROUP BY 라 Gather 통과 행이 많아 비용이 거절한다.
# A 는 접근량(buffers)을 줄이고 B 는 같은 일을 나눠 든다 — 그래서 **같이 걸면 더 내려간다.**
printf "  %s%10s %14s %7s   %s\n" "$(padr 조건 34)" "$(padl 시간ms 10)" "$(padl buffers 14)" "$(padl 워커 7)" "계획 맨 위 조인"
printf "  %s\n" "--------------------------------------------------------------------------------------------"
BASEB=""; BASEJ=""; BASET=""
declare -A T13
for c in "기본 (그대로)|" \
         "A  enable_indexscan=off|SET enable_indexscan=off;" \
         "A' enable_mergejoin=off|SET enable_mergejoin=off;" \
         "B  parallel_tuple_cost=0.01|SET parallel_tuple_cost=0.01;" \
         "A+B 둘 다|SET enable_indexscan=off; SET parallel_tuple_cost=0.01;"; do
  LBL="${c%%|*}"; S="${c#*|}"
  P=$(plan "$S" "$Q13"); B=$(bufs "$P"); T=$(best "$S" "$Q13")
  J=$(echo "$P" | grep -oE "(Merge|Hash|Nested)[A-Za-z ]*Join" | head -1)
  [ -z "$BASEB" ] && { BASEB="$B"; BASEJ="$J"; BASET="$T"; }
  T13["$LBL"]="$T"
  printf "  %s%10s %14s %7s   %s\n" "$(padr "$LBL" 34)" "$T" "$B" "$(wrk "$P")" "${J:-?}"
done
echo
# 두 손잡이가 곱해지는지(=독립인지) 숫자로 확인한다. 합쳐서 더 안 내려가면 독립이 아니다.
awk -v base="${BASET:-0}" -v a="${T13[A  enable_indexscan=off]:-0}" \
    -v b="${T13[B  parallel_tuple_cost=0.01]:-0}" -v ab="${T13[A+B 둘 다]:-0}" 'BEGIN{
  if (base>0 && a>0 && b>0 && ab>0) {
    printf "  배수:  A 단독 %.2fx / B 단독 %.2fx / 곱하면 %.2fx 예상  →  실제 A+B %.2fx\n",
           base/a, base/b, (base/a)*(base/b), base/ab
    if (base/ab > (base/a)*1.05 && base/ab > (base/b)*1.05)
      printf "  → **둘 다 걸면 각각보다 더 내려간다. 두 손잡이는 독립이다.**\n"
    else
      printf "  → 합쳐도 한쪽만큼밖에 안 내려간다 — 이 환경에서는 한 손잡이가 할 일이 없었다는 뜻이다.\n  바로 아래 판정을 함께 읽을 것.\n"
  }}'
echo
# **재현 여부를 먼저 판정한다.** 기본 계획이 Merge Join 이 아니면 이 절의 함정이 안 걸린 것이고,
# 그 상태에서 아래 해설을 결과처럼 읽으면 안 된다.
case "$BASEJ" in
  Merge*) echo "  → **함정이 재현됐다.** 기본 계획이 ${BASEJ} 다. 위 표에서 enable_* 를 끈 쪽이"
          echo "    더 빠르고 buffers 도 적다면, 인덱스가 고른 경로가 손해라는 뜻이다." ;;
  *)      echo "  ⚠️ **A 쪽 함정은 이 규모에서 재현되지 않았다.** 기본 계획이 이미 ${BASEJ:-?} 다 —"
          echo "    플래너가 Merge/Index 경로를 아예 고르지 않았으므로 **A 가 되돌릴 것이 없다.**"
          echo "    A 의 배수가 1 근처이거나 오히려 손해라면 그 뜻이고, 그건 정상이다"
          echo "    (인덱스 스캔을 막으면 customer_pkey 의 Index Only Scan 까지 막혀 buffers 가 는다)."
          echo "    **B 는 규모와 무관하게 값을 낸다** — 직렬 판정은 선택도가 아니라 그룹 수가 정하므로."
          echo "    A 쪽 수치는 SF=10(lineitem 6,000만) 실측을 참고한다. 이 함정은 행수에 비례해"
          echo "    깊어지므로 규모를 키워야 비로소 나타난다 — **작은 규모의 '문제 없네'는 결론이 아니다.**" ;;
esac
echo
if [ "${DROP:-0}" = "1" ]; then
  echo "  DROP=1 — idx_orders_custkey 를 실제로 지우고 재 본다 (되돌리는 데 시간이 걸린다)"
  q "DROP INDEX idx_orders_custkey" >/dev/null
  P=$(plan "" "$Q13")
  printf "  %s%10s %14s   %s\n" "$(padr "인덱스를 지우면" 30)" "$(best "" "$Q13")" "$(bufs "$P")" \
    "$(echo "$P" | grep -oE '(Merge|Hash|Nested)[A-Za-z ]*Join' | head -1)"
  echo "  인덱스를 다시 만든다..."
  q "CREATE INDEX idx_orders_custkey ON orders(o_custkey)" >/dev/null
  q "ANALYZE orders" >/dev/null
  echo "  복구 완료 (idx_orders_custkey $(q "SELECT count(*) FROM pg_indexes WHERE indexname='idx_orders_custkey'")개)"
  echo
fi
NORD=$(q "SELECT count(*) FROM orders")
KEPT=$(q "SELECT round(100.0*count(*) FILTER (WHERE o_comment NOT LIKE '%special%requests%')/count(*),1) FROM orders")
echo "  왜 이렇게 되나 — 이 쿼리의 필터는 **거의 아무것도 안 거른다.**"
echo "    orders ${NORD}행 중 ${KEPT}% 가 통과한다. 즉 사실상 전체 스캔이다."
echo "    그런데 인덱스가 있으면 플래너는 'GROUP BY c_custkey 에 필요한 정렬을 공짜로 얻는'"
echo "    Merge Join 경로를 볼 수 있게 되고, 비용 모델이 그쪽을 고른다."
echo "    대가는 **테이블의 99% 를 인덱스 순서로 읽는 것**이다 — 힙 접근이 랜덤이 되어"
echo "    같은 블록을 여러 번 만진다. buffers 열의 배수가 그 값이다."
echo "    SF=10 실측: 30만 → **1,500만 buffers(48배)**, I/O 만 14.4초."
echo
echo "  그리고 **q13 은 인덱스가 있든 없든 직렬이다**(위 표의 워커 열, 기본 행). §T-6 확장 ①의"
echo "  그 문제다 — 고카디널리티 GROUP BY 라 Gather 를 통과할 행이 많아 비용 모델이 병렬을 거절한다."
echo "  그래서 손잡이가 둘이고 **서로 독립**이다: A 는 접근량을 줄이고, B 는 같은 일을 나눠 든다."
echo "  (B 의 값은 환경마다 다르다. 여기서는 0.05 로는 안 켜지고 0.01 에서 켜졌다 —"
echo "   워커 열이 '직렬'로 남아 있으면 더 낮춰야 한다. 전역이 아니라 **세션 단위로** 쓸 것.)"
echo
echo "  → 규칙: **전체를 읽는 쿼리에 인덱스 순서 접근을 붙이면 진다.**"
echo "    정렬을 공짜로 얻는 이득보다 랜덤 힙 접근의 손해가 크고, 그 손해는 **행수에 비례**한다."
echo "    그래서 이 함정은 규모를 키울수록 깊어진다(SF=0.5 에서는 안 보일 수 있다)."
echo
echo "  ※ 이 인덱스는 §T-8 에서도 걸림돌이었다 — 좁은 idx_orders_custkey 가 남아 있으면"
echo "    옵티마이저가 결합 인덱스를 안 쓴다. **같은 인덱스가 두 번 해를 끼쳤다.**"
echo "    '이 인덱스가 어느 쿼리를 위한 것인가'를 답할 수 없으면 지우는 쪽이 맞다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
echo "── ③ 나머지 쿼리는 왜 좋아졌나 — 대조군 ──"
echo
printf "  %s%12s %s\n" "$(padr 쿼리 10)" "$(padl "필터 통과율" 12)" "  인덱스가 값을 내는 조건"
printf "  %s\n" "---------------------------------------------------------------------------"
printf "  %s%12s   %s\n" "$(padr q06 10)" \
  "$(q "SELECT round(100.0*count(*) FILTER (WHERE l_shipdate >= DATE '1994-01-01' AND l_shipdate < DATE '1995-01-01' AND l_discount BETWEEN 0.05 AND 0.07 AND l_quantity < 24)/count(*),3)||'%' FROM lineitem")" \
  "최종 통과율은 낮지만 **인덱스가 아는 것은 날짜뿐**이다(위 ①의 ${SEL:-?}%)"
printf "  %s%12s   %s\n" "$(padr q13 10)" \
  "$(q "SELECT round(100.0*count(*) FILTER (WHERE o_comment NOT LIKE '%special%requests%')/count(*),1)||'%' FROM orders")" \
  "거의 전부 통과 — 인덱스가 거를 것이 없다"
printf "  %s%12s   %s\n" "$(padr q09 10)" \
  "$(q "SELECT round(100.0*count(*) FILTER (WHERE p_name LIKE '%green%')/count(*),1)||'%' FROM part")" \
  "part 를 크게 줄여 lineitem 을 **적게 찌른다** → 13배 개선"
echo
echo "  → 셋을 나란히 놓으면 규칙이 하나로 모인다."
echo "    **인덱스가 값을 내는 조건은 '필터가 선택적인가'가 아니라"
echo "      '인덱스가 그 선택성을 아는가' 다.**"
echo "    q06 의 최종 통과율은 아주 낮지만 discount/quantity 는 인덱스에 없다 —"
echo "    인덱스는 날짜만 알고, 날짜만으로는 ${SEL:-?}% 라 전환점 밖이다."
echo "    q09 는 반대다: 줄이는 조건이 part 쪽에 있고 그걸 쓴 뒤 lineitem 을 찌르므로 인덱스가 산다."
echo
fi

echo "정리: '인덱스를 만들면 빨라진다' 가 깨지는 방식이 둘이었다."
echo "  ① 선택도가 전환점 밖인데 골랐다 (+ 비트맵이 lossy 로 떨어져 재검사 폭증)"
echo "  ② 전체를 읽는 쿼리에 인덱스 순서 접근이 붙어 buffers 가 자릿수로 늘었다"
echo "  EXPLAIN 에서 볼 자리: Heap Blocks 의 lossy= / Rows Removed by Index Recheck / Buffers 합계."
echo "  이 스크립트는 서버 설정을 바꾸지 않는다 (세션 SET 만 쓴다)."
