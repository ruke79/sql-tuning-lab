#!/usr/bin/env bash
# 랩 환경 복구 — 컨테이너/VM 이 재생성된 뒤 실습을 이어가기 위한 한 줄 진입점.
#
# 이 랩은 **두 가지 모양**으로 돌아간다. 이 스크립트는 둘 다 다룬다:
#   (a) 호스트에 직접 설치된 PostgreSQL 16 / MySQL 8  → pg_ctlcluster, service mysql
#   (b) docker/docker-compose.yml 의 컨테이너         → tuninglab-postgres, tuninglab-mysql
# 기동 방법만 다르고 나머지 점검은 같다. **어느 쪽인지 스크립트가 알아서 판별한다** —
# 예전에는 (a)만 가정해서, Docker 를 쓰는 환경에서 `pg_ctlcluster: command not found` 로 죽었다.
#
# 컨테이너/클러스터가 재생성되면 다음 중 하나가 깨져 있고, 증상이 서로 비슷해서 헷갈린다:
#
#   증상                                          실제 원인            이 스크립트가 하는 일
#   ─────────────────────────────────────────────────────────────────────────────
#   Connection refused                            클러스터가 down      pg_ctlcluster start
#   password authentication failed for "tuner"    롤이 사라짐          롤 재생성
#   database "tpcds" does not exist               DB 가 사라짐         DB 재생성
#   relation "store_sales" does not exist         데이터만 사라짐      generate→schema→load→index
#   측정값이 문서와 배수로 다름                   서버 설정이 기본값   측정 조건으로 되돌림
#   gradlew build 가 verify-lab:test 에서 실패  verifylab DB 없음    setup-verifylab.sh 실행
#
# **데이터가 남아 있으면 건드리지 않는다.** 재적재는 비어 있을 때만 한다.
#
# 사용법:
#   ./scripts/restore-lab.sh              # PostgreSQL 을 점검하고 빠진 것만 복구
#   ./scripts/restore-lab.sh --mysql      # **MySQL 쪽**을 점검/복구 (mt-*-mysql.sh·sysbench 용)
#   ./scripts/restore-lab.sh --check      # 점검만 (아무것도 바꾸지 않는다)
#   ./scripts/restore-lab.sh --mysql --check
#   ./scripts/restore-lab.sh --force-tpch # tpch 를 데이터가 있어도 다시 적재
#   SF=1 ./scripts/restore-lab.sh         # tpch 스케일 (기본 0.5 — 문서의 측정 조건)
#   SALES=2000000 ./scripts/restore-lab.sh   # tpcds store_sales 행수 (기본 200만)
set -uo pipefail

usage() {
  sed -n '/^# 사용법:/,/^set -uo/p' "$0" | sed '$d;s/^# \{0,1\}//'
}

# 모르는 인자를 **조용히 무시하면** 안 된다. 실제로 `--mysql` 이 없던 시절에 그 인자를 주면
# 스크립트가 그걸 버리고 PostgreSQL 경로로 들어가, 엉뚱한 곳에서 실패했다
# (`pg_ctlcluster: command not found`). 사용자는 MySQL 을 고치려다 PostgreSQL 에러를 받는다.
MODE=""
DO_MYSQL=0
for a in "$@"; do
  case "$a" in
    --check)      MODE="--check" ;;
    --force-tpch) MODE="--force-tpch" ;;
    --mysql)      DO_MYSQL=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) printf "  \033[33m!\033[0m 알 수 없는 인자: %s\n\n" "$a"; usage; exit 2 ;;
  esac
done

SF="${SF:-0.5}"
SALES="${SALES:-2000000}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

# 문서(§T-0 이후 전 실습)의 측정 조건. 이 값이 다르면 실측표와 배수가 어긋난다.
WANT_SHARED_BUFFERS="1GB"
WANT_WORK_MEM="64MB"          # 스크립트들은 자기 세션에만 PGOPTIONS 로 4GB 를 건다
WANT_PARALLEL="4"

say()  { printf "%s\n" "$*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$*"; }
act()  { printf "  \033[36m→\033[0m %s\n" "$*"; }
CHANGED=0

as_pg()  { sudo -u postgres psql -X -q -tAc "$1" 2>/dev/null; }
as_pgc() { sudo -u postgres psql -X -q -c "$1" 2>&1; }
t_sql()  { PGPASSWORD=tuner psql -h localhost -U tuner -d "$1" -X -q -tAc "$2" 2>/dev/null; }

# 호스트 설치냐 Docker 냐 — 기동/재기동 방법만 다르다. 둘 다 없으면 그렇게 말한다.
have()      { command -v "$1" >/dev/null 2>&1; }
dk_exists() { have docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
pg_start() {
  if have pg_ctlcluster; then
    # 컨테이너가 죽을 때 남은 pid 파일이 기동을 막는다 — pg_ctlcluster 가 알아서 치운다
    pg_ctlcluster 16 main start 2>&1 | sed 's/^/     /'
  elif dk_exists tuninglab-postgres; then
    say "     (호스트 설치가 아니라 Docker 다 — tuninglab-postgres 를 올린다)"
    docker start tuninglab-postgres 2>&1 | sed 's/^/     /'
  elif have docker && [ -f docker/docker-compose.yml ]; then
    say "     (컨테이너가 아직 없다 — docker compose up -d postgres)"
    ( cd docker && docker compose up -d postgres ) 2>&1 | tail -3 | sed 's/^/     /'
  else
    warn "PostgreSQL 을 기동할 방법이 없다 — pg_ctlcluster 도 docker 도 안 보인다"
    return 1
  fi
}
pg_restart() {
  if have pg_ctlcluster;                then pg_ctlcluster 16 main restart 2>&1 | sed 's/^/     /'
  elif dk_exists tuninglab-postgres;    then docker restart tuninglab-postgres 2>&1 | sed 's/^/     /'
  else warn "재기동 방법을 못 찾았다 — 설정이 반영되지 않았다"; fi
}

# MySQL 쪽은 PostgreSQL 과 겹치는 점검이 하나도 없어서 별도 경로로 끝낸다.
if [ "$DO_MYSQL" = "1" ]; then
  . "$HERE/scripts/restore-lab-mysql.inc"
  restore_mysql
  exit $?
fi

say "랩 환경 점검 — $HERE"
say

# ── 1) 클러스터 ───────────────────────────────────────────────────────
if pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
  ok "PostgreSQL 클러스터 online"
else
  if [ "$MODE" = "--check" ]; then
    warn "클러스터 down"
  else
    act "클러스터를 기동한다"
    pg_start
    sleep 2
    pg_isready -h localhost -p 5432 >/dev/null 2>&1 \
      && { ok "클러스터 기동됨"; CHANGED=1; } \
      || { warn "기동 실패 — 호스트 설치면 /var/log/postgresql/postgresql-16-main.log,"
           warn "           Docker 면 docker logs tuninglab-postgres"; exit 1; }
  fi
fi
pg_isready -h localhost -p 5432 >/dev/null 2>&1 || { warn "클러스터가 없으면 아래를 볼 수 없다"; exit 1; }

# ── 2) 롤 ─────────────────────────────────────────────────────────────
if [ "$(as_pg "SELECT 1 FROM pg_roles WHERE rolname='tuner'")" = "1" ]; then
  ok "롤 tuner 있음"
else
  if [ "$MODE" = "--check" ]; then warn "롤 tuner 없음"; else
    act "롤 tuner 를 만든다 (슈퍼유저 — verify-lab 의 RLS 케이스가 롤 생성 권한을 쓴다)"
    as_pgc "CREATE ROLE tuner LOGIN SUPERUSER PASSWORD 'tuner'" | sed 's/^/     /'; CHANGED=1
  fi
fi

# ── 3) 데이터베이스 ───────────────────────────────────────────────────
for db in tpch tpcds; do
  if [ "$(as_pg "SELECT 1 FROM pg_database WHERE datname='$db'")" = "1" ]; then
    ok "DB $db 있음"
  else
    if [ "$MODE" = "--check" ]; then warn "DB $db 없음"; else
      act "DB $db 를 만든다"
      as_pgc "CREATE DATABASE $db OWNER tuner" | sed 's/^/     /'; CHANGED=1
    fi
  fi
done

# ── 4) 서버 설정 ──────────────────────────────────────────────────────
# ALTER SYSTEM 은 트랜잭션 블록 안에서 못 돈다 — -c 를 나눠 보낸다(정정 목록의 그 함정).
NEED_RESTART=0
chk() {  # $1 = 파라미터, $2 = 원하는 값
  local cur; cur=$(as_pg "SELECT setting||coalesce(unit,'') FROM pg_settings WHERE name='$1'")
  local want_b cur_b
  # 8kB 단위로 나오는 것(shared_buffers)과 문자열을 같은 자로 비교한다
  want_b=$(as_pg "SELECT pg_size_bytes('$2')" 2>/dev/null)
  cur_b=$(as_pg "SELECT CASE WHEN unit='8kB' THEN setting::bigint*8192
                             WHEN unit='kB'  THEN setting::bigint*1024
                             WHEN unit IS NULL THEN setting::bigint
                             ELSE NULL END FROM pg_settings WHERE name='$1'")
  if [ -n "$want_b" ] && [ "$want_b" = "$cur_b" ]; then ok "$1 = $2"; return; fi
  if [ "$(as_pg "SELECT setting FROM pg_settings WHERE name='$1'")" = "$2" ]; then ok "$1 = $2"; return; fi
  if [ "$MODE" = "--check" ]; then warn "$1 이 $2 가 아니다 (현재 $cur)"; else
    act "$1 → $2 (현재 $cur)"
    as_pgc "ALTER SYSTEM SET $1 = '$2'" >/dev/null; NEED_RESTART=1; CHANGED=1
  fi
}
chk shared_buffers "$WANT_SHARED_BUFFERS"
chk work_mem "$WANT_WORK_MEM"
chk max_parallel_workers_per_gather "$WANT_PARALLEL"
# wal_level 은 성능 설정처럼 안 보이지만 **측정 기준**이다 — logical 로 올라가 있으면
# UPDATE 당 WAL 이 약 80바이트 늘어 §T-8 의 쓰기 비용 수치가 통째로 달라진다.
# verify-lab 의 DB-10(CDC)을 돌리려고 올렸다가 안 되돌린 경우가 실제로 있었다.
chk wal_level "${WANT_WAL_LEVEL:-replica}"
if [ "$NEED_RESTART" = "1" ]; then
  act "설정 반영을 위해 재기동"
  pg_restart; sleep 2
fi

# ── 5) 데이터 ─────────────────────────────────────────────────────────
# 주의: `--dir=./data/tpch` 는 저장소 루트가 아니라 **모듈 디렉터리** 기준으로 풀린다
# (gradle bootRun 의 작업 디렉터리가 tpch/ 라서 실제 경로는 tpch/data/tpch 다).
# generate 와 load 가 같은 상대 경로를 쓰므로 동작에는 문제가 없지만,
# COPY 스크립트를 직접 부를 때는 tpch/data/tpch 를 줘야 한다.
gen() {  # $1 = 모듈, $2.. = args
  local m="$1"; shift
  for a in "$@"; do
    printf "     ./gradlew :%s:bootRun --args=\"%s\"\n" "$m" "$a"
    ./gradlew -q ":$m:bootRun" --args="$a" 2>&1 | grep -viE '^(picked up|note:|warning: )' | tail -3 | sed 's/^/       /'
  done
}

# 행이 있어도 **인덱스가 없으면 쓸 수 없는 상태**다. 정정 목록 8번이 그 사고였다 —
# load 후 index 를 안 돌린 채 재니 lineitem 에 PK 가 없어 ON CONFLICT 가 무력화되고
# 중복이 들어갔고, 측정값은 39배 어긋났다. 에러가 안 나므로 여기서 잡아 준다.
idx_warn() {  # $1 = db, $2 = 테이블, $3 = 최소 인덱스 수
  local n; n=$(t_sql "$1" "SELECT count(*) FROM pg_indexes WHERE tablename='$2'")
  [ "${n:-0}" -ge "$3" ] && { echo "$n"; return 0; }
  echo "$n"; return 1
}
TPCH_N=$(t_sql tpch "SELECT count(*) FROM lineitem")
if [ -n "$TPCH_N" ] && [ "$TPCH_N" -gt 0 ] && [ "$MODE" != "--force-tpch" ]; then
  if NIDX=$(idx_warn tpch lineitem 2); then
    ok "tpch lineitem $TPCH_N 행 (인덱스 ${NIDX}개)"
  else
    warn "tpch lineitem 이 $TPCH_N 행인데 인덱스가 ${NIDX}개다 — 적재가 덜 끝났거나 index 를 안 돌렸다"
    say  "     이 상태로 재면 측정값이 배수로 어긋난다(정정 8번). 인덱스를 만든다:"
    if [ "$MODE" != "--check" ]; then
      act "index 실행"
      gen tpch "index --db=postgres"
      ok "tpch 인덱스 $(t_sql tpch "SELECT count(*) FROM pg_indexes WHERE tablename='lineitem'")개"; CHANGED=1
    else
      say "       ./gradlew :tpch:bootRun --args=\"index --db=postgres\""
    fi
  fi
else
  if [ "$MODE" = "--check" ]; then warn "tpch 가 비어 있다"; else
    act "tpch 재적재 (SF=$SF — 문서 실측표의 조건)"
    gen tpch "generate --sf=$SF --dir=./data/tpch" "schema --db=postgres" \
             "load --db=postgres --dir=./data/tpch" "index --db=postgres"
    ok "tpch lineitem $(t_sql tpch "SELECT count(*) FROM lineitem") 행"; CHANGED=1
  fi
fi

TPCDS_N=$(t_sql tpcds "SELECT count(*) FROM store_sales")
if [ -n "$TPCDS_N" ] && [ "$TPCDS_N" -gt 0 ]; then
  if NIDX=$(idx_warn tpcds store_sales 2); then
    ok "tpcds store_sales $TPCDS_N 행 (인덱스 ${NIDX}개)"
  else
    warn "tpcds store_sales 가 $TPCDS_N 행인데 인덱스가 ${NIDX}개다"
    if [ "$MODE" != "--check" ]; then
      act "index 실행"; gen tpcds "index --db=postgres"
      ok "tpcds 인덱스 $(t_sql tpcds "SELECT count(*) FROM pg_indexes WHERE tablename='store_sales'")개"; CHANGED=1
    else
      say "       ./gradlew :tpcds:bootRun --args=\"index --db=postgres\""
    fi
  fi
else
  if [ "$MODE" = "--check" ]; then warn "tpcds 가 비어 있다"; else
    act "tpcds 재적재 (store_sales $SALES 행)"
    gen tpcds "generate --sales=$SALES" "schema --db=postgres" "load --db=postgres" "index --db=postgres"
    ok "tpcds store_sales $(t_sql tpcds "SELECT count(*) FROM store_sales") 행"; CHANGED=1
  fi
fi

# ── 6) 실습 잔여물 ────────────────────────────────────────────────────
# 실험 스크립트는 스스로 지우지만, 중간에 끊기면 남는다. 남으면 다음 측정을 오염시킨다
# (특히 lineitem 의 트리거는 **모든 쓰기**에 붙는다).
# verify-lab 테스트가 쓰는 DB. 없으면 ./gradlew build 가 :verify-lab:test 에서 죽는데,
# 콘솔 에러(DialectFactoryImpl:191)가 원인을 안 알려줘서 헤매기 쉽다 — 여기서 짚어 준다.
VL=$(as_pg "SELECT count(*) FROM pg_database WHERE datname='verifylab'")
if [ "${VL:-0}" = "1" ]; then
  ok "verifylab DB 있음 (./gradlew build 가 이걸 요구한다)"
else
  if [ "$MODE" = "--check" ]; then
    warn "verifylab DB 없음 — ./gradlew build 가 :verify-lab:test 에서 실패한다"
    say  "       ./scripts/verify/setup-verifylab.sh"
  else
    act "verifylab DB/계정을 만든다"
    # 스크립트가 스스로 호스트/도커 경로와 슈퍼유저를 판별한다 — 여기서 넘기지 않는다.
    "$HERE/scripts/verify/setup-verifylab.sh" 2>&1 | sed 's/^/     /'
    CHANGED=1
  fi
fi

# t_sync%(동기화 트리거)만 보면 큐 실습의 t_enq%(enqueue 트리거)를 놓친다 — 둘 다 lineitem 의
# 모든 쓰기에 붙는다. 실제로 t9-notify-vs-poll 을 돌린 뒤 3개가 남아 있는데 "잔여물 없음" 이
# 나왔다. 둘 다 본다.
LEFT=$(t_sql tpch "SELECT count(*) FROM pg_trigger WHERE tgname LIKE 't\_sync%' OR tgname LIKE 't\_enq%'")
# 큐/동시성 실습은 lineitem 에 l_linenumber>=90 인 행을 넣었다 지운다. 중간에 끊기면 남는데,
# **행수가 늘어난 것은 에러가 아니라 숫자만 달라지는 오염**이다(SF=0.5 는 3,000,491 행이다).
LEFT5=$(t_sql tpch "SELECT count(*) FROM lineitem WHERE l_linenumber >= 90")
LEFT2=$(t_sql tpcds "SELECT count(*) FROM pg_class WHERE relname LIKE 'mt\_%' OR relname IN ('ss_probe','ss_denorm')")
# 실험이 만든 인덱스도 잔여물이다. §T-8 은 정리 명령을 **출력만** 하므로 손으로 안 지우면 남고,
# 남은 idx_li_orderkey_shipdate 는 §T-3·§T-5 의 조인 측정을 조용히 바꿔 놓는다
# (에러가 없으니 다음 사람은 자기가 다른 것을 재고 있다는 걸 모른다).
LEFT3=$(t_sql tpch "SELECT count(*) FROM pg_indexes WHERE indexname IN
          ('idx_li_orderkey_shipdate','idx_li_cover','idx_ord_custkey_orderdate')")
LEFT4=$(t_sql tpcds "SELECT count(*) FROM pg_indexes WHERE indexname IN
          ('idx_ss_item_solddate','idx_ss_cover','mt_shared_date')")
if [ "${LEFT:-0}" = "0" ] && [ "${LEFT2:-0}" = "0" ] && [ "${LEFT3:-0}" = "0" ] && [ "${LEFT4:-0}" = "0" ] \
   && [ "${LEFT5:-0}" = "0" ]; then
  ok "실습 잔여물 없음"
else
  warn "실습 잔여물 — tpch 트리거 ${LEFT:-0} / tpcds 임시테이블 ${LEFT2:-0} / 실험 인덱스 tpch ${LEFT3:-0}·tpcds ${LEFT4:-0} / 실험 lineitem 행 ${LEFT5:-0}"
  say  "     남으면 다음 측정이 **에러 없이** 달라진다. 지우려면:"
  say  "       psql -d tpch  -c \"DROP TRIGGER IF EXISTS t_sync_li ON lineitem;\" \\"
  say  "                     -c \"DROP TRIGGER IF EXISTS t_sync_ord ON orders;\" \\"
  say  "                     -c \"DROP TRIGGER IF EXISTS t_sync_cust ON customer;\" \\"
  say  "                     -c \"DROP TABLE IF EXISTS lineitem_denorm;\" \\"
  say  "                     -c \"DROP INDEX IF EXISTS idx_li_orderkey_shipdate, idx_li_cover, idx_ord_custkey_orderdate;\" \\"
  say  "                     -c \"CREATE INDEX IF NOT EXISTS idx_orders_custkey ON orders(o_custkey);\""
  say  "       psql -d tpcds -c \"DROP TABLE IF EXISTS mt_shared, mt_part, ss_probe, ss_denorm CASCADE;\" \\"
  say  "                     -c \"DROP INDEX IF EXISTS idx_ss_item_solddate, idx_ss_cover;\""
fi

say
if [ "$MODE" = "--check" ]; then
  say "점검만 했다. 복구하려면 인자 없이 다시 실행한다."
elif [ "$CHANGED" = "1" ]; then
  say "복구 완료. 바로 실습을 이어갈 수 있다:"
  say "  ./scripts/tpcds/mt-tenant-isolation.sh"
  say "  ./scripts/tpch/t8-combined-index.sh"
else
  say "고칠 것이 없었다."
fi
