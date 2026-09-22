#!/usr/bin/env bash
# 서버 튜닝: **shared_buffers 를 올리면 정말 빨라지는가.**
#
# 이 랩에서 두 번 틀렸던 질문이다.
#   · 한 번은 "SF=10 이 느린 건 shared_buffers 탓"이라고 가설을 세웠다가, 1GB → 48MB 로
#     **줄였는데도 1.26배**밖에 안 변해서 뒤집혔다(16배를 예상했다).
#   · 한 번은 postgresql.conf 를 고치고 재시작했는데 값이 안 바뀌었다 — ALTER SYSTEM 이
#     써 둔 postgresql.auto.conf 가 그걸 덮어쓰기 때문이다.
# 그래서 이 스크립트는 **설정이 실제로 먹었는지 먼저 확인**하고, 두 가지 접근 패턴을
# 따로 잰다. 답이 패턴마다 다르기 때문이다:
#
#   A) 무작위 점조회 (pgbench -b select-only)
#      같은 블록을 다시 찾아오므로 캐시가 있으면 이득이 있다. **여기는 효과가 있어야 한다.**
#   B) 전체 스캔 (SELECT sum(abalance))
#      PostgreSQL 은 큰 순차 스캔에 **링 버퍼**(BAS_BULKREAD, 256KB)를 쓴다 — 스캔이
#      shared_buffers 를 통째로 밀어내지 못하게 막는 장치다. 그래서 버퍼를 아무리 키워도
#      **여기는 효과가 없어야 한다.** '메모리를 늘렸는데 왜 스캔이 안 빨라지죠'의 답이다.
#
# 그리고 세 번째 함정: **OS 페이지 캐시**. shared_buffers 는 2차 캐시다. PostgreSQL 이
# 놓쳐도 OS 캐시가 받아 주면 디스크까지 안 간다. 그래서 '버퍼 미스는 늘었는데 시간은
# 그대로'가 흔하다 — 이 스크립트는 **미스 증가와 시간 증가를 따로 찍어** 그걸 가른다.
#
# 사용법:
#   ./t-shared-buffers.sh                 # 표 크기에서 스윕 값을 자동으로 정한다
#   SB_LIST="128MB 1GB 4GB" ./t-shared-buffers.sh
#   ROUNDS=3 SECS=15 ./t-shared-buffers.sh
#
# ⚠️ 이 스크립트는 **ALTER SYSTEM 으로 서버 설정을 바꾸고 재시작한다.** 다른 사람이 쓰는
#    서버에서 돌리지 말 것. 끝나면(중단해도) 원래 값으로 되돌리고 다시 재시작한다.
set -uo pipefail

DB=pgbench_lab
ROUNDS="${ROUNDS:-2}"
SECS="${SECS:-10}"
CLIENTS="${CLIENTS:-8}"
JOBS="${JOBS:-4}"
WARM="${WARM:-8}"                 # 조건마다 동일하게 주는 예열 시간(초)
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
export PGPASSWORD="${PGPASSWORD:-tuner}"
PGUSER_="${PGUSER:-tuner}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

if command -v psql >/dev/null 2>&1; then
  PG_VIA=host
  q()  { psql -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -d "$DB" -X -q -tAc "$1" 2>&1; }
  qs() { psql -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -d postgres -X -q -tAc "$1" 2>&1; }
  PGBENCH(){ pgbench -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" "$@"; }
else
  PG_VIA=docker
  q()  { docker exec -i -e PGPASSWORD=tuner "$CONTAINER" psql -U "$PGUSER_" -d "$DB" -X -q -tAc "$1" 2>&1; }
  qs() { docker exec -i -e PGPASSWORD=tuner "$CONTAINER" psql -U "$PGUSER_" -d postgres -X -q -tAc "$1" 2>&1; }
  PGBENCH(){ docker exec -i -e PGPASSWORD=tuner "$CONTAINER" pgbench -U "$PGUSER_" "$@"; }
fi

die() { echo "  [중단] $*"; exit 1; }

# ── 재시작 ────────────────────────────────────────────────────────────
# **재시작 뒤 '떴는지'를 반드시 기다려야 한다.** 바로 질의하면 아직 안 떠서 빈 값이 오고,
# 그 빈 값이 측정값으로 둔갑한다(이 랩이 여러 번 당한 실패다).
pg_restart() {
  if [ "$PG_VIA" = host ] && command -v pg_ctlcluster >/dev/null 2>&1; then
    pg_ctlcluster 16 main restart >/dev/null 2>&1
  elif command -v docker >/dev/null 2>&1; then
    docker restart "$CONTAINER" >/dev/null 2>&1
  else
    die "재기동 방법을 못 찾았다 — pg_ctlcluster 도 docker 도 없다."
  fi
  local i
  for i in $(seq 1 60); do
    [ "$(qs 'SELECT 1' 2>/dev/null)" = "1" ] && return 0
    sleep 1
  done
  die "재기동 뒤 60초 안에 접속되지 않았다."
}

# ALTER SYSTEM 은 트랜잭션 블록 안에서 못 돈다 — -c 하나에 혼자 보낸다.
# 그리고 **먹었는지 확인한다.** postgresql.conf 를 고쳐도 auto.conf 가 이기므로,
# '바꿨다고 생각했는데 안 바뀐' 상태로 측정하는 일이 실제로 있었다.
set_sb() {
  local want="$1"
  qs "ALTER SYSTEM SET shared_buffers = '$want'" >/dev/null 2>&1
  pg_restart
  local got; got=$(qs "SHOW shared_buffers")
  # 8kB 단위 반올림 때문에 '4GB' 가 '4GB' 로 그대로 나오지 않을 수 있다 — 바이트로 견준다.
  local gb wb
  gb=$(qs "SELECT pg_size_bytes('$got')"); wb=$(qs "SELECT pg_size_bytes('$want')")
  if [ "${gb:-0}" != "${wb:-1}" ]; then
    echo "  [중단] shared_buffers 를 $want 로 바꿨는데 서버는 $got 다."
    echo "         설정이 안 먹었다. 어디서 오는지 보라:"
    qs "SELECT name, setting, unit, source, sourcefile FROM pg_settings WHERE name='shared_buffers'" | sed 's/^/         /'
    exit 1
  fi
}

# ── 선행 확인 ─────────────────────────────────────────────────────────
[ "$(qs 'SELECT 1')" = "1" ] || die "PostgreSQL 에 접속할 수 없다 (경로: $PG_VIA)."
NACC=$(q "SELECT count(*) FROM pgbench_accounts")
case "$NACC" in ''|*[!0-9]*) die "pgbench_accounts 를 읽지 못했다: $NACC
         ./gradlew :pgbench-lab:bootRun --args=\"init --scale=10\"";; esac
TOTMB=$(q "SELECT round(pg_total_relation_size('pgbench_accounts')/1048576.0)")
ORIG=$(qs "SHOW shared_buffers")
ORIG_SRC=$(qs "SELECT coalesce(sourcefile,'(기본값)') FROM pg_settings WHERE name='shared_buffers'")

# **원복은 무조건 한다.** 중단해도 서버 설정을 남겨 두면 이후 모든 실습의 측정 조건이 달라진다.
LAB_DONE=0
restore_sb() {
  [ "$LAB_DONE" = 1 ] && return 0
  echo
  echo "  [중단] shared_buffers 를 $ORIG 로 되돌리고 재기동한다..."
  qs "ALTER SYSTEM SET shared_buffers = '$ORIG'" >/dev/null 2>&1
  pg_restart
  echo "         현재: $(qs 'SHOW shared_buffers')"
}
trap restore_sb EXIT

# ── 스윕 값 정하기 ────────────────────────────────────────────────────
# 표 크기를 기준으로 **작업집합을 가로지르게** 잡는다. 전부 표보다 크면 아무것도 안 보인다.
if [ -z "${SB_LIST:-}" ]; then
  SMALL=$(( TOTMB / 8 )); [ "$SMALL" -lt 16 ] && SMALL=16
  MID=$(( TOTMB / 2 ));   [ "$MID" -lt 32 ] && MID=32
  BIG=$(( TOTMB * 2 ));   [ "$BIG" -lt 64 ] && BIG=64
  # RAM 의 1/4 을 넘기지 않는다 — 넘기면 OS 가 스왑하며 딴 것을 재게 된다.
  RAMMB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "${RAMMB:-0}" -gt 0 ] && [ "$BIG" -gt $(( RAMMB / 4 )) ]; then
    BIG=$(( RAMMB / 4 ))
    echo "  ※ 상한을 RAM 의 1/4(${BIG}MB)로 낮춘다 — 그 이상은 OS 캐시를 빼앗아 다른 것을 재게 된다."
  fi
  SB_LIST="${SMALL}MB ${MID}MB ${BIG}MB"
fi

echo "§ shared_buffers 는 무엇을 빠르게 하는가"
echo "  pgbench_accounts ${NACC}행 / ${TOTMB}MB · 클라이언트 ${CLIENTS} · 조건당 예열 ${WARM}초 + 측정 ${SECS}초 × ${ROUNDS}라운드 교차"
echo "  스윕: $SB_LIST   (현재 $ORIG — 출처 $ORIG_SRC)"
echo
# 전부 표보다 크면 이 실험은 아무것도 못 본다. 그때는 그렇게 말한다.
MINMB=$(qs "SELECT round(pg_size_bytes('$(echo $SB_LIST | awk '{print $1}')')/1048576.0)")
if [ "${MINMB:-0}" -gt "$TOTMB" ]; then
  echo "  ⚠️ 가장 작은 스윕 값(${MINMB}MB)도 표(${TOTMB}MB)보다 크다 — **어느 조건에서도 다 들어간다.**"
  echo "     이러면 차이가 안 나는 게 당연하고, 그건 shared_buffers 에 대한 답이 아니다."
  echo "     SB_LIST 를 더 작게 주거나 scale 을 올려라."
  echo
fi

# ── 측정 ──────────────────────────────────────────────────────────────
# A) 무작위 점조회. pgbench 내장 select-only = SELECT abalance ... WHERE aid = :aid.
#    DB 단위 블록 통계를 조건마다 리셋해서 '실제로 더 읽었는가'를 같이 본다.
meas_random() {
  PGBENCH -b select-only -c "$CLIENTS" -j "$JOBS" -T "$WARM" -n "$DB" >/dev/null 2>&1
  qs "SELECT pg_stat_reset_shared('bgwriter')" >/dev/null 2>&1
  q  "SELECT pg_stat_reset()" >/dev/null 2>&1
  local t; t=$(PGBENCH -b select-only -c "$CLIENTS" -j "$JOBS" -T "$SECS" -n "$DB" 2>&1 \
               | grep -oE "^tps = [0-9.]+" | grep -oE "[0-9.]+" | head -1)
  # blks_read = 실제로 OS 에 요청한 블록. hit% = shared_buffers 가 막아 준 비율.
  local s; s=$(q "SELECT coalesce(blks_read,0)||'|'||
                         coalesce(round(100.0*blks_hit/NULLIF(blks_hit+blks_read,0),2),0)
                    FROM pg_stat_database WHERE datname='$DB'")
  echo "${t:-0}|$s"
}

# B) 전체 스캔. EXPLAIN (ANALYZE, BUFFERS) 로 블록을 **이 실행에 대해서만** 정확히 받는다.
#    링 버퍼 때문에 버퍼를 키워도 안 빨라지는 것을 보여 주는 자리다.
meas_scan() {
  q "EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, COSTS OFF, FORMAT JSON)
     SELECT sum(abalance) FROM pgbench_accounts" > /tmp/t_sb_$$.json 2>&1
  python3 - "/tmp/t_sb_$$.json" <<'PY'
import json,sys,re
raw=open(sys.argv[1]).read()
m=re.search(r'\[.*\]', raw, re.S)
if not m: print("0|0|0"); sys.exit()
p=json.loads(m.group(0))[0]
ms=p.get("Execution Time",0)
n=p["Plan"]
def walk(x,acc):
    acc[0]+=x.get("Shared Hit Blocks",0); acc[1]+=x.get("Shared Read Blocks",0)
    for c in x.get("Plans",[]): walk(c,acc)
acc=[0,0]; walk(n,acc)
print(f"{ms:.0f}|{acc[0]}|{acc[1]}")
PY
  rm -f /tmp/t_sb_$$.json
}

med(){ echo "$1"|tr ' ' '\n'|grep -v '^$'|sort -g|awk '{a[NR]=$1}END{if(NR)print a[int((NR+1)/2)]}'; }

declare -A R_TPS R_READ R_HIT S_MS S_HIT S_READ
for sb in $SB_LIST; do R_TPS[$sb]=""; R_READ[$sb]=""; R_HIT[$sb]=""; S_MS[$sb]=""; S_HIT[$sb]=""; S_READ[$sb]=""; done

# 라운드 바깥 / 조건 안쪽 — 라운드마다 조건을 **교차**한다. 한 조건을 몰아 재면
# 시간대 드리프트(OS 캐시가 점점 더워지는 것)가 조건 차이로 둔갑한다.
for r in $(seq 1 "$ROUNDS"); do
  for sb in $SB_LIST; do
    printf "  라운드 %s · shared_buffers=%s ... " "$r" "$sb"
    set_sb "$sb"
    IFS='|' read -r t rd hp <<<"$(meas_random)"
    R_TPS[$sb]="${R_TPS[$sb]} ${t%%.*}"; R_READ[$sb]="${R_READ[$sb]} $rd"; R_HIT[$sb]="${R_HIT[$sb]} $hp"
    IFS='|' read -r ms sh sr <<<"$(meas_scan)"
    S_MS[$sb]="${S_MS[$sb]} $ms"; S_HIT[$sb]="${S_HIT[$sb]} $sh"; S_READ[$sb]="${S_READ[$sb]} $sr"
    echo "완료 (점조회 ${t%%.*} tps / 스캔 ${ms}ms)"
  done
done
echo

echo "── A) 무작위 점조회 — 캐시가 듣는 패턴 (${ROUNDS}라운드 중앙값) ──"
printf "  %-16s %10s %14s %10s\n" "shared_buffers" "tps" "읽은블록" "버퍼적중%"
printf "  %s\n" "----------------------------------------------------------"
for sb in $SB_LIST; do
  printf "  %-16s %10s %14s %9s%%\n" "$sb" "$(med "${R_TPS[$sb]}")" "$(med "${R_READ[$sb]}")" "$(med "${R_HIT[$sb]}")"
done
echo

echo "── B) 전체 스캔 — 링 버퍼가 막는 패턴 (${ROUNDS}라운드 중앙값) ──"
printf "  %-16s %10s %14s %14s\n" "shared_buffers" "실행ms" "버퍼에서(hit)" "읽어옴(read)"
printf "  %s\n" "----------------------------------------------------------------"
for sb in $SB_LIST; do
  printf "  %-16s %10s %14s %14s\n" "$sb" "$(med "${S_MS[$sb]}")" "$(med "${S_HIT[$sb]}")" "$(med "${S_READ[$sb]}")"
done
echo

# ── 해석 — 전부 위 표에서 만든다 ──────────────────────────────────────
FIRST=$(echo $SB_LIST | awk '{print $1}'); LAST=$(echo $SB_LIST | awk '{print $NF}')
AT1=$(med "${R_TPS[$FIRST]}"); ATN=$(med "${R_TPS[$LAST]}")
AR1=$(med "${R_READ[$FIRST]}"); ARN=$(med "${R_READ[$LAST]}")
BM1=$(med "${S_MS[$FIRST]}");  BMN=$(med "${S_MS[$LAST]}")
BR1=$(med "${S_READ[$FIRST]}"); BRN=$(med "${S_READ[$LAST]}")
rat(){ awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{if(b+0==0)print "?";else printf "%.2f",a/b}'; }

echo "해석:"
echo "  · A(점조회): ${FIRST} → ${LAST} 에서 tps $AT1 → $ATN ($(rat "$ATN" "$AT1")배),"
echo "    읽은 블록 $AR1 → $ARN ($(rat "$ARN" "$AR1")배)."
# 미스는 줄었는데 시간은 그대로 → OS 페이지 캐시가 받아 준 것이다. 이게 이 실습의 핵심이다.
if awk -v a="$ARN" -v b="$AR1" 'BEGIN{exit !(b+0>0 && a+0 < b*0.5)}'; then
  if awk -v a="$ATN" -v b="$AT1" 'BEGIN{exit !(b+0>0 && a+0 < b*1.15)}'; then
    echo "    ★ **읽은 블록은 확 줄었는데 tps 는 거의 안 늘었다.**"
    echo "      shared_buffers 는 **2차 캐시**다 — PostgreSQL 이 놓쳐도 OS 페이지 캐시가 받아 주면"
    echo "      디스크까지 안 간다. 그래서 '버퍼 적중률'이 오르는 것과 '빨라지는 것'은 다른 얘기다."
    echo "      적중률을 KPI 로 잡으면 아무 이득 없는 튜닝을 성공이라고 보고하게 된다."
    echo "      진짜 효과를 보려면 작업집합이 **OS 캐시까지 넘어야** 한다(표 ${TOTMB}MB)."
  else
    echo "    ★ 블록도 줄고 tps 도 늘었다 — 이 조건에서는 작업집합이 OS 캐시로도 안 덮여서,"
    echo "      shared_buffers 가 **실제 디스크 I/O 를 줄였다.** 이게 효과가 있는 구간이다."
  fi
else
  echo "    ※ 읽은 블록이 별로 안 줄었다. 가장 작은 값에서도 이미 다 들어갔거나(표 ${TOTMB}MB),"
  echo "      스윕 폭이 좁은 것이다. SB_LIST 를 더 벌려서 다시 보라."
fi
echo
echo "  · B(전체 스캔): 실행 $BM1 → $BMN ms ($(rat "$BMN" "$BM1")배), 읽어온 블록 $BR1 → $BRN."
if awk -v a="$BRN" -v b="$BR1" 'BEGIN{exit !(b+0>0 && a+0 > b*0.5)}'; then
  echo "    ★ **버퍼를 키워도 읽어오는 블록이 거의 안 줄었다.** 이게 링 버퍼다 —"
  echo "      PostgreSQL 은 큰 순차 스캔에 256KB 짜리 작은 링만 내주고, 스캔이 캐시를 통째로"
  echo "      밀어내지 못하게 막는다. **큰 스캔은 shared_buffers 로 못 고친다.**"
  echo "      '메모리를 늘렸는데 왜 배치가 안 빨라지죠'의 답이 여기 있다."
else
  echo "    ※ 이 실행에서는 스캔의 읽기도 줄었다($BR1 → $BRN). 표가 작아 링 버퍼 임계"
  echo "      (shared_buffers 의 1/4)보다 작으면 통째로 캐시되므로 그럴 수 있다."
  echo "      링 버퍼를 보려면 표가 shared_buffers 의 1/4 보다 커야 한다."
fi
echo
echo "  → 정리: shared_buffers 는 **무작위 재접근**에 듣고, **큰 순차 스캔**에는 안 듣는다."
echo "    그리고 듣는 구간에서도 OS 캐시가 겹쳐 있어 적중률만큼 시간이 줄지는 않는다."
echo "    올리기 전에 **어떤 패턴이 느린지부터** 보라 — 패턴이 스캔이면 올려도 소용없다."
echo

LAB_DONE=1
qs "ALTER SYSTEM SET shared_buffers = '$ORIG'" >/dev/null 2>&1
pg_restart
echo "정리: shared_buffers 를 $ORIG 로 되돌렸다 — 현재 $(qs 'SHOW shared_buffers')"
echo "  ※ 이 값은 postgresql.auto.conf 에 박힌다(ALTER SYSTEM 이라서). postgresql.conf 를"
echo "     고쳐도 이 파일이 이긴다 — 바꾸려면 ALTER SYSTEM 을 쓰거나 이 항목을 지워야 한다:"
echo "       ALTER SYSTEM RESET shared_buffers;   -- 단, 설정파일 기본값(128MB)으로 돌아간다"
