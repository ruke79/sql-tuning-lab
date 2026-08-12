#!/usr/bin/env bash
# 공식 sysbench 실행 (docker 이미지 사용)
# 사용법:
#   ./run-official-sysbench.sh prepare 10 10000000   # 표 기준: 10 tables x 1000만 = 1억 건 (~24GB)
#   ./run-official-sysbench.sh prepare 4  100000     # 빠른 실습용
#   ./run-official-sysbench.sh run 16 60             # 16 threads, 60초
#   ./run-official-sysbench.sh cleanup 10
set -euo pipefail

CMD="${1:-run}"
COMMON="--db-driver=mysql --mysql-host=host.docker.internal --mysql-port=3306 \
  --mysql-user=tuner --mysql-password=tuner --mysql-db=sysbench_lab"
IMG=severalnines/sysbench

case "$CMD" in
  prepare)
    TABLES="${2:-4}"; SIZE="${3:-100000}"
    docker run --rm --add-host=host.docker.internal:host-gateway $IMG \
      sysbench oltp_read_write $COMMON --tables="$TABLES" --table-size="$SIZE" prepare
    ;;
  run)
    THREADS="${2:-8}"; TIME="${3:-30}"; TABLES="${4:-4}"; SIZE="${5:-100000}"
    docker run --rm --add-host=host.docker.internal:host-gateway $IMG \
      sysbench oltp_read_write $COMMON --tables="$TABLES" --table-size="$SIZE" \
      --threads="$THREADS" --time="$TIME" --report-interval=5 run
    ;;
  cleanup)
    TABLES="${2:-4}"
    docker run --rm --add-host=host.docker.internal:host-gateway $IMG \
      sysbench oltp_read_write $COMMON --tables="$TABLES" cleanup
    ;;
  *)
    echo "usage: $0 prepare <tables> <table-size> | run <threads> <seconds> [tables] [size] | cleanup <tables>"; exit 1;;
esac
