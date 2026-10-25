#!/usr/bin/env bash
# §X-3 진단용 — cutover(RENAME) 가 실제로 **무엇을 기다리는지** pg_locks/
# pg_stat_activity 를 0.1초마다 찍어서 직접 본다.
#
# 왜 필요한가. 부하 0 일 땐 31ms, 연결 1~4 개 중 아무거나 있으면 ~1,032ms로
# 고정되는 이진법적 패턴이 실측으로 나왔다(§9 후속3/4) — 추측으로는 더 못
# 좁힌다. cutover 가 도는 그 찰나에 누가 무슨 락을 들고 있고 누굴 기다리는지
# 직접 봐야 한다.
#
# 사용법: 토폴로지가 이미 떠 있고 LOADERS 는 기본값(4) 수준의 배경 부하가
# 걸릴 수 있는 상태라고 가정한다.
#   ./diag-cutover-locks.sh
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

PRIMARY_HOST=127.0.0.1; PRIMARY_PORT=5433
ROWS="${ROWS:-10000000}"
PSQL_P() { PGPASSWORD="$PGPASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -d pgosctest -v ON_ERROR_STOP=1 -At "$@"; }
LOGDIR="${LOGDIR:-/tmp/pg-osc-scratch/probe}"; mkdir -p "$LOGDIR"
LOCKLOG="$LOGDIR/cutover-locks.log"

echo "── 원복 + 섀도 컬럼 + 백필 (아직 부하 없음) ──"
PSQL_P -c "ALTER TABLE orders ALTER COLUMN cust_id TYPE INT;" >/dev/null 2>&1
PSQL_P -c "ALTER TABLE orders DROP COLUMN IF EXISTS cust_id_new, DROP COLUMN IF EXISTS cust_id_old;" >/dev/null 2>&1
PSQL_P -c "DROP TRIGGER IF EXISTS cust_id_sync ON orders;" >/dev/null 2>&1
PSQL_P -c "DROP FUNCTION IF EXISTS cust_id_sync_fn();" >/dev/null 2>&1
PSQL_P -c "ALTER TABLE orders ADD COLUMN cust_id_new BIGINT;" >/dev/null
PSQL_P -c "UPDATE orders SET cust_id_new = cust_id;" >/dev/null
echo "완료."

echo "── 배경 부하(연결 1개, 끊김 없이) 시작 ──"
setsid bash -c '
  while true; do
    id=$(( (RANDOM * RANDOM) % '"$ROWS"' + 1 ))
    echo "UPDATE orders SET amount=amount+1 WHERE id=$id;"
  done | PGPASSWORD="'"$PGPASS"'" psql -h "'"$PRIMARY_HOST"'" -p "'"$PRIMARY_PORT"'" -U postgres -d pgosctest -v ON_ERROR_STOP=0 -At >/dev/null 2>&1
' &
LOAD_PID=$!
trap 'kill -- "-$LOAD_PID" 2>/dev/null' EXIT
sleep 2

echo "── 0.1초마다 pg_locks/pg_stat_activity 샘플링 시작 ──"
: > "$LOCKLOG"
( while true; do
    echo "=== $(date +%s%3N) ===" >> "$LOCKLOG"
    PSQL_P -c "
      SELECT now(), pid, mode, granted, relation::regclass, wait_event_type, wait_event
      FROM pg_locks l LEFT JOIN pg_stat_activity a USING (pid)
      WHERE relation = 'orders'::regclass;
    " >> "$LOCKLOG" 2>&1
    sleep 0.1
  done ) &
SAMPLER_PID=$!

sleep 0.5
echo "── cutover 시작 ──"
T0=$(date +%s%3N)
PSQL_P -c "
  BEGIN;
  ALTER TABLE orders RENAME COLUMN cust_id TO cust_id_old;
  ALTER TABLE orders RENAME COLUMN cust_id_new TO cust_id;
  COMMIT;
"
T1=$(date +%s%3N)
sleep 0.5

kill "$SAMPLER_PID" 2>/dev/null
kill -- "-$LOAD_PID" 2>/dev/null
trap - EXIT

echo
echo "cutover 소요(부하 1개): $(( T1 - T0 ))ms"
echo "락 샘플 로그: $LOCKLOG"
PSQL_P -c "ALTER TABLE orders DROP COLUMN IF EXISTS cust_id_old;" >/dev/null 2>&1
