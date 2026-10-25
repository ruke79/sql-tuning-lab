#!/usr/bin/env bash
# §X-3(책 밖) 무정지 스키마 변경 — PostgreSQL 판 — 토폴로지 준비.
#
# MySQL 판(scripts/mysql-osc)과 구조는 같다: 1 primary + replica 2개(정상 1 /
# 지연 1)를 Docker 로 띄우고 물리 스트리밍 복제를 건다. 왜 PG 는 다른 구조로
# 가야 하는가 — MySQL 은 replica 가 **빈 상태로 시작**해서 CHANGE REPLICATION
# SOURCE 로 특정 binlog 위치부터 스트리밍을 받으면 되지만, PostgreSQL 물리
# 복제는 **진짜 베이스 백업**(pg_basebackup)이 있어야 한다 — 그래서 primary 를
# 먼저 띄우고, pg_basebackup 으로 데이터 디렉터리를 복사해 그걸로 replica 를
# 띄운다.
#
# replica2 의 인위적 지연은 MySQL 의 SOURCE_DELAY 에 정확히 대응하는 PG 설정
# `recovery_min_apply_delay` 로 만든다 — WAL 을 다 받아놓고도 재생(replay)만
# 그만큼 늦춘다.
#
# 사용법:
#   ./setup-topology.sh                   # 기본: 1,000만 행
#   ROWS=1000000 ./setup-topology.sh      # 빠른 반복용 — 100만 행
#   REPLICA_DELAY=30 ./setup-topology.sh  # replica2 지연 초 (기본 30)
#   FORCE=1 ./setup-topology.sh           # 이미 떠 있어도 지우고 다시
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ROWS="${ROWS:-10000000}"
REPLICA_DELAY="${REPLICA_DELAY:-30}"
PG_NET="${PG_NET:-pg-osc-net}"
PG_CONTAINERS="pg-primary pg-replica1 pg-replica2"
PG_VOLUMES="pg-osc-primary-data pg-osc-replica1-data pg-osc-replica2-data"

. ./_docker-trap.inc

pg_osc_container_count() {
  docker ps -a --filter "name=pg-" --format '{{.Names}}' 2>/dev/null | grep -c '^pg-' || true
}

# ⚠️ _docker-trap.inc 는 scripts/mysql-osc 에서 OSC_CONTAINERS="osc-*" 로 만든
# 범용 트랩을 그대로 복사해왔다 — 여기서는 이름이 다르므로(pg-*) 그 변수들을
# 덮어써야 한다. osc_cleanup/osc_container_count 는 OSC_CONTAINERS/OSC_NET 을
# 참조하므로, 여기 맞게 재정의한다.
OSC_NET="$PG_NET"
OSC_CONTAINERS="$PG_CONTAINERS"
osc_cleanup() {
  for c in $PG_CONTAINERS; do docker rm -fv "$c" >/dev/null 2>&1; done
  for v in $PG_VOLUMES; do docker volume rm "$v" >/dev/null 2>&1; done
  docker network rm "$PG_NET" >/dev/null 2>&1
}
osc_container_count() { pg_osc_container_count; }

existing=$(pg_osc_container_count)
if [ "${existing:-0}" -ge 3 ] && [ "${FORCE:-0}" != "1" ]; then
  echo "  이미 ${existing}개 떠 있다 — 그대로 쓴다(FORCE=1 로 다시 만들 수 있다)."
  cnt=$(P "SELECT count(*) FROM orders" 2>/dev/null)
  echo "  orders 행 수: ${cnt:-?}"
  LAB_DONE=1
  exit 0
fi
osc_cleanup

echo "── primary 기동 ──"
docker network create "$PG_NET" >/dev/null
docker volume create pg-osc-primary-data >/dev/null
docker run -d --name pg-primary --network "$PG_NET" -p 127.0.0.1:5433:5432 \
  -v pg-osc-primary-data:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:16 \
  -c wal_level=replica -c max_wal_senders=10 -c max_replication_slots=10 \
  -c hot_standby=on >/dev/null
wait_container_ready pg-primary || exit 1
echo "  pg-primary ready"

echo
echo "── 복제 계정 + 베이스 백업으로 replica 2개 준비 ──"
# ⚠️ 여기서 에러를 숨기면(>/dev/null 2>&1) CREATE ROLE 이 일시적으로 실패해도
# 아무도 모른다 — 실측: 바로 이 자리에서 CREATE ROLE 이 조용히 실패했고,
# 증상은 몇 단계 뒤(pg_basebackup 이 "role replicator does not exist")에서야
# 나타났다. "ready for connections" 가 로그에 찍혀도 DDL 이 즉시 다 되는 건
# 아닐 수 있다는 게 이 디렉터리에서 반복되는 교훈이다(wait_container_ready 의
# 주석 참조) — 여기도 같은 패턴이라 재시도 + 실제 확인을 넣는다.
for i in 1 2 3 4 5; do
  PD "CREATE ROLE replicator WITH REPLICATION LOGIN;" >/dev/null 2>&1
  [ "$(PD "SELECT 1 FROM pg_roles WHERE rolname='replicator';")" = "1" ] && break
  sleep 1
done
if [ "$(PD "SELECT 1 FROM pg_roles WHERE rolname='replicator';")" != "1" ]; then
  echo "  [중단] replicator 롤을 5번 재시도해도 못 만들었다."
  exit 1
fi
# ⚠️ POSTGRES_HOST_AUTH_METHOD=trust 는 `host all all all trust` 한 줄만
# pg_hba.conf 에 추가한다 — pg_hba.conf 에서 "replication" 은 database 필드의
# "all" 에 **포함되지 않는** 별도 항목이다(공식 문서에 명시돼 있다). 그래서
# 다른 컨테이너(replica1/2)에서 오는 복제 연결은 루프백 전용 줄에만 걸려
# 거부된다(실측: "no pg_hba.conf entry for replication connection from host
# ..." — pg_basebackup 이 이 에러로 실패하면서 볼륨이 빈 채로 남았고, 그
# 빈 볼륨으로 replica 컨테이너를 올리니 엔트리포인트가 "uninitialized" 로
# 보고 다시 initdb 를 요구했다 — 진짜 원인은 몇 단계 전인데 증상은 전혀
# 다른 곳[replica 컨테이너 기동]에서 나타났다). 복제 전용 줄을 명시적으로
# 추가하고 반영한다.
docker exec -u postgres pg-primary bash -c \
  "echo 'host replication all all trust' >> /var/lib/postgresql/data/pg_hba.conf"
# ⚠️ P() 는 pgosctest DB 에 붙는데 이 시점엔 아직 그 DB 가 없다(뒤에서 만든다)
# — P 로 호출하면 접속 자체가 조용히 실패해 pg_reload_conf() 가 안 먹는다
# (실측: 이 줄 때문에 pg_hba.conf 에 줄을 추가해도 반영이 안 됐다). 항상 있는
# postgres DB 에 붙는 PD 를 쓴다.
PD "SELECT pg_reload_conf();" >/dev/null 2>&1

docker volume create pg-osc-replica1-data >/dev/null
docker volume create pg-osc-replica2-data >/dev/null

# ⚠️ pg_basebackup 은 호스트가 아니라 **primary 와 같은 도커 네트워크 안**에서
# 돌려야 한다(서비스명 pg-primary 로 찾아간다) — 그래서 1회성 컨테이너로 돈다.
# -R 은 standby.signal + primary_conninfo 를 자동으로 써 준다(PG12+).
for n in 1 2; do
  docker run --rm --network "$PG_NET" -u postgres \
    -v "pg-osc-replica${n}-data:/var/lib/postgresql/data" \
    postgres:16 bash -c \
    "pg_basebackup -h pg-primary -U replicator -D /var/lib/postgresql/data -P -R --wal-method=stream" \
    >/dev/null 2>&1
done

# replica2 만 recovery_min_apply_delay 를 추가해 인위적으로 지연시킨다 — MySQL
# 판의 SOURCE_DELAY 와 정확히 같은 역할(WAL 은 다 받고 재생만 늦춘다).
docker run --rm -u postgres -v pg-osc-replica2-data:/var/lib/postgresql/data postgres:16 \
  bash -c "echo \"recovery_min_apply_delay = '${REPLICA_DELAY}s'\" >> /var/lib/postgresql/data/postgresql.auto.conf"

docker run -d --name pg-replica1 --network "$PG_NET" -p 127.0.0.1:5434:5432 \
  -v pg-osc-replica1-data:/var/lib/postgresql/data postgres:16 >/dev/null
docker run -d --name pg-replica2 --network "$PG_NET" -p 127.0.0.1:5435:5432 \
  -v pg-osc-replica2-data:/var/lib/postgresql/data postgres:16 >/dev/null

wait_container_ready pg-replica1 || exit 1
echo "  pg-replica1 ready"
wait_container_ready pg-replica2 || exit 1
echo "  pg-replica2 ready"

wait_replica_caught_up "replica1(정상)" R1 || { echo "  [중단] 복제가 안 붙으면 나머지 전부가 무의미하다."; exit 1; }
# replica2 는 일부러 지연시켰으므로 "따라잡음"을 기다리지 않는다.
r2_replaying=$(R2 "SELECT pg_is_wal_replay_paused();" 2>/dev/null)
echo "  replica2(지연 ${REPLICA_DELAY}s): 복제 수신 중(재생만 지연)"

echo
echo "── 테스트 테이블 준비 (${ROWS}행) ──"
PD "DROP DATABASE IF EXISTS pgosctest;" >/dev/null
PD "CREATE DATABASE pgosctest;" >/dev/null
P "CREATE TABLE orders (
     id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
     cust_id INT NOT NULL,
     amount INT NOT NULL,
     created_at TIMESTAMPTZ DEFAULT now()
   );" >/dev/null

# ⚠️ MySQL 판은 자기참조 배증(INSERT...SELECT FROM t)으로 빨리 채웠는데, 거기서
# AUTO_INCREMENT 가 행 수만큼 연속으로 안 붙는 버그를 실측으로 잡은 바 있다
# (§9). PostgreSQL 의 GENERATED ALWAYS AS IDENTITY 도 내부적으로 시퀀스라 같은
# 함정이 있을 수 있다 — 그래서 여기서도 id 값이 아니라 **행 수**로 목표를 맞춘다.
P "INSERT INTO orders (cust_id, amount) VALUES (1, 100);" >/dev/null
n=1
while [ "$n" -lt "$ROWS" ]; do
  before="$n"
  out=$(P "INSERT INTO orders (cust_id, amount)
       SELECT (random()*1000000)::int+1, (random()*100000)::int+1 FROM orders;")
  if echo "$out" | grep -qi "ERROR"; then
    echo "  [중단] 배증 중 SQL 에러 (n=$n): $out"
    exit 1
  fi
  n=$(P "SELECT count(*) FROM orders;")
  case "$n" in ''|*[!0-9]*) echo "  [중단] 행 수를 못 읽었다: '$n'"; exit 1;; esac
  if [ "$n" -le "$before" ]; then
    echo "  [중단] 배증이 실제로 안 먹혔다 — ${before}행 그대로다(에러 없이 멈췄다)."
    exit 1
  fi
done
excess=$((n - ROWS))
if [ "$excess" -gt 0 ]; then
  P "DELETE FROM orders WHERE id IN (SELECT id FROM orders ORDER BY id DESC LIMIT $excess);" >/dev/null
fi
actual=$(P "SELECT count(*) FROM orders;")
echo "  적재 완료: ${actual}행"

wait_replica_caught_up "replica1" R1
for i in 1 2 3 4 5 6 7 8 9 10; do
  rep1=$(R1 "SELECT count(*) FROM orders;" 2>/dev/null)
  [ "$rep1" = "$actual" ] && break
  sleep 1
done
echo "  replica1 복제 확인: ${rep1:-?}행"
[ "${rep1:-}" != "$actual" ] && echo "  [경고] primary(${actual})와 replica1(${rep1:-?}) 행 수가 10초 뒤에도 다르다."

LAB_DONE=1
echo
echo "완료. 실험은 ./t-pg-ddl.sh 로 돌린다."
