# scripts/pg-osc/t-pg-ddl.sh 전용 — 실험 중단 시 **컨테이너는 그대로 두고**
# 그 실행이 남긴 것만 치운다.
#
# _docker-trap.inc 와 역할이 다르다. 그건 토폴로지(컨테이너 3개) 자체를 치우는
# 용도고, 이건 "토폴로지는 떠 있는 채로 반복 실행하는" 실험 스크립트용이다.
# 매번 컨테이너를 내렸다 올리면 10M행 재적재에 시간을 또 쓴다 — 그러지 않는다.
#
# 중단 시 남는 것:
#   - 배경 부하 루프(백그라운드 bash 프로세스) — 안 죽이면 다음 실행과 경쟁하며
#     계속 쓴다. 다음 측정이 "배경 부하가 두 배"인 걸 아무도 모른다.
#   - 수동 expand-contract 가 남긴 섀도 컬럼(cust_id_new)과 동기화 트리거 —
#     안 지우면 다음 실행이 "컬럼이 이미 있다"며 멈추거나, 트리거가 계속 살아서
#     cust_id 를 바꾸는 측정(②)에 몰래 간섭한다.

LAB_DONE=0
EXP_PIDS=""

exp_kill_bg() {
  [ -z "$EXP_PIDS" ] && return 0
  # start_load() 는 로더마다 setsid 로 별도 프로세스 그룹을 만든다(§9 의
  # MySQL 판과 같은 설계, 같은 이유) — `kill -- -$pid` 로 그 그룹 전체(생성기+
  # psql+리더)를 죽인다.
  for pid in $EXP_PIDS; do kill -- "-$pid" 2>/dev/null; done
  wait $EXP_PIDS 2>/dev/null
  EXP_PIDS=""
}

exp_cleanup() {
  exp_kill_bg
  PSQL_P -c "DROP TRIGGER IF EXISTS cust_id_sync ON orders;" >/dev/null 2>&1
  PSQL_P -c "DROP FUNCTION IF EXISTS cust_id_sync_fn();" >/dev/null 2>&1
  PSQL_P -c "ALTER TABLE orders DROP COLUMN IF EXISTS cust_id_new, DROP COLUMN IF EXISTS cust_id_old;" >/dev/null 2>&1
}

ON_ABORT_RUNNING=0
on_abort() {
  [ "${LAB_DONE:-0}" = "1" ] && return 0
  [ "${ON_ABORT_RUNNING:-0}" = "1" ] && return 0
  ON_ABORT_RUNNING=1
  echo
  echo "  [중단] 배경 부하를 끄고 섀도 컬럼/트리거 잔여물을 치운다."
  echo "         (컨테이너는 그대로 둔다 — 지우려면 ./teardown.sh)"
  exp_cleanup
  left=$(PSQL_P -c "SELECT count(*) FROM information_schema.columns WHERE table_name='orders' AND column_name IN ('cust_id_new','cust_id_old');" 2>/dev/null)
  echo "         남은 섀도 컬럼: ${left:-?}   (0 이어야 한다)"
}

trap on_abort EXIT INT TERM
