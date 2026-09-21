# shellcheck shell=bash
# restore-lab.sh --mysql 의 본체. 단독 실행용이 아니라 source 해서 쓴다.
#
# 왜 따로 있나 — PostgreSQL 쪽과 겹치는 점검이 하나도 없기 때문이다. 롤도 DB 도 설정도
# 잔여물도 전부 다른 이름·다른 명령이고, 같은 파일에 넣으면 분기가 줄줄이 붙는다.
#
# 다루는 것:
#   1) 클라이언트 / 서버        — 호스트 설치(service mysql)와 Docker(tuninglab-mysql) 둘 다
#   2) 계정 tuner
#   3) DB tpch / tpcds / sysbench_lab 와 데이터·인덱스
#   4) 측정 조건                 — innodb_buffer_pool_size 등. **보고만 하고 바꾸지 않는다**(아래 주석)
#   5) 실습 잔여물               — mt-*-mysql.sh 가 만드는 테이블·DB·뷰·함수·계정
#
# 쓰는 곳: scripts/tpch/mt-tenant-isolation-mysql.sh, scripts/tpcds/mt-tenant-isolation-mysql.sh,
#          scripts/sysbench/m4-m7-mysql.sh

restore_mysql() {
  local MYHOST="${MYSQL_HOST:-127.0.0.1}"
  local MYPORT="${MYSQL_PORT:-3306}"
  local MYUSER="${MYSQL_USER:-tuner}"
  local MYPASS="${MYSQL_PASS:-tuner}"
  local MYROOT="${MYSQL_ROOT_PASS:-root}"
  local MYCON="${MYSQL_CONTAINER:-tuninglab-mysql}"

  say "MySQL 랩 점검 — $HERE"
  say

  # ── 1) 클라이언트 ───────────────────────────────────────────────────
  # PostgreSQL 쪽 스크립트들이 psql 없으면 docker exec 로 넘어가는 것과 같은 구조다.
  # Docker 로 돌리는 환경에는 호스트에 클라이언트가 없는 게 보통이라, 없다고 멈추면
  # **서버는 멀쩡한데 점검을 못 한다.** 실제로 그렇게 막혔다.
  local VIA
  if have mysql; then
    VIA=host; ok "mysql 클라이언트 있음 (호스트)"
  elif have docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$MYCON"; then
    VIA=docker; ok "호스트에 클라이언트가 없다 — 컨테이너($MYCON) 안의 것을 쓴다"
  else
    warn "mysql 클라이언트도 $MYCON 컨테이너도 없다"
    say  "       sudo apt install mysql-client        # 호스트에 설치하거나"
    say  "       docker compose -f docker/docker-compose.yml up -d mysql   # 컨테이너를 올린다"
    return 1
  fi

  # -N -B 로 헤더·격자를 빼서 값만 받는다. 경고 한 줄("Using a password on the command line")은
  # 항상 붙으므로 걸러낸다 — 안 걸러내면 숫자 비교가 전부 어긋난다.
  # docker 경로는 -i(표준입력 유지)만 주고 -t 는 주지 않는다 — TTY 를 붙이면 출력에 CR 이
  # 섞여 숫자 비교가 조용히 어긋난다.
  m() {
    if [ "$VIA" = host ]; then mysql -h "$MYHOST" -P "$MYPORT" -u "$MYUSER" -p"$MYPASS" -N -B -e "$1" 2>/dev/null
    else docker exec -i "$MYCON" mysql -u "$MYUSER" -p"$MYPASS" -N -B -e "$1" 2>/dev/null; fi
  }
  mr() {
    if [ "$VIA" = host ]; then mysql -h "$MYHOST" -P "$MYPORT" -u root -p"$MYROOT" -N -B -e "$1" 2>/dev/null
    else docker exec -i "$MYCON" mysql -u root -p"$MYROOT" -N -B -e "$1" 2>/dev/null; fi
  }
  # mysqladmin 도 호스트에 없을 수 있으므로 핑을 쿼리로 대신한다.
  m_up() { [ "$(m "SELECT 1")" = "1" ]; }

  # ── 2) 서버 ─────────────────────────────────────────────────────────
  if m_up; then
    ok "MySQL 서버 online ($(m "SELECT VERSION()"))"
  elif [ "$MODE" = "--check" ]; then
    warn "MySQL 서버 down 또는 접속 불가"
    return 1
  else
    act "MySQL 을 기동한다"
    if dk_exists "$MYCON"; then
      say "     (Docker — $MYCON)"
      docker start "$MYCON" 2>&1 | sed 's/^/     /'
    elif have docker && [ -f docker/docker-compose.yml ] && ! have mysqld; then
      say "     (컨테이너가 아직 없다 — docker compose up -d mysql)"
      ( cd docker && docker compose up -d mysql ) 2>&1 | tail -3 | sed 's/^/     /'
    elif have mysqld || [ -x /etc/init.d/mysql ]; then
      say "     (호스트 설치 — service mysql start)"
      service mysql start 2>&1 | tail -2 | sed 's/^/     /'
    else
      warn "MySQL 을 기동할 방법이 없다 — mysqld 도 tuninglab-mysql 컨테이너도 안 보인다"
      return 1
    fi
    # 기동 직후에는 소켓이 열려도 초기화가 안 끝나 있다. 최대 30초 기다린다.
    local i=0
    while [ "$i" -lt 30 ] && ! m_up; do sleep 1; i=$((i+1)); done
    m_up && { ok "MySQL 기동됨 ($(m "SELECT VERSION()"))"; CHANGED=1; } \
          || { warn "기동했는데 접속이 안 된다 — 호스트면 /var/log/mysql/error.log,"
               warn "           Docker 면 docker logs tuninglab-mysql"; return 1; }
  fi

  # ── 3) 계정 ─────────────────────────────────────────────────────────
  # 여기까지 왔다는 건 tuner 로 이미 붙었다는 뜻이다(m_up 이 tuner 로 핑한다).
  # 권한은 따로 본다 — mt-*-mysql.sh 가 DB 25개와 계정 하나를 만들고 지운다.
  #
  # `ALL PRIVILEGES ON *.*` 문자열만 찾으면 안 된다. MySQL 은 GRANT 를 개별 권한 목록으로
  # 펼쳐 보여 주는 경우가 많아서(특히 동적 권한이 붙으면), 충분한 계정도 '좁다'고 잡힌다.
  # **필요한 권한을 하나씩 본다** — 그래야 부족할 때 무엇이 없는지도 같이 말할 수 있다.
  local GRANTS MISSING=""
  GRANTS=$(m "SHOW GRANTS FOR CURRENT_USER()" | tr '\n' ' ')
  case "$GRANTS" in *"ALL PRIVILEGES ON *.*"*|*"GRANT ALL ON *.*"*) GRANTS="$GRANTS CREATE DROP CREATE USER CREATE ROUTINE" ;; esac
  for p in "CREATE" "DROP" "CREATE USER" "CREATE ROUTINE"; do
    case "$GRANTS" in *"$p"*) ;; *) MISSING="$MISSING $p," ;; esac
  done
  if [ -z "$MISSING" ]; then
    ok "계정 tuner — DB·계정·함수를 만들 권한 있음"
  elif [ "$MODE" = "--check" ]; then
    warn "계정 tuner 에 없는 권한:${MISSING%,} — mt-*-mysql.sh 가 중간에 죽는다"
    say  "       GRANT ALL ON *.* TO '$MYUSER'@'%' WITH GRANT OPTION;"
  else
    # compose 의 init(docker/mysql/init/01-create-databases.sql)은 **tpch.\*·tpcds.\*·
    # sysbench_lab.\* 에만** ALL 을 준다. 그런데 mt-*-mysql.sh 는 mt_n0..24 라는 **새 DB** 25개와
    # 계정 mt_app 을 만든다 — 그 권한은 init 에 없다. 그래서 스크립트가 준비 단계에서 죽는다.
    # 실습용 로컬 컨테이너이므로 root 로 넓혀 준다. 무엇을 실행했는지 그대로 찍는다.
    warn "계정 $MYUSER 에 없는 권한:${MISSING%,} — mt-*-mysql.sh 가 중간에 죽는다"
    act "root 로 권한을 넓힌다"
    for h in '%' 'localhost'; do
      mr "GRANT ALL ON *.* TO '$MYUSER'@'$h' WITH GRANT OPTION" >/dev/null 2>&1
      # SET GLOBAL(§M-7 의 redo·내구성 조절)은 ALL 에 안 들어간다 — 동적 권한은 따로 준다.
      mr "GRANT SYSTEM_VARIABLES_ADMIN ON *.* TO '$MYUSER'@'$h'" >/dev/null 2>&1
    done
    mr "FLUSH PRIVILEGES" >/dev/null 2>&1
    say  "       GRANT ALL ON *.* TO '$MYUSER'@'%' WITH GRANT OPTION;"
    say  "       GRANT SYSTEM_VARIABLES_ADMIN ON *.* TO '$MYUSER'@'%';"
    GRANTS=$(m "SHOW GRANTS FOR CURRENT_USER()" | tr '\n' ' ')
    case "$GRANTS" in
      *"ALL PRIVILEGES ON *.*"*|*"GRANT ALL ON *.*"*) ok "넓혔다"; CHANGED=1 ;;
      *) warn "권한이 그대로다 — root 비밀번호가 다를 수 있다. MYSQL_ROOT_PASS=... 로 다시:"
         say  "       MYSQL_ROOT_PASS=<비번> ./scripts/restore-lab.sh --mysql" ;;
    esac
  fi

  # ── 4) 데이터 ───────────────────────────────────────────────────────
  # MySQL 에는 pg_indexes 가 없다. information_schema.statistics 는 **컬럼당 한 행**이므로
  # DISTINCT index_name 으로 세야 한다 — 안 그러면 복합 인덱스가 여러 개로 잡힌다.
  local mgen_ran=0
  mgen() {  # $1 = 모듈, $2.. = args
    local mod="$1"; shift
    for a in "$@"; do
      printf "     ./gradlew :%s:bootRun --args=\"%s\"\n" "$mod" "$a"
      ./gradlew -q ":$mod:bootRun" --args="$a" 2>&1 \
        | grep -viE '^(picked up|note:|warning: )' | tail -3 | sed 's/^/       /'
    done
    mgen_ran=1
  }
  nidx() { m "SELECT count(DISTINCT index_name) FROM information_schema.statistics
               WHERE table_schema='$1' AND table_name='$2'"; }

  chk_data() {  # $1 = DB, $2 = 테이블, $3 = 모듈, $4 = generate 인자(없으면 빈 문자열)
    local db="$1" tbl="$2" mod="$3" genarg="$4" n idx
    if [ "$(m "SELECT count(*) FROM information_schema.schemata WHERE schema_name='$db'")" != "1" ]; then
      if [ "$MODE" = "--check" ]; then
        # 여기서 멈춰서 gradlew 를 먼저 돌리면 이렇게 죽는다 — 원인이 안 보이는 에러라 적어 둔다:
        #   HikariPool$PoolInitializationException: Failed to initialize pool: Unknown database 'tpch'
        # JDBC URL 이 .../tpch 라서 **DB 가 먼저 있어야** schema 가 돈다.
        warn "DB $db 없음 — 이 상태로 gradlew 를 돌리면 Unknown database '$db' 로 죽는다"
        return
      fi
      # compose 의 init 은 **볼륨이 비어 있는 첫 기동에만** 돈다. 볼륨을 먼저 만들어 둔
      # 환경에서는 tpch/tpcds/sysbench_lab 이 영영 안 생긴다 — 실제로 그 상태였다.
      act "DB $db 를 만든다"
      m "CREATE DATABASE $db CHARACTER SET utf8mb4" >/dev/null 2>&1 \
        || mr "CREATE DATABASE $db CHARACTER SET utf8mb4" >/dev/null 2>&1
      if [ "$(m "SELECT count(*) FROM information_schema.schemata WHERE schema_name='$db'")" != "1" ]; then
        warn "DB $db 를 못 만들었다 — $MYUSER 에게 CREATE 권한이 없고 root 접속도 안 된다"
        say  "       MYSQL_ROOT_PASS=<비번> ./scripts/restore-lab.sh --mysql"
        return
      fi
      CHANGED=1
    fi
    n=$(m "SELECT count(*) FROM $db.$tbl" 2>/dev/null)
    if [ -n "$n" ] && [ "$n" -gt 0 ]; then
      idx=$(nidx "$db" "$tbl")
      if [ "${idx:-0}" -ge 2 ]; then
        ok "$db.$tbl $n 행 (인덱스 ${idx}개)"
      else
        # PostgreSQL 쪽 정정 8번과 같은 함정이다 — 행은 있는데 인덱스가 없으면
        # 에러 없이 측정값만 배수로 어긋난다. InnoDB 는 PK 가 곧 물리 배치라 더 크게 어긋난다.
        warn "$db.$tbl 이 $n 행인데 인덱스가 ${idx:-0}개다 — index 를 안 돌렸다"
        if [ "$MODE" = "--check" ]; then
          say "       ./gradlew :$mod:bootRun --args=\"index --db=mysql\""
        else
          act "index 실행"; mgen "$mod" "index --db=mysql"
          ok "$db.$tbl 인덱스 $(nidx "$db" "$tbl")개"; CHANGED=1
        fi
      fi
    else
      if [ "$MODE" = "--check" ]; then warn "$db 가 비어 있다"; return; fi
      act "$db 적재 (MySQL)"
      # 데이터 파일은 PostgreSQL 쪽과 공유한다. 이미 있으면 generate 를 건너뛴다
      # (SF=10 이면 생성에만 수 분 걸린다).
      if [ -n "$genarg" ] && [ ! -d "$HERE/$mod/data/$mod" ]; then
        mgen "$mod" "$genarg"
      fi
      case "$mod" in
        tpch)  mgen tpch  "schema --db=mysql" "load --db=mysql --dir=./data/tpch" "index --db=mysql" ;;
        tpcds) mgen tpcds "schema --db=mysql" "load --db=mysql"                   "index --db=mysql" ;;
      esac
      # 행수만 찍으면 안 된다 — 이 절이 존재하는 이유가 '인덱스가 빠진 채 적재된 상태'다.
      ok "$db.$tbl $(m "SELECT count(*) FROM $db.$tbl") 행 (인덱스 $(nidx "$db" "$tbl")개)"; CHANGED=1
    fi
  }
  chk_data tpch  lineitem    tpch  "generate --sf=$SF --dir=./data/tpch"
  chk_data tpcds store_sales tpcds "generate --sales=$SALES"

  # sysbench_lab 은 gradle 이 아니라 sysbench 바이너리가 채운다 — 명령이 다르다.
  local SB; SB=$(m "SELECT count(*) FROM information_schema.tables WHERE table_schema='sysbench_lab'")
  if [ "${SB:-0}" -gt 0 ]; then
    ok "sysbench_lab 테이블 ${SB}개 (M-4~M-7 용)"
  else
    warn "sysbench_lab 이 비어 있다 — scripts/sysbench/m4-m7-mysql.sh 가 못 돈다"
    say  "       sysbench oltp_read_write --mysql-host=$MYHOST --mysql-user=tuner --mysql-password=tuner \\"
    say  "         --mysql-db=sysbench_lab --tables=4 --table-size=1000000 prepare"
  fi

  # ── 5) 측정 조건 ────────────────────────────────────────────────────
  # PostgreSQL 쪽은 ALTER SYSTEM 으로 되돌리지만 여기서는 **보고만 한다.**
  # 설정 출처가 환경마다 다르기 때문이다 — Docker 면 docker/mysql/my.cnf(재기동 필요),
  # 호스트 설치면 /etc/mysql/...  SET GLOBAL 로 덮으면 파일과 실제 값이 어긋난 채로 남아
  # 다음 사람이 my.cnf 를 읽고 틀린 조건을 가정하게 된다. 그게 더 나쁘다.
  local BP RL FL TI
  BP=$(m "SELECT round(@@innodb_buffer_pool_size/1024/1024)")
  RL=$(m "SELECT round(@@innodb_redo_log_capacity/1024/1024)")
  FL=$(m "SELECT @@innodb_flush_log_at_trx_commit")
  TI=$(m "SELECT @@transaction_isolation")
  say
  say "  측정 조건 (docker/mysql/my.cnf 의 값이 기준):"
  [ "${BP:-0}" = "1024" ] && ok "innodb_buffer_pool_size = ${BP}M" \
                          || warn "innodb_buffer_pool_size = ${BP}M (기준 1024M) — hit rate 실습값이 어긋난다"
  [ "${RL:-0}" = "1024" ] && ok "innodb_redo_log_capacity = ${RL}M" \
                          || warn "innodb_redo_log_capacity = ${RL}M (기준 1024M) — M-7 이 압력을 못 만들거나 과하게 만든다"
  [ "${FL:-}" = "1" ]     && ok "innodb_flush_log_at_trx_commit = 1" \
                          || warn "innodb_flush_log_at_trx_commit = $FL (기준 1) — 커밋 내구성이 다르면 TPS 가 통째로 다르다"
  [ "${TI:-}" = "REPEATABLE-READ" ] && ok "transaction_isolation = $TI" \
                          || warn "transaction_isolation = $TI (기준 REPEATABLE-READ) — 갭락 실습이 달라진다"
  say "  ※ m4-m7-mysql.sh 는 redo·내구성을 실습 중에 바꿨다가 **끝에서 원래 값으로 되돌린다.**"
  say "     중간에 끊겼으면 위 값이 그 흔적이다. 되돌리려면:"
  say "       mysql -u tuner -ptuner -e \"SET GLOBAL innodb_redo_log_capacity=1073741824;\""

  # ── 6) 실습 잔여물 ──────────────────────────────────────────────────
  # mt-*-mysql.sh 는 스스로 지우지만 중간에 끊기면 남는다. 남은 li_ac/ss_ac 는
  # 다음 실행의 ① 측정을 조용히 바꾸고, 남은 mt_n* DB 25개는 SHOW DATABASES 를 덮는다.
  local L_TBL L_DB L_USR
  L_TBL=$(m "SELECT count(*) FROM information_schema.tables
              WHERE (table_schema='tpch'  AND table_name IN ('li_a','li_ac','li_part','li_bad','v_li'))
                 OR (table_schema='tpcds' AND table_name IN ('ss_a','ss_ac','ss_part','ss_bad','v_ss'))")
  L_DB=$(m "SELECT count(*) FROM information_schema.schemata
             WHERE schema_name LIKE 'mt\_n%' OR schema_name LIKE 'mt\_s%'")
  L_USR=$(m "SELECT count(*) FROM mysql.user WHERE user='mt_app'")
  say
  if [ "${L_TBL:-0}" = "0" ] && [ "${L_DB:-0}" = "0" ] && [ "${L_USR:-0}" = "0" ]; then
    ok "실습 잔여물 없음"
  else
    warn "실습 잔여물 — 테이블/뷰 ${L_TBL:-0} / DB ${L_DB:-0}개 / 계정 mt_app ${L_USR:-0}"
    say  "     남으면 다음 측정이 **에러 없이** 달라진다. 지우려면:"
    say  "       mysql -u tuner -ptuner -e \"DROP TABLE IF EXISTS tpch.li_a, tpch.li_ac, tpch.li_part, tpch.li_bad;\" \\"
    say  "         -e \"DROP VIEW IF EXISTS tpch.v_li; DROP FUNCTION IF EXISTS tpch.app_tenant;\" \\"
    say  "         -e \"DROP TABLE IF EXISTS tpcds.ss_a, tpcds.ss_ac, tpcds.ss_part, tpcds.ss_bad;\" \\"
    say  "         -e \"DROP VIEW IF EXISTS tpcds.v_ss; DROP FUNCTION IF EXISTS tpcds.app_store;\" \\"
    say  "         -e \"DROP USER IF EXISTS 'mt_app'@'%';\""
    say  "       # mt_n0..24 / mt_s1..N 은 수가 많다 — 한 줄로:"
    say  "       mysql -N -B -u tuner -ptuner -e \"SELECT concat('DROP DATABASE \\\`',schema_name,'\\\`;')"
    say  "         FROM information_schema.schemata WHERE schema_name LIKE 'mt\\_n%' OR schema_name LIKE 'mt\\_s%'\" \\"
    say  "         | mysql -u tuner -ptuner"
  fi

  say
  if [ "$MODE" = "--check" ]; then
    say "점검만 했다. 복구하려면 --check 없이 다시 실행한다."
  elif [ "$CHANGED" = "1" ]; then
    say "복구 완료. 바로 실습을 이어갈 수 있다:"
    say "  ./scripts/tpch/mt-tenant-isolation-mysql.sh"
    say "  ./scripts/tpcds/mt-tenant-isolation-mysql.sh"
  else
    say "고칠 것이 없었다."
  fi
  return 0
}
