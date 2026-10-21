# scripts/mysql-osc 공용 — 컨테이너 접속 헬퍼.
#
# docker exec 로 붙는다(호스트에 mysql 클라이언트가 없어도 된다 — 컨테이너 안의
# mysql 클라이언트를 쓴다). 비밀번호 경고는 노이즈라 걸러낸다.
set -uo pipefail

MYROOT_PW="${MYROOT_PW:-root}"

P()  { docker exec osc-primary  mysql -uroot -p"$MYROOT_PW" -e "$1" 2>&1 | grep -v '^mysql: \[Warning\]'; }
R1() { docker exec osc-replica1 mysql -uroot -p"$MYROOT_PW" -e "$1" 2>&1 | grep -v '^mysql: \[Warning\]'; }
R2() { docker exec osc-replica2 mysql -uroot -p"$MYROOT_PW" -e "$1" 2>&1 | grep -v '^mysql: \[Warning\]'; }

# ⚠️ 여기 `.Networks.osc-net.IPAddress` 라고 썼었다. Go 템플릿은 `-` 를 뺄셈으로
# 파싱한다 — `osc` 빼기 `net` 이 되어 "bad character" 에러를 내고 IP 가 빈 문자열로
# 나온다. 그러면 CHANGE REPLICATION SOURCE TO SOURCE_HOST='' 가 조용히 실패하고
# 복제가 영원히 안 붙는다. **네트워크/컨테이너 이름에 하이픈이 있으면 index 함수를
# 써야 한다** — 실측: 이 버그로 처음 돌린 setup-topology.sh 가 "복제가 60초 안에
# 따라잡지 못했다" 경고를 내고 조용히 지나갔다(에러가 아니라 경고라 더 위험했다).
osc_ip() { docker inspect -f '{{(index .NetworkSettings.Networks "'"$OSC_NET"'").IPAddress}}' "$1"; }

# "ready for connections" 가 두 번 나와야 MySQL 8 엔트리포인트의 초기화(임시 서버
# → 설정 적용 → 재기동)가 완전히 끝난 것이다. 한 번만 보고 접속하면 비밀번호가
# 아직 안 걸린 상태라 "Access denied" 가 **타이밍 문제인데 인증 실패로 보인다**
# (이 실습을 준비하며 실제로 두 번 겪었다).
# "ready for connections" 가 로그에 두 번 나오는 것과 "실제로 접속된다"는 다른
# 문제다 — 엔트리포인트가 소켓 파일을 옮기는(mv) 찰나와 겹치면 로그엔 이미
# 찍혔는데 접속은 ERROR 2002(소켓 없음)로 실패한다(실측: 이 자리에서 실제로
# 겪었다 — replica2 하나만, 간헐적으로). 로그 문구가 아니라 **진짜 SELECT 1 이
# 성공하는 것**을 기다린다.
wait_container_ready() {
  local c="$1" i
  for i in $(seq 1 60); do
    [ "$(docker logs "$c" 2>&1 | grep -c 'ready for connections')" -ge 2 ] && break
    sleep 1
  done
  for i in $(seq 1 20); do
    docker exec "$c" mysql -uroot -p"$MYROOT_PW" -e "SELECT 1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "  [중단] $c 가 로그엔 ready 인데 실제 접속이 20초 안에 안 된다 — docker logs $c 로 확인하라." >&2
  return 1
}

# 복제가 **실제로** 따라잡았는지 — IO/SQL 스레드 상태만 보고 "복제된다"고 말하면 안 된다.
# 두 스레드가 Yes 이고 Seconds_Behind_Source 가 숫자(NULL 아님)여야 한다.
wait_replica_caught_up() {
  local who="$1" fn="$2" i st io sql lag
  for i in $(seq 1 60); do
    st=$("$fn" "SHOW REPLICA STATUS\G" 2>/dev/null)
    io=$(echo "$st" | awk -F': ' '/Replica_IO_Running:/{print $2}')
    sql=$(echo "$st" | awk -F': ' '/Replica_SQL_Running:/{print $2}')
    lag=$(echo "$st" | awk -F': ' '/Seconds_Behind_Source:/{print $2}')
    if [ "$io" = "Yes" ] && [ "$sql" = "Yes" ] && [ "${lag:-NULL}" = "0" ]; then
      return 0
    fi
    sleep 1
  done
  echo "  [경고] $who 복제가 60초 안에 따라잡지 못했다(IO=$io SQL=$sql lag=$lag)." >&2
  return 1
}
