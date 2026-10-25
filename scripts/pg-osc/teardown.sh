#!/usr/bin/env bash
# scripts/pg-osc 토폴로지를 완전히 치운다 — 컨테이너 3개 + 볼륨 3개 + 네트워크.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh
PG_NET="${PG_NET:-pg-osc-net}"
PG_CONTAINERS="pg-primary pg-replica1 pg-replica2"
PG_VOLUMES="pg-osc-primary-data pg-osc-replica1-data pg-osc-replica2-data"
for c in $PG_CONTAINERS; do docker rm -fv "$c" >/dev/null 2>&1; done
for v in $PG_VOLUMES; do docker volume rm "$v" >/dev/null 2>&1; done
docker network rm "$PG_NET" >/dev/null 2>&1
echo "남은 pg-* 컨테이너: $(docker ps -a --filter "name=pg-" --format '{{.Names}}' 2>/dev/null | grep -c '^pg-' || true)   (0 이어야 한다)"
LAB_DONE=1
