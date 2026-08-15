#!/usr/bin/env bash
# Docker 없이 로컬 KRaft 단일 노드 브로커를 띄운다 (verify-lab-kafka 용).
# 이 세션에서 실제로 이 방식으로 7케이스 전부 CONFIRMED 를 확인했다.
#
#   ./scripts/verify/kafka-local.sh start   # 다운로드(최초 1회) + 기동
#   ./scripts/verify/kafka-local.sh stop
set -euo pipefail
KDIR="${KAFKA_DIR:-$HOME/.cache/kafka-lab}"
VER=3.9.1
LOGDIR="$KDIR/kraft-logs"

start(){
  if [ ! -x "$KDIR/kafka/bin/kafka-server-start.sh" ]; then
    mkdir -p "$KDIR"; cd "$KDIR"
    echo "Kafka $VER 다운로드 중..."
    curl -sSL -o kafka.tgz "https://archive.apache.org/dist/kafka/$VER/kafka_2.13-$VER.tgz"
    tar xzf kafka.tgz && mv "kafka_2.13-$VER" kafka && rm kafka.tgz
  fi
  cd "$KDIR/kafka"
  if [ ! -f "$LOGDIR/meta.properties" ]; then
    cat > config/kraft/lab.properties <<CONF
node.id=1
process.roles=broker,controller
listeners=PLAINTEXT://localhost:9092,CONTROLLER://localhost:9093
advertised.listeners=PLAINTEXT://localhost:9092
controller.quorum.voters=1@localhost:9093
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
group.initial.rebalance.delay.ms=0
log.dirs=$LOGDIR
CONF
    bin/kafka-storage.sh format -t "$(bin/kafka-storage.sh random-uuid | tail -1)" -c config/kraft/lab.properties
  fi
  nohup bin/kafka-server-start.sh config/kraft/lab.properties > "$KDIR/broker.log" 2>&1 &
  echo $! > "$KDIR/kafka.pid"
  for i in $(seq 1 30); do
    bin/kafka-topics.sh --bootstrap-server localhost:9092 --list >/dev/null 2>&1 && { echo "브로커 기동 (localhost:9092)"; return; }
    sleep 1
  done
  echo "기동 실패 — $KDIR/broker.log 확인"; exit 1
}

stop(){ [ -f "$KDIR/kafka.pid" ] && kill "$(cat "$KDIR/kafka.pid")" 2>/dev/null && rm -f "$KDIR/kafka.pid" && echo "중지됨" || echo "안 떠 있음"; }

case "${1:-start}" in start) start;; stop) stop;; *) echo "usage: $0 start|stop"; exit 1;; esac
