#!/usr/bin/env bash
# §X-5(책 밖) 온라인 인덱스 생성 — MySQL 쪽 토폴로지 준비.
#
# 복제가 필요 없다(§X-2/§9 의 gh-ost 쓰로틀과 달리, 인덱스 생성 블로킹 자체를
# 보는 거라 대조군 replica 가 필요 없다) — 단일 컨테이너로 충분하다.
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
  # ⚠️ "있다"(docker ps -a)와 "떠서 돈다"는 다른 상태다(mysql-osc/pg-osc 에서
  # 실측으로 겪었다 — 멈춰 있는데 바로 쿼리해서 "is not running" 에러) — 켜고 쓴다.
  echo "  이미 있다 — 멈춰 있으면 켜고 그대로 쓴다(FORCE=1 로 다시 만들 수 있다)."
  docker start idx-mysql >/dev/null 2>&1
  wait_container_ready idx-mysql || exit 1
  cnt=$(P "SELECT count(*) FROM idxtest.orders" 2>/dev/null | tail -1)
  echo "  idxtest.orders 행 수: ${cnt:-?}"
  LAB_DONE=1
  exit 0
fi
idx_cleanup

echo "── 컨테이너 기동 ──"
docker run -d --name idx-mysql -p 127.0.0.1:3310:3306 -e MYSQL_ROOT_PASSWORD="$MYROOT_PW" mysql:8.4 >/dev/null
wait_container_ready idx-mysql
echo "  idx-mysql ready"

P "ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYROOT_PW'; FLUSH PRIVILEGES;" >/dev/null

echo
echo "── 테스트 테이블 준비 (${ROWS}행, amount 에는 인덱스 없음) ──"
P "DROP DATABASE IF EXISTS idxtest; CREATE DATABASE idxtest;
   CREATE TABLE idxtest.orders (
     id BIGINT PRIMARY KEY AUTO_INCREMENT,
     cust_id INT NOT NULL,
     amount INT NOT NULL,
     created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
   ) ENGINE=InnoDB;"

# mysql-osc/setup-topology.sh 와 같은 배증+행수기준 트림 패턴(§9 참조) — id 값
# 기준으로 깎으면 AUTO_INCREMENT 의 interleaved 모드 때문에 틀어진다.
P "INSERT INTO idxtest.orders (cust_id, amount) VALUES (1, 100);" >/dev/null
n=1
while [ "$n" -lt "$ROWS" ]; do
  before="$n"
  out=$(P "INSERT INTO idxtest.orders (cust_id, amount)
       SELECT FLOOR(RAND()*1000000)+1, FLOOR(RAND()*100000)+1 FROM idxtest.orders;")
  if echo "$out" | grep -qi "ERROR"; then
    echo "  [중단] 배증 중 SQL 에러 (n=$n): $out"; exit 1
  fi
  n=$(P "SELECT count(*) FROM idxtest.orders" | tail -1)
  case "$n" in ''|*[!0-9]*) echo "  [중단] 행 수를 못 읽었다: '$n'"; exit 1;; esac
  if [ "$n" -le "$before" ]; then
    echo "  [중단] 배증이 실제로 안 먹혔다 — ${before}행 그대로다."; exit 1
  fi
done
excess=$((n - ROWS))
[ "$excess" -gt 0 ] && P "DELETE FROM idxtest.orders ORDER BY id DESC LIMIT $excess;" >/dev/null
actual=$(P "SELECT count(*) FROM idxtest.orders" | tail -1)
echo "  적재 완료: ${actual}행"

LAB_DONE=1
echo
echo "완료. 실험은 ./t-online-index.sh 로 돌린다."
