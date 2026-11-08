# scripts/pg-index 공용 — 중단(Ctrl-C) 시 Docker 리소스를 치우는 안전망.
LAB_DONE=0
IDX_CONTAINERS="idx-pg"

idx_container_count() {
  docker ps -a --filter "name=idx-pg" --format '{{.Names}}' 2>/dev/null | grep -c '^idx-pg' || true
}

idx_cleanup() {
  for c in $IDX_CONTAINERS; do docker rm -fv "$c" >/dev/null 2>&1; done
}

on_abort() {
  [ "${LAB_DONE:-0}" = "1" ] && return 0
  local n; n=$(idx_container_count)
  [ "${n:-0}" = "0" ] && return 0
  echo
  if [ "${KEEP:-0}" = "1" ]; then
    echo "  [중단] KEEP=1 이므로 컨테이너를 남긴다."
    return 0
  fi
  echo "  [중단] Docker 리소스부터 치운다."
  idx_cleanup
}

trap on_abort EXIT INT TERM
