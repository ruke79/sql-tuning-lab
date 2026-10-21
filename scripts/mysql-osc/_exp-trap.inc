# scripts/mysql-osc/t-online-ddl.sh 전용 — 실험 중단 시 **컨테이너는 그대로 두고**
# 그 실행이 남긴 것만 치운다.
#
# _docker-trap.inc 와 역할이 다르다. 그건 토폴로지(컨테이너 3개) 자체를 치우는
# 용도고, 이건 "토폴로지는 떠 있는 채로 반복 실행하는" 실험 스크립트용이다.
# 매번 컨테이너를 내렸다 올리면 10M행 재적재에 시간을 또 쓴다 — 그러지 않는다.
#
# 중단 시 남는 것:
#   - 배경 부하/프로브 루프(백그라운드 bash 프로세스) — 안 죽이면 다음 실행과
#     경쟁하며 계속 쓴다. 다음 측정이 "배경 부하가 두 배"인 걸 아무도 모른다.
#   - gh-ost 의 고스트/구-테이블(_orders_gho, _orders_ghc, _orders_del) — 안 지우면
#     다음 gh-ost 실행이 "테이블이 이미 있다"며 멈추거나, 더 나쁘게 **에러 없이**
#     옛 고스트 테이블을 재사용한다.
#   - /tmp/gh-ost.throttle — 남아 있으면 다음 실행이 **영원히 쓰로틀된 채** 멈춘다
#     (이 파일의 존재 자체가 쓰로틀 신호라서, 중단해도 에러가 안 난다).

LAB_DONE=0
EXP_PIDS=""

exp_kill_bg() {
  [ -z "$EXP_PIDS" ] && return 0
  for pid in $EXP_PIDS; do kill "$pid" 2>/dev/null; done
  wait $EXP_PIDS 2>/dev/null
  EXP_PIDS=""
}

exp_cleanup() {
  exp_kill_bg
  P "DROP TABLE IF EXISTS osctest._orders_gho, osctest._orders_ghc, osctest._orders_del;" >/dev/null 2>&1
  rm -f /tmp/gh-ost.*.sock /tmp/gh-ost.throttle 2>/dev/null
}

on_abort() {
  [ "${LAB_DONE:-0}" = "1" ] && return 0
  echo
  echo "  [중단] 배경 부하/프로브를 끄고 gh-ost 잔여 테이블·스로틀 파일을 치운다."
  echo "         (컨테이너는 그대로 둔다 — 지우려면 ./teardown.sh)"
  exp_cleanup
  left=$(P "SELECT count(*) FROM information_schema.tables WHERE table_schema='osctest' AND table_name LIKE '\\_orders\\_%'" 2>/dev/null | tail -1)
  echo "         남은 고스트/구 테이블: ${left:-?}   (0 이어야 한다)"
}

trap on_abort EXIT INT TERM
