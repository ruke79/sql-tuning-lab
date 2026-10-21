#!/usr/bin/env bash
# §X-2(책 밖) 무정지 스키마 변경 — 토폴로지 준비.
#
# 1 primary + 2 replica(정상 1 / 지연 1)를 Docker 컨테이너로 띄우고 복제를 건다.
# 왜 컨테이너인가 — 네이티브 다중 mysqld(mysqld_multi)보다 리셋이 쉽다.
# "replica2 를 완전히 지우고 다시"가 컨테이너 재생성 한 줄이다.
#
# 왜 replica 가 둘인가 — gh-ost 의 "replica lag 넘으면 쓰로틀" 을 재려면 **대조군**이
# 있어야 한다. replica1(정상)만 있으면 gh-ost 가 멈췄을 때 그게 쓰로틀 때문인지
# 그냥 느린 건지 구분이 안 된다. replica2 를 SOURCE_DELAY 로 일부러 늦춰서
# "replica1 은 안 멈추는데 replica2 lag 가 크면 그제야 쓰로틀"을 대조한다.
#
# 복제는 GTID 가 아니라 file+pos 로 건다 — GTID_MODE=ON 은 두 서버가 같이 재기동
# 해야 해서 토폴로지가 복잡해지고, gh-ost 는 어느 쪽이든 동작한다(공식 문서에
# GTID 요구 없음). 단순한 쪽을 쓴다.
#
# 사용법:
#   ./setup-topology.sh                 # 기본: 1,000만 행
#   ROWS=1000000 ./setup-topology.sh    # 빠른 반복용 — 100만 행
#   REPLICA_DELAY=30 ./setup-topology.sh  # replica2 지연 초 (기본 30)
#   FORCE=1 ./setup-topology.sh         # 이미 떠 있어도 지우고 다시
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ROWS="${ROWS:-10000000}"
REPLICA_DELAY="${REPLICA_DELAY:-30}"
SC="${SC:-/tmp/claude-0/-home-user-db-modeling/d3dd1f58-4266-5bdf-acd9-a25044e15fc4/scratchpad}"

. ./_docker-trap.inc

existing=$(osc_container_count)
if [ "${existing:-0}" -ge 3 ] && [ "${FORCE:-0}" != "1" ]; then
  echo "  이미 ${existing}개 떠 있다 — 그대로 쓴다(FORCE=1 로 다시 만들 수 있다)."
  cnt=$(P "SELECT count(*) FROM osctest.orders" 2>/dev/null | tail -1)
  echo "  osctest.orders 행 수: ${cnt:-?}"
  LAB_DONE=1
  exit 0
fi
osc_cleanup

mkdir -p "$SC"
cat > "$SC/my-primary.cnf" <<'EOF'
[mysqld]
server-id=1
log-bin=mysql-bin
binlog_format=ROW
binlog_row_image=FULL
mysql-native-password=ON
innodb_buffer_pool_size=512M
EOF
cat > "$SC/my-replica1.cnf" <<'EOF'
[mysqld]
server-id=2
log-bin=mysql-bin
binlog_format=ROW
read_only=ON
log-replica-updates=ON
mysql-native-password=ON
innodb_buffer_pool_size=512M
EOF
cat > "$SC/my-replica2.cnf" <<EOF
[mysqld]
server-id=3
log-bin=mysql-bin
binlog_format=ROW
read_only=ON
log-replica-updates=ON
mysql-native-password=ON
innodb_buffer_pool_size=512M
EOF

echo "── 컨테이너 3개 기동 ──"
docker network create "$OSC_NET" >/dev/null
docker run -d --name osc-primary  --network "$OSC_NET" -v "$SC/my-primary.cnf:/etc/mysql/conf.d/custom.cnf"  -e MYSQL_ROOT_PASSWORD="$MYROOT_PW" mysql:8.4 >/dev/null
docker run -d --name osc-replica1 --network "$OSC_NET" -v "$SC/my-replica1.cnf:/etc/mysql/conf.d/custom.cnf" -e MYSQL_ROOT_PASSWORD="$MYROOT_PW" mysql:8.4 >/dev/null
docker run -d --name osc-replica2 --network "$OSC_NET" -v "$SC/my-replica2.cnf:/etc/mysql/conf.d/custom.cnf" -e MYSQL_ROOT_PASSWORD="$MYROOT_PW" mysql:8.4 >/dev/null

for c in osc-primary osc-replica1 osc-replica2; do
  wait_container_ready "$c" || exit 1
  echo "  $c ready"
done

echo
echo "── 복제 배선 ──"
P "ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYROOT_PW';
   CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED WITH mysql_native_password BY 'replpass';
   GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
   CREATE USER IF NOT EXISTS 'ghost'@'%' IDENTIFIED WITH mysql_native_password BY 'ghostpass';
   GRANT ALL ON osctest.* TO 'ghost'@'%';
   GRANT SUPER, REPLICATION SLAVE, REPLICATION CLIENT, PROCESS ON *.* TO 'ghost'@'%';
   GRANT SELECT ON performance_schema.* TO 'ghost'@'%';
   FLUSH PRIVILEGES;" >/dev/null

# ⚠️ gh-ost 는 --throttle-control-replicas 로 각 replica 에 *직접* 접속해 lag 를
# 확인한다 — 이건 복제로 전파되는 데이터가 아니라 replica 자신의 로컬 계정이
# 필요하다는 뜻이다. 위 CREATE USER/GRANT 는 primary 의 binlog 에 찍히지만,
# 그 직후에 읽는 바로 지금 이 위치부터 replica 가 복제를 시작하므로(파일+포지션을
# "현재" 값으로 잡는다) **이 GRANT 보다 뒤의 binlog 만 받는다 — 즉 ghost 유저가
# replica 에 영원히 안 생긴다**(실측: throttle-control-replicas 연결이
# "Access denied for user 'ghost'" 로 막혔다). 복제에 기대지 말고 각 replica 에
# 직접 만든다.
# ⚠️ 처음엔 performance_schema 만 더 줬다. gh-ost 는 replica 에서도 자기가 만든
# 고스트/체인지로그 테이블(osctest._orders_ghc)을 직접 SELECT 해서 lag 를
# 재므로 osctest.* 도 있어야 한다(실측: "SELECT command denied ... for table
# '_orders_ghc'" 로 계속 throttled 상태에 갇혀, 대조군조차 끝나지 않았다).
for GR in R1 R2; do
  $GR "CREATE USER IF NOT EXISTS 'ghost'@'%' IDENTIFIED WITH mysql_native_password BY 'ghostpass';
       GRANT ALL ON osctest.* TO 'ghost'@'%';
       GRANT SUPER, REPLICATION SLAVE, REPLICATION CLIENT, PROCESS ON *.* TO 'ghost'@'%';
       GRANT SELECT ON performance_schema.* TO 'ghost'@'%';
       FLUSH PRIVILEGES;" >/dev/null
done

PRIMARY_IP=$(osc_ip osc-primary)
# ⚠️ 바로 위 ALTER USER/FLUSH PRIVILEGES 직후 새 연결을 맺으면 가끔 일시적으로
# 실패한다(실측: 이 자리에서 LOGFILE/LOGPOS 가 빈 채로 넘어가 복제가 영원히
# 못 붙었다 — 에러 메시지 없이, 그냥 빈 문자열로). 결과를 검증하고, 비면
# 재시도한다 — 빈 값을 그대로 CHANGE REPLICATION SOURCE 에 넣지 않는다.
read_binlog_pos() {
  local i out
  for i in 1 2 3 4 5; do
    out=$(P "SHOW BINARY LOG STATUS\G")
    LOGFILE=$(echo "$out" | awk -F': ' '/^ *File:/{print $2}')
    LOGPOS=$(echo "$out" | awk -F': ' '/^ *Position:/{print $2}')
    [ -n "$LOGFILE" ] && [ -n "$LOGPOS" ] && return 0
    sleep 1
  done
  echo "  [중단] SHOW BINARY LOG STATUS 를 5회 재시도해도 못 읽었다. 원본 출력:"
  echo "$out" | sed 's/^/    /'
  return 1
}
read_binlog_pos || exit 1
echo "  primary IP=$PRIMARY_IP  binlog=$LOGFILE:$LOGPOS"

R1OUT=$(R1 "ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYROOT_PW';
    CHANGE REPLICATION SOURCE TO SOURCE_HOST='$PRIMARY_IP', SOURCE_PORT=3306,
      SOURCE_USER='repl', SOURCE_PASSWORD='replpass',
      SOURCE_LOG_FILE='$LOGFILE', SOURCE_LOG_POS=$LOGPOS, SOURCE_AUTO_POSITION=0;
    START REPLICA;")
[ -n "$R1OUT" ] && echo "  replica1 배선 응답: $R1OUT"
R2OUT=$(R2 "ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYROOT_PW';
    CHANGE REPLICATION SOURCE TO SOURCE_HOST='$PRIMARY_IP', SOURCE_PORT=3306,
      SOURCE_USER='repl', SOURCE_PASSWORD='replpass',
      SOURCE_LOG_FILE='$LOGFILE', SOURCE_LOG_POS=$LOGPOS, SOURCE_AUTO_POSITION=0;
    CHANGE REPLICATION SOURCE TO SOURCE_DELAY=$REPLICA_DELAY;
    START REPLICA;")
[ -n "$R2OUT" ] && echo "  replica2 배선 응답: $R2OUT"

wait_replica_caught_up "replica1(정상)" R1 || { echo "  [중단] 복제가 안 붙으면 나머지 전부가 무의미하다."; exit 1; }
# replica2 는 일부러 지연시켰으므로 "따라잡음"을 기다리지 않는다 — IO/SQL 스레드가
# 도는지만 본다. Seconds_Behind_Source 가 한동안 non-zero 인 게 **의도된 상태**다.
r2st=$(R2 "SHOW REPLICA STATUS\G")
echo "  replica2(지연 ${REPLICA_DELAY}s): IO=$(echo "$r2st" | awk -F': ' '/Replica_IO_Running:/{print $2}') SQL=$(echo "$r2st" | awk -F': ' '/Replica_SQL_Running:/{print $2}')"

echo
echo "── 테스트 테이블 준비 (${ROWS}행) ──"
# 돈 금액 컬럼 하나를 INT 로 두고, 이게 이 실습 전체가 BIGINT 로 넓히는 대상이다.
# cust_id 는 배경 쓰기 부하가 때릴 대상(핫스팟 아님 — 넓게 분포).
P "DROP DATABASE IF EXISTS osctest; CREATE DATABASE osctest;
   CREATE TABLE osctest.orders (
     id BIGINT PRIMARY KEY AUTO_INCREMENT,
     cust_id INT NOT NULL,
     amount INT NOT NULL,
     created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
   ) ENGINE=InnoDB;"

# 1행에서 두 배씩 늘려 ROWS 에 근접시킨다 — 외부 데이터 생성기 없이 가장 빠르다.
# ⚠️ 처음엔 각 배증을 확인 없이 믿고 n 을 두 배로 올렸다. ONE 번의 배증이 말없이
# 실패해도(이 환경에서 실제로 한 번 그랬다 — 사유는 못 찾았지만 docker exec 로
# 매번 새 연결을 여는 와중의 일시적 문제로 보인다) n 은 그대로 전진해 버리고,
# 루프는 "다 됐다"고 믿고 끝났다. 그 결과 200,000행을 요청했는데 131,072행에서
# **에러 하나 없이** 멈췄다. 이제 매 배증 뒤에 실제 행 수를 재서 확인한다.
P "INSERT INTO osctest.orders (cust_id, amount) VALUES (1, 100);" >/dev/null
n=1
while [ "$n" -lt "$ROWS" ]; do
  before="$n"
  out=$(P "INSERT INTO osctest.orders (cust_id, amount)
       SELECT FLOOR(RAND()*1000000)+1, FLOOR(RAND()*100000)+1 FROM osctest.orders;")
  if echo "$out" | grep -qi "ERROR"; then
    echo "  [중단] 배증 중 SQL 에러 (n=$n): $out"
    exit 1
  fi
  n=$(P "SELECT count(*) FROM osctest.orders" | tail -1)
  case "$n" in ''|*[!0-9]*) echo "  [중단] 행 수를 못 읽었다: '$n'"; exit 1;; esac
  if [ "$n" -le "$before" ]; then
    echo "  [중단] 배증이 실제로 안 먹혔다 — ${before}행 그대로다(에러 없이 멈췄다)."
    echo "         docker logs osc-primary 로 확인하라."
    exit 1
  fi
done
# 정확히 ROWS 로 맞춘다(배로 늘리면 넘친다).
# ⚠️ 처음엔 "WHERE id > $ROWS" 로 깎았다. INSERT...SELECT 자기참조 배증은
# innodb_autoinc_lock_mode(기본 2, interleaved)에서 id 를 행 수만큼 연속으로
# 주지 않고 성큰 건너뛴다(실측: 262,144행인데 id<=200000 인 행은 131,072개뿐이었다
# — 거의 절반이 id 값 기준으로는 "200000 넘는" 취급을 받았다). id 값이 아니라
# **행 수** 기준으로 깎아야 한다 — ORDER BY ... LIMIT 삭제를 쓴다.
excess=$((n - ROWS))
if [ "$excess" -gt 0 ]; then
  P "DELETE FROM osctest.orders ORDER BY id DESC LIMIT $excess;" >/dev/null
fi
actual=$(P "SELECT count(*) FROM osctest.orders" | tail -1)
echo "  적재 완료: ${actual}행"

wait_replica_caught_up "replica1" R1
rep1=$(R1 "SELECT count(*) FROM osctest.orders" | tail -1)
echo "  replica1 복제 확인: ${rep1}행"

LAB_DONE=1
echo
echo "완료. 실험은 ./t-online-ddl.sh 로 돌린다."
