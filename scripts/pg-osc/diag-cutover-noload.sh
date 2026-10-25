#!/usr/bin/env bash
# §X-3 진단용 — 배경 부하 **전혀 없이** cutover(RENAME) 블로킹만 단독으로 잰다.
# "~1,032ms 고정 비용이 배경 부하와 무관하다"는 가설(§9 후속3)을 마저 검증한다:
# 부하가 0인데도 ~1,032ms 가 나오면 락 경합이 아니라 다른 고정 비용(연결 수립,
# 카탈로그 캐시 무효화, 체크포인트 등)을 의심해야 한다.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

PRIMARY_HOST=127.0.0.1; PRIMARY_PORT=5433
PSQL_P() { PGPASSWORD="$PGPASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -d pgosctest -v ON_ERROR_STOP=1 -Atq "$@"; }

echo "── 원복 + 섀도 컬럼 준비 (부하 없음) ──"
PSQL_P -c "ALTER TABLE orders ALTER COLUMN cust_id TYPE INT;" >/dev/null 2>&1
PSQL_P -c "ALTER TABLE orders DROP COLUMN IF EXISTS cust_id_new, DROP COLUMN IF EXISTS cust_id_old;" >/dev/null 2>&1
PSQL_P -c "DROP TRIGGER IF EXISTS cust_id_sync ON orders;" >/dev/null 2>&1
PSQL_P -c "DROP FUNCTION IF EXISTS cust_id_sync_fn();" >/dev/null 2>&1
PSQL_P -c "ALTER TABLE orders ADD COLUMN cust_id_new BIGINT;" >/dev/null
echo "── 백필(단건 UPDATE, 부하 없는 상태라 느긋하게) ──"
PSQL_P -c "UPDATE orders SET cust_id_new = cust_id;" >/dev/null
echo "완료. cutover 측정 시작..."

T0=$(date +%s%3N)
PSQL_P -c "
  BEGIN;
  ALTER TABLE orders RENAME COLUMN cust_id TO cust_id_old;
  ALTER TABLE orders RENAME COLUMN cust_id_new TO cust_id;
  COMMIT;
"
T1=$(date +%s%3N)
echo
echo "cutover 소요(부하 0): $(( T1 - T0 ))ms"

PSQL_P -c "ALTER TABLE orders DROP COLUMN IF EXISTS cust_id_old;" >/dev/null
