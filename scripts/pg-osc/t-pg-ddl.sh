#!/usr/bin/env bash
# §X-3(책 밖) 무정지 스키마 변경 — PostgreSQL 판 — INT→BIGINT, 네이티브 vs 수동 expand-contract.
#
# MySQL 판(scripts/mysql-osc)과 같은 질문을 PostgreSQL 로 다시 묻는다. 그런데
# PostgreSQL 은 MySQL 과 답이 다르다:
#
#   - ADD COLUMN(기본값 포함)은 PG 11+ 에서 **이미 무정지**다(기본값을 카탈로그에만
#     저장한다, 테이블 재작성 없음) — 도구가 필요 없다는 결론이 MySQL 의
#     ALGORITHM=INSTANT 보다도 더 일찍(PG 11, 2018) 왔다.
#   - 컬럼 타입 변경(INT→BIGINT)은 **대부분 테이블 전체 재작성**을 요구하고
#     ACCESS EXCLUSIVE 락(읽기도 막는다, MySQL 의 COPY 보다 강하다)을 그 끝날
#     때까지 잡는다 — 이 환경에서 직접 확인한다.
#   - **PostgreSQL 에는 gh-ost 같은 기성 온라인 DDL 도구가 없다.** 실무에서 쓰는
#     표준 해법은 "새 컬럼 추가(shadow) → 트리거로 이중 쓰기 → 배치로 백필 →
#     원자적 컬럼 교체(RENAME)" 를 **직접 만드는** 것이다(GitLab·Shopify 등이
#     공개적으로 쓰는 패턴). ③이 그걸 구현해서 배치 크기별로 잰다 — gh-ost의
#     청크 스윕과 같은 질문, 도구만 손으로 만든 버전이다.
#   - replica lag 쓰로틀도 마찬가지로 **직접 만든다** — gh-ost 는
#     --throttle-control-replicas 로 공짜로 주지만, PostgreSQL 에서는 백필
#     루프 안에 pg_stat_replication 을 직접 재서 끼워 넣어야 한다. ④가 그걸
#     한다.
#
# 사용법:
#   ./setup-topology.sh 를 먼저 돌려 토폴로지를 준비해 둔다.
#   ./t-pg-ddl.sh                  # 전부
#   ONLY=3 ./t-pg-ddl.sh           # 수동 백필 배치 스윕만
#   BATCHES="100 1000 10000" ./t-pg-ddl.sh
#
# 중단해도 컨테이너는 안 지운다(_exp-trap.inc). 완전히 치우려면 ./teardown.sh.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ONLY="${ONLY:-1234}"
want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }
BATCHES="${BATCHES:-100 1000 10000}"
LOADERS="${LOADERS:-4}"
THROTTLE_TIMEOUT="${THROTTLE_TIMEOUT:-450}"
PROBEDIR="${PROBEDIR:-/tmp/pg-osc-scratch/probe}"; mkdir -p "$PROBEDIR"

PG_NET="${PG_NET:-pg-osc-net}"
NUP=$(docker ps --filter "name=^pg-" --format '{{.Names}}' 2>/dev/null | grep -c '^pg-' || true)
if [ "${NUP:-0}" -lt 3 ]; then
  echo "  [중단] 토폴로지가 없다 — 먼저 ./setup-topology.sh 를 돌려라."
  exit 1
fi

PRIMARY_HOST=127.0.0.1; PRIMARY_PORT=5433
REPLICA1_HOST=127.0.0.1; REPLICA1_PORT=5434
REPLICA2_HOST=127.0.0.1; REPLICA2_PORT=5435
REPLICA1_IP=$(pg_ip pg-replica1)
REPLICA2_IP=$(pg_ip pg-replica2)

if ! command -v psql >/dev/null 2>&1; then
  echo "  [중단] 호스트에 psql 클라이언트가 없다 — 배경 부하 접속에 필요하다."
  exit 1
fi
if ! PREFLIGHT=$(PGPASSWORD="$PGPASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -d pgosctest -tAc "SELECT 1" 2>&1); then
  echo "  [중단] primary(${PRIMARY_HOST}:${PRIMARY_PORT}) 접속 실패 — 실제 에러:"
  echo "$PREFLIGHT" | sed 's/^/    /'
  exit 1
fi

ROWS=$(P "SELECT count(*) FROM orders;")
case "$ROWS" in ''|*[!0-9]*) echo "  [중단] orders 를 못 읽었다."; exit 1;; esac
echo "§X-3 무정지 스키마 변경(PostgreSQL) — INT→BIGINT, 네이티브 vs 수동 expand-contract"
echo "  토폴로지: primary(${PRIMARY_HOST}:${PRIMARY_PORT}) + replica1 정상(${REPLICA1_HOST}:${REPLICA1_PORT}) + replica2 지연(${REPLICA2_HOST}:${REPLICA2_PORT})"
echo "  orders ${ROWS}행"
echo

. ./_exp-trap.inc

PSQL_P() { PGPASSWORD="$PGPASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -d pgosctest -v ON_ERROR_STOP=1 -Atq "$@"; }

# ══════════════════════════════════════════════════════════════════════
# 배경 쓰기 부하 — MySQL 판(§9)에서 "UPDATE 한 건마다 새 연결"이 처리량을
# 50~130/초로 깔아뭉갠 걸 실측으로 잡았다(연결당 새 TCP+인증 오버헤드가
# 실제 부하보다 커짐). 처음부터 로더당 연결 하나를 열어 재사용한다.
# ⚠️ psql 의 `-q`(quiet) 는 "UPDATE 1" 같은 커맨드 태그 출력 자체를 지운다
# (MySQL 의 --batch 와 다르다 — 거기선 그 출력이 남는다). `-q` 를 쓰면 완료
# 신호로 삼을 게 아무것도 안 나와서 로그가 영원히 0줄이다(실측: 처음 이렇게
# 짜서 "배경 부하 확인: 0 writes/s" 로 매번 막혔다 — 연결 자체는 멀쩡했다).
start_load() {
  local logfile="$1"
  : > "$logfile"
  for i in $(seq 1 "$LOADERS"); do
    setsid bash -c '
      while true; do
        id=$(( (RANDOM * RANDOM) % '"$ROWS"' + 1 ))
        echo "UPDATE orders SET amount=amount+1 WHERE id=$id;"
      done | PGPASSWORD="'"$PGPASS"'" psql -h "'"$PRIMARY_HOST"'" -p "'"$PRIMARY_PORT"'" -U postgres -d pgosctest -v ON_ERROR_STOP=0 -At 2>/dev/null \
        | while IFS= read -r line; do
            case "$line" in UPDATE*) date +%s%3N >> "'"$logfile"'";; esac
          done
    ' &
    EXP_PIDS="$EXP_PIDS $!"
  done
}
stop_load() { exp_kill_bg; }

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

max_gap_ms() {
  sort -n "$1" | awk '
    NR>1 { d=$1-prev; if (d>max) max=d }
    { prev=$1 }
    END { print max+0 }'
}

restore_to_int() {
  # ②/③/④ 가 cust_id 를 바꿔 놓고 끝난다 — 다음 섹션이 "INT→BIGINT" 를 다시
  # 재려면 원복해야 한다. 이 원복도 ②와 똑같이 재작성을 유발하지만, 측정
  # 구간 밖에서 조용히 한다(MySQL 판과 같은 이유).
  PSQL_P -c "ALTER TABLE orders ALTER COLUMN cust_id TYPE INT;" >/dev/null 2>&1
  PSQL_P -c "ALTER TABLE orders DROP COLUMN IF EXISTS cust_id_new, DROP COLUMN IF EXISTS cust_id_old;" >/dev/null 2>&1
  PSQL_P -c "DROP TRIGGER IF EXISTS cust_id_sync ON orders;" >/dev/null 2>&1
  PSQL_P -c "DROP FUNCTION IF EXISTS cust_id_sync_fn();" >/dev/null 2>&1
  # §9 후속5 에서 autovacuum_enabled=false 로 꺼 두고 측정하므로, 다음 섹션이
  # 그 설정을 물려받지 않도록 매번 기본값으로 되돌린다.
  PSQL_P -c "ALTER TABLE orders RESET (autovacuum_enabled);" >/dev/null 2>&1
}

echo "현재 cust_id 타입: $(P "SELECT data_type FROM information_schema.columns WHERE table_name='orders' AND column_name='cust_id';")"
echo

# ══════════════════════════════════════════════════════════════════════
if want 1; then
echo "── ① ADD COLUMN DEFAULT — PG 11+ 는 이미 무정지다 ──"
LOG="$PROBEDIR/add.log"
start_load "$LOG"
verify_load_running "$LOG" || { stop_load; exit 1; }
PSQL_P -c "ALTER TABLE orders DROP COLUMN IF EXISTS note;" >/dev/null 2>&1
T0=$(date +%s%3N)
PSQL_P -c "ALTER TABLE orders ADD COLUMN note VARCHAR(50) DEFAULT 'x';" >/dev/null
T1=$(date +%s%3N)
sleep 1
stop_load
DUR1=$(( T1 - T0 ))
GAP1=$(max_gap_ms "$LOG")
printf "  ALTER 소요: %sms   쓰기 로그 최대 공백: %sms\n" "$DUR1" "$GAP1"
echo "  → DEFAULT 가 있어도 카탈로그에만 저장한다(PG 11+) — 테이블을 안 건드린다."
echo "    MySQL 의 ALGORITHM=INSTANT 와 같은 결론이지만, PG 는 11(2018)부터 이미 이랬다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② ALTER COLUMN TYPE INT→BIGINT, 네이티브 — 쓰기(그리고 읽기도)가 멈추는 시간 ──"
restore_to_int
LOG="$PROBEDIR/native.log"
start_load "$LOG"
verify_load_running "$LOG" || { stop_load; exit 1; }
echo "  ALTER 시작 (${ROWS}행 재작성)..."
T0=$(date +%s%3N)
PSQL_P -c "ALTER TABLE orders ALTER COLUMN cust_id TYPE BIGINT;" >/dev/null
T1=$(date +%s%3N)
sleep 1
stop_load
DUR2=$(( T1 - T0 ))
GAP2=$(max_gap_ms "$LOG")
printf "  ALTER 소요: %sms (%.1f초)   쓰기 로그 최대 공백: %sms (%.1f초)\n" \
  "$DUR2" "$(awk -v d=$DUR2 'BEGIN{print d/1000}')" "$GAP2" "$(awk -v g=$GAP2 'BEGIN{print g/1000}')"
RATIO2=$(awk -v g="$GAP2" -v d="$DUR2" 'BEGIN{ if(d>0) printf "%.0f", g*100/d; else print "?" }')
echo "  → 최대 공백이 ALTER 전체 시간의 ${RATIO2}% 다 — int4→int8 은 바이너리 호환이"
echo "    아니라 전체 재작성이 강제된다. ACCESS EXCLUSIVE 락이라 이 구간엔 SELECT 도 막힌다"
echo "    (MySQL 의 COPY 는 쓰기만 막고 읽기는 됐다 — PG 가 더 심하다)."
echo
fi

# ══════════════════════════════════════════════════════════════════════
# 수동 expand-contract 백필 — gh-ost 가 하는 일(섀도 컬럼 + 트리거로 이중쓰기 +
# 배치 백필 + 원자적 교체)을 손으로 구현한다. PostgreSQL 에 이걸 패키지로 해
# 주는 공식 도구가 없다는 것 자체가 결론이다.
expand_contract_backfill() {
  local batch="$1" throttle_ip="${2:-}" out="$3"
  local ok=1 total=0 lag_ms attempts
  # ⚠️ 쓰로틀 대기 횟수를 배치 루프 안에서 매번 0으로 리셋하면, "이번 배치만
  # 보면 안 풀렸다"가 아니라 "배치 경계를 넘나들며 간헐적으로 쓰로틀되는
  # 경우"에 전체 누적 대기 시간이 THROTTLE_TIMEOUT 을 넘겨도 못 잡는다(배치
  # 바뀔 때마다 카운터가 새로 시작하므로). 벽시계 데드라인으로 재야 배치
  # 경계와 무관하게 정확하다.
  local deadline=$(( $(date +%s) + THROTTLE_TIMEOUT ))

  # §9 후속5 실측: 대량 백필(수백만 행 UPDATE)은 dead tuple 을 autovacuum
  # 임계치 너머로 쌓고, 그 autovacuum(VACUUM ANALYZE)이 cutover(RENAME)의
  # AccessExclusiveLock 과 충돌해 ~1초(deadlock_timeout 기본값, autovacuum
  # 이 자기 자신을 취소하기 전까지 다른 백엔드를 막는 체크 주기) 가까이
  # 묶이는 게 cutover 가 매번 "약 1초"로 고정됐던 진짜 원인이었다(직접
  # pg_locks 를 찍어서 확인했다 — watch-locks.sh). 백필 동안은 꺼 두고,
  # cutover 가 끝난 뒤에 수동으로 켜고 돌린다.
  PSQL_P -c "ALTER TABLE orders SET (autovacuum_enabled = false);" >> "$out" 2>&1

  PSQL_P -c "ALTER TABLE orders ADD COLUMN cust_id_new BIGINT;" >> "$out" 2>&1 || return 1
  PSQL_P -c "
    CREATE OR REPLACE FUNCTION cust_id_sync_fn() RETURNS trigger AS \$\$
    BEGIN
      NEW.cust_id_new := NEW.cust_id;
      RETURN NEW;
    END;
    \$\$ LANGUAGE plpgsql;
    CREATE TRIGGER cust_id_sync BEFORE INSERT OR UPDATE ON orders
      FOR EACH ROW EXECUTE FUNCTION cust_id_sync_fn();
  " >> "$out" 2>&1 || return 1

  local maxid; maxid=$(PSQL_P -c "SELECT max(id) FROM orders;")
  local lo=1
  while [ "$lo" -le "$maxid" ]; do
    local hi=$(( lo + batch - 1 ))

    if [ -n "$throttle_ip" ]; then
      attempts=0
      while :; do
        lag_ms=$(P "SELECT COALESCE(EXTRACT(EPOCH FROM replay_lag)*1000, 0)::bigint FROM pg_stat_replication WHERE client_addr='${throttle_ip}';" 2>/dev/null)
        case "$lag_ms" in ''|*[!0-9]*) lag_ms=0;; esac
        [ "$lag_ms" -le 500 ] && break
        attempts=$((attempts+1))
        echo "    [쓰로틀] replica(${throttle_ip}) lag=${lag_ms}ms > 500ms — 대기 (${attempts}번째)" >> "$out"
        sleep 1
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "  [중단] ${THROTTLE_TIMEOUT}초 동안 쓰로틀이 안 풀렸다." >> "$out"
          ok=0
          break 2
        fi
      done
    fi

    PSQL_P -c "UPDATE orders SET cust_id_new = cust_id WHERE id BETWEEN $lo AND $hi AND cust_id_new IS NULL;" >> "$out" 2>&1 || { ok=0; break; }
    total=$((total + batch))
    lo=$((hi + 1))
  done
  [ "$ok" = 1 ] || return 1

  # 커밋되지 않은 채 남은 NULL(백필 창과 교차한 UPDATE 가 있었다면) 마지막으로 한 번 더 쓸어준다.
  PSQL_P -c "UPDATE orders SET cust_id_new = cust_id WHERE cust_id_new IS NULL;" >> "$out" 2>&1

  return 0
}

cutover_rename() {
  # ⚠️ 한때 여기 lock_timeout(50ms) + 재시도를 넣었다 — gh-ost 식 전략을
  # 따라한 것이었는데, **실측해보니 역효과였다**: cutover 가 1,034ms 에서
  # 29,236~29,780ms 로 약 29배 악화됐다. 이유: 배경 로더 4개가 끊김 없이
  # 연속으로 UPDATE 를 쏘는 상황에서는 50ms 짜리 빈 틈이 거의 없어 거의
  # 매번 실패했고, PostgreSQL 의 락 대기열은 FIFO 라 **실패해서 물러나는
  # 시도조차 그 대기 중엔 뒤따라오는 새 UPDATE 들을 줄 세운다** — "짧게
  # 수백 번 실패"의 누적 차단 시간이 "길게 한 번 기다림"보다 훨씬 커졌다.
  # gh-ost 가 MySQL 에서 이 전략으로 성공하는 건 MySQL 의 cutover 메커니즘
  # 자체가 다르기 때문이지, 이 재시도 패턴을 PostgreSQL 에 그대로 옮긴다고
  # 똑같이 된다는 보장이 없었다 — 가설을 틀렸다고 실측으로 확인했으니
  # 단순한 버전으로 되돌린다.
  PSQL_P -c "
    BEGIN;
    ALTER TABLE orders RENAME COLUMN cust_id TO cust_id_old;
    ALTER TABLE orders RENAME COLUMN cust_id_new TO cust_id;
    COMMIT;
  "
}

# ── 연결 재사용 cutover (§X-3 "잔차" 진단 이후 추가) ──────────────────────
# cutover_rename() 은 매번 새 psql 프로세스로 TCP+인증을 처음부터 다시 맺는다
# — 로컬 재현(도커 없는 환경, 2,000,000행)으로 분리 재 보니 배경 부하가 있어도
# 같은 연결 안에서의 ACCESS EXCLUSIVE 락 대기는 1ms 미만이고, 관측된
# 44~87ms(10M행)의 거의 전부가 "매번 새 연결을 맺는 비용"이었다. gh-ost 는
# 백필 내내 열어 둔 MySQL 연결 하나를 cutover 까지 그대로 쓴다 — 그 모양을
# 그대로 흉내낸다: 백필이 끝나는 시점에 연결을 미리 열어 두고(CT0 측정 전),
# 그 위에서 cutover 만 실행한다(bash coproc 로 psql 를 대화형으로 띄워 둔다).
open_cutover_conn() {
  coproc CUTCONN { PGPASSWORD="$PGPASS" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -d pgosctest -v ON_ERROR_STOP=1 -Atq; }
  CUTCONN_IN=${CUTCONN[1]}
  CUTCONN_OUT=${CUTCONN[0]}
  # ⚠️ coproc 는 포크만 하고 즉시 돌아온다 — TCP+인증이 끝나기 전에 CT0 를
  # 찍으면 그 연결 수립 시간이 그대로 측정 구간에 섞여 들어가 "연결 재사용"의
  # 의미가 없어진다(실측: 이 대기를 빼먹고 처음 쟀을 때 57~85ms로 수정 전과
  # 다를 바 없이 나왔다). 연결이 실제로 응답할 때까지 기다린 뒤에야 CT0 를
  # 찍어야 한다.
  echo "SELECT 'ready';" >&"$CUTCONN_IN"
  while IFS= read -r line <&"$CUTCONN_OUT"; do [ "$line" = "ready" ] && break; done
}
close_cutover_conn() {
  echo '\q' >&"$CUTCONN_IN" 2>/dev/null
  exec {CUTCONN_IN}>&- 2>/dev/null
  wait "$CUTCONN_PID" 2>/dev/null
}
cutover_rename_reuse() {
  local marker="__pgosc_cutover_done_$$__"
  {
    echo "BEGIN;"
    echo "ALTER TABLE orders RENAME COLUMN cust_id TO cust_id_old;"
    echo "ALTER TABLE orders RENAME COLUMN cust_id_new TO cust_id;"
    echo "COMMIT;"
    echo "SELECT '$marker';"
  } >&"$CUTCONN_IN"
  while IFS= read -r line <&"$CUTCONN_OUT"; do
    [ "$line" = "$marker" ] && break
  done
}

if want 3; then
echo "── ③ 수동 expand-contract — 배치 크기별 백필 처리량과 cutover 블로킹 ──"
printf "  %-10s %12s %16s %16s\n" "배치" "소요(초)" "cutover블록(ms)" "백필 행/초(추정)"
printf "  %s\n" "------------------------------------------------------------------"
FIRST=1
for b in $BATCHES; do
  restore_to_int
  LOG="$PROBEDIR/ec_$b.log"
  OUT="$PROBEDIR/ec_$b.out"
  start_load "$LOG"
  verify_load_running "$LOG" || { stop_load; continue; }
  T0=$(date +%s%3N)
  if ! expand_contract_backfill "$b" "" "$OUT"; then
    echo "  [실패] batch=$b — 백필이 완료되지 않았다. 로그: $OUT"
    tail -5 "$OUT" | sed 's/^/    /'
    stop_load
    continue
  fi
  open_cutover_conn
  CT0=$(date +%s%3N)
  cutover_rename_reuse
  CT1=$(date +%s%3N)
  close_cutover_conn
  T1=$(date +%s%3N)
  # cutover 가 끝난 뒤에 autovacuum 을 다시 켜고 수동으로 한 번 돌린다 — 이건
  # "마이그레이션이 끝났다고 볼 수 있는 시점" 이후의 뒷정리라 DUR/CUTGAP 측정
  # 구간 밖에서 한다(실제 운영에서도 비동기로 해도 되는 일이다).
  PSQL_P -c "ALTER TABLE orders RESET (autovacuum_enabled); VACUUM ANALYZE orders;" >> "$OUT" 2>&1
  sleep 1
  stop_load
  DUR=$(( T1 - T0 ))
  CUTGAP=$(( CT1 - CT0 ))
  GAP=$(max_gap_ms "$LOG")
  THR=$(awk -v r="$ROWS" -v d="$DUR" 'BEGIN{ if(d>0) printf "%.0f", r*1000/d }')
  printf "  %-10s %12s %16s %16s\n" "$b" "$(awk -v d=$DUR 'BEGIN{printf "%.1f", d/1000}')" "$CUTGAP" "$THR"
  [ "$FIRST" = "1" ] && { FIRST_GAP="$GAP"; FIRST=0; }
done
echo
if [ -n "${GAP2:-}" ]; then
  echo "  → 네이티브 ALTER TYPE 의 쓰기 공백 ${GAP2}ms 대비, 수동 백필의 cutover(RENAME)"
  echo "    블로킹은 자릿수가 다르다 — RENAME 은 카탈로그만 바꾸는 메타데이터 연산이다."
  echo "    gh-ost 가 바이너리 하나로 자동으로 해 주는 걸, PG 는 트리거+배치 UPDATE+"
  echo "    RENAME 을 직접 짜야 똑같은 모양이 나온다는 게 이 섹션의 결론이다."
fi
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 4; then
echo "── ④ replica lag 쓰로틀 — 대조군(정상 replica1) vs 처치군(지연 replica2) ──"
restore_to_int
R2LAG_RAW=$(R2 "SELECT now() - pg_last_xact_replay_timestamp();" 2>/dev/null)
echo "  replica2 현재 지연: ${R2LAG_RAW:-?} (recovery_min_apply_delay 로 인위 생성)"
echo

echo "  [대조군] throttle-check=replica1(지연 없음), max-lag=500ms"
LOG="$PROBEDIR/throttle_ctrl.log"; OUT="$PROBEDIR/throttle_ctrl.out"
start_load "$LOG"; verify_load_running "$LOG" || { stop_load; exit 1; }
T0=$(date +%s%3N)
expand_contract_backfill 10000 "$REPLICA1_IP" "$OUT"
RC_CTRL=$?
T1=$(date +%s%3N)
stop_load
DUR_CTRL=$(( T1 - T0 ))
DONE_CTRL=$([ "$RC_CTRL" -eq 0 ] && echo 1 || echo 0)
THROTTLE_LINES_CTRL=$(grep -c "\[쓰로틀\]" "$OUT" 2>/dev/null); THROTTLE_LINES_CTRL=${THROTTLE_LINES_CTRL:-0}
echo "  대조군: ${DUR_CTRL}ms 소요, 완료=$([ "$DONE_CTRL" -ge 1 ] && echo 예 || echo 아니오), 실제 쓰로틀 ${THROTTLE_LINES_CTRL}줄"
if [ "$DONE_CTRL" = 1 ]; then
  cutover_rename >/dev/null 2>&1
  PSQL_P -c "ALTER TABLE orders RESET (autovacuum_enabled); VACUUM ANALYZE orders;" >/dev/null 2>&1
fi
restore_to_int

echo
echo "  [처치군] throttle-check=replica2(지연), max-lag=500ms"
LOG="$PROBEDIR/throttle_treat.log"; OUT="$PROBEDIR/throttle_treat.out"
start_load "$LOG"; verify_load_running "$LOG" || { stop_load; exit 1; }
T0=$(date +%s%3N)
expand_contract_backfill 10000 "$REPLICA2_IP" "$OUT"
RC_TREAT=$?
T1=$(date +%s%3N)
stop_load
DUR_TREAT=$(( T1 - T0 ))
DONE_TREAT=$([ "$RC_TREAT" -eq 0 ] && echo 1 || echo 0)
THROTTLE_LINES_TREAT=$(grep -c "\[쓰로틀\]" "$OUT" 2>/dev/null); THROTTLE_LINES_TREAT=${THROTTLE_LINES_TREAT:-0}
echo "  처치군: ${DUR_TREAT}ms 소요(타임아웃 ${THROTTLE_TIMEOUT}s 안에 $([ "$DONE_TREAT" -ge 1 ] && echo 완료 || echo 미완료)), 실제 쓰로틀 ${THROTTLE_LINES_TREAT}줄"
if [ "$DONE_TREAT" = 1 ]; then
  cutover_rename >/dev/null 2>&1
  PSQL_P -c "ALTER TABLE orders RESET (autovacuum_enabled); VACUUM ANALYZE orders;" >/dev/null 2>&1
fi
echo
if [ "${THROTTLE_LINES_TREAT:-0}" -gt "${THROTTLE_LINES_CTRL:-0}" ] && [ "$DONE_TREAT" -lt 1 ]; then
  echo "  → 대조군은 완료됐고(쓰로틀 ${THROTTLE_LINES_CTRL}줄), 처치군은 ${THROTTLE_TIMEOUT}초 안에"
  echo "    못 끝났다(쓰로틀 ${THROTTLE_LINES_TREAT}줄) — 같은 변경, 같은 부하인데 replica lag 만"
  echo "    다르다. gh-ost 와 달리 이 쓰로틀은 전부 손으로 짠 것이다 — PostgreSQL 은"
  echo "    이 안전장치를 공짜로 안 준다는 게 이 섹션의 결론이다."
else
  echo "  [주의] 기대한 대비가 안 나왔다 — 로그를 직접 보라: $PROBEDIR/throttle_ctrl.out, $PROBEDIR/throttle_treat.out"
fi
restore_to_int
echo
fi

LAB_DONE=1
echo "정리: 실험 테이블(orders)은 cust_id=INT 상태로 남겨 둔다."
echo "  토폴로지를 완전히 치우려면: ./teardown.sh"
