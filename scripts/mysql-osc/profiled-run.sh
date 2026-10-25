#!/usr/bin/env bash
# scripts/mysql-osc 전용 — 이미 돌고 있는 gh-ost(예: 수동으로 먼저 돌려둔
# CHUNKS=100)가 끝나길 기다렸다가, 이어서 지정한 CHUNKS 를 실행하면서
# monitor.sh 의 프로파일링 수치(버퍼풀 히트율·fsync/초·처리량)를 같은
# 타임라인으로 로그에 남긴다.
#
# 왜 필요한가. t-online-ddl.sh 는 CHUNKS 안의 값을 순차로 돌지만, 이미 따로
# 손으로 돌려 둔 실행(예: chunk=100 만 먼저 돌린 경우)을 이어받아 "남은
# 청크들"을 자동으로 잇는 기능은 없다. 그리고 gh-ost 자신의 Copy/ETA 로그는
# "얼마나 갔는지"는 보여줘도 "왜 느린지"는 안 보여준다 — monitor.sh 를 같이
# 돌려서 그 답을 같은 시각 기준으로 남긴다.
#
# 사용법:
#   ./scripts/mysql-osc/profiled-run.sh                        # 기본: CHUNKS="1000 10000", ONLY=3
#   CHUNKS="1000 10000" ./scripts/mysql-osc/profiled-run.sh
#   ONLY=34 CHUNKS=10000 ./scripts/mysql-osc/profiled-run.sh    # ③④ 둘 다
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

CHUNKS="${CHUNKS:-1000 10000}"
ONLY="${ONLY:-3}"
LOGDIR="${LOGDIR:-/tmp/mysql-osc-scratch/profile-runs}"
mkdir -p "$LOGDIR"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOGDIR/run-$TS.log"
MON_LOG="$LOGDIR/monitor-$TS.log"

echo "실행 로그: $RUN_LOG"
echo "모니터 로그: $MON_LOG"

# ── 이미 돌고 있는 gh-ost 가 있으면 끝날 때까지 기다린다. 두 gh-ost 가 동시에
#    같은 unix 소켓(/tmp/gh-ost.osctest.orders.sock)을 쓰려 하면 뒤에 뜬 쪽이
#    "bind: address already in use" 로 즉사한다(§9 기록에 실측 있음) — 먼저
#    뜬 걸 존중하고 기다린다. `[g]h-ost` 는 pgrep 자신이 자기 패턴에 걸리는 걸
#    피하는 관용구다(이 디렉터리에서 pkill -f 가 자기 쉘을 죽인 전례가 있다 —
#    같은 함정을 pgrep 에서도 피한다). ──
if pgrep -f '[g]h-ost' >/dev/null 2>&1; then
  echo "── 이미 돌고 있는 gh-ost 가 있다 — 끝날 때까지 기다린다 ──"
  while pgrep -f '[g]h-ost' >/dev/null 2>&1; do
    sleep 5
  done
  echo "  끝났다. 이어서 시작한다."
fi

# ── monitor.sh 를 백그라운드로 띄워 같은 타임라인에 남긴다. ──
./monitor.sh > "$MON_LOG" 2>&1 &
MON_PID=$!
trap 'kill "$MON_PID" 2>/dev/null' EXIT

echo "── CHUNKS=\"$CHUNKS\" ONLY=$ONLY 시작 ──"
CHUNKS="$CHUNKS" ONLY="$ONLY" ./t-online-ddl.sh 2>&1 | tee "$RUN_LOG"

kill "$MON_PID" 2>/dev/null
trap - EXIT
echo
echo "완료."
echo "  실행 로그: $RUN_LOG"
echo "  모니터 로그: $MON_LOG"
