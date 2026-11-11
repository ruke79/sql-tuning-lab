# scripts/pg-index 공용 — 컨테이너 접속 헬퍼. pg-osc/lib.sh 와 같은 패턴,
# 단일 컨테이너(복제 없음)다.
set -uo pipefail

PGPASS="${PGPASS:-postgres}"
P() { docker exec -u postgres idx-pg psql -U postgres -d idxtest -v ON_ERROR_STOP=1 -Atq -c "$1" 2>&1; }
PD() { docker exec -u postgres idx-pg psql -U postgres -d postgres -v ON_ERROR_STOP=1 -Atq -c "$1" 2>&1; }

wait_container_ready() {
  local c="$1" i
  for i in $(seq 1 60); do
    docker logs "$c" 2>&1 | grep -q 'database system is ready to accept connections' && break
    sleep 1
  done
  for i in $(seq 1 240); do
    docker exec -u postgres "$c" psql -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "  [중단] $c 가 로그엔 ready 인데 실제 접속이 4분 안에 안 된다." >&2
  return 1
}
