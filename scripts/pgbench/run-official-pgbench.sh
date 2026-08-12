#!/usr/bin/env bash
# 공식 pgbench 실행 (docker 컨테이너 내장 pgbench 사용)
# 사용법:
#   ./run-official-pgbench.sh init 10        # scale 10 (accounts 100만 건) 초기화
#   ./run-official-pgbench.sh init 1000      # scale 1000 (accounts 1억 건, ~15GB) ← 표 기준
#   ./run-official-pgbench.sh run 8 30       # 8 clients, 30초
set -euo pipefail

CMD="${1:-run}"
C=tuninglab-postgres

case "$CMD" in
  init)
    SCALE="${2:-10}"
    docker exec -e PGPASSWORD=tuner "$C" \
      pgbench -h localhost -U tuner -d pgbench_lab -i -s "$SCALE" --foreign-keys=false
    ;;
  run)
    CLIENTS="${2:-8}"
    SECONDS_ARG="${3:-30}"
    docker exec -e PGPASSWORD=tuner "$C" \
      pgbench -h localhost -U tuner -d pgbench_lab -c "$CLIENTS" -j 4 -T "$SECONDS_ARG" -P 5 -r
    ;;
  *)
    echo "usage: $0 init <scale> | run <clients> <seconds>"; exit 1;;
esac
