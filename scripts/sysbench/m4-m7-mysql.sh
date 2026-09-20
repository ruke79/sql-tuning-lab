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
#
# 선행 조건: sysbench 바이너리, MySQL 접속. 데이터가 없으면 만든다(sysbench_lab DB).
# 내구성 설정은 **전역**을 건드리므로 끝에 원래 값으로 되돌린다.
set -uo pipefail

SECS="${SECS:-10}"
TABLES="${TABLES:-4}"
TSIZE="${TSIZE:-100000}"
ONLY="${ONLY:-123}"
MYHOST="${MYSQL_HOST:-127.0.0.1}"
MYPORT="${MYSQL_PORT:-3306}"
MYUSER="${MYSQL_USER:-tuner}"
MYPASS="${MYSQL_PASS:-tuner}"
DB="${MYSQL_DB:-sysbench_lab}"

want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
my() { mysql -h "$MYHOST" -P "$MYPORT" -u "$MYUSER" -p"$MYPASS" -N -B "$@" 2>&1 | grep -v '^mysql: \[Warning\]'; }
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
restore() {
  q "SET GLOBAL innodb_flush_log_at_trx_commit=$F0" >/dev/null 2>&1
  q "SET GLOBAL sync_binlog=$S0" >/dev/null 2>&1
  q "SET GLOBAL innodb_redo_log_capacity=$R0" >/dev/null 2>&1
}
trap restore EXIT

# 한 번 실행 → "tps|avg|p99|max"
#
# 라벨을 grep 으로 긁어 숫자만 뽑으면 **라벨 안의 숫자에 걸린다** — '99th percentile' 의 99 가
# 먼저 잡혀서 p99 자리에 99 가, max 자리에 아무것도 안 들어갔다(실제로 그랬다).
# 필드 위치로 집는다.
# $2 를 주면 그 lua 로 돌린다(기본은 oltp_read_write).
run1() {
  local th="$1" lua="${2:-$LUA}" out
  out=$(sysbench "$lua" --db-driver=mysql --mysql-host="$MYHOST" --mysql-port="$MYPORT" \
        --mysql-user="$MYUSER" --mysql-password="$MYPASS" --mysql-db="$DB" \
        --tables="$TABLES" --table-size="$TSIZE" --percentile=99 \
        --threads="$th" --time="$SECS" --report-interval=0 run 2>&1)
  echo "$out" | awk '
    /transactions:/ && /per sec/ { gsub(/[()]/,""); tps=$3 }
    /^[ \t]*avg:/ && !a { a=$2 }
    /^[ \t]*max:/ && !m { m=$2 }
    /99th percentile:/  { p=$NF }
    END { printf "%s|%s|%s|%s", tps, a, p, m }'
}

BP=$(q "SELECT round(@@innodb_buffer_pool_size/1024/1024)")
echo "§M-4 / M-6 / M-7 의 MySQL/InnoDB 판"
echo "  MySQL $V / CPU $(nproc 2>/dev/null || echo '?') / buffer pool ${BP}MB"
echo "  sysbench oltp_read_write, ${TABLES}테이블 × ${TSIZE}행, 조건당 ${SECS}초"
echo "  현재 내구성: flush_log_at_trx_commit=$F0 / sync_binlog=$S0 / redo=$((R0/1024/1024))MB"
echo

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① M-4 대기열 이론 — 무릎이 어디인가 ──"
echo
# 무릎은 절대값이 아니라 **직전 대비 배수**로 보인다 — 스레드를 두 배로 올렸을 때
# 처리량이 얼마나 따라오고 지연이 얼마나 늘었는가. 그래서 그 두 열을 같이 찍는다.
# (어느 줄이 무릎인지는 스크립트가 단정하지 않는다. 워크로드마다 기준이 다르다.)
printf "  %s%10s %9s %9s %9s %11s %11s\n" "$(padr 스레드 8)" "$(padl TPS 10)" "$(padl avg 9)" "$(padl p99 9)" "$(padl max 9)" "$(padl "직전 TPS×" 11)" "$(padl "직전 지연×" 11)"
printf "  %s\n" "--------------------------------------------------------------------------------"
BEST=0; BESTT=""; PT=""; PA=""
for th in 1 2 4 8 16 32 64; do
  IFS='|' read -r T A P M <<<"$(run1 "$th")"
  awk -v a="${T:-0}" -v b="$BEST" 'BEGIN{exit !(a>b)}' && { BEST="$T"; BESTT="$th"; }
  RT=$(awk -v a="${T:-0}" -v b="${PT:-0}" 'BEGIN{ if(b>0) printf "%.2fx", a/b; else printf "-" }')
  RA=$(awk -v a="${A:-0}" -v b="${PA:-0}" 'BEGIN{ if(b>0) printf "%.2fx", a/b; else printf "-" }')
  printf "  %s%10s %9s %9s %9s %11s %11s\n" "$(padr "$th" 8)" "${T:-?}" "${A:-?}" "${P:-?}" "${M:-?}" "$RT" "$RA"
  PT="$T"; PA="$A"
done
echo
echo "  최대 TPS 는 스레드 ${BESTT} 에서 나왔다 (CPU $(nproc 2>/dev/null || echo '?')개)."
echo
echo "  읽는 법 — **오른쪽 두 열이 무릎을 가리킨다.** 스레드를 두 배로 올렸을 때"
echo "   'TPS× 는 1 에 가까워지는데 지연× 는 2 에 가까워지는' 줄부터가 무릎 너머다."
echo "   거기서부터는 더 넣은 동시성이 처리량이 아니라 **대기열 길이**로만 간다."
echo
echo "   pgbench(tpcb-like)에서는 4→8 에서 **TPS 가 실제로 줄었다.** 여기서는 그런 구간이"
echo "   없을 수 있다 — oltp_read_write 는 14문장 중 10이 읽기라 버퍼 풀에서 끝나고,"
echo "   그 사이 CPU 가 비는 순간이 있어 스레드를 더 넣으면 그 틈을 메운다."
echo "   그래서 TPS 는 꺾이는 대신 **포화**한다. 포화 뒤에도 지연은 계속 는다."
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
BASE=""
for combo in "1:1" "1:0" "2:1" "2:0"; do
  F="${combo%%:*}"; S="${combo##*:}"
  q "SET GLOBAL innodb_flush_log_at_trx_commit=$F; SET GLOBAL sync_binlog=$S" >/dev/null
  IFS='|' read -r T A P M <<<"$(run1 8)"
  [ -z "$BASE" ] && BASE="$T"
  [ "$F" = 1 ] && FL="켬 (=1)" || FL="끔 (=2)"
  [ "$S" = 1 ] && SL="켬 (=1)" || SL="끔 (=0)"
  printf "  %s%s%12s %10s %10s\n" "$(padr "$FL" 14)" "$(padr "$SL" 16)" "${T:-?}" "${P:-?}" \
    "$(awk -v a="${T:-0}" -v b="${BASE:-0}" 'BEGIN{ if(b>0) printf "%.2fx", a/b }')"
done
restore
echo
echo "  둘 중에서는 binlog 쪽이 더 비싼 게 보통이다 — 커밋마다 파일 두 개를 다루기 때문이다."
echo "  그런데 **둘 다 꺼도 배수가 작다.** PostgreSQL 의 synchronous_commit 은 2.2배였는데."
echo
echo "  왜 작은가 — 가설 둘을 세우고 둘 다 재 봤다."
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
  printf "  %s%s%12s %12s %10s\n" "$(padr "$WL" 18)" "$(padr "$TH" 8)" "${ON:-?}" "${OFF:-?}" \
    "$(awk -v a="${OFF:-0}" -v b="${ON:-0}" 'BEGIN{ if(b>0) printf "%.2fx", a/b }')"
done
restore
echo
echo "  → **(가) 그룹 커밋 가설은 기각됐다.** 쓰기만 하는 워크로드에서 스레드 1과 8의 배수가"
echo "    거의 같다. 그룹 커밋이 원인이라면 혼자 도는 1스레드에서 배수가 훨씬 커야 한다."
echo "  → **(나)가 맞다.** 같은 손잡이가 읽기 섞인 트랜잭션에서는 작고, 쓰기만 하면 크게 벌어진다."
echo
echo "  그래서 이 절의 결론은 엔진 비교가 아니다 — **커밋 내구성의 '값'은 트랜잭션에서 커밋이"
echo "  차지하는 비율이 정한다.** PostgreSQL 의 2.2배와 여기의 배수를 나란히 놓고 '엔진이 다르다'고"
echo "  읽으면 안 된다. pgbench tpcb 는 5문장, oltp_read_write 는 14문장이다."
echo "  **손잡이의 효과를 벤치마크 사이에서 비교하려면 트랜잭션 구성부터 맞춰야 한다**(§T-0)."
echo
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
BT=""; BM=""
for cap in 1024 8; do
  q "SET GLOBAL innodb_redo_log_capacity=$((cap*1024*1024))" >/dev/null
  W0=$(q "SHOW GLOBAL STATUS LIKE 'Innodb_os_log_written'" | awk '{print $2}')
  IFS='|' read -r T A P M <<<"$(run1 8 "$LUAW")"
  W1=$(q "SHOW GLOBAL STATUS LIKE 'Innodb_os_log_written'" | awk '{print $2}')
  [ -z "$BT" ] && { BT="$T"; BM="$M"; }
  printf "  %s%12s %10s %10s %14s\n" "$(padr "${cap}MB" 14)" "${T:-?}" "${P:-?}" "${M:-?}" \
    "$(awk -v a="${W1:-0}" -v b="${W0:-0}" 'BEGIN{printf "%.0f MB", (a-b)/1048576}')"
done
restore
echo
echo "  읽는 법 — **TPS 와 p99 만 보면 이 사고를 놓친다.**"
echo "   redo 를 좁히면 InnoDB 는 더티 페이지를 급하게 내려야 하고(비동기 플러시),"
echo "   그 압력이 가장 운 나쁜 트랜잭션 하나에 몰린다. 그게 max 열이다."
echo "   redo 기록량이 용량을 여러 번 감을 만큼 나와야 압력이 걸린 것이다 — 그래서 그 열을 같이 찍는다."
echo
echo "   PostgreSQL: TPS -12%, p99 +10%, **max 54배**. 여기서도 같은 모양이 나온다면"
echo "   이건 엔진 문제가 아니라 **'로그 공간을 좁히면 스톨이 생긴다'는 구조 문제**다."
echo "   두 엔진의 배수 크기가 다른 것은 정상이다(로그 크기도 플러시 알고리즘도 다르다)."
echo "   **같은 것은 방향이다: 평균은 조금 나빠지고 최악은 자릿수로 나빠진다.**"
echo
echo "   → p99 만 보는 대시보드는 이 스톨을 통째로 놓친다."
echo "     Millsap 의 미계상 시간(§M-3)은 실행계획에도 평균에도 p99 에도 안 나온다."
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
