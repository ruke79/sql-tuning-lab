#!/usr/bin/env bash
# scripts/mysql-osc 토폴로지를 완전히 치운다 — 컨테이너 3개 + 네트워크.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh
. ./_docker-trap.inc
osc_cleanup
echo "남은 osc-* 컨테이너: $(osc_container_count)   (0 이어야 한다)"
LAB_DONE=1
