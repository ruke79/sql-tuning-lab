#!/usr/bin/env bash
# §X-5(책 밖) 온라인 인덱스 생성 — PostgreSQL 쪽 토폴로지 준비. 단일 컨테이너
# (복제 불필요 — 인덱스 생성 블로킹 자체를 보는 실험이라 대조군 replica 가
# 필요 없다).
#
# 사용법:
#   ./setup.sh                      # 기본: 1,000만 행
#   ROWS=1000000 ./setup.sh         # 빠른 반복용
#   FORCE=1 ./setup.sh              # 이미 떠 있어도 지우고 다시
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ROWS="${ROWS:-10000000}"

. ./_docker-trap.inc

existing=$(idx_container_count)
if [ "${existing:-0}" -ge 1 ] && [ "${FORCE:-0}" != "1" ]; then
  echo "  이미 떠 있다 — 그대로 쓴다(FORCE=1 로 다시 만들 수 있다)."
  cnt=$(P "SELECT count(*) FROM orders;" 2>/dev/null)
  echo "  orders 행 수: ${cnt:-?}"
  LAB_DONE=1
  exit 0
fi
idx_cleanup

echo "── 컨테이너 기동 ──"
docker run -d --name idx-pg -p 127.0.0.1:5436:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16 >/dev/null
wait_container_ready idx-pg
echo "  idx-pg ready"

PD "CREATE DATABASE idxtest;" >/dev/null 2>&1
P "ALTER USER postgres PASSWORD '$PGPASS';" >/dev/null

echo
echo "── 테스트 테이블 준비 (${ROWS}행, amount 에는 인덱스 없음) ──"
P "CREATE TABLE orders (
     id BIGINT PRIMARY KEY,
     cust_id INT NOT NULL,
     amount NUMERIC(12,2) NOT NULL DEFAULT 0
   );"

# pg-osc/setup-topology.sh 와 같은 배증+행수기준 트림 패턴(§X-3 참조).
P "INSERT INTO orders VALUES (1, 1, 1.00);" >/dev/null
n=1
while [ "$n" -lt "$ROWS" ]; do
  before="$n"
  out=$(P "INSERT INTO orders SELECT id + (SELECT max(id) FROM orders), (cust_id+1)%1000000, amount FROM orders;")
  if echo "$out" | grep -qi "ERROR"; then
    echo "  [중단] 배증 중 SQL 에러 (n=$n): $out"; exit 1
  fi
  n=$(P "SELECT count(*) FROM orders;")
  case "$n" in ''|*[!0-9]*) echo "  [중단] 행 수를 못 읽었다: '$n'"; exit 1;; esac
  if [ "$n" -le "$before" ]; then
    echo "  [중단] 배증이 실제로 안 먹혔다 — ${before}행 그대로다."; exit 1
  fi
done
excess=$((n - ROWS))
if [ "$excess" -gt 0 ]; then
  P "DELETE FROM orders WHERE id IN (SELECT id FROM orders ORDER BY id DESC LIMIT $excess);" >/dev/null
fi
actual=$(P "SELECT count(*) FROM orders;")
echo "  적재 완료: ${actual}행"
P "ALTER TABLE orders SET (autovacuum_enabled=false); VACUUM ANALYZE orders; ALTER TABLE orders RESET (autovacuum_enabled);" >/dev/null 2>&1

LAB_DONE=1
echo
echo "완료. 실험은 ./t-pg-index.sh 로 돌린다."
