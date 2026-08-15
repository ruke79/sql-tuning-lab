#!/usr/bin/env bash
# verify-lab 이 쓰는 verifylab DB/계정을 만든다. 케이스들이 테이블을 만들고 지우므로
# tpch 실습 데이터와 반드시 분리한다. 몇 번을 다시 실행해도 안전하다(멱등).
#
# DB-10(CDC)은 wal_level=logical 을 요구한다 — replica 로는 논리 디코딩이 불가능하다.
# 설정돼 있지 않으면 안내만 하고 계속 진행한다(그 케이스만 판정 불가로 남는다).
set -euo pipefail
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
SUPER="${PGSUPER:-postgres}"

run(){ psql -h "$PGHOST_" -p "$PGPORT_" -U "$SUPER" -d postgres -X -tAc "$1"; }

[ "$(run "SELECT count(*) FROM pg_roles WHERE rolname='verifylab'")" = "0" ] && \
  run "CREATE ROLE verifylab LOGIN PASSWORD 'verifylab' REPLICATION CREATEROLE" >/dev/null
# DB-13(RLS)이 테넌트 롤을 만들어 SET ROLE 로 갈아탄다. PG16 부터 CREATEROLE 은
# 만든 롤의 ADMIN 만 받고 SET 권한은 못 받으므로, 스스로 부여하게 설정한다.
run "ALTER ROLE verifylab SET createrole_self_grant = 'set, inherit'" >/dev/null
[ "$(run "SELECT count(*) FROM pg_database WHERE datname='verifylab'")" = "0" ] && \
  run "CREATE DATABASE verifylab OWNER verifylab" >/dev/null

WAL=$(run "SHOW wal_level")
echo "verifylab DB/계정 준비 완료 (wal_level=$WAL)"
if [ "$WAL" != "logical" ]; then
  echo "  [안내] DB-10(CDC) 케이스를 돌리려면:"
  echo "    ALTER SYSTEM SET wal_level = 'logical';  후 PostgreSQL 재시작"
fi
