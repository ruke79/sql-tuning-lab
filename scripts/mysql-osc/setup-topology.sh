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
#   INNODB_BUFFER_POOL=4G ./setup-topology.sh  # 버퍼풀 크기 (기본 512M — 샌드박스 기준)
#   FSYNC_MODE=fast ./setup-topology.sh        # 커밋마다 fsync 끄기 (실험 전용, 기본 durable)
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ROWS="${ROWS:-10000000}"
REPLICA_DELAY="${REPLICA_DELAY:-30}"
SC="${SC:-/tmp/mysql-osc-scratch}"
# ⚠️ 이 값은 애초에 메모리 제한된 샌드박스 VM 기준으로 잡혔다 — 호스트 RAM 과
# 무관하게 하드코딩돼 있었다. 좋은 하드웨어(실측: 5900X/128GB/NVMe)에서도 10M행
# 백필이 샌드박스보다 9배 느리게 나온 사례가 있었는데, 버퍼풀이 작으면 디스크가
# 아무리 빨라도 "불필요하게 자주 두드리는" 비효율은 못 가린다. 호스트 RAM 에
# 맞게 늘려서 재보라 — 예: `INNODB_BUFFER_POOL=4G ./setup-topology.sh`.
INNODB_BUFFER_POOL="${INNODB_BUFFER_POOL:-512M}"

# ⚠️ 버퍼풀을 16G 까지 올려도 처리량이 안 뛰는 사례가 실측됐다 — 모니터링
# (monitor.sh)으로 보니 버퍼풀 히트율 100%·사용량 10%(남아돈다)인데도 처리량이
# fsync/초와 거의 1:1로 붙어 다녔다. MySQL 기본값(`sync_binlog=1`,
# `innodb_flush_log_at_trx_commit=1`)은 **커밋마다 fsync** 를 강제한다 — 디스크
# 대역폭이 아니라 fsync 1회의 지연시간이 상한을 만든다. **실험용으로만**(크래시
# 시 최근 커밋 유실 가능 — 운영에 쓰지 말 것) 이 둘을 끄고 재서 fsync 가 진짜
# 병목인지 확인한다: `FSYNC_MODE=fast ./setup-topology.sh`.
FSYNC_MODE="${FSYNC_MODE:-durable}"
if [ "$FSYNC_MODE" = "fast" ]; then
  FSYNC_CNF="sync_binlog=0
innodb_flush_log_at_trx_commit=2"
  echo "  [주의] FSYNC_MODE=fast — 커밋마다 fsync 를 안 한다. 실험 전용, 운영 설정 아님."
else
  FSYNC_CNF="sync_binlog=1
innodb_flush_log_at_trx_commit=1"
fi

. ./_docker-trap.inc

existing=$(osc_container_count)
if [ "${existing:-0}" -ge 3 ] && [ "${FORCE:-0}" != "1" ]; then
  # ⚠️ 여기서 세는 건 `docker ps -a`(꺼져 있는 것도 포함)다 — 컨테이너가
  # "있다"와 "떠서 돈다"는 다른 상태다(실측: 컨테이너는 있는데 멈춰 있어서
  # 바로 뒤의 P() 가 "container ... is not running" 에러를 냈다). 재사용하기
  # 전에 멈춰 있으면 먼저 켠다 — `docker start`는 이미 돈다면 그냥 no-op다.
  echo "  이미 ${existing}개 있다 — 멈춰 있으면 켜고 그대로 쓴다(FORCE=1 로 다시 만들 수 있다)."
  docker start osc-primary osc-replica1 osc-replica2 >/dev/null 2>&1
  # ⚠️★사고 실측★ — 여기서 wait 가 실패하면 "중단"으로 간주해 trap(on_abort)이
  # 돌면서 osc_cleanup() 이 **이미 있던 10M행 데이터를 통째로 지웠다**(docker
  # rm -fv, 볼륨까지). 10M행 InnoDB 가 멈췄다가 재기동하면 복구(redo log
  # replay)에 wait_container_ready() 의 기본 대기(최대 80초)보다 더 걸릴 수
  # 있는데, 그게 "실패"가 아니라 "느린 성공"인데도 cleanup 이 발동됐다.
  # 재사용 경로에서는 **느려도 데이터를 지우면 안 된다** — trap 을 먼저 끄고
  # 안내만 하고 나간다(컨테이너를 그대로 둬서 사람이 `docker logs osc-primary`
  # 로 보거나, 몇 초 더 뒤에 다시 이 스크립트를 돌리게 한다).
  if ! wait_container_ready osc-primary; then
    trap - EXIT INT TERM
    echo "  [중단] 10M행 InnoDB 복구가 느릴 수 있다 — 데이터는 그대로 뒀다(지우지 않음)."
    echo "         docker logs osc-primary 로 진행 상황을 보고, 좀 더 기다린 뒤 이 스크립트를 다시 돌려라."
    exit 1
  fi
  cnt=$(P "SELECT count(*) FROM osctest.orders" 2>/dev/null | tail -1)
  echo "  osctest.orders 행 수: ${cnt:-?}"
  LAB_DONE=1
  exit 0
fi
osc_cleanup

mkdir -p "$SC"
cat > "$SC/my-primary.cnf" <<EOF
[mysqld]
server-id=1
log-bin=mysql-bin
binlog_format=ROW
binlog_row_image=FULL
mysql-native-password=ON
innodb_buffer_pool_size=$INNODB_BUFFER_POOL
$FSYNC_CNF
EOF
cat > "$SC/my-replica1.cnf" <<EOF
[mysqld]
server-id=2
log-bin=mysql-bin
binlog_format=ROW
read_only=ON
log-replica-updates=ON
mysql-native-password=ON
innodb_buffer_pool_size=$INNODB_BUFFER_POOL
$FSYNC_CNF
EOF
cat > "$SC/my-replica2.cnf" <<EOF
[mysqld]
server-id=3
log-bin=mysql-bin
binlog_format=ROW
read_only=ON
log-replica-updates=ON
mysql-native-password=ON
innodb_buffer_pool_size=$INNODB_BUFFER_POOL
$FSYNC_CNF
EOF

echo "── 컨테이너 3개 기동 ──"
docker network create "$OSC_NET" >/dev/null
# ⚠️ 포트를 공개한다(-p). t-online-ddl.sh 의 배경 부하(호스트의 mysql 클라이언트)와
# gh-ost(호스트에서 도는 바이너리) 는 컨테이너의 **브리지 IP 에 직접** 접속해야 하는데,
# 이건 Linux 도커 호스트에서만 되고 Docker Desktop(macOS/Windows) 에서는 호스트가
# 브리지 네트워크 IP 로 라우팅이 안 된다(실측: 다른 머신에서 전부 "0 writes/s" 로
# 조용히 멈췄다 — MYSQL_P 의 `2>/dev/null` 가 진짜 원인[연결 실패]을 삼켜 증상만
# 보였다). 포트를 공개해 127.0.0.1 로 접속하면 플랫폼과 무관하게 동작한다.
docker run -d --name osc-primary  --network "$OSC_NET" -p 127.0.0.1:3307:3306 -v "$SC/my-primary.cnf:/etc/mysql/conf.d/custom.cnf"  -e MYSQL_ROOT_PASSWORD="$MYROOT_PW" mysql:8.4 >/dev/null
docker run -d --name osc-replica1 --network "$OSC_NET" -p 127.0.0.1:3308:3306 -v "$SC/my-replica1.cnf:/etc/mysql/conf.d/custom.cnf" -e MYSQL_ROOT_PASSWORD="$MYROOT_PW" mysql:8.4 >/dev/null
docker run -d --name osc-replica2 --network "$OSC_NET" -p 127.0.0.1:3309:3306 -v "$SC/my-replica2.cnf:/etc/mysql/conf.d/custom.cnf" -e MYSQL_ROOT_PASSWORD="$MYROOT_PW" mysql:8.4 >/dev/null

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
# ⚠️ `Seconds_Behind_Source=0` 는 초 단위 타임스탬프 비교라 "따라잡았다"고 말해도
# 바로 앞의 트랜잭션(이 DELETE)이 아직 안 적용된 순간이 있을 수 있다(실측: IO/SQL=Yes,
# lag=0 인데 그 직후 읽은 행 수가 트리밍 전 값 그대로였다 — 몇 초 뒤엔 맞았다).
# 행 수를 직접 비교해 재시도한다 — 간접 신호(lag)가 아니라 실제 상태로 확인한다.
for i in 1 2 3 4 5 6 7 8 9 10; do
  rep1=$(R1 "SELECT count(*) FROM osctest.orders" | tail -1)
  [ "$rep1" = "$actual" ] && break
  sleep 1
done
echo "  replica1 복제 확인: ${rep1}행"
[ "$rep1" != "$actual" ] && echo "  [경고] primary(${actual})와 replica1(${rep1}) 행 수가 10초 뒤에도 다르다."

LAB_DONE=1
echo
echo "완료. 실험은 ./t-online-ddl.sh 로 돌린다."
