#!/usr/bin/env bash
# §X-3 진단용 — orders 테이블의 pg_locks/pg_stat_activity 를 0.1초마다 계속
# 찍는다. **실제 ③번 실험과 동시에, 별도 터미널에서** 돌린다 — 독립된 진단
# 스크립트(diag-cutover-locks.sh)는 조건이 달라서 ~1,032ms 현상을 재현하지
# 못했다(단발 UPDATE 백필 + 짧은 대기 뒤 cutover). 실제 조건(배치 백필 전체를
# 끝내고 바로 이어지는 cutover)에서 봐야 한다.
#
# 사용법 — 터미널 A 에서:
#   ./watch-locks.sh
# 터미널 B 에서 동시에:
#   BATCHES=10000 ONLY=3 ./t-pg-ddl.sh
# ③번이 "cutover블록(ms)" 줄을 찍을 즈음의 로그를 본다 — granted=f(대기 중)
# 인 줄, 그리고 wait_event/wait_event_type 이 뭔지가 핵심이다.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh
PRIMARY_HOST=127.0.0.1; PRIMARY_PORT=5433
PSQL_P() { PGPASSWORD="$PGPASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -d pgosctest -v ON_ERROR_STOP=1 -At "$@"; }
LOGDIR="${LOGDIR:-/tmp/pg-osc-scratch/probe}"; mkdir -p "$LOGDIR"
LOCKLOG="$LOGDIR/watch-locks-$(date +%Y%m%d-%H%M%S).log"
echo "로그: $LOCKLOG"
: > "$LOCKLOG"
while true; do
  echo "=== $(date +%H:%M:%S.%3N) ===" >> "$LOCKLOG"
  PSQL_P -c "
    SELECT pid, mode, granted, relation::regclass, state, wait_event_type, wait_event,
           left(query, 60) AS query
    FROM pg_locks l LEFT JOIN pg_stat_activity a USING (pid)
    WHERE relation = 'orders'::regclass
       OR (query ILIKE '%RENAME COLUMN%' AND state != 'idle');
  " >> "$LOCKLOG" 2>&1
  sleep 0.1
done
