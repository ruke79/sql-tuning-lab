# scripts/pg-osc 공용 — 컨테이너 접속 헬퍼.
#
# docker exec 로 붙는다(호스트에 psql 클라이언트가 없어도 된다 — 컨테이너 안의
# psql 클라이언트를 쓴다).
set -uo pipefail

PGPASS="${PGPASS:-postgres}"

P()  { docker exec -u postgres pg-primary  psql -U postgres -d pgosctest -v ON_ERROR_STOP=1 -Atq -c "$1" 2>&1; }
R1() { docker exec -u postgres pg-replica1 psql -U postgres -d pgosctest -v ON_ERROR_STOP=1 -Atq -c "$1" 2>&1; }
R2() { docker exec -u postgres pg-replica2 psql -U postgres -d pgosctest -v ON_ERROR_STOP=1 -Atq -c "$1" 2>&1; }
# postgres 기본 db 에 붙는 버전(DB 가 아직 없을 때 CREATE DATABASE 등에 쓴다).
PD() { docker exec -u postgres pg-primary  psql -U postgres -d postgres   -v ON_ERROR_STOP=1 -Atq -c "$1" 2>&1; }

pg_ip() { docker inspect -f '{{(index .NetworkSettings.Networks "'"$PG_NET"'").IPAddress}}' "$1"; }

# MySQL 판(wait_container_ready)과 같은 이유 — "ready to accept connections" 가
# 로그에 찍히는 것과 실제 접속되는 것 사이에 찰나의 간극이 있을 수 있다. 로그
# 문구가 아니라 진짜 SELECT 1 이 성공하는 것을 기다린다.
wait_container_ready() {
  local c="$1" i
  for i in $(seq 1 60); do
    [ "$(docker logs "$c" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 1 ] && break
    sleep 1
  done
  # ⚠️ mysql-osc 에서 실측으로 겪었다 — 멈춘 컨테이너를 재기동할 때 대량의
  # 데이터(10M행)면 복구(WAL replay)에 30초보다 더 걸릴 수 있다. 재시도를
  # 넉넉히 늘린다(최대 4분).
  for i in $(seq 1 240); do
    docker exec -u postgres "$c" psql -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "  [중단] $c 가 로그엔 ready 인데 실제 접속이 4분 안에 안 된다 — docker logs $c 로 확인하라." >&2
  return 1
}

# 복제가 **실제로** 따라잡았는지 — WAL receive/replay LSN 이 primary 의 현재
# LSN 과 같아질 때까지 기다린다(MySQL 판의 Seconds_Behind_Source=0 과 같은 역할).
wait_replica_caught_up() {
  local who="$1" fn="$2" i primary_lsn replica_lsn
  for i in $(seq 1 60); do
    primary_lsn=$(P "SELECT pg_current_wal_lsn();" 2>/dev/null)
    replica_lsn=$("$fn" "SELECT pg_last_wal_replay_lsn();" 2>/dev/null)
    if [ -n "$primary_lsn" ] && [ "$primary_lsn" = "$replica_lsn" ]; then
      return 0
    fi
    sleep 1
  done
  echo "  [경고] $who 복제가 60초 안에 따라잡지 못했다(primary=$primary_lsn replica=$replica_lsn)." >&2
  return 1
}
