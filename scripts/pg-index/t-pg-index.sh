#!/usr/bin/env bash
# §X-5(책 밖) 온라인 인덱스 생성 — PostgreSQL 쪽. 일반 `CREATE INDEX`(SHARE
# 락, 쓰기 차단) vs `CREATE INDEX CONCURRENTLY`(비차단, 2-pass) vs
# CONCURRENTLY 가 중간에 죽으면 남는 INVALID 인덱스 함정.
#
# ⚠️ ①(일반 CREATE INDEX)의 블로킹을 처음 쟀을 때 구버전 로더("생성기 | psql
# | while read")로는 **2~115ms**(거의 안 막힘)로 나왔다 — 완전히 틀렸다.
# 동기식(coproc) 로더로 다시 재니 실제로는 **1,104ms/1,141ms = 97%**가
# 막혀 있었다(§X-2 "cutover 재검증" 경고 참조). 이 스크립트는 처음부터
# 그 동기식 로더(_loader-body.sh)를 쓴다.
#
# 사용법:
#   ./setup.sh 를 먼저 돌려 토폴로지를 준비해 둔다.
#   ./t-pg-index.sh            # 전부
#   ONLY=1 ./t-pg-index.sh     # 일반 CREATE INDEX 만
#   ONLY=2 ./t-pg-index.sh     # CONCURRENTLY 만
#   ONLY=3 ./t-pg-index.sh     # INVALID 함정 데모만
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ONLY="${ONLY:-123}"
want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
LOADERS="${LOADERS:-4}"
PROBEDIR="${PROBEDIR:-/tmp/pg-index-scratch/probe}"; mkdir -p "$PROBEDIR"

PRIMARY_HOST=127.0.0.1; PRIMARY_PORT=5436

if ! command -v psql >/dev/null 2>&1; then
  echo "  [중단] 호스트에 psql 클라이언트가 없다 — 배경 부하 접속에 필요하다."
  exit 1
fi
if ! PREFLIGHT=$(PGPASSWORD="$PGPASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -d idxtest -tAc "SELECT 1" 2>&1); then
  echo "  [중단] primary(${PRIMARY_HOST}:${PRIMARY_PORT}) 접속 실패 — 실제 에러:"
  echo "$PREFLIGHT" | sed 's/^/    /'
  exit 1
fi

ROWS=$(P "SELECT count(*) FROM orders;")
case "$ROWS" in ''|*[!0-9]*) echo "  [중단] orders 를 못 읽었다."; exit 1;; esac
echo "§X-5 온라인 인덱스 생성(PostgreSQL) — 일반 CREATE INDEX vs CONCURRENTLY"
echo "  orders ${ROWS}행 (amount 컬럼엔 아직 인덱스 없음)"
echo

. ./_exp-trap.inc

start_load() {
  local logfile="$1"
  : > "$logfile"
  for i in $(seq 1 "$LOADERS"); do
    LOADER_ROWS="$ROWS" LOADER_HOST="$PRIMARY_HOST" LOADER_PORT="$PRIMARY_PORT" \
    LOADER_PW="$PGPASS" LOADER_IDX="$i" LOADER_LOG="$logfile" \
    setsid "$(dirname "$0")/_loader-body.sh" &
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
echo "── ① CREATE INDEX (일반, SHARE 락) ──"
P "DROP INDEX IF EXISTS idx_amount;" >/dev/null 2>&1
LOG="$PROBEDIR/plain.log"
start_load "$LOG"
verify_load_running "$LOG" || { stop_load; exit 1; }
T0=$(date +%s%3N)
P "CREATE INDEX idx_amount ON orders(amount);" >/dev/null
T1=$(date +%s%3N)
sleep 1
stop_load
DUR1=$(( T1 - T0 ))
GAP1=$(max_gap_ms "$LOG")
RATIO1=$(awk -v g="$GAP1" -v d="$DUR1" 'BEGIN{ if(d>0) printf "%.0f", g*100/d; else print "?" }')
printf "  CREATE INDEX 소요: %sms   쓰기 로그 최대 공백: %sms (%s%%)\n" "$DUR1" "$GAP1" "$RATIO1"
echo "  → SHARE 락은 쓰기(UPDATE/INSERT/DELETE)를 ALTER 가 끝날 때까지 전부 막는다"
echo "    (읽기는 된다 — MySQL COPY 와 달리 이 점은 PG 가 낫다). MySQL 의 ALGORITHM=COPY"
echo "    와 성격이 같다 — 인덱스 추가도 '그냥 돌리면' 전체 시간이 차단 구간이 된다."
P "DROP INDEX IF EXISTS idx_amount;" >/dev/null 2>&1
echo
fi

if want 2; then
echo "── ② CREATE INDEX CONCURRENTLY — 2-pass, 비차단 ──"
LOG="$PROBEDIR/concurrent.log"
start_load "$LOG"
verify_load_running "$LOG" || { stop_load; exit 1; }
T0=$(date +%s%3N)
P "CREATE INDEX CONCURRENTLY idx_amount ON orders(amount);" >/dev/null
T1=$(date +%s%3N)
sleep 1
stop_load
DUR2=$(( T1 - T0 ))
GAP2=$(max_gap_ms "$LOG")
RATIO2=$(awk -v g="$GAP2" -v d="$DUR2" 'BEGIN{ if(d>0) printf "%.0f", g*100/d; else print "?" }')
printf "  CREATE INDEX CONCURRENTLY 소요: %sms   쓰기 로그 최대 공백: %sms (%s%%)\n" "$DUR2" "$GAP2" "$RATIO2"
if [ -n "${DUR1:-}" ]; then
  echo "  → ①(${DUR1}ms, ${RATIO1:-?}% 차단)과 비교하면 전체 소요는 더 길어졌지만"
  echo "    (2-pass + 대기 때문) 차단 비율은 훨씬 낮다 — gh-ost 와 같은 교환이다:"
  echo "    '더 오래 걸리지만 덜 막는다'."
fi
echo "  → MySQL 의 ALGORITHM=INPLACE,LOCK=NONE 과 같은 자리를 차지한다 — 단,"
echo "    PostgreSQL 은 이걸 **옵션으로 명시**해야 한다(기본값이 아니다). 깜빡하고"
echo "    CONCURRENTLY 를 안 쓰면 ①로 돌아간다는 게 실무 함정이다."
P "DROP INDEX IF EXISTS idx_amount;" >/dev/null 2>&1
echo
fi

if want 3; then
echo "── ③ CONCURRENTLY 빌드 중 강제 종료 → INVALID 인덱스 함정 ──"
P "DROP INDEX IF EXISTS idx_amount;" >/dev/null 2>&1
( PGPASSWORD="$PGPASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -d idxtest -v ON_ERROR_STOP=1 -At \
    -c "CREATE INDEX CONCURRENTLY idx_amount ON orders(amount);" >/dev/null 2>&1 & )
sleep 0.3
BPID=$(P "SELECT pid FROM pg_stat_activity WHERE query ILIKE '%CREATE INDEX CONCURRENTLY%' LIMIT 1;")
if [ -z "$BPID" ]; then
  echo "  [주의] 빌드 중인 backend 를 못 찾았다 — 10,000,000행처럼 느린 환경에서"
  echo "         다시 시도하라. 작은 행수에서는 빌드가 0.3초보다 먼저 끝날 수 있다."
else
  echo "  빌드 중인 backend pid=$BPID 를 강제 종료한다(가정: 배포 중 배포 파이프라인이"
  echo "  타임아웃으로 죽이거나, DBA 가 실수로 kill 하는 상황)"
  P "SELECT pg_terminate_backend($BPID);" >/dev/null
  sleep 1
  echo "  인덱스 상태(indexrelid, indisvalid, indisready):"
  P "SELECT indexrelid::regclass, indisvalid, indisready FROM pg_index WHERE indexrelid='idx_amount'::regclass;" \
    | sed 's/^/    /'
  echo "  → indisvalid=f 면 이 인덱스는 **플래너가 쓰지 않는다** — 그냥 둬도 디스크"
  echo "    공간만 먹고 아무 도움이 안 된다. 평범한 DROP INDEX 로 지울 수는 있지만"
  echo "    그건 다시 ACCESS EXCLUSIVE 를 잡는다 — 지울 때도 CONCURRENTLY 를 써야"
  echo "    처음부터 끝까지 무중단을 지킬 수 있다."
fi
P "DROP INDEX CONCURRENTLY IF EXISTS idx_amount;" >/dev/null 2>&1
echo
fi

LAB_DONE=1
echo "정리: 실험 테이블(orders)은 인덱스 없는 상태로 남겨 둔다."
echo "  토폴로지를 완전히 치우려면: ./teardown.sh"
