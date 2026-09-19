#!/usr/bin/env bash
# verify-lab 이 쓰는 verifylab DB/계정을 만든다. 케이스들이 테이블을 만들고 지우므로
# tpch 실습 데이터와 반드시 분리한다. 몇 번을 다시 실행해도 안전하다(멱등).
#
# **이 스크립트는 호스트에서 실행한다.** 컨테이너에 들어갈 필요가 없다 —
# 호스트에 psql 이 있으면 그걸로 붙고, 없으면 docker exec 로 컨테이너 안의 psql 을 쓴다
# (이 저장소의 다른 스크립트들과 같은 방식이다).
#
# 슈퍼유저 기본값은 **tuner** 다. docker/docker-compose.yml 의 POSTGRES_USER 가 tuner 라
# 그 인스턴스에는 postgres 롤이 아예 없다. 호스트에 직접 설치한 PostgreSQL 을 쓴다면
# PGSUPER=postgres 로 넘긴다.
#
# 사용법:
#   ./scripts/verify/setup-verifylab.sh                  # 자동 판별
#   PGSUPER=postgres ./scripts/verify/setup-verifylab.sh # 호스트 설치판(슈퍼유저가 postgres)
#   CONTAINER=이름 ./scripts/verify/setup-verifylab.sh   # 컨테이너 이름이 다를 때
#
# DB-10(CDC)은 wal_level=logical 을 요구한다 — replica 로는 논리 디코딩이 불가능하다.
# 설정돼 있지 않으면 안내만 하고 계속 진행한다(그 케이스만 판정 불가로 남는다).
set -euo pipefail
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
SUPER="${PGSUPER:-tuner}"
SUPERPW="${PGSUPERPASSWORD:-tuner}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

# 어느 경로로 붙을지 정한다. 호스트 psql 로 실제 접속이 되는지까지 확인하고,
# 안 되면 docker 로 넘어간다 — psql 이 설치돼 있어도 서버가 컨테이너 안에만 있을 수 있다.
MODE=""
if command -v psql >/dev/null 2>&1 &&
   PGPASSWORD="$SUPERPW" psql -h "$PGHOST_" -p "$PGPORT_" -U "$SUPER" -d postgres -X -tAc "SELECT 1" >/dev/null 2>&1; then
  MODE=host
  run(){ PGPASSWORD="$SUPERPW" psql -h "$PGHOST_" -p "$PGPORT_" -U "$SUPER" -d postgres -X -tAc "$1"; }
elif command -v docker >/dev/null 2>&1 &&
     docker exec -e PGPASSWORD="$SUPERPW" "$CONTAINER" psql -U "$SUPER" -d postgres -X -tAc "SELECT 1" >/dev/null 2>&1; then
  MODE=docker
  run(){ docker exec -e PGPASSWORD="$SUPERPW" "$CONTAINER" psql -U "$SUPER" -d postgres -X -tAc "$1"; }
else
  echo "PostgreSQL 에 붙지 못했습니다. 다음 중 하나를 확인하세요:" >&2
  echo "  · 서버가 떠 있는가        docker compose -f docker/docker-compose.yml up -d postgres" >&2
  echo "                            (호스트 설치판이면) ./scripts/restore-lab.sh" >&2
  echo "  · 슈퍼유저 이름이 맞는가  현재 '$SUPER' 로 시도했다." >&2
  echo "                            compose 판은 tuner, 호스트 설치판은 보통 postgres 다:" >&2
  echo "                              PGSUPER=postgres $0" >&2
  echo "  · 컨테이너 이름이 맞는가  현재 '$CONTAINER' (CONTAINER=... 로 바꾼다)" >&2
  exit 1
fi
echo "접속 경로: $MODE (슈퍼유저 $SUPER)"

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
