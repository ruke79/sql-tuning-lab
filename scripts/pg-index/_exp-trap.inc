# scripts/pg-index 공용 — 실험 중단 시 로더/인덱스 잔여물을 치우는 안전망.
EXP_PIDS=""
exp_kill_bg() {
  [ -z "${EXP_PIDS:-}" ] && return 0
  for pid in $EXP_PIDS; do kill -- "-$pid" 2>/dev/null; done
  wait $EXP_PIDS 2>/dev/null
  EXP_PIDS=""
}

exp_cleanup() {
  exp_kill_bg
  # ③ 에서 CONCURRENTLY 빌드를 중간에 죽이면 INVALID 인덱스가 남는다 — 그건
  # 반드시 DROP INDEX CONCURRENTLY 로만 지울 수 있다(평범한 DROP INDEX 도
  # 되긴 하지만 그러면 다시 ACCESS EXCLUSIVE 를 잡는다. 여기선 구애받지 않고
  # 그냥 지운다 — 실험 사이 정리일 뿐이다).
  P "DROP INDEX IF EXISTS idx_amount;" >/dev/null 2>&1
}

ON_ABORT_RUNNING=0
on_abort() {
  [ "$ON_ABORT_RUNNING" = "1" ] && return 0
  ON_ABORT_RUNNING=1
  exp_cleanup
}
trap on_abort EXIT INT TERM
