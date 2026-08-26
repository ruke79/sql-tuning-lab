#!/usr/bin/env bash
# §T-3 / §T-5 (TPC-DS 판) — 조인 방식(NL/Hash/Merge)을 강제해 비교한다.
#
# 로직은 scripts/tpch/join-method-compare.sh 와 완전히 같다. 다른 것은 DB 이름과
# 쿼리 디렉터리뿐이라, 복제하지 않고 MODULE 변수만 바꿔 그 스크립트를 그대로 호출한다.
# (로직을 복사하면 한쪽만 고쳐지는 일이 반드시 생긴다.)
#
# 사용법:
#   ./join-method-compare.sh                        # 기본 q03_brand_by_year
#   ./join-method-compare.sh q19_store_zip          # 6-way 조인
#   ./join-method-compare.sh q07_demographics 6     # 6회 반복
#   TIMEOUT=120s ./join-method-compare.sh q67_window_rank
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec env MODULE=tpcds DBNAME=tpcds "$HERE/../tpch/join-method-compare.sh" "${1:-q03_brand_by_year}" "${2:-4}"
