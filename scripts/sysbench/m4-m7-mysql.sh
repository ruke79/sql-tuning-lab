#!/usr/bin/env bash
# §M-4 / M-6 / M-7 의 **MySQL/InnoDB 판** — 같은 세 질문을 다른 엔진에서.
#
# pgbench 로 이미 잰 것(§4 "M-4 / M-6 / M-7" 항목):
#   M-4 무릎이 코어 수(4)에 정확히 있었다. 4→8 에서 TPS 가 줄고 지연만 2배.
#   M-6 커밋마다 WAL 을 내리는 값이 2.2배(synchronous_commit on/off).
#   M-7 redo 공간을 줄이면 TPS 는 12% 주는데 **max 가 54배**(69ms → 3,746ms) 뛰었다.
#
# 이 스크립트는 같은 질문을 InnoDB 에 던진다. 엔진이 다르면 답도 다른가.
# 특히 M-6 은 구조부터 다르다 — **PostgreSQL 은 커밋에 내릴 것이 하나(WAL)인데
# MySQL 은 둘(redo + binlog)이다.** 그래서 2×2 로 잰다.
#
#   ① M-4  스레드 sweep — 무릎이 어디인가
#   ② M-6  내구성 손잡이 2×2 — innodb_flush_log_at_trx_commit × sync_binlog
#   ③ M-7  redo 용량 압력 — innodb_redo_log_capacity 를 줄이면 max 가 뛰는가
#
# **비교 시 주의:** sysbench 의 oltp_read_write 는 한 트랜잭션이 14문장(읽기 10 + 쓰기 4)이고
# pgbench 의 tpcb-like 는 5문장이다. **절대 TPS 를 나란히 놓으면 안 된다.**
# 비교할 수 있는 것은 무릎의 **위치**와 손잡이의 **배수**다.
#
# 사용법:
#   ./m4-m7-mysql.sh              # 전부 (약 6분)
#   ONLY=1 ./m4-m7-mysql.sh       # 무릎 sweep 만
#   SECS=20 ./m4-m7-mysql.sh      # 조건당 시간(기본 10초)
#   TABLES=8 TSIZE=200000 ./m4-m7-mysql.sh
#   THREADS="1 2 4 8 16 32 64 128 256" ./m4-m7-mysql.sh   # ①의 스레드 목록
#     — 코어가 많으면 기본 목록(…64)으로는 **무릎에 닿지 못한다.** 스윕의 마지막
#       칸에서 최대 TPS 가 나오면 스크립트가 그렇다고 말하고 다음 목록을 제안한다.
#
# 선행 조건: sysbench 바이너리, MySQL 접속. 데이터가 없으면 만든다(sysbench_lab DB).
# 내구성 설정은 **전역**을 건드리므로 끝에 원래 값으로 되돌린다.
set -uo pipefail

SECS="${SECS:-10}"
TABLES="${TABLES:-4}"
TSIZE="${TSIZE:-100000}"
# ①의 스레드 목록. 예전에는 루프에 `for th in 1 2 4 8 16 32 64` 로 **박혀** 있었다.
# THREADS=... 를 앞에 붙여도 조용히 무시되고, 표는 64 까지만 나온 채 정상처럼 보였다.
# (같은 부류를 t9-queue-tuning 에서도 겪었다 — 그쪽은 위치 인자인데 환경변수로 줬다.)
THREADS="${THREADS:-1 2 4 8 16 32 64}"
case "$THREADS" in
  *[!0-9\ ]*) echo "  [중단] THREADS 는 공백으로 구분한 양의 정수여야 한다: '$THREADS'"; exit 1;;
esac
[ -z "${THREADS// /}" ] && { echo "  [중단] THREADS 가 비어 있다."; exit 1; }
ONLY="${ONLY:-123}"
MYHOST="${MYSQL_HOST:-127.0.0.1}"
MYPORT="${MYSQL_PORT:-3306}"
MYUSER="${MYSQL_USER:-tuner}"
MYPASS="${MYSQL_PASS:-tuner}"
DB="${MYSQL_DB:-sysbench_lab}"

want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
MYCON="${MYSQL_CONTAINER:-tuninglab-mysql}"

# 호스트에 클라이언트가 없으면 컨테이너 안의 것을 쓴다. (sysbench 자체는 호스트 바이너리이고
# TCP 로 붙으므로 이 분기와 무관하다 — 여기서 갈리는 건 설정을 읽고 쓰는 SQL 호출뿐이다.)
# docker 경로에 -t 를 주면 출력에 CR 이 섞여 숫자 비교가 에러 없이 어긋난다 — -i 만.
if command -v mysql >/dev/null 2>&1; then
  mycli() { mysql -h "$MYHOST" -P "$MYPORT" -u "$MYUSER" -p"$MYPASS" "$@"; }
elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$MYCON"; then
  mycli() { docker exec -i "$MYCON" mysql -u "$MYUSER" -p"$MYPASS" "$@"; }
else
  echo "  mysql 클라이언트도 $MYCON 컨테이너도 없습니다. 둘 중 하나:"
  echo "    sudo apt install mysql-client"
  echo "    docker compose -f docker/docker-compose.yml up -d mysql"
  exit 1
fi
my() { mycli -N -B "$@" 2>&1 | grep -v '^mysql: \[Warning\]'; }
q()  { my -e "$1"; }
qx() { local o; o=$(q "$1"); case "$o" in *ERROR*) echo "  [중단] 준비 실패: $1"; echo "  $o"; exit 1;; esac; }

dispw() { local b k; b=$(printf %s "$1" | wc -c); k=$(printf %s "$1" | LC_ALL=C tr -dc '\200-\277' | wc -c)
          echo $(( b - k / 2 )); }
padr()  { local n; n=$(dispw "$1"); printf "%s" "$1"; while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; }
padl()  { local n; n=$(dispw "$1"); while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; printf "%s" "$1"; }

command -v sysbench >/dev/null 2>&1 || {
  echo "sysbench 가 없습니다.  apt-get install -y sysbench"; exit 1; }
LUA=""
for c in /usr/share/sysbench/oltp_read_write.lua /usr/local/share/sysbench/oltp_read_write.lua oltp_read_write; do
  [ -f "$c" ] && LUA="$c" && break
done
[ -z "$LUA" ] && LUA=oltp_read_write
LUAW="${LUA/oltp_read_write/oltp_write_only}"
[ -f "$LUAW" ] || LUAW=oltp_write_only
V=$(q "SELECT version()")
case "$V" in *ERROR*|'') echo "MySQL 에 붙지 못했습니다: $V"; exit 1;; esac

qx "CREATE DATABASE IF NOT EXISTS $DB"
SB=(sysbench "$LUA" --db-driver=mysql --mysql-host="$MYHOST" --mysql-port="$MYPORT"
    --mysql-user="$MYUSER" --mysql-password="$MYPASS" --mysql-db="$DB"
    --tables="$TABLES" --table-size="$TSIZE" --percentile=99)
N=$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='$DB' AND table_name LIKE 'sbtest%'")
case "$N" in ''|*[!0-9]*) N=0;; esac
if [ "$N" -lt "$TABLES" ]; then
  echo "sysbench 데이터를 만든다 (${TABLES}테이블 × ${TSIZE}행)"
  "${SB[@]}" prepare >/dev/null 2>&1 || { echo "  prepare 실패"; exit 1; }
fi

# 내구성 설정 원복용 — 실험이 죽어도 서버를 원래대로 돌려놓는다.
# 이것들은 **전역 설정**이라 남으면 다른 측정을 조용히 바꾼다(§T-0, restore-lab 의 교훈).
F0=$(q "SELECT @@innodb_flush_log_at_trx_commit")
S0=$(q "SELECT @@sync_binlog")
R0=$(q "SELECT @@innodb_redo_log_capacity")
# max_connections 도 전역이라 같이 원복한다. ①에서 스레드가 이 값을 넘으면 sysbench 가
# 아예 못 붙는다(error 1040) — 기본값이 151 이라 256 스레드부터 걸린다.
MC0=$(q "SELECT @@max_connections")
MC_RAISED=0
# max_prepared_stmt_count 도 같은 종류의 벽이다. sysbench 는 **연결마다 준비문을 여러 개**
# 잡는데(--tables 에 비례한다) 기본 상한이 16382 다. max_connections 를 올려서 붙기는
# 했는데 거기서 막히면 `FATAL: mysql_stmt_prepare() failed` 가 난다 — 실측: 512 스레드.
MPS0=$(q "SELECT @@max_prepared_stmt_count")
MPS_RAISED=0
restore() {
  q "SET GLOBAL innodb_flush_log_at_trx_commit=$F0" >/dev/null 2>&1
  q "SET GLOBAL sync_binlog=$S0" >/dev/null 2>&1
  q "SET GLOBAL innodb_redo_log_capacity=$R0" >/dev/null 2>&1
  [ "$MC_RAISED" = "1" ]  && q "SET GLOBAL max_connections=$MC0" >/dev/null 2>&1
  [ "$MPS_RAISED" = "1" ] && q "SET GLOBAL max_prepared_stmt_count=$MPS0" >/dev/null 2>&1
  return 0
}
trap restore EXIT

# 한 번 실행 → "tps|avg|p99|max"
#
# 라벨을 grep 으로 긁어 숫자만 뽑으면 **라벨 안의 숫자에 걸린다** — '99th percentile' 의 99 가
# 먼저 잡혀서 p99 자리에 99 가, max 자리에 아무것도 안 들어갔다(실제로 그랬다).
# 필드 위치로 집는다.
# $2 를 주면 그 lua 로 돌린다(기본은 oltp_read_write).
# **실패를 빈 값으로 흘려보내지 않는다.** sysbench 가 못 붙으면(예: max_connections 초과)
# tps 자리가 비고, 표에는 '?' 가 찍힌다. 그 '?' 를 0 으로 읽으면 아래 판정이
# "처리량이 줄었다"로 말한다 — **측정 실패를 측정 결과로 narrate 하는 것**이다.
# 실패하면 사유를 RUN1_ERR 에 담고 tps 자리를 비운 채 돌려준다.
# 사유는 **파일로** 남긴다. run1 은 $(...) 안에서 불리므로 서브셸이고,
# 거기서 변수에 담으면 호출한 쪽에는 안 남는다 — 이 랩에서 이미 겪은 함정이다
# (첫 판에서 실제로 '사유:' 줄이 통째로 비었다).
RUN1_ERRF="${TMPDIR:-/tmp}/m4run1err.$$"
run1() {
  local th="$1" lua="${2:-$LUA}" out res
  : > "$RUN1_ERRF"
  out=$(sysbench "$lua" --db-driver=mysql --mysql-host="$MYHOST" --mysql-port="$MYPORT" \
        --mysql-user="$MYUSER" --mysql-password="$MYPASS" --mysql-db="$DB" \
        --tables="$TABLES" --table-size="$TSIZE" --percentile=99 \
        --threads="$th" --time="$SECS" --report-interval=0 run 2>&1)
  res=$(echo "$out" | awk '
    /transactions:/ && /per sec/ { gsub(/[()]/,""); tps=$3 }
    /^[ \t]*avg:/ && !a { a=$2 }
    /^[ \t]*max:/ && !m { m=$2 }
    /99th percentile:/  { p=$NF }
    END { printf "%s|%s|%s|%s", tps, a, p, m }')
  case "$res" in
    # 'unable to connect ... aborting' 보다 'error 1040: Too many connections' 가 먼저다 —
    # 앞엣것은 증상이고 뒤엣것이 사유다. 고칠 수 있는 쪽을 보여준다.
    #
    # 그리고 **가장 거짓말 같은 메시지를 먼저 잡는다.** 서술자가 바닥나면 sysbench 는
    #   FATAL: Cannot find benchmark '...oltp_read_write.lua': no such ... file or module
    # 을 낸다. 워커 스레드마다 lua 를 다시 여는데 그 open 이 EMFILE 로 실패한 것이라,
    # **파일은 멀쩡한데 "없다"고 말한다.** 실측: 1024스레드에서 ulimit -n 1088·1400 이면
    # 이 메시지가 나오고 2304 면 사라진다. 그대로 보여주면 파일을 찾으러 가게 된다.
    #
    # 'Worker threads failed to initialize within 30 seconds' 는 **늘릴 수 없는 벽**이다.
    # sysbench 1.0 에 --thread-init-timeout 같은 옵션이 없고 30 이 코드에 박혀 있다
    # (`sysbench --help` 에 timeout 류가 하나도 없고, 바이너리에 형식 문자열만 있다).
    # 그러니 "올려라"가 아니라 **초기화 일감을 줄여라**가 유일한 조언이다.
    "|"*) { if echo "$out" | grep -q "failed to initialize within"; then
              echo "FATAL: 워커 초기화가 30초를 넘겼다 — sysbench 1.0 에는 이 30초를 늘리는 옵션이 없다(코드 고정). 준비문 약 $(( ${PER:-0} * th ))개(스레드당 ${PER:-?}개 × ${th})를 그 안에 다 잡아야 한다. TABLES 를 줄여라(스레드당 9×tables+1)"
            fi
            if echo "$out" | grep -q "Cannot find benchmark" && [ -f "$lua" ]; then
              echo "FATAL: '$lua' 가 없다고 하지만 파일은 있다 — 파일 서술자 고갈(EMFILE)이다. ulimit -n 을 올려라"
            fi
            echo "$out" | grep -iE '^(FATAL|ERROR).*error [0-9]+' | head -1
            echo "$out" | grep -iE '^(FATAL|ERROR)' | head -1
            echo "sysbench 가 결과를 내지 않았다"; } | grep -m1 . > "$RUN1_ERRF";;
  esac
  echo "$res"
}

BP=$(q "SELECT round(@@innodb_buffer_pool_size/1024/1024)")
echo "§M-4 / M-6 / M-7 의 MySQL/InnoDB 판"
echo "  MySQL $V / CPU $(nproc 2>/dev/null || echo '?') / buffer pool ${BP}MB"
echo "  sysbench oltp_read_write, ${TABLES}테이블 × ${TSIZE}행, 조건당 ${SECS}초"
# 실제로 쓰는 목록을 찍는다 — 예전에 THREADS 가 무시되던 때, 무시됐다는 사실이
# 출력 어디에도 없어서 스윕이 잘린 표가 정상처럼 보였다.
want 1 && echo "  ① 스레드 스윕: $THREADS"
echo "  현재 내구성: flush_log_at_trx_commit=$F0 / sync_binlog=$S0 / redo=$((R0/1024/1024))MB"
echo

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① M-4 대기열 이론 — 무릎이 어디인가 ──"
echo
# **돌리기 전에 붙을 수 있는지 본다.** sysbench 는 스레드마다 연결을 하나 연다.
# max_connections(기본 151)를 넘으면 error 1040 으로 아예 못 붙고, 그 칸은 빈 줄이 된다.
# 실측: CPU 32 장비에서 THREADS=... 256 512 를 줬더니 128 까지 재고 256·512 는 '?' 였다.
# 2분을 다 쓰고 나서야 알게 되는 일이라, 먼저 재고 먼저 말한다.
# '직전 대비 배수' 두 열은 **스레드를 두 배로 올렸다**는 전제 위에 있다. 목록이
# 두 배씩이 아니면 그 열은 비교 가능한 값이 아닌데, 표는 똑같이 생겨서 그냥 읽힌다.
if ! echo "$THREADS" | awk '{ for(i=2;i<=NF;i++) if ($i != $(i-1)*2) exit 1 }'; then
  echo "  [주의] 스레드 목록이 2배씩이 아니다 — '직전 TPS×/지연×' 두 열은 **두 배씩 올릴 때**를"
  echo "  전제로 한 값이라, 이 목록에서는 칸마다 의미가 다르다. 무릎 판정도 그만큼 느슨하게 읽어라."
  echo
fi
# 못 재는 칸은 **목록에서 지운다.** 빈 줄을 남기면 아래 판정이 그걸 0 으로 읽는다.
trim_threads() {   # $1 = 허용 최대 스레드
  local cap="$1" keep="" drop="" th
  for th in $THREADS; do
    if [ "$th" -le "$cap" ]; then keep="$keep $th"; else drop="$drop $th"; fi
  done
  echo "     **잴 수 없는 칸을 목록에서 뺀다:${drop:- (없음)}**"
  THREADS="${keep# }"
  [ -z "$THREADS" ] && { echo "  [중단] 남는 칸이 없다."; exit 1; }
  echo "     이번 스윕: $THREADS"
}
MAXTH=$(echo "$THREADS" | tr ' ' '\n' | sort -n | tail -1)

# **이 벽은 서버가 아니라 클라이언트에 있다.** sysbench 는 스레드마다 소켓을 하나 여는데
# 그 프로세스의 파일 서술자 한도(ulimit -n, 리눅스 기본 soft 1024)를 넘으면
#   FATAL: error 2004: Can't create TCP/IP socket (24)
# 가 난다 — 24 는 EMFILE(Too many open files)이다. SQL 로는 못 고친다.
# bash 는 soft 를 hard 까지 올릴 수 있으므로 여기서 올린다.
# (개발 컨테이너는 soft 가 20000 이라 이 벽이 안 보였다 — **내 환경이 더 관대해서
#  못 잡은 결함**이다. 그래서 값을 재서 말한다.)
FD_S=$(ulimit -Sn 2>/dev/null); FD_H=$(ulimit -Hn 2>/dev/null)
# **스레드당 하나로는 모자란다.** 워커는 소켓 하나 말고 lua 스크립트도 따로 연다.
# 실측(1024스레드): soft 1088·1400 은 실패하고 2304 에서 그 실패가 사라졌다.
# 그래서 2배 + 여유로 잡는다. 처음엔 MAXTH+64 로 잡았다가 1024 에서 또 걸렸다.
NEEDFD=$(( MAXTH * 2 + 256 ))
if [ "${FD_S:-unlimited}" != "unlimited" ] && [ "${FD_S:-0}" -lt "$NEEDFD" ]; then
  echo "  ulimit -n(soft)=$FD_S 인데 이 스윕의 최대 스레드는 ${MAXTH} 다 — 소켓을 못 연다(error 2004 / errno 24)."
  if [ "${FD_H:-0}" = "unlimited" ] || [ "${FD_H:-0}" -ge "$NEEDFD" ]; then
    ulimit -n "$NEEDFD" 2>/dev/null
    FD_S=$(ulimit -Sn 2>/dev/null)
  fi
  if [ "${FD_S:-unlimited}" = "unlimited" ] || [ "${FD_S:-0}" -ge "$NEEDFD" ]; then
    echo "  → 이 프로세스에서만 ${FD_S} 로 올렸다(hard=${FD_H}). 셸을 나가면 원래대로다."
  else
    echo "  → hard 한도(${FD_H})가 모자라 못 올린다. 이건 **서버가 아니라 이 셸**의 한도다:"
    echo "     ulimit -n $NEEDFD   # hard 가 허락하면 즉시"
    echo "     또는 /etc/security/limits.conf 에 nofile 을 올리고 다시 로그인"
    trim_threads "$(( (${FD_S:-256} - 256) / 2 ))"
    MAXTH=$(echo "$THREADS" | tr ' ' '\n' | sort -n | tail -1)
  fi
  echo
fi

# 워커 하나에 연결 하나가 원칙이지만 **앞 칸의 연결이 다 닫히기 전에 다음 칸이 시작된다.**
# 실측: 1024스레드 칸에서 Max_used_connections 가 1201 까지 갔다(상한 1200 에 막혔다).
# 그래서 25% + 50 을 얹는다. 이 스크립트 자신의 mysql 호출 몫도 여기 들어 있다.
NEED=$(( MAXTH + MAXTH / 4 + 50 ))
if [ "${MC0:-0}" -lt "$NEED" ]; then
  echo "  max_connections=$MC0 인데 이 스윕의 최대 스레드는 ${MAXTH} 다 — 그대로면 못 붙는다(error 1040)."
  q "SET GLOBAL max_connections=$NEED" >/dev/null 2>&1
  MCN=$(q "SELECT @@max_connections")
  if [ "${MCN:-0}" -ge "$NEED" ]; then
    MC_RAISED=1
    echo "  → 이 실행 동안만 ${MCN} 로 올렸다(끝나면 ${MC0} 로 되돌린다)."
  elif [ "${MCN:-0}" -gt "${MC0:-0}" ]; then
    # **오른 건 올랐는데 원하는 만큼은 아니다.** MySQL 은 open_files_limit 이 모자라면
    # max_connections 를 말없이 깎아서 받는다. 이걸 '권한 부족'이라고 말하면
    # 고칠 수 없는 조언이 된다 — 되읽은 값이 그 구분을 준다.
    echo "  → 서버가 ${MCN} 까지만 받았다(요청 ${NEED}). 권한 문제가 아니라 **서버가 깎은 것**이다."
    echo "     open_files_limit=$(q "SELECT @@open_files_limit") 이 흔한 원인이다 —"
    echo "     연결마다 파일 서술자가 필요하다. 늘리려면 mysqld 의 open_files_limit 을 올려라(재기동)."
    MC_RAISED=1
    trim_threads "$(( (MCN - 50) * 4 / 5 ))"
    MAXTH=$(echo "$THREADS" | tr ' ' '\n' | sort -n | tail -1)
  else
    echo "  → 올리지 못했다(권한 부족일 수 있다: SYSTEM_VARIABLES_ADMIN)."
    echo "     전부 재려면 서버에서 먼저:  SET GLOBAL max_connections=$NEED;"
    trim_threads "$(( (${MC0:-0} - 50) * 4 / 5 ))"
    MAXTH=$(echo "$THREADS" | tr ' ' '\n' | sort -n | tail -1)
  fi
  echo
fi
# 첫 줄을 버릴 워밍업 한 번. 스윕의 첫 칸은 버퍼 풀이 차가워서 혼자 느리게 나오고,
# 그러면 '직전 대비 배수' 열의 두 번째 줄이 터무니없이 커진다(실측: SECS=5 에서
# 1스레드 18.77 tps · max 2,007ms → 2스레드 배수 12.15x). 배수로 무릎을 짚는 표라
# 그 한 칸이 열 전체의 의미를 흔든다.
#
# 그리고 이 워밍업에서 **스레드 하나가 준비문을 몇 개 잡는지 잰다.** 추정하지 않는다 —
# --tables 에 따라 달라지고, 틀리면 아래 상한 계산이 통째로 틀린다.
WARM_TH=4
run1 "$WARM_TH" >/dev/null 2>&1 &
WARMPID=$!
PSMAX=0
while kill -0 "$WARMPID" 2>/dev/null; do
  PSN=$(q "SHOW GLOBAL STATUS LIKE 'Prepared_stmt_count'" | awk '{print $2}')
  case "${PSN:-}" in ''|*[!0-9]*) ;; *) [ "$PSN" -gt "$PSMAX" ] && PSMAX="$PSN";; esac
  sleep 1
done
wait "$WARMPID" 2>/dev/null
# 실측(--tables=4): 32스레드에서 Prepared_stmt_count 1184 → 스레드당 **37** 이고,
# 그것이 9×tables+1 과 정확히 맞는다. 표본이 스레드가 다 붙기 전에 찍힐 수 있으므로
# **작게 나오면 그 모양을 바닥으로 쓴다** — 적게 잡으면 상한을 적게 올려 또 죽는다.
PER=$(( (PSMAX + WARM_TH - 1) / WARM_TH ))
FLOORPS=$(( 9 * TABLES + 1 ))
[ "$PER" -lt "$FLOORPS" ] && PER="$FLOORPS"

NEEDPS=$(( MAXTH * PER * 12 / 10 + 500 ))   # 20% 여유 — 올리는 건 상한일 뿐 할당이 아니다
if [ "${MPS0:-0}" -lt "$NEEDPS" ]; then
  echo "  max_prepared_stmt_count=$MPS0 인데 이 스윕은 최대 ${MAXTH}스레드 × ${PER}개 = 약 $(( MAXTH * PER ))개가 필요하다"
  echo "  (스레드당 ${PER}개는 워밍업에서 **재서** 얻은 값이다 — tables=${TABLES})."
  echo "  그대로면 붙기는 해도 준비 단계에서 죽는다(FATAL: mysql_stmt_prepare() failed)."
  q "SET GLOBAL max_prepared_stmt_count=$NEEDPS" >/dev/null 2>&1
  MPSN=$(q "SELECT @@max_prepared_stmt_count")
  if [ "${MPSN:-0}" -ge "$NEEDPS" ]; then
    MPS_RAISED=1
    echo "  → 이 실행 동안만 ${MPSN} 로 올렸다(끝나면 ${MPS0} 로 되돌린다)."
  else
    echo "  → 올리지 못했다. 전부 재려면 서버에서 먼저:  SET GLOBAL max_prepared_stmt_count=$NEEDPS;"
    trim_threads "$(( (${MPS0:-0} - 200) / PER ))"
  fi
  echo
fi

# 표 머리는 **사전 점검이 다 끝난 뒤에** 찍는다. 앞에 두면 "…로 올렸다" 같은 줄이
# 표 안에 끼어 들어가 표처럼 보이지 않는다.
# 무릎은 절대값이 아니라 **직전 대비 배수**로 보인다 — 스레드를 두 배로 올렸을 때
# 처리량이 얼마나 따라오고 지연이 얼마나 늘었는가. 그래서 그 두 열을 같이 찍는다.
# (어느 줄이 무릎인지는 스크립트가 단정하지 않는다. 워크로드마다 기준이 다르다.)
printf "  %s%10s %9s %9s %9s %11s %11s\n" "$(padr 스레드 8)" "$(padl TPS 10)" "$(padl avg 9)" "$(padl p99 9)" "$(padl max 9)" "$(padl "직전 TPS×" 11)" "$(padl "직전 지연×" 11)"
printf "  %s\n" "--------------------------------------------------------------------------------"
BEST=0; BESTT=""; PT=""; PA=""; LASTT=""; KNEE=""; FAILED=""; FAILWHY=""; SUCC=""
for th in $THREADS; do
  IFS='|' read -r T A P M <<<"$(run1 "$th")"
  # 실패한 칸은 **표에만 남기고 계산에서 뺀다.** 예전에는 빈 값이 0 으로 읽혀
  # "처리량이 줄었다"는 판정을 만들었다 — 재지 못한 것을 재서 줄었다고 말한 셈이다.
  if [ -z "${T:-}" ]; then
    FAILED="$FAILED $th"
    [ -z "$FAILWHY" ] && FAILWHY=$(cat "$RUN1_ERRF" 2>/dev/null)
    printf "  %s%10s %9s %9s %9s %11s %11s\n" "$(padr "$th" 8)" "측정실패" "-" "-" "-" "-" "-"
    continue
  fi
  awk -v a="${T:-0}" -v b="$BEST" 'BEGIN{exit !(a>b)}' && { BEST="$T"; BESTT="$th"; }
  # 배수를 **숫자로** 먼저 내고 표시는 그 다음이다. 예전에는 "1.44x" 문자열만 만들어
  # 찍고 버려서, 무릎에 닿았는지를 스크립트가 판정할 수 없었다.
  RTn=$(awk -v a="${T:-0}" -v b="${PT:-0}" 'BEGIN{ if(b>0) printf "%.4f", a/b; else printf "0" }')
  RAn=$(awk -v a="${A:-0}" -v b="${PA:-0}" 'BEGIN{ if(b>0) printf "%.4f", a/b; else printf "0" }')
  RT=$(awk -v r="$RTn" 'BEGIN{ if(r>0) printf "%.2fx", r; else printf "-" }')
  RA=$(awk -v r="$RAn" 'BEGIN{ if(r>0) printf "%.2fx", r; else printf "-" }')
  # 무릎 너머의 정의 — 처리량은 거의 안 따라오는데(1.3배 미만) 지연은 크게 는다(1.5배 초과).
  if [ -z "$KNEE" ] && awk -v t="$RTn" -v a="$RAn" 'BEGIN{exit !(t>0 && a>0 && t<1.3 && a>1.5)}'; then
    KNEE="$th"
  fi
  printf "  %s%10s %9s %9s %9s %11s %11s\n" "$(padr "$th" 8)" "${T:-?}" "${A:-?}" "${P:-?}" "${M:-?}" "$RT" "$RA"
  PT="$T"; PA="$A"; LASTT="$th"; SUCC="$SUCC $th"
done
SUCC="${SUCC# }"
rm -f "$RUN1_ERRF"
echo
# 실패한 칸이 있으면 **그 사실부터** 말한다. 아래 판정은 성공한 칸까지만의 이야기다.
if [ -n "$FAILED" ]; then
  echo "  ⚠️ **재지 못한 칸이 있다:${FAILED}**"
  [ -n "$FAILWHY" ] && echo "     사유: $FAILWHY"
  # 한 칸도 못 쟀으면 '어디까지의 이야기'라는 말 자체가 성립하지 않는다.
  # 그냥 두면 "아래 판정은 ? 까지만의 이야기다" 가 찍혔다.
  if [ -n "$LASTT" ]; then
    echo "     아래 판정은 ${LASTT} 까지만의 이야기다 — 빈 칸을 '처리량이 줄었다'로 읽으면 안 된다."
  else
    echo "     **판정할 칸이 남지 않았다.**"
  fi
  echo
fi
if [ -z "$BESTT" ]; then
  echo "  [중단] 한 칸도 재지 못했다."
else
echo "  최대 TPS 는 스레드 ${BESTT} 에서 나왔다 (CPU $(nproc 2>/dev/null || echo '?')개)."
# 스윕의 **마지막 칸**에서 최대가 나왔다면 그건 '무릎이 거기'가 아니라 **아직 안 왔다**는 뜻이다.
# 그 구분을 안 하면 "무릎은 64" 라는 결론이 스윕 길이에서 나온 것이 되어 버린다.
# 다음 목록은 **성공한 칸들에 이어서** 만든다. 처음엔 THREADS 뒤에 LASTT 의 2·4·8배를
# 그냥 붙였더니, 실패한 칸이 섞인 목록에서 `1 2 4 256 8 16 32` 같은 순서 뒤엉킨 제안이 나왔다.
NEXT=$(awk -v cur="$SUCC" 'BEGIN{
  n=split(cur, a, " "); mx=0
  for(i=1;i<=n;i++){ if(a[i]+0>mx) mx=a[i]+0; s=s (s?" ":"") a[i] }
  for(i=1;i<=3;i++){ mx*=2; s=s" "mx }
  print s }')
if [ -n "$KNEE" ]; then
  echo "  **무릎은 스레드 ${KNEE} 에서 넘었다** — 거기서 처리량 배수가 1.3 아래로 떨어지고"
  echo "  지연 배수가 1.5 를 넘었다."
  # 무릎이 **잰 마지막 칸**이면 그 뒤가 없다. 조건을 만족한 건 맞지만, 한 칸으로 판정한
  # 것이라 다음 칸에서 되돌아올 수도 있다. 그 차이를 말해 둔다.
  if [ "$KNEE" = "$LASTT" ]; then
    echo "  다만 그 줄이 **잰 마지막 칸**이다 — 조건은 만족했지만 한 칸짜리 근거다."
    echo "  한 칸 더 재서 확인하라:  THREADS=\"$NEXT\" $0"
  fi
elif [ -n "$FAILED" ]; then
  echo "  ⚠️ **잰 칸 중 마지막(${LASTT})에서 최대가 나왔다 — 무릎에 닿지 못했다.**"
  echo "  그런데 못 늘린 이유는 스윕이 짧아서가 아니라 **위의 측정 실패** 때문이다."
  echo "  먼저 그 사유를 고쳐야 한다 — 그 전에는 이 표로 무릎을 말할 수 없다."
elif [ "$BESTT" = "$LASTT" ]; then
  echo "  ⚠️ **스윕의 마지막 칸에서 최대가 나왔다 — 무릎에 닿지 못했다.**"
  echo "  이 표로는 '무릎이 ${LASTT}' 라고 말할 수 없다. 그건 측정이 아니라 **스윕 길이**다."
  echo "  더 늘려서 다시 재라:  THREADS=\"$NEXT\" $0"
else
  echo "  처리량이 ${BESTT} 이후 줄긴 했지만, '처리량 정체 + 지연 급증' 조건을 만족한 줄은 없다."
  echo "  **무릎을 이 표로 짚을 수 없다** — 조건당 ${SECS}초가 짧아 흔들렸을 수 있다(SECS 를 올려 보라)."
fi
fi
echo
echo "  읽는 법 — **오른쪽 두 열이 무릎을 가리킨다.** 스레드를 두 배로 올렸을 때"
echo "   'TPS× 는 1 에 가까워지는데 지연× 는 2 에 가까워지는' 줄부터가 무릎 너머다."
echo "   위 판정은 **TPS× < 1.3 이면서 지연× > 1.5** 인 첫 줄을 무릎으로 본 것이다."
echo "   거기서부터는 더 넣은 동시성이 처리량이 아니라 **대기열 길이**로만 간다."
echo
# 여기에는 "TPS 는 꺾이는 대신 **포화**한다" 가 박혀 있었다. 짧은 스윕(…64)에서는
# 늘 맞는 말이었는데, 1→2048 까지 밀어 보니 **실제로 꺾였다**(실측 CPU 32:
# 최대 4,959 → 마지막 2,431, -51%). 표가 꺾였다고 말하는데 해설은 포화라고 말했다.
# 꺾였는지 아닌지는 표가 안다 — 최대와 마지막을 견준다.
FALLPCT=$(awk -v b="${BEST:-0}" -v l="${PT:-0}" 'BEGIN{ if(b>0) printf "%.0f", (b-l)*100/b; else printf "0" }')
echo "   pgbench(tpcb-like)에서는 4→8 에서 **TPS 가 실제로 줄었다.**"
if [ -z "${BESTT:-}" ]; then
  echo "   여기서는 잰 것이 없어 비교할 수 없다."
elif [ "${FALLPCT:-0}" -ge 10 ]; then
  echo "   여기서도 꺾였다 — 최대 ${BEST}(스레드 ${BESTT}) 에서 마지막 ${PT}(스레드 ${LASTT}) 로 **${FALLPCT}%** 내려왔다."
  echo "   짧은 스윕에서는 이게 안 보인다. 포화처럼 보이는 구간이 먼저 오기 때문이다 —"
  echo "   oltp_read_write 는 14문장 중 10이 읽기라 버퍼 풀에서 끝나고, 그 사이 CPU 가"
  echo "   비는 순간을 추가 스레드가 메운다. 그 여유가 다 차야 비로소 꺾인다."
else
  # 최대가 곧 마지막 칸이면 "대비 0% 낮다" 는 하나 마나 한 말이다 — 아직 그 구간에
  # 가지도 않은 것이다. 두 경우를 갈라서 말한다.
  if [ "${BESTT:-}" = "${LASTT:-}" ]; then
    echo "   여기서는 안 꺾였다 — 아니, **최대가 곧 마지막 칸이라 꺾이는 구간에 가지도 않았다.**"
  else
    echo "   여기서는 안 꺾였다 — 최대 ${BEST}(스레드 ${BESTT}) 대비 마지막이 ${FALLPCT}% 낮을 뿐이다."
  fi
  echo "   oltp_read_write 는 14문장 중 10이 읽기라 버퍼 풀에서 끝나고, 그 사이 CPU 가"
  echo "   비는 순간이 있어 스레드를 더 넣으면 그 틈을 메운다. 그래서 **포화**한다."
  echo "   다만 **스윕이 짧아서 안 꺾인 것일 수도 있다** — 더 밀면 꺾이는 구간이 나온다."
fi
echo "   어느 쪽이든 그 뒤로도 **지연은 계속 는다.**"
echo "   → **무릎은 코어 수가 아니라 '한 트랜잭션이 CPU 를 붙잡는 비율'이 정한다.**"
echo "     '커넥션 풀 = 코어 수 × N' 같은 고정 규칙이 위험한 이유다 — 워크로드마다 답이 다르다."
echo "     그리고 **TPS 만 보면 무릎을 못 찾는다.** 포화 구간에서 TPS 는 계속 최고치이기 때문이다."
echo
echo "   **max 열도 보라.** 평균과 p99 가 완만하게 늘어도 max 는 따로 논다 —"
echo "   Millsap 의 미계상 시간이 거기 숨는다(③에서 정면으로 다룬다)."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② M-6 커밋 비용 — PostgreSQL 은 하나, MySQL 은 **둘**을 내린다 ──"
echo
echo "  PostgreSQL 의 synchronous_commit 은 WAL 하나를 내리느냐다."
echo "  MySQL 은 커밋마다 **redo 와 binlog 두 군데**에 fsync 할 수 있다. 그래서 2×2 다."
echo "    innodb_flush_log_at_trx_commit: 1=커밋마다 redo fsync, 2=OS 캐시까지만"
echo "    sync_binlog: 1=커밋마다 binlog fsync, 0=OS 에 맡김"
echo
printf "  %s%s%12s %10s %10s\n" "$(padr "redo fsync" 14)" "$(padr "binlog fsync" 16)" "$(padl TPS 12)" "$(padl p99 10)" "$(padl 배수 10)"
printf "  %s\n" "----------------------------------------------------------------------"
BASE=""; FAIL2=""
for combo in "1:1" "1:0" "2:1" "2:0"; do
  F="${combo%%:*}"; S="${combo##*:}"
  q "SET GLOBAL innodb_flush_log_at_trx_commit=$F; SET GLOBAL sync_binlog=$S" >/dev/null
  IFS='|' read -r T A P M <<<"$(run1 8)"
  # ①에서 고친 것과 같은 구멍이 ②③에도 있었다 — 실패하면 T 가 비고, 아래 배수 계산이
  # 빈 값을 0 으로 읽어 "redo 만 꺼서 배, binlog 만 꺼서 배" 처럼 숫자 없는 문장을 찍는다.
  [ -z "${T:-}" ] && FAIL2="$FAIL2 ${F}/${S}"
  [ -z "$BASE" ] && BASE="$T"
  # 문장을 표에서 만들려면 값을 남겨야 한다. 조합별 TPS 를 보관한다.
  case "$combo" in 1:1) C11="$T";; 1:0) C10="$T";; 2:1) C21="$T";; 2:0) C20="$T";; esac
  [ "$F" = 1 ] && FL="켬 (=1)" || FL="끔 (=2)"
  [ "$S" = 1 ] && SL="켬 (=1)" || SL="끔 (=0)"
  printf "  %s%s%12s %10s %10s\n" "$(padr "$FL" 14)" "$(padr "$SL" 16)" "${T:-?}" "${P:-?}" \
    "$(awk -v a="${T:-0}" -v b="${BASE:-0}" 'BEGIN{ if(b>0) printf "%.2fx", a/b }')"
done
restore
echo
# **어느 쪽이 더 비싼지는 재서 말한다.** "binlog 쪽이 더 비싼 게 보통"이라고 박아 뒀는데,
# 실측에서 redo 쪽이 더 비싼 실행이 나왔다(binlog 만 끄면 1.76배 / redo 만 끄면 2.10배).
RB=$(awk -v a="${C10:-0}" -v b="${C11:-0}" 'BEGIN{ if(b>0) printf "%.2f", a/b }')   # binlog 만 끔
RR=$(awk -v a="${C21:-0}" -v b="${C11:-0}" 'BEGIN{ if(b>0) printf "%.2f", a/b }')   # redo 만 끔
RBOTH=$(awk -v a="${C20:-0}" -v b="${C11:-0}" 'BEGIN{ if(b>0) printf "%.2f", a/b }')
if [ -n "$FAIL2" ]; then
  echo "  ⚠️ **재지 못한 조합이 있다:${FAIL2}** (flush_log_at_trx_commit/sync_binlog)"
  echo "     배수를 계산할 수 없다 — 아래 해석은 건너뛴다. 빈 칸을 0 으로 읽으면"
  echo "     '어느 쪽이 더 비싸다'가 근거 없이 찍힌다."
  echo
elif awk -v a="$RB" -v b="$RR" 'BEGIN{exit !(a+0>b+0)}'; then
  echo "  이 실행에서는 **binlog 쪽이 더 비싸다** — binlog 만 꺼서 ${RB}배, redo 만 꺼서 ${RR}배."
else
  echo "  이 실행에서는 **redo 쪽이 더 비싸다** — redo 만 꺼서 ${RR}배, binlog 만 꺼서 ${RB}배."
  echo "  (binlog 가 더 비싼 경우가 흔하다고들 하지만 이 장비·이 워크로드에서는 반대다.)"
fi
# "둘 다 꺼도 배수가 작다"고 박아 뒀는데, 11.93배가 나오는 실행이 있었다 —
# PostgreSQL 의 2.2배보다 **크다.** 크기를 재서 말하고, 그에 맞는 질문을 던진다.
if [ -z "$FAIL2" ]; then
echo "  둘 다 끄면 **${RBOTH}배**다. PostgreSQL 의 synchronous_commit 은 같은 랩에서 2.2배였다"
echo "  (이 수치는 이 랩의 pgbench 판 실측값이다 — 이번 실행에서 잰 것이 아니다)."
echo
if awk -v a="$RBOTH" 'BEGIN{exit !(a+0 < 3)}'; then
  echo "  **왜 이렇게 작은가** — 가설 둘을 세우고 둘 다 재 봤다."
else
  echo "  **왜 이렇게 큰가** — 배수는 엔진이 아니라 워크로드가 정한다. 가설 둘을 재 봤다."
fi
echo "   (가) 8스레드라 **그룹 커밋**이 fsync 를 여러 트랜잭션에 나눠 물린다."
echo "   (나) oltp_read_write 는 14문장 중 10이 **읽기**라, 커밋이 트랜잭션에서 차지하는 몫이 작다."
echo
printf "  %s%s%12s %12s %10s\n" "$(padr 워크로드 18)" "$(padr 스레드 8)" "$(padl "둘 다 켬" 12)" "$(padl "둘 다 끔" 12)" "$(padl 배수 10)"
printf "  %s\n" "--------------------------------------------------------------------------"
for pair in "읽기+쓰기 (기본):8:$LUA" "쓰기만:8:$LUAW" "쓰기만:1:$LUAW"; do
  WL="${pair%%:*}"; r="${pair#*:}"; TH="${r%%:*}"; LU="${r##*:}"
  q "SET GLOBAL innodb_flush_log_at_trx_commit=1; SET GLOBAL sync_binlog=1" >/dev/null
  IFS='|' read -r ON _ _ _ <<<"$(run1 "$TH" "$LU")"
  q "SET GLOBAL innodb_flush_log_at_trx_commit=2; SET GLOBAL sync_binlog=0" >/dev/null
  IFS='|' read -r OFF _ _ _ <<<"$(run1 "$TH" "$LU")"
  RM=$(awk -v a="${OFF:-0}" -v b="${ON:-0}" 'BEGIN{ if(b>0) printf "%.2f", a/b }')
  [ -z "${ON:-}" ] || [ -z "${OFF:-}" ] && FAIL2B="${FAIL2B:-} ${WL}/${TH}스레드"
  case "$WL:$TH" in "쓰기만:8") W8="$RM";; "쓰기만:1") W1="$RM";; *) RW="$RM";; esac
  printf "  %s%s%12s %12s %10s\n" "$(padr "$WL" 18)" "$(padr "$TH" 8)" "${ON:-?}" "${OFF:-?}" "${RM:-?}x"
done
restore
echo
if [ -n "${FAIL2B:-}" ]; then
  echo "  ⚠️ **재지 못한 줄이 있다:${FAIL2B}** — 배수가 비어 있어 두 가설을 판정할 수 없다."
  echo "     여기서 멈춘다. 빈 값으로 '지지/기각'을 찍으면 근거 없는 판정이 남는다."
else
# "1과 8의 배수가 거의 같다"고 박아 뒀는데 42.12 대 25.14 가 나왔다 — 거의 같지 않다.
# 기각 근거는 '같다'가 아니라 **방향**이다: 그룹 커밋이 원인이라면 혼자 도는 1스레드에서
# 배수가 훨씬 커야 하는데, 오히려 8스레드 쪽이 크면 가설과 정반대다.
#
# ⚠️ 여기 `b+0*1.3` 이라고 썼었다. awk 에서 `*` 가 `+` 보다 먼저라 **`b+0` 즉 그냥 b** 다.
# 30% 여유를 두려던 것이 **한 번도 적용된 적이 없고**, W1 이 W8 보다 조금이라도 크면
# '지지된다'가 찍혔다. 괄호를 안 쳐서 생긴, 출력만 봐서는 절대 안 보이는 결함이다.
if awk -v a="$W1" -v b="$W8" 'BEGIN{exit !(a+0 > b*1.3)}'; then
  echo "  → **(가) 그룹 커밋 가설이 지지된다.** 쓰기만에서 1스레드 배수(${W1}배)가"
  echo "    8스레드(${W8}배)보다 크다 — 혼자면 fsync 를 나눠 물릴 상대가 없다."
else
  echo "  → **(가) 그룹 커밋 가설은 기각됐다.** 쓰기만에서 1스레드 배수가 ${W1}배, 8스레드가 ${W8}배다."
  echo "    그룹 커밋이 원인이라면 혼자 도는 1스레드에서 배수가 **훨씬 커야** 하는데 그렇지 않다"
  echo "    (오히려 8스레드 쪽이 크다면 가설과 정반대다)."
fi
# **(나)도 재야 한다.** 여기 "→ **(나)가 맞다.**" 가 조건 없이 박혀 있었다.
# (나)는 '커밋 비중이 크면 배수도 크다'는 주장이므로, 쓰기 전용의 배수가 읽기 섞인 쪽보다
# 실제로 커야 지지된다. 두 값이 비슷하게 나온 실행에서도 "맞다"가 찍혔을 것이다.
if awk -v w="$W8" -v r="$RW" 'BEGIN{exit !(r+0>0 && w+0 > r*1.3)}'; then
  echo "  → **(나)가 지지된다.** 같은 손잡이가 읽기 섞인 트랜잭션에서는 ${RW}배,"
  echo "    쓰기만 하면 ${W8}배로 벌어진다 — 커밋이 트랜잭션에서 차지하는 몫이 정한다."
elif awk -v w="$W8" -v r="$RW" 'BEGIN{exit !(r+0>0 && w+0 > r)}'; then
  echo "  → **(나)는 방향만 맞다.** 쓰기 전용이 ${W8}배, 읽기 섞인 쪽이 ${RW}배로 크긴 한데"
  echo "    30% 여유를 넘지 못했다 — 이 실행만으로 '커밋 비중이 정한다'고 말하기엔 약하다."
else
  echo "  → **(나)도 이 실행에서는 지지되지 않는다.** 쓰기 전용 ${W8}배, 읽기 섞인 쪽 ${RW}배로"
  echo "    벌어지지 않았다. 커밋 비중 말고 다른 것이 배수를 정하고 있다는 뜻이다."
fi
fi
fi   # ← 2×2 표가 온전할 때만 도는 해석 블록의 끝
echo
# 결론 문단도 **잰 게 있을 때만** 찍는다. 가짜 sysbench 로 전 칸을 실패시켜 봤더니
# 표가 전부 '?' 인데 "그래서 이 절의 결론은 … 커밋이 차지하는 비율이 정한다" 가 그대로
# 나왔다. 데이터가 하나도 없는 결론이다.
if [ -z "$FAIL2" ] && [ -z "${FAIL2B:-}" ]; then
echo "  그래서 이 절의 결론은 엔진 비교가 아니다 — **커밋 내구성의 '값'은 트랜잭션에서 커밋이"
echo "  차지하는 비율이 정한다.** PostgreSQL 의 2.2배와 여기의 배수를 나란히 놓고 '엔진이 다르다'고"
echo "  읽으면 안 된다. pgbench tpcb 는 5문장, oltp_read_write 는 14문장이다."
echo "  **손잡이의 효과를 벤치마크 사이에서 비교하려면 트랜잭션 구성부터 맞춰야 한다**(§T-0)."
echo
fi
echo "  주의: 이건 **데이터를 잃을 수 있는 설정**이다. flush_log_at_trx_commit=2 는 OS 가 죽으면"
echo "  마지막 1초를, sync_binlog=0 은 복제/PITR 의 연속성을 잃는다. 측정은 '얼마를 벌 수 있나'"
echo "  지 '꺼도 된다'가 아니다 — 이 스크립트는 끝나면 원래 값으로 되돌린다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
echo "── ③ M-7 redo 압력 — TPS 가 아니라 max 를 본다 ──"
echo
echo "  PostgreSQL 에서 max_wal_size 를 1GB→256MB 로 줄였더니 TPS 는 12% 주는데"
echo "  **max 지연이 69ms → 3,746ms(54배)** 였다. InnoDB 의 대응 손잡이는"
echo "  innodb_redo_log_capacity 다 (8.0.30 부터 동적으로 바뀐다 — 재기동이 필요 없다)."
echo
echo "  **쓰기 전용 워크로드로 잰다.** 처음엔 기본(읽기+쓰기)으로 1GB vs 64MB 를 재 봤는데"
echo "  아무 차이가 없었다 — Innodb_os_log_written 이 양쪽 다 같아서, 64MB 조차 남아돌았던 것이다."
echo "  **압력을 안 만들고 '영향 없음'을 결론으로 쓸 뻔했다.** 로그를 실제로 감는 조건이 필요하다."
echo
printf "  %s%12s %10s %10s %14s\n" "$(padr "redo 용량" 14)" "$(padl TPS 12)" "$(padl p99 10)" "$(padl max 10)" "$(padl "redo 기록량" 14)"
printf "  %s\n" "--------------------------------------------------------------------------"
BT=""; BM=""; FAIL3=""; CAPWARN=""
for cap in 1024 8; do
  q "SET GLOBAL innodb_redo_log_capacity=$((cap*1024*1024))" >/dev/null
  # **요청한 용량과 실제 용량이 같은지 확인한다.** 서버가 안 받거나 깎으면 표의 왼쪽 열이
  # 거짓말을 한다 — "8MB 에서 이렇게 나빠졌다"의 8MB 가 사실이 아닌 채로.
  CAPN=$(q "SELECT round(@@innodb_redo_log_capacity/1048576)")
  case "${CAPN:-}" in ''|*[!0-9]*) CAPN="?";; esac
  [ "${CAPN}" != "$cap" ] && CAPWARN="${CAPWARN} ${cap}MB→실제${CAPN}MB"
  W0=$(q "SHOW GLOBAL STATUS LIKE 'Innodb_os_log_written'" | awk '{print $2}')
  IFS='|' read -r T A P M <<<"$(run1 8 "$LUAW")"
  W1=$(q "SHOW GLOBAL STATUS LIKE 'Innodb_os_log_written'" | awk '{print $2}')
  [ -z "${T:-}" ] && FAIL3="$FAIL3 ${cap}MB"
  # 문장을 표에서 만들려면 값을 남겨야 한다. 두 조건의 TPS/p99/max/기록량을 보관한다.
  MBW=$(( (W1 - W0) / 1048576 ))
  if [ -z "$BT" ]; then BT="$T"; BM="$M"; BP="$P"; BW="$MBW"; else NT="$T"; NM="$M"; NP="$P"; NW="$MBW"; NCAP="$CAPN"; fi
  printf "  %s%12s %10s %10s %14s\n" "$(padr "${CAPN}MB" 14)" "${T:-?}" "${P:-?}" "${M:-?}" \
    "$(awk -v a="${W1:-0}" -v b="${W0:-0}" 'BEGIN{printf "%.0f MB", (a-b)/1048576}')"
done
restore
echo
echo "  읽는 법 — **TPS 와 p99 만 보면 이 사고를 놓친다.**"
echo "   redo 를 좁히면 InnoDB 는 더티 페이지를 급하게 내려야 하고(비동기 플러시),"
echo "   그 압력이 가장 운 나쁜 트랜잭션 하나에 몰린다. 그게 max 열이다."
echo "   redo 기록량이 용량을 여러 번 감을 만큼 나와야 압력이 걸린 것이다 — 그래서 그 열을 같이 찍는다."
echo
# **PostgreSQL 의 모양을 여기 그대로 옮겨 적으면 안 된다.** 그쪽은 max 만 54배 뛰고
# p99 는 10% 였는데, 여기서는 p99 와 max 가 나란히 3배씩 오르는 실행이 나왔다.
# 그러면 "p99 만 보는 대시보드는 놓친다"가 이 데이터에서는 틀린 말이 된다. 재서 말한다.
if [ -n "$CAPWARN" ]; then
  echo "   ⚠️ **요청한 용량과 실제 용량이 다르다:${CAPWARN}**"
  echo "     왼쪽 열은 실제 값으로 찍었다. 서버가 안 받았거나 깎은 것이다."
  echo
fi
if [ -n "$FAIL3" ]; then
  echo "   ⚠️ **재지 못한 조건이 있다:${FAIL3}** — 두 조건을 견줄 수 없어 해석을 건너뛴다."
  echo "     빈 값으로 배수를 내면 'p99 배, max 배' 같은 숫자 없는 문장이 남는다."
  echo
else
RT=$(awk -v a="$NT" -v b="$BT" 'BEGIN{ if(b>0) printf "%.0f", (a-b)*100/b }')
RP=$(awk -v a="$NP" -v b="$BP" 'BEGIN{ if(b>0) printf "%.1f", a/b }')
RMX=$(awk -v a="$NM" -v b="$BM" 'BEGIN{ if(b>0) printf "%.1f", a/b }')
echo "   이 실행: TPS ${RT}%, p99 **${RP}배**, max **${RMX}배** (${NCAP}MB 기준)."
echo "   참고로 PostgreSQL 의 max_wal_size 1GB→256MB 는 TPS -12%, p99 +10%, max 54배였다."
# 압력이 실제로 걸렸는지부터 본다 — 기록량이 용량을 넘지 못하면 이 표는 압력 실험이 아니다.
if [ "${NW:-0}" -lt "${NCAP:-1}" ]; then
  echo "   ⚠️ **다만 이 실행은 로그를 한 바퀴도 못 감았다** — 기록량 ${NW}MB < 용량 ${NCAP}MB."
  echo "     InnoDB 는 용량의 일부만 차도 비동기 플러시를 시작하므로 열화가 보이긴 하지만,"
  echo "     '로그가 감겨 체크포인트가 강제된' 상태는 아니다. 더 세게 보려면 SECS 를 늘리거나"
  echo "     용량을 더 줄여라. **압력을 안 만들고 결론을 쓰지 않기 위해 이 줄을 찍는다.**"
fi
if awk -v m="$RMX" -v pp="$RP" 'BEGIN{exit !(m+0 > pp*2)}'; then
  echo "   ★ **max 가 p99 보다 훨씬 크게 나빠졌다**(${RMX}배 대 ${RP}배) — 압력이 가장 운 나쁜"
  echo "     트랜잭션 하나에 몰렸다는 뜻이다. **p99 만 보는 대시보드는 이 스톨을 놓친다.**"
  echo "     Millsap 의 미계상 시간(§M-3)은 실행계획에도 평균에도 p99 에도 안 나온다."
else
  echo "   ※ 이 실행에서는 **p99 와 max 가 비슷한 폭으로** 나빠졌다(${RP}배 대 ${RMX}배)."
  echo "     PostgreSQL 쪽처럼 '최악만 자릿수로 튀는' 모양이 아니다 — 여기서는 p99 로도 잡힌다."
  echo "     같은 것은 **방향**이다(좁히면 지연이 나빠진다). **크기와 분포는 엔진·조건마다 다르므로**"
  echo "     'max 만 본다'를 규칙으로 옮기지 말고, 두 지표를 같이 두고 어느 쪽이 먼저 움직이는지 보라."
fi
fi   # ← 두 조건을 다 잰 경우에만 도는 해석 블록의 끝
echo
fi

restore; trap - EXIT
echo "정리: 내구성/redo 설정을 원래 값으로 되돌렸다."
printf "  flush_log_at_trx_commit=%s (원래 %s) / sync_binlog=%s (원래 %s) / redo=%sMB (원래 %sMB)\n" \
  "$(q "SELECT @@innodb_flush_log_at_trx_commit")" "$F0" \
  "$(q "SELECT @@sync_binlog")" "$S0" \
  "$(q "SELECT round(@@innodb_redo_log_capacity/1024/1024)")" "$((R0/1024/1024))"
echo "  sysbench 데이터($DB.sbtest*)는 남겨 둔다. 지우려면:"
echo "    sysbench $LUA --db-driver=mysql --mysql-host=$MYHOST --mysql-user=$MYUSER \\"
echo "      --mysql-password=... --mysql-db=$DB --tables=$TABLES cleanup"
