# scripts/mysql-osc 공용 — 중단(Ctrl-C) 시 Docker 리소스를 치우는 안전망.
#
# 왜 필요한가.
#   이 디렉터리의 실험은 컨테이너 3개(primary·replica1·replica2)와 백그라운드
#   쓰기 부하(sysbench 또는 커스텀 writer), 그리고 gh-ost 가 띄우는 소켓/스로틀
#   파일을 남긴다. 10M 행 백필은 수 분~수십 분 걸리므로 **실제로 중간에 취소된다.**
#   중단하면 컨테이너가 떠 있는 채로 남고, 다음 실행이 "이미 떠 있다"고 착각해
#   옛 데이터 위에서 측정하거나 포트가 충돌해 에러 없이 다른 걸 잰다.
#   _abort-trap.inc(§T-9)와 같은 사상 — **에러가 나지 않는 오염이 제일 나쁘다.**
#
# 이 파일을 쓰는 법.
#   1. docker_exists() 등 헬퍼 정의 뒤, 본문 로직 전에 source 한다.
#   2. 본문이 정상 종료하는 자리에서 LAB_DONE=1 을 둔다.
#   3. KEEP=1 이면 중단 시에도 컨테이너를 남긴다(다음 실행에서 재사용).

LAB_DONE=0
OSC_NET="${OSC_NET:-osc-net}"
OSC_CONTAINERS="osc-primary osc-replica1 osc-replica2"

osc_container_count() {
  docker ps -a --filter "name=osc-" --format '{{.Names}}' 2>/dev/null | grep -c '^osc-' || true
}

osc_cleanup() {
  # ⚠️ `docker rm -f`(볼륨 옵션 없이)는 컨테이너만 지우고 데이터 디렉터리의
  # 익명 볼륨은 그대로 남긴다 — 10M행 InnoDB 데이터(컨테이너당 수GB)가 매
  # FORCE=1 재실행마다 쌓여 디스크를 다 먹는다(실측: 이 디렉터리를 반복
  # 재구성하다 "No space left on device" 로 컨테이너 기동 자체가 실패했다 —
  # 익명 볼륨 46개, 29GB 가 고아로 남아 있었다). `-v` 로 컨테이너와 함께 지운다.
  for c in $OSC_CONTAINERS; do docker rm -fv "$c" >/dev/null 2>&1; done
  docker network rm "$OSC_NET" >/dev/null 2>&1
  # gh-ost 는 작업 중단 시 소켓·스로틀 플래그 파일을 치우지 않는다.
  rm -f /tmp/gh-ost.*.sock /tmp/gh-ost.throttle 2>/dev/null
}

on_abort() {
  [ "${LAB_DONE:-0}" = "1" ] && return 0
  local n; n=$(osc_container_count)
  [ "${n:-0}" = "0" ] && return 0
  echo
  if [ "${KEEP:-0}" = "1" ]; then
    echo "  [중단] KEEP=1 이므로 컨테이너 ${n}개를 남긴다 — 다음 실행이 재사용한다."
    echo "         완전히 치우려면: ./scripts/mysql-osc/teardown.sh"
    return 0
  fi
  echo "  [중단] Docker 리소스부터 치운다 — 남기면 다음 실행이 옛 데이터 위에서 재거나"
  echo "         포트/컨테이너 이름 충돌로 에러 없이 다른 걸 잰다."
  osc_cleanup
  echo "         남은 osc-* 컨테이너: $(osc_container_count)   (0 이어야 한다)"
}

trap on_abort EXIT INT TERM
