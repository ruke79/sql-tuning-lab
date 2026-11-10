#!/usr/bin/env bash
# §X-5(책 밖) 온라인 인덱스 생성 — MySQL 쪽. ALGORITHM=INPLACE,LOCK=NONE
# (InnoDB 가 8.0 부터 공짜로 주는 온라인 인덱스 빌드) vs ALGORITHM=COPY
# (강제로 예전 방식을 재현 — 전체 테이블을 복사해 다시 만든다).
#
# 왜 중요한가 — §X-2/§X-3 은 "컬럼 타입을 바꾸는" 변경만 다뤘다. 실무에서
# "무중단 스키마 변경"의 또 다른 축은 **인덱스 추가**다. MySQL 은 InnoDB
# 온라인 DDL(5.6+)이 인덱스 생성을 기본으로 온라인화했다 — gh-ost 가 필요한
# 경우(타입 변경)와 달리, 인덱스는 보통 네이티브 ALTER 만으로 충분하다는 걸
# 이 실험이 보여준다.
#
# ⚠️ 이 로더(_loader-body.sh)는 §X-2 에서 실측으로 찾은 "배치 숨김 버그"를
# 피해 가는 동기식(coproc) 버전이다 — 과거의 "생성기 | mysql | while read"
# 구조로 쟀으면 ②(COPY)의 블로킹이 거의 안 보이는 식으로 완전히 틀린 결론이
# 나올 뻔했다(§X-2 참조).
#
# 사용법:
#   ./setup.sh 를 먼저 돌려 토폴로지를 준비해 둔다.
#   ./t-online-index.sh            # 전부
#   ONLY=1 ./t-online-index.sh     # INPLACE,LOCK=NONE 만
#   ONLY=2 ./t-online-index.sh     # COPY 강제만
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ONLY="${ONLY:-12}"
want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
LOADERS="${LOADERS:-4}"
PROBEDIR="${PROBEDIR:-/tmp/mysql-index-scratch/probe}"; mkdir -p "$PROBEDIR"

PRIMARY_HOST=127.0.0.1; PRIMARY_PORT=3310

if ! command -v mysql >/dev/null 2>&1; then
  echo "  [중단] 호스트에 mysql 클라이언트가 없다 — 배경 부하 접속에 필요하다."
  exit 1
fi
if ! PREFLIGHT=$(mysql -h "$PRIMARY_HOST" -P "$PRIMARY_PORT" -uroot -p"$MYROOT_PW" -e "SELECT 1" 2>&1); then
  echo "  [중단] primary(${PRIMARY_HOST}:${PRIMARY_PORT}) 접속 실패 — 실제 에러:"
  echo "$PREFLIGHT" | sed 's/^/    /'
  exit 1
fi

ROWS=$(P "SELECT count(*) FROM idxtest.orders" | tail -1)
case "$ROWS" in ''|*[!0-9]*) echo "  [중단] idxtest.orders 를 못 읽었다."; exit 1;; esac
echo "§X-5 온라인 인덱스 생성(MySQL) — ALGORITHM=INPLACE,LOCK=NONE vs COPY"
echo "  idxtest.orders ${ROWS}행 (amount 컬럼엔 아직 인덱스 없음)"
echo

. ./_exp-trap.inc

start_load() {
  local logfile="$1"
  : > "$logfile"
  for i in $(seq 1 "$LOADERS"); do
    LOADER_ROWS="$ROWS" LOADER_HOST="$PRIMARY_HOST" LOADER_PORT="$PRIMARY_PORT" \
    LOADER_PW="$MYROOT_PW" LOADER_IDX="$i" LOADER_LOG="$logfile" \
    setsid ./_loader-body.sh &
    EXP_PIDS="$EXP_PIDS $!"
  done
}
stop_load() { exp_kill_bg; }

verify_load_running() {
  local logfile="$1" before after tps i
  for i in 1 2 3; do
    before=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    sleep 2
    after=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    tps=$(( (after - before) / 2 ))
    if [ "$tps" -gt 0 ]; then
      echo "  배경 부하 확인: ${tps} writes/s (연결 ${LOADERS}개)"
      return 0
    fi
    echo "  배경 부하 확인: 0 writes/s — 재확인 ${i}/3"
  done
  echo "  [중단] 배경 부하가 안 돈다 — 이 상태로 재면 '쓰기 차단'이 무의미하다."
  return 1
}

max_gap_ms() {
  sort -n "$1" | awk '
    NR>1 { d=$1-prev; if (d>max) max=d }
    { prev=$1 }
    END { print max+0 }'
}

if want 1; then
echo "── ① ADD INDEX, ALGORITHM=INPLACE, LOCK=NONE — InnoDB 온라인 인덱스 빌드 ──"
P "DROP INDEX idx_amount ON idxtest.orders;" >/dev/null 2>&1
LOG="$PROBEDIR/inplace.log"
start_load "$LOG"
verify_load_running "$LOG" || { stop_load; exit 1; }
T0=$(date +%s%3N)
P "ALTER TABLE idxtest.orders ADD INDEX idx_amount (amount), ALGORITHM=INPLACE, LOCK=NONE;" >/dev/null
T1=$(date +%s%3N)
sleep 1
stop_load
DUR1=$(( T1 - T0 ))
GAP1=$(max_gap_ms "$LOG")
printf "  ALTER 소요: %sms   쓰기 로그 최대 공백: %sms\n" "$DUR1" "$GAP1"
echo "  → InnoDB 가 백그라운드로 B+트리를 만들고, 끝날 때 짧게 메타데이터 락만 잡는다."
echo "    gh-ost 같은 도구 없이도 네이티브 ALTER 하나로 거의 무중단이다."
P "DROP INDEX idx_amount ON idxtest.orders;" >/dev/null 2>&1
echo
fi

if want 2; then
echo "── ② 같은 인덱스를 ALGORITHM=COPY 로 강제 — 예전 방식(8.0 이전 기본) 재현 ──"
LOG="$PROBEDIR/copy.log"
start_load "$LOG"
verify_load_running "$LOG" || { stop_load; exit 1; }
T0=$(date +%s%3N)
P "ALTER TABLE idxtest.orders ADD INDEX idx_amount (amount), ALGORITHM=COPY;" >/dev/null
T1=$(date +%s%3N)
sleep 1
stop_load
DUR2=$(( T1 - T0 ))
GAP2=$(max_gap_ms "$LOG")
printf "  ALTER 소요: %sms (%.1f초)   쓰기 로그 최대 공백: %sms (%.1f초)\n" \
  "$DUR2" "$(awk -v d=$DUR2 'BEGIN{print d/1000}')" "$GAP2" "$(awk -v g=$GAP2 'BEGIN{print g/1000}')"
RATIO2=$(awk -v g="$GAP2" -v d="$DUR2" 'BEGIN{ if(d>0) printf "%.0f", g*100/d; else print "?" }')
echo "  → 최대 공백이 ALTER 전체 시간의 ${RATIO2}% 다 — COPY 는 테이블 전체를"
echo "    다시 써서 그 내내 쓰기를 막는다. 인덱스 추가에도 COPY 를 강제하면"
echo "    §X-2 의 MODIFY COPY(컬럼 타입 변경)와 같은 문제가 그대로 생긴다는 뜻이다."
P "DROP INDEX idx_amount ON idxtest.orders;" >/dev/null 2>&1
echo
fi

LAB_DONE=1
echo "정리: 실험 테이블(idxtest.orders)은 인덱스 없는 상태로 남겨 둔다."
echo "  토폴로지를 완전히 치우려면: ./teardown.sh"
