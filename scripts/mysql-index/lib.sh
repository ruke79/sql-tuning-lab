# scripts/mysql-index 공용 — 컨테이너 접속 헬퍼. mysql-osc/lib.sh 와 같은 패턴,
# 단일 컨테이너(복제 없음)라 P() 하나뿐이다 — 이 실험은 인덱스 생성 자체의
# 블로킹을 보는 거라 replica lag 쓰로틀 비교가 필요 없다.
set -uo pipefail

MYROOT_PW="${MYROOT_PW:-root}"

P() { docker exec idx-mysql mysql -uroot -p"$MYROOT_PW" -e "$1" 2>&1 | grep -v '^mysql: \[Warning\]'; }

# mysql-osc/lib.sh 의 "ready for connections 두 번 + 진짜 SELECT 1" 교훈을 그대로
# 가져온다(§9 mysql-osc 참조) — 로그 문구만 보고 접속 가능하다고 믿으면 안 된다.
wait_container_ready() {
  local c="$1" i
  for i in $(seq 1 60); do
    [ "$(docker logs "$c" 2>&1 | grep -c 'ready for connections')" -ge 2 ] && break
    sleep 1
  done
  for i in $(seq 1 240); do
    docker exec "$c" mysql -uroot -p"$MYROOT_PW" -e "SELECT 1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "  [중단] $c 가 로그엔 ready 인데 실제 접속이 4분 안에 안 된다 — docker logs $c 로 확인하라." >&2
  return 1
}
