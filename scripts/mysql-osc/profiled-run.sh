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

# ── 이미 돌고 있는 t-online-ddl.sh 가 있으면 **완전히 끝날 때까지** 기다린다.
#    ⚠️ 처음엔 gh-ost **바이너리**가 떠 있는지만 봤다 — 그런데 t-online-ddl.sh
#    는 청크 사이사이(100→1000→10000)에 restore_to_int()(COPY, 수 초~수십 초)와
#    배경 부하 재확인을 하는 **gh-ost 가 안 떠 있는 빈 구간**이 있다. 실측으로
#    바로 이 구간에서 사고가 났다: 하필 그 빈 구간에 이 스크립트가 "gh-ost
#    없네, 끝났다"고 오판하고 자기 몫을 시작해버렸고, 원래 실행이 곧이어 자기
#    chunk=1000 을 시작하면서 **두 gh-ost 가 같은 테이블을 동시에 마이그레이션**
#    하려다 "FATAL another gh-ost process is already migrating ... lock held
#    by connection id ..." 로 충돌했다. gh-ost 가 아니라 **오케스트레이터
#    스크립트 자신**(t-online-ddl.sh)이 완전히 끝났는지를 봐야 한다 — 청크
#    사이 빈 구간에도 그 프로세스는 계속 살아있다. ──
if pgrep -f '[t]-online-ddl.sh' >/dev/null 2>&1; then
  echo "── 이미 돌고 있는 t-online-ddl.sh 가 있다 — 완전히 끝날 때까지 기다린다 ──"
  while pgrep -f '[t]-online-ddl.sh' >/dev/null 2>&1; do
    sleep 5
  done
  echo "  끝났다. 이어서 시작한다."
fi
# gh-ost 자체도 한 번 더 — t-online-ddl.sh 가 막 끝났어도 그 자식 gh-ost 가
# 정리 중일 수 있다(§9 의 Ctrl-C 경합 기록 참조).
while pgrep -f '[g]h-ost' >/dev/null 2>&1; do
  sleep 2
done

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
