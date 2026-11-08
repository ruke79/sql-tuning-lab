# scripts/mysql-index 공용 — 중단(Ctrl-C) 시 Docker 리소스를 치우는 안전망.
# mysql-osc/_docker-trap.inc 와 같은 사상(§9 참조) — 에러 없이 남는 오염이
# 제일 나쁘다. 컨테이너 1개뿐이라 훨씬 단순하다.
LAB_DONE=0
IDX_CONTAINERS="idx-mysql"

idx_container_count() {
  docker ps -a --filter "name=idx-mysql" --format '{{.Names}}' 2>/dev/null | grep -c '^idx-mysql' || true
}

idx_cleanup() {
  # `-v` 로 익명 볼륨까지 같이 지운다 — mysql-osc 에서 반복 재구성 중 29GB 를
  # 고아 볼륨으로 날린 전례가 있다(§9 참조).
  for c in $IDX_CONTAINERS; do docker rm -fv "$c" >/dev/null 2>&1; done
}

on_abort() {
  [ "${LAB_DONE:-0}" = "1" ] && return 0
  local n; n=$(idx_container_count)
  [ "${n:-0}" = "0" ] && return 0
  echo
  if [ "${KEEP:-0}" = "1" ]; then
    echo "  [중단] KEEP=1 이므로 컨테이너를 남긴다 — 다음 실행이 재사용한다."
    return 0
  fi
  echo "  [중단] Docker 리소스부터 치운다."
  idx_cleanup
}

trap on_abort EXIT INT TERM
