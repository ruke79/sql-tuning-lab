#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
docker rm -fv idx-pg >/dev/null 2>&1
echo "완료."
