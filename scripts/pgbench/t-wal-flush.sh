#!/usr/bin/env bash
# WAL flush: **클라이언트 1 → 2 에서 지연이 뛰는 이유는 fsync 인가.**
#
# 동시성 스윕에서 이런 모양이 나왔다(scale=2000, 32 CPU):
#   clients   1    2    4    8   16   32   64
#   지연ms  2.62 3.90 3.82 3.92 4.09 4.95 6.65
# 1→2 에서 49% 뛰고 **2→16 은 거의 평평하다.** 경합이 점점 심해지는 모양이 아니라
# **2에서 값을 한 번 치르고 그 뒤로는 분할상환되는** 모양이다. 전형적인 후보가
# 그룹 커밋이다 — 혼자면 커밋마다 자기 fsync 를 기다리지만, 여럿이면 한 번의 fsync 가
# 여러 커밋을 함께 실어 나른다.
#
# 모양이 가설과 맞는 것만으로는 확정이 아니다. 이 스크립트는 두 가지로 가른다:
#   1) synchronous_commit on/off 를 **교차 측정**한다. off 면 커밋이 fsync 를 안 기다린다.
#      off 에서 1→2 점프가 사라지면 fsync 가 맞다.
#   2) 측정 중 **다른 세션에서 pg_stat_activity 를 샘플링**해 wait_event 를 센다.
#      WALSync/WALWrite 가 실제로 찍히는지 본다. (monitor 의 락 대기 절이 "실행 중
#      다른 세션에서 조회해야 잡힘"이라고 적어 둔 것이 이것이다.)
#
# ⚠️ synchronous_commit=off 는 **크래시 시 마지막 몇 백 ms 의 커밋을 잃는다.**
#    데이터가 깨지지는 않는다(원자성은 유지된다). 이 실습은 세션 단위로만 바꾸므로
#    서버 설정을 건드리지 않고, 재시작도 원복도 필요 없다 — shared_buffers 와 다르다.
#
# 사용법:
#   ./t-wal-flush.sh                       # 1 2 4 8 16 32 64
#   CLIST="1 2 4" SECS=10 ./t-wal-flush.sh
#   ROUNDS=3 ./t-wal-flush.sh
set -uo pipefail

DB=pgbench_lab
CLIST="${CLIST:-1 2 4 8 16 32 64}"
SECS="${SECS:-15}"
WARM="${WARM:-5}"                 # 조건마다 동일하게 주는 예열 시간(초)
ROUNDS="${ROUNDS:-2}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
export PGPASSWORD="${PGPASSWORD:-tuner}"
PGUSER_="${PGUSER:-tuner}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"
SCRATCH="${TMPDIR:-/tmp}/t_wal.$$"
mkdir -p "$SCRATCH"

if command -v psql >/dev/null 2>&1; then
  PG_VIA=host
  q() { psql -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -d "$DB" -X -q -tAc "$1" 2>&1; }
  # PGOPTIONS 는 호출자가 export 해서 넘긴다 — libpq 가 읽어 세션 설정으로 건다.
  PGBENCH() { pgbench -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" "$@"; }
else
  PG_VIA=docker
  q() { docker exec -i -e PGPASSWORD=tuner "$CONTAINER" psql -U "$PGUSER_" -d "$DB" -X -q -tAc "$1" 2>&1; }
  PGBENCH() { docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="${PGOPTIONS:-}" "$CONTAINER" \
                pgbench -U "$PGUSER_" "$@"; }
fi

die() { echo "  [중단] $*"; exit 1; }

[ "$(q 'SELECT 1')" = "1" ] || die "PostgreSQL 에 접속할 수 없다 (경로: $PG_VIA)."
NB=$(q "SELECT count(*) FROM pgbench_branches")
case "$NB" in ''|*[!0-9]*) die "pgbench_branches 를 읽지 못했다: $NB
         ./gradlew :pgbench-lab:bootRun --args=\"init --scale=10\"";; esac
# pgbench 는 scale 을 pgbench_branches 행 수에서 **스스로** 읽는다 — 자바 러너의
# --scale 어긋남 함정이 여기엔 없다.
SRV_SC=$(q "SHOW synchronous_commit")
echo "§ WAL flush — 1→2 지연 점프는 fsync 인가"
echo "  pgbench_lab scale=${NB} · 조건당 예열 ${WARM}초 + 측정 ${SECS}초 × ${ROUNDS}라운드 교차 · 서버 기본 synchronous_commit=${SRV_SC}"
echo "  클라이언트: $CLIST"
echo

# ── wait_event 샘플러 ─────────────────────────────────────────────────
# 측정 중 다른 세션에서 100ms 마다 찍는다. 이게 '무엇을 기다렸나'의 유일한 직접 증거다.
SAMPLER=""
start_sampler() {
  : > "$1"
  (
    while :; do
      q "SELECT coalesce(wait_event_type||'.'||wait_event,'(실행중)')
           FROM pg_stat_activity
          WHERE datname='$DB' AND state='active' AND pid <> pg_backend_pid()" >> "$1" 2>/dev/null
      sleep 0.1
    done
  ) & SAMPLER=$!
}
# **우리가 띄운 PID 만 죽인다.** pkill -f 로 잡다가 자기 셸을 죽인 적이 있다.
stop_sampler() { [ -n "$SAMPLER" ] && kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null; SAMPLER=""; }
cleanup() { stop_sampler; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# 한 조건 1회 → "tps|평균지연ms|상위대기"
measure() {  # $1=clients $2=on|off
  # **한 local 문 안에서 방금 선언한 변수를 참조하면 안 된다** — set -u 가 unbound 로 잡는다.
  # 그리고 그 죽음은 $(measure ...) 서브셸 안에서 일어나므로 **아래 fail-loud 가드까지 같이
  # 죽는다.** 그래서 호출부에도 빈 값 검사를 뒀다(이중 방어).
  local c="$1"
  local sc="$2"
  local f="$SCRATCH/w.$c.$sc"
  export PGOPTIONS="-c synchronous_commit=$sc"
  # **예열.** 없으면 맨 처음 측정되는 조건이 식은 캐시를 혼자 뒤집어쓴다 —
  # 실제로 clients=1/on 에서 대기 이벤트 83% 가 IO.DataFileRead 로 찍혔다(WAL 이 아니라).
  # 그 값으로 fsync 를 논하면 엉뚱한 것을 재는 것이다.
  PGBENCH -b tpcb-like -c "$c" -j "$(( c > 8 ? 8 : c ))" -T "$WARM" -n "$DB" >/dev/null 2>&1
  start_sampler "$f"
  local out; out=$(PGBENCH -b tpcb-like -c "$c" -j "$(( c > 8 ? 8 : c ))" -T "$SECS" -n "$DB" 2>&1)
  stop_sampler
  unset PGOPTIONS
  local tps lat
  tps=$(printf %s "$out" | grep -oE "^tps = [0-9.]+" | grep -oE "[0-9.]+" | head -1)
  lat=$(printf %s "$out" | grep -oE "^latency average = [0-9.]+" | grep -oE "[0-9.]+" | head -1)
  # **빈 값을 0 으로 찍고 넘어가지 않는다.** 왜 비었는지 보여 준다.
  if [ -z "$tps" ]; then
    echo "  [중단] pgbench 가 결과를 안 냈다 (clients=$c, synchronous_commit=$sc)."
    printf %s "$out" | sed 's/^/         /' | head -8
    exit 1
  fi
  # 대기 이벤트. **'(실행중)'을 빼고 세야 한다** — 안 그러면 상위가 전부 (실행중)으로 나와서
  # '무엇을 기다렸나'를 못 본다. 처음에 그렇게 짰다가 대기 이벤트 열이 무용지물이었다.
  # 실제로 기다린 비율(대기%)과 그중 최상위 이벤트를 같이 준다.
  local top ntot nwait
  ntot=$(grep -vc '^$' "$f" 2>/dev/null); ntot=${ntot:-0}
  nwait=$(grep -v '^$' "$f" 2>/dev/null | grep -vc '^(실행중)$'); nwait=${nwait:-0}
  if [ "$nwait" -gt 0 ]; then
    top=$(grep -v '^$' "$f" | grep -v '^(실행중)$' | sort | uniq -c | sort -rn | head -1 \
          | awk -v n="$ntot" '{printf "%s %d%%", $2, (n>0)? $1*100/n : 0}')
    top="$top (대기 $(awk -v a="$nwait" -v b="$ntot" 'BEGIN{printf "%d%%",(b>0)?a*100/b:0}'))"
  else
    top="대기 0% (전부 실행중)"
  fi
  echo "${tps}|${lat}|${top:-(샘플없음)}"
}

# **측정이 빈 값을 돌려주면 거기서 멈춘다.** 처음에 이 검사가 measure() 안에만 있었는데,
# set -u 로 함수가 서브셸에서 죽으니 가드까지 같이 죽어 0 으로 채운 표와 결론이 찍혔다.
# 빈 값을 측정값으로 읽는 것이 이 랩에서 가장 자주 난 사고다.
need() {
  if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo
    echo "  [중단] 측정이 값을 돌려주지 않았다 ($3)."
    echo "         스크립트나 pgbench 가 실패한 것이지 '0' 이라는 결과가 아니다."
    echo "         위쪽에 찍힌 에러를 보라. 표를 찍고 넘어가면 없는 결론을 만들게 된다."
    exit 1
  fi
}

med() { echo "$1" | tr ' ' '\n' | grep -v '^$' | sort -g \
        | awk '{a[NR]=$1} END{if(NR) printf "%.2f", a[int((NR+1)/2)]}'; }

declare -A T_ON T_OFF L_ON L_OFF W_ON W_OFF
for c in $CLIST; do T_ON[$c]=""; T_OFF[$c]=""; L_ON[$c]=""; L_OFF[$c]=""; done

# 라운드가 바깥, on/off 가 가장 안쪽 — 같은 클라이언트 수에서 **붙여서** 교차한다.
# 한 설정을 몰아 재면 시간대 드리프트가 설정 차이로 둔갑한다.
for r in $(seq 1 "$ROUNDS"); do
  for c in $CLIST; do
    printf "  라운드 %s · clients=%-3s " "$r" "$c"
    IFS='|' read -r t l w <<<"$(measure "$c" on)"
    need "$t" "$l" "clients=$c synchronous_commit=on"
    T_ON[$c]="${T_ON[$c]} $t"; L_ON[$c]="${L_ON[$c]} $l"; W_ON[$c]="$w"
    IFS='|' read -r t2 l2 w2 <<<"$(measure "$c" off)"
    need "$t2" "$l2" "clients=$c synchronous_commit=off"
    T_OFF[$c]="${T_OFF[$c]} $t2"; L_OFF[$c]="${L_OFF[$c]} $l2"; W_OFF[$c]="$w2"
    echo "on ${l}ms / off ${l2}ms"
  done
done
echo

printf "  %-9s %11s %11s %8s %11s %11s %8s\n" \
  "clients" "on tps" "on 지연ms" "on 배수" "off tps" "off 지연ms" "off 배수"
printf "  %s\n" "--------------------------------------------------------------------------------"
FIRST=$(echo $CLIST | awk '{print $1}')
BON=$(med "${L_ON[$FIRST]}"); BOFF=$(med "${L_OFF[$FIRST]}")
for c in $CLIST; do
  lo=$(med "${L_ON[$c]}"); lf=$(med "${L_OFF[$c]}")
  printf "  %-9s %11s %11s %7sx %11s %11s %7sx\n" "$c" \
    "$(med "${T_ON[$c]}")" "$lo" "$(awk -v a="$lo" -v b="$BON" 'BEGIN{printf "%.2f", (b>0)?a/b:0}')" \
    "$(med "${T_OFF[$c]}")" "$lf" "$(awk -v a="$lf" -v b="$BOFF" 'BEGIN{printf "%.2f", (b>0)?a/b:0}')"
done
echo
echo "  측정 중 가장 많이 찍힌 대기 이벤트 (100ms 간격 샘플링):"
for c in $CLIST; do
  printf "    clients=%-3s on: %-28s off: %s\n" "$c" "${W_ON[$c]:-?}" "${W_OFF[$c]:-?}"
done
echo

# ── 해석 — 전부 위 표에서 만든다 ──────────────────────────────────────
SECOND=$(echo $CLIST | awk '{print $2}')
if [ -z "${SECOND:-}" ]; then
  echo "해석: 클라이언트 값이 하나뿐이라 1→2 점프를 볼 수 없다. CLIST 에 둘 이상을 줘라."
  exit 0
fi
J_ON=$(awk -v a="$(med "${L_ON[$SECOND]}")" -v b="$BON" 'BEGIN{printf "%.2f", (b>0)?a/b:0}')
J_OFF=$(awk -v a="$(med "${L_OFF[$SECOND]}")" -v b="$BOFF" 'BEGIN{printf "%.2f", (b>0)?a/b:0}')

echo "해석:"
# **fsync 가 비싼가를 먼저 본다.** 같은 클라이언트 수에서 off/on 처리량 비가 그 답이다.
# 점프 유무로 먼저 가르면 안 된다 — 점프가 없는 데에는 두 가지 이유가 있고 정반대다.
LAST=$(echo $CLIST | awk '{print $NF}')
R1=$(awk -v a="$(med "${T_OFF[$FIRST]}")" -v b="$(med "${T_ON[$FIRST]}")" 'BEGIN{printf "%.2f",(b>0)?a/b:0}')
RN=$(awk -v a="$(med "${T_OFF[$LAST]}")"  -v b="$(med "${T_ON[$LAST]}")"  'BEGIN{printf "%.2f",(b>0)?a/b:0}')
# WAL 이 최상위였던 구간을 먼저 추린다 — 아래 두 단락이 모두 이걸 쓴다.
WALC=""; LOCKC=""
for c in $CLIST; do
  printf %s "${W_ON[$c]:-}"  | grep -qE "WALSync|WALWrite" && WALC="$WALC $c"
  # **^Lock. 로 앵커해야 한다.** 앵커 없이 Lock\\. 로 잡으면 LWLock.WALWrite 에도 걸린다 —
  # LWLock 은 경량 락(내부 구조 보호)이고 Lock 은 중량 락(행·테이블)이라 전혀 다른 얘기다.
  # 실제로 clients=8 의 LWLock.WALWrite 를 "행 락으로 병목이 옮겨 갔다"고 읽었다.
  { printf %s "${W_ON[$c]:-}" | grep -qE "^Lock\\." || \
    printf %s "${W_OFF[$c]:-}" | grep -qE "^Lock\\."; } && LOCKC="$LOCKC $c"
done
echo "  · fsync 는 비싼가 — off/on 처리량 비: clients=${FIRST} 에서 **${R1}배**, clients=${LAST} 에서 **${RN}배**."
# **분할상환 판정은 처리량 비가 아니라 WAL 대기 점유율로 한다.**
# 처음에 비로 판정했다가 "분할상환이 안 되고 있다"고 썼는데, 같은 출력의 대기 점유율은
# 51% → 29% → 20% 로 분명히 줄고 있었다 — 두 문장이 서로 모순됐다.
# 비가 안 줄어드는 것은 분할상환이 없어서가 아니라, on 이 WAL 천장에 닿는 동안
# off 는 계속 확장해서 격차가 유지되기 때문이다. 둘은 다른 얘기다.
# **WAL 이 최상위가 아닌 조건의 숫자를 'WAL 점유율'이라 부르면 안 된다.**
# 처음에 최상위 이벤트의 숫자를 무조건 뽑았다가, clients=8 의 Lock.transactionid 25% 를
# "WAL 점유율이 25% 로 줄었다"고 썼다. 다른 것의 점유율이다.
pct() { printf %s "${1:-}" | grep -oE '[0-9]+%' | head -1 | tr -d '%'; }
WF=$(echo $WALC | awk '{print $1}'); WL=$(echo $WALC | awk '{print $NF}')
SH1=""; SHN=""
if [ -n "${WF:-}" ] && [ "$WF" != "$WL" ]; then
  SH1=$(pct "${W_ON[$WF]:-}"); SHN=$(pct "${W_ON[$WL]:-}")
fi
if awk -v r="$R1" 'BEGIN{exit !(r+0<=1.2)}'; then
  echo "    ★ 가장 낮은 동시성에서도 차이가 없다 — **이 장비의 fsync 는 싸다**(쓰기 캐시·NVMe)."
  echo "      여기서는 synchronous_commit 으로 얻을 것이 없다."
else
  echo "    ★ **fsync 는 비싸다.** 가장 낮은 동시성에서 이미 ${R1}배 차다."
  if [ -n "${SH1:-}" ] && [ -n "${SHN:-}" ] && [ "$SHN" -lt "$SH1" ]; then
    echo "      그리고 WAL 대기 점유율이 clients=${WF} 의 ${SH1}% 에서 clients=${WL} 의 ${SHN}% 로"
    echo "      **줄어든다 — 그룹 커밋이 돌고 있다.** 여럿이 커밋하면 한 번의 flush 가 여러 커밋을"
    echo "      함께 실어 나르므로, 커밋 하나가 무는 fsync 비용이 동시성으로 갚아진다."
  fi
  if awk -v a="$RN" -v b="$R1" 'BEGIN{exit !(a+0 >= b*0.9)}'; then
    echo "      그런데 **처리량 격차는 안 줄어든다**(${R1}배 → ${RN}배). 분할상환이 없어서가 아니라,"
    echo "      on 이 WAL flush 속도라는 천장에 닿는 동안 off 는 계속 확장하기 때문이다 —"
    echo "      위 표의 on tps 가 어디서 평평해지는지 보라. 그 값이 이 장비의 커밋 상한이다."
  else
    echo "      처리량 격차도 ${R1}배 → ${RN}배로 줄어든다 — 분할상환이 격차까지 좁히고 있다."
  fi
fi
echo
echo "  · ${FIRST}→${SECOND} 지연 변화 — on: ${BON} → $(med "${L_ON[$SECOND]}") ms (**${J_ON}배**),"
echo "    off: ${BOFF} → $(med "${L_OFF[$SECOND]}") ms (**${J_OFF}배**)"
if awk -v j="$J_ON" 'BEGIN{exit !(j+0>1.2)}'; then
  if awk -v a="$J_OFF" -v b="$J_ON" 'BEGIN{exit !(a+0 < b*0.6)}'; then
    echo "    ★ **on 에서만 뛴다 — 그 점프는 fsync 다.** 둘이 되면 서로의 flush 를 기다리느라"
    echo "      지연이 붙고, 그 뒤로는 분할상환되어 더 안 는다."
  else
    echo "    ★ **off 로 바꿔도 점프가 남는다.** fsync 가 아니다 — 커밋을 안 기다려도 직렬화되는"
    echo "      지점이 있다는 뜻이고, 후보는 WAL 삽입 락이나 같은 행/페이지 경합이다."
    echo "      아래 대기 이벤트에서 LWLock 계열이 찍히는지 보라."
  fi
else
  echo "    ※ 이 실행에서는 on 에서 지연이 **뛰지 않았다**(오히려 줄었다면 1 클라이언트가"
  echo "      fsync 를 혼자 물고 있었다는 뜻이다). 위 off/on 비가 그 해석을 가른다 —"
  echo "      **'점프가 없다'를 'fsync 가 싸다'로 읽지 마라.** 둘은 다른 얘기다."
fi
echo
# 대기 이벤트는 추론이 아니라 직접 증거다. WAL 계열이 on 쪽에만 있으면 그게 답이다.
# **대기 이벤트를 읽어서 결론을 만든다.** 이걸 찍어 놓고 해석에 안 쓰면 그냥 장식이다.
# 위의 off/on 비는 '얼마나 손해인가'를, 이 열은 '무엇을 기다렸나'를 말한다.
#
# **전 구간을 훑어야 한다.** 처음에 clients=$LAST 하나만 봤는데, WAL 증거는 오히려
# **낮은 동시성에서 선명하다** — 혼자일수록 fsync 를 분할상환 못 하기 때문이다.
# 높은 동시성에서는 행 락에 밀려 회차마다 최상위가 뒤집힌다(실측: c=8 에서 한 번은
# IO.WALSync 19%, 다음 실행은 Lock.transactionid 23%). LAST 만 보면 그 회차에
# 어떤 게 올라왔느냐로 결론이 흔들린다.
echo "  · 대기 이벤트가 말하는 것 —"
for c in $CLIST; do
  printf "    clients=%-3s on: %-30s off: %s\n" "$c" "${W_ON[$c]:-?}" "${W_OFF[$c]:-?}"
done
if [ -n "$WALC" ]; then
  echo "    ★ **clients=${WALC# } 에서 on 쪽 최상위 대기가 WAL flush 다 — 추론이 아니라 관측이다.**"
  echo "      off 쪽에는 안 나온다. 위 처리량 차이의 원인이 fsync 라는 것이 여기서 확정된다."
  if [ -n "$LOCKC" ]; then
    echo "    ★ 그런데 clients=${LOCKC# } 에서는 Lock 계열이 올라온다 — **병목이 옮겨 간 것**이다."
    echo "      fsync 는 동시성이 오르면 분할상환되지만 행 락은 반대로 심해진다. 그래서"
    echo "      **높은 동시성에서는 WAL 증거가 오히려 흐려진다** — 낮은 쪽을 봐야 선명하다."
    echo "      synchronous_commit 을 꺼서 얻을 수 있는 상한도 그 다음 병목이 정한다."
  fi
elif printf %s "${W_ON[$FIRST]:-}" | grep -q "DataFileRead"; then
  echo "    ※ 최상위가 IO.DataFileRead 다 — **아직 캐시가 덜 찼다.** 이 측정은 WAL 이 아니라"
  echo "      읽기를 재고 있다. WARM 을 늘려 다시 재라(지금 ${WARM}초)."
else
  echo "    ※ 어느 조건에서도 WAL 계열이 최상위에 안 잡혔다. 위 해석은 처리량 차이에 근거한"
  echo "      추론이지 관측이 아니다 — ROUNDS 나 SECS 를 늘려 샘플을 더 모아 보라."
fi
echo
echo "  ⚠️ synchronous_commit=off 는 공짜가 아니다 — 크래시 시 **마지막 몇 백 ms 의 커밋이 사라진다.**"
echo "     데이터가 깨지지는 않는다(원자성은 유지). '커밋했다고 응답했는데 없어도 되는가'를"
echo "     업무로 판단해야 하는 설정이지, 성능만 보고 켜는 것이 아니다."
echo
echo "정리: 세션 단위로만 바꿨으므로 서버 설정은 그대로다 — 현재 $(q 'SHOW synchronous_commit')"
