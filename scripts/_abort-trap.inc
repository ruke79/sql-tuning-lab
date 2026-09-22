# §T-9 공용 — 중단(Ctrl-C) 시 실습 트리거를 치우는 안전망.
#
# 왜 필요한가.
#   §T-9 스크립트들은 본문 끝에서 스스로 트리거를 치운다. 그런데 이 스크립트들은
#   SF=10 에서 수십 분씩 걸리고, 그래서 **실제로 중간에 취소된다**. 취소하면 본문
#   끝의 정리 코드까지 못 가므로 t_enq_* / t_sync_* 트리거가 lineitem 에 남는다.
#   남은 트리거는 에러를 내지 않는다. 그냥 이후 모든 쓰기에 조용히 붙어서 다음
#   실습의 측정값을 바꾼다. 다음 사람은 자기가 다른 것을 재고 있다는 걸 모른다.
#   에러가 나지 않는 오염이 제일 나쁘다.
#
# 이 파일을 쓰는 법 (이 순서를 지켜야 한다).
#   1. sql() 정의 **뒤에** source 한다. 트랩은 sql() 을 쓴다.
#   2. 본문의 정리 코드가 끝나는 자리에서 LAB_DONE=1 을 둔다.
#      그래야 정상 종료에서 트랩이 같은 일을 두 번 하지 않는다.

LAB_DONE=0

# 두 계열을 모두 지운다 — 어느 스크립트를 중단했든 남아 있을 수 있는 것 전부.
# lineitem 쪽은 스크립트마다 이름이 t_sync_li / t_sync_line 로 갈려 있어 둘 다 건다.
drop_lab_triggers() {
  sql "DROP TRIGGER IF EXISTS t_enq_cust  ON customer;
       DROP TRIGGER IF EXISTS t_enq_ord   ON orders;
       DROP TRIGGER IF EXISTS t_enq_line  ON lineitem;
       DROP TRIGGER IF EXISTS t_sync_cust ON customer;
       DROP TRIGGER IF EXISTS t_sync_ord  ON orders;
       DROP TRIGGER IF EXISTS t_sync_li   ON lineitem;
       DROP TRIGGER IF EXISTS t_sync_line ON lineitem;" >/dev/null 2>&1
}

lab_trigger_count() {
  # LIKE 의 _ 는 한 글자 와일드카드다. 이름을 그대로 맞추려면 이스케이프해야 한다.
  sql "SELECT count(*) FROM pg_trigger
        WHERE tgname LIKE 't\_enq\_%' OR tgname LIKE 't\_sync\_%'" 2>/dev/null
}

on_abort() {
  [ "${LAB_DONE:-0}" = "1" ] && return 0      # 정상 종료 — 본문이 이미 치웠다
  # 트리거를 달기 **전에** 끝난 경우(선행 조건 미충족 등)에는 아무 말도 하지 않는다.
  # 여기서 "[중단] 트리거부터 치운다"를 찍으면 진짜 중단 사유를 가린다 —
  # 원인을 흐리는 메시지가 이 실습에서 반복된 실패였다.
  local n; n=$(lab_trigger_count)
  [ "${n:-0}" = "0" ] && return 0
  echo
  if [ "${KEEP:-0}" = "1" ]; then
    echo "  [중단] KEEP=1 이므로 트리거를 남긴다. 다음 실습 전에 직접 지워라."
    return 0
  fi
  echo "  [중단] 트리거부터 치운다 — 남기면 lineitem 의 모든 쓰기에 붙어 다음 실습을 조용히 오염시킨다."
  drop_lab_triggers
  echo "         남은 실습 트리거 $(lab_trigger_count)   (0 이어야 한다)"
  echo "  ※ 파생 테이블과 실험이 넣은 행은 그대로 남는다. 원복까지 하려면"
  echo "     ./scripts/restore-lab.sh --check 로 잔여물을 확인해라."
}

trap on_abort EXIT
