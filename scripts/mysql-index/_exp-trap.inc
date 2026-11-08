# scripts/mysql-index 공용 — 실험 중단 시 로더/인덱스 잔여물을 치우는 안전망.
EXP_PIDS=""
exp_kill_bg() {
  [ -z "${EXP_PIDS:-}" ] && return 0
  for pid in $EXP_PIDS; do kill -- "-$pid" 2>/dev/null; done
  wait $EXP_PIDS 2>/dev/null
  EXP_PIDS=""
}

exp_cleanup() {
  exp_kill_bg
  P "DROP INDEX idx_amount ON idxtest.orders;" >/dev/null 2>&1
}

ON_ABORT_RUNNING=0
on_abort() {
  [ "$ON_ABORT_RUNNING" = "1" ] && return 0
  ON_ABORT_RUNNING=1
  exp_cleanup
}
trap on_abort EXIT INT TERM
