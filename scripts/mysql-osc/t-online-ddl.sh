#!/usr/bin/env bash
# §X-2(책 밖) 무정지 스키마 변경 — INT→BIGINT, 네이티브 vs gh-ost.
#
# 왜 이 타입 변경인가. ADD/DROP COLUMN 은 MySQL 8.0.12+ 에서 ALGORITHM=INSTANT 라
# 메타데이터만 바꾸고 즉시 끝난다 — 거기엔 온라인 DDL 도구가 필요 없다. 반면
# **컬럼의 타입을 바꾸는 것(INT→BIGINT)은 INSTANT 도 INPLACE 도 안 된다** —
# 이 환경에서 직접 확인했다(ALGORITHM=INPLACE 를 주면 "Cannot change column type
# INPLACE... Try ALGORITHM=COPY" 로 거부된다). PK 가 INT 로 만들어진 뒤 21억에
# 다가가는 것이 실무에서 가장 흔한 "무정지 스키마 변경"이 필요해지는 이유이고,
# gh-ost·pt-online-schema-change 가 존재하는 이유 그 자체다. 그래서 이 스크립트는
# ①②에서 그 대비(INSTANT 대 COPY)를 먼저 찍고, ③④에서 COPY 의 대가(쓰기 차단)와
# gh-ost 가 그걸 어떻게 피하는지(백필+binlog 적용+원자적 cutover, 그리고
# replica lag 쓰로틀)를 잰다.
#
# 부하 없이 재면 숫자가 거짓말이 된다 — 아무도 안 쓰는 테이블의 COPY 는 "차단"이라는
# 말이 무의미하고(차단할 쓰기가 없다), 쓰로틀도 발동할 일이 없다. 그래서 모든 측정
# 구간에 배경 쓰기 부하를 걸고, **TPS>0 로 실제로 돌고 있는지 확인한 뒤에만** 잰다.
#
# 사용법:
#   ./setup-topology.sh 를 먼저 돌려 토폴로지를 준비해 둔다.
#   ./t-online-ddl.sh                 # 전부
#   ONLY=3 ./t-online-ddl.sh          # gh-ost 청크 스윕만
#   CHUNKS="100 1000 10000" ./t-online-ddl.sh
#
# 중단해도 컨테이너는 안 지운다(_exp-trap.inc). 완전히 치우려면 ./teardown.sh.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ONLY="${ONLY:-1234}"
want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
CHUNKS="${CHUNKS:-100 1000 10000}"
LOADERS="${LOADERS:-4}"
SC="${SC:-/tmp/claude-0/-home-user-db-modeling/d3dd1f58-4266-5bdf-acd9-a25044e15fc4/scratchpad}"
GHOST_BIN="$SC/gh-ost"
PROBEDIR="$SC/osc-probe"
mkdir -p "$PROBEDIR"

. ./_exp-trap.inc

OSC_NET="${OSC_NET:-osc-net}"
# ── 토폴로지가 실제로 떠 있는지 먼저 확인한다 — "컨테이너가 없는데 측정을 시도해서
#    에러 메시지만 보고 끝나는" 것보다 여기서 바로 멈추는 게 낫다. ──
NUP=$(docker ps --filter "name=^osc-" --format '{{.Names}}' 2>/dev/null | grep -c '^osc-' || true)
if [ "${NUP:-0}" -lt 3 ]; then
  echo "  [중단] 토폴로지가 없다 — 먼저 ./setup-topology.sh 를 돌려라."
  exit 1
fi

PRIMARY_IP=$(osc_ip osc-primary)
REPLICA1_IP=$(osc_ip osc-replica1)
REPLICA2_IP=$(osc_ip osc-replica2)
ROWS=$(P "SELECT count(*) FROM osctest.orders" | tail -1)
case "$ROWS" in ''|*[!0-9]*) echo "  [중단] osctest.orders 를 못 읽었다."; exit 1;; esac
echo "§X-2 무정지 스키마 변경 — INT→BIGINT, 네이티브 vs gh-ost"
echo "  토폴로지: primary($PRIMARY_IP) + replica1 정상($REPLICA1_IP) + replica2 지연($REPLICA2_IP)"
echo "  osctest.orders ${ROWS}행"
echo

MYSQL_P() { mysql -h "$PRIMARY_IP" -P 3306 -uroot -p"$MYROOT_PW" "$@" 2>/dev/null; }

# ══════════════════════════════════════════════════════════════════════
# 배경 쓰기 부하 — $LOADERS 개의 독립 연결이 무작위 id 에 단건 UPDATE 를 반복한다.
# 각 성공 시각(ms epoch)을 공유 로그에 한 줄씩 남긴다. 이 로그가 "지금 멈췄다"를
# 재는 유일한 근거다 — gh-ost 의 진행률 출력이 아니라 **실제 쓰기가 끊긴 시간**을 본다.
start_load() {
  local logfile="$1"
  : > "$logfile"
  for i in $(seq 1 "$LOADERS"); do
    ( while true; do
        id=$(( (RANDOM * RANDOM) % ROWS + 1 ))
        if MYSQL_P -e "UPDATE osctest.orders SET amount=amount+1 WHERE id=$id;" >/dev/null 2>&1; then
          date +%s%3N >> "$logfile"
        fi
      done ) &
    EXP_PIDS="$EXP_PIDS $!"
  done
}

stop_load() { exp_kill_bg; }

# 부하가 **실제로** 돌고 있는지 2초 재서 확인한다. 0 이면 "부하를 걸었다"고
# 말하면 안 된다 — 걸었다고 쓴 코드와 실제로 도는 것은 다른 문제다.
# ⚠️ 직전에 restore_to_int()(COPY, ~30초 블로킹)나 강제 종료된 gh-ost 가 있었다면
# 메타데이터 락/커넥션이 아주 잠깐 안 풀린 채로 start_load 가 시작될 수 있다
# (실측: ④ 처치군 직전 restore_to_int 뒤 0 writes/s 로 한 번 그렇게 잡혔다 —
# 몇 초 뒤엔 수동 UPDATE 가 멀쩡히 먹혔다). 0 이라고 바로 포기하지 않고 몇 번
# 더 재서 진짜 멈춘 것인지 확인한다.
verify_load_running() {
  local logfile="$1" before after tps i
  for i in 1 2 3; do
    before=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    sleep 2
    after=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    tps=$(( (after - before) / 2 ))
    if [ "$tps" -gt 0 ]; then
      echo "  배경 부하 확인: ${tps} writes/s (연결 ${LOADERS}개)"
      return 0
    fi
    echo "  배경 부하 확인: 0 writes/s — 재확인 ${i}/3"
  done
  echo "  [중단] 배경 부하가 안 돈다 — 이 상태로 재면 '쓰기 차단'이 무의미하다."
  return 1
}

# 로그 파일에서 "가장 긴 연속 공백"을 ms 로 뽑는다 — COPY/cutover 의 블로킹 시간.
max_gap_ms() {
  sort -n "$1" | awk '
    NR>1 { d=$1-prev; if (d>max) max=d }
    { prev=$1 }
    END { print max+0 }'
}

ensure_ghost() {
  [ -x "$GHOST_BIN" ] && return 0
  echo "  gh-ost 바이너리가 없다 — 소스에서 빌드한다(최초 1회, ~1분)."
  local src="$SC/gh-ost-src"
  [ -d "$src" ] || git clone --depth 1 https://github.com/github/gh-ost "$src" >/dev/null 2>&1
  ( cd "$src" && go build -o "$GHOST_BIN" ./go/cmd/gh-ost ) || { echo "  [중단] gh-ost 빌드 실패"; exit 1; }
}

restore_to_int() {
  # §2/§3/§4 가 cust_id 를 BIGINT 로 바꿔 놓고 끝난다. 다음 섹션이 "INT→BIGINT" 를
  # 다시 재려면 원복해야 한다 — 그런데 **원복도 COPY 다**(BIGINT→INT 도 타입 변경).
  # 그래서 매 섹션의 "변경 전" 모양을 맞추기 위해 조용히 되돌리고, 이 되돌리기
  # 자체도 §2 의 COPY 시간에 포함되지 않도록 측정 밖에서 한다.
  P "ALTER TABLE osctest.orders MODIFY cust_id INT NOT NULL;" >/dev/null 2>&1
}

echo "현재 cust_id 타입: $(P "SELECT column_type FROM information_schema.columns WHERE table_schema='osctest' AND table_name='orders' AND column_name='cust_id'" | tail -1)"
echo

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① ADD COLUMN — INSTANT 는 도구가 필요 없다 ──"
LOG="$PROBEDIR/add.log"
start_load "$LOG"
verify_load_running "$LOG" || { stop_load; exit 1; }
P "ALTER TABLE osctest.orders DROP COLUMN IF EXISTS note;" >/dev/null 2>&1
T0=$(date +%s%3N)
P "ALTER TABLE osctest.orders ADD COLUMN note VARCHAR(50) NULL, ALGORITHM=INSTANT;" >/dev/null
T1=$(date +%s%3N)
sleep 1   # 후행 쓰기 몇 번을 더 로그에 남겨 직후 공백도 잡는다
stop_load
DUR1=$(( T1 - T0 ))
GAP1=$(max_gap_ms "$LOG")
printf "  ALTER 소요: %sms   쓰기 로그 최대 공백: %sms\n" "$DUR1" "$GAP1"
echo "  → ALGORITHM=INSTANT 는 메타데이터만 바꾼다 — 소요 시간과 최대 공백이 둘 다"
echo "    배경 부하의 쓰기 간격(수십 ms) 수준이면 '사실상 무정지'다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② MODIFY INT→BIGINT, 네이티브 ALTER(COPY) — 쓰기가 멈추는 시간 ──"
restore_to_int
LOG="$PROBEDIR/native.log"
start_load "$LOG"
verify_load_running "$LOG" || { stop_load; exit 1; }
echo "  ALTER 시작 (${ROWS}행 COPY)..."
T0=$(date +%s%3N)
P "ALTER TABLE osctest.orders MODIFY cust_id BIGINT NOT NULL;" >/dev/null
T1=$(date +%s%3N)
sleep 1
stop_load
DUR2=$(( T1 - T0 ))
GAP2=$(max_gap_ms "$LOG")
printf "  ALTER 소요: %sms (%.1f초)   쓰기 로그 최대 공백: %sms (%.1f초)\n" \
  "$DUR2" "$(awk -v d=$DUR2 'BEGIN{print d/1000}')" "$GAP2" "$(awk -v g=$GAP2 'BEGIN{print g/1000}')"
RATIO2=$(awk -v g="$GAP2" -v d="$DUR2" 'BEGIN{ if(d>0) printf "%.0f", g*100/d; else print "?" }')
echo "  → 최대 공백이 ALTER 전체 시간의 ${RATIO2}% 다 — COPY 는 '거의 전체 시간'"
echo "    쓰기를 막는다는 것이 숫자로 확인된다(ALGORITHM=INPLACE 는 이 타입 변경에서"
echo "    아예 거부된다 — 이 환경에서 직접 확인했다: 'Try ALGORITHM=COPY')."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
echo "── ③ 같은 변경을 gh-ost 로 — 청크 크기별 백필 처리량과 cutover 블로킹 ──"
ensure_ghost
printf "  %-10s %12s %14s %16s\n" "청크" "소요(초)" "cutover블록(ms)" "백필 행/초(추정)"
printf "  %s\n" "------------------------------------------------------------------"
FIRST=1
for ch in $CHUNKS; do
  restore_to_int
  LOG="$PROBEDIR/ghost_$ch.log"
  start_load "$LOG"
  verify_load_running "$LOG" || { stop_load; continue; }
  OUT="$PROBEDIR/ghost_$ch.out"
  T0=$(date +%s%3N)
  "$GHOST_BIN" \
    --host="$PRIMARY_IP" --port=3306 --user=ghost --password=ghostpass \
    --database=osctest --table=orders \
    --alter="MODIFY COLUMN cust_id BIGINT NOT NULL" \
    --chunk-size="$ch" \
    --allow-on-master --initially-drop-ghost-table --initially-drop-old-table \
    --execute > "$OUT" 2>&1
  RC=$?
  T1=$(date +%s%3N)
  sleep 1
  stop_load
  DUR=$(( T1 - T0 ))
  GAP=$(max_gap_ms "$LOG")
  if [ "$RC" -ne 0 ] || ! grep -q "^# Done" "$OUT"; then
    echo "  [실패] chunk=$ch — gh-ost 가 완료되지 않았다. 로그: $OUT"
    tail -5 "$OUT" | sed 's/^/    /'
    continue
  fi
  THR=$(awk -v r="$ROWS" -v d="$DUR" 'BEGIN{ if(d>0) printf "%.0f", r*1000/d }')
  printf "  %-10s %12s %16s %16s\n" "$ch" "$(awk -v d=$DUR 'BEGIN{printf "%.1f", d/1000}')" "$GAP" "$THR"
  [ "$FIRST" = "1" ] && { FIRST_GAP="$GAP"; FIRST_DUR="$DUR"; FIRST=0; }
done
echo
if [ -n "${GAP2:-}" ] && [ -n "${FIRST_GAP:-}" ]; then
  echo "  → 네이티브 COPY 의 쓰기 공백 ${GAP2}ms 대비, gh-ost 의 cutover 공백은"
  echo "    자릿수가 다르다(gh-ost 는 백필을 binlog 로 따라잡다가 **그 순간만**"
  echo "    짧게 테이블을 잠그고 치환한다 — COPY 처럼 전체 복사 내내 막지 않는다)."
fi
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 4; then
echo "── ④ replica lag 쓰로틀 — 대조군(정상 replica1) vs 처치군(지연 replica2) ──"
ensure_ghost
restore_to_int
R2LAG=$(R2 "SHOW REPLICA STATUS\G" | awk -F': ' '/Seconds_Behind_Source:/{print $2}')
echo "  replica2 현재 지연: ${R2LAG:-?}초 (SOURCE_DELAY 로 인위 생성)"
echo

echo "  [대조군] --throttle-control-replicas=replica1(지연 없음), max-lag-millis=500"
LOG="$PROBEDIR/throttle_ctrl.log"
rm -f /tmp/gh-ost.*.sock
start_load "$LOG"; verify_load_running "$LOG" || { stop_load; exit 1; }
T0=$(date +%s%3N)
timeout 450 "$GHOST_BIN" \
  --host="$PRIMARY_IP" --port=3306 --user=ghost --password=ghostpass \
  --database=osctest --table=orders --alter="MODIFY COLUMN cust_id BIGINT NOT NULL" \
  --throttle-control-replicas="${REPLICA1_IP}:3306" --max-lag-millis=500 \
  --allow-on-master --initially-drop-ghost-table --initially-drop-old-table \
  --execute > "$PROBEDIR/throttle_ctrl.out" 2>&1
RC_CTRL=$?
T1=$(date +%s%3N)
stop_load
DUR_CTRL=$(( T1 - T0 ))
grep -qc "^# Done" "$PROBEDIR/throttle_ctrl.out" >/dev/null
DONE_CTRL=$(grep -c "^# Done" "$PROBEDIR/throttle_ctrl.out")
THROTTLE_LINES_CTRL=$(grep -c "State: throttled" "$PROBEDIR/throttle_ctrl.out")
echo "  대조군: ${DUR_CTRL}ms 소요, 완료=$([ "$DONE_CTRL" -ge 1 ] && echo 예 || echo 아니오), 실제 쓰로틀 ${THROTTLE_LINES_CTRL}줄"
restore_to_int

echo
echo "  [처치군] --throttle-control-replicas=replica2(지연 ${R2LAG:-?}초), max-lag-millis=500"
LOG="$PROBEDIR/throttle_treat.log"
# ⚠️ 대조군이 timeout 60 에 의해 강제 종료되면 gh-ost 가 정상 종료 경로를 못 타서
# /tmp/gh-ost.*.sock 을 못 지운다. 다음 gh-ost 가 같은 소켓 경로로 바인드를
# 시도하다 "bind: address already in use" 로 즉사한다(실측: 처치군이 256ms 만에
# 끝나고 쓰로틀 로그가 0줄이었다 — 쓰로틀이 안 걸린 게 아니라 아예 못 뜬 것이었다).
# 매 gh-ost 실행 직전에 지운다.
rm -f /tmp/gh-ost.*.sock
start_load "$LOG"; verify_load_running "$LOG" || { stop_load; exit 1; }
T0=$(date +%s%3N)
timeout 450 "$GHOST_BIN" \
  --host="$PRIMARY_IP" --port=3306 --user=ghost --password=ghostpass \
  --database=osctest --table=orders --alter="MODIFY COLUMN cust_id BIGINT NOT NULL" \
  --throttle-control-replicas="${REPLICA2_IP}:3306" --max-lag-millis=500 \
  --allow-on-master --initially-drop-ghost-table --initially-drop-old-table \
  --execute > "$PROBEDIR/throttle_treat.out" 2>&1
RC_TREAT=$?
T1=$(date +%s%3N)
stop_load
DUR_TREAT=$(( T1 - T0 ))
DONE_TREAT=$(grep -c "^# Done" "$PROBEDIR/throttle_treat.out")
THROTTLE_LINES_TREAT=$(grep -c "State: throttled" "$PROBEDIR/throttle_treat.out")
echo "  처치군: ${DUR_TREAT}ms 소요(타임아웃 450s 안에 $([ "$DONE_TREAT" -ge 1 ] && echo 완료 || echo 미완료)), 실제 쓰로틀 ${THROTTLE_LINES_TREAT}줄"
echo
if [ "${THROTTLE_LINES_TREAT:-0}" -gt "${THROTTLE_LINES_CTRL:-0}" ] && [ "$DONE_TREAT" -lt 1 ]; then
  echo "  → 대조군은 완료됐고(실제 쓰로틀 ${THROTTLE_LINES_CTRL}줄), 처치군은 450초 안에"
  echo "    못 끝났다(실제 쓰로틀 ${THROTTLE_LINES_TREAT}줄) — **같은 변경, 같은 부하인데"
  echo "    replica lag 만 다르다.** 쓰로틀이 지연된 replica 를 보고 실제로 멈춘 것이다."
  echo "    대조군이 없었으면 '처치군이 느린 것'과 '쓰로틀이 작동한 것'을 구분할 수 없었다."
else
  echo "  [주의] 기대한 대비(대조군 완료 / 처치군 미완료)가 안 나왔다 — 로그를 직접 보라:"
  echo "    $PROBEDIR/throttle_ctrl.out"
  echo "    $PROBEDIR/throttle_treat.out"
fi
restore_to_int
echo
fi

LAB_DONE=1
echo "정리: 실험 테이블(osctest.orders)은 cust_id=INT 상태로 남겨 둔다."
echo "  토폴로지를 완전히 치우려면: ./teardown.sh"
