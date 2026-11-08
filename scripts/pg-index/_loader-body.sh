#!/usr/bin/env bash
# start_load() 가 setsid 로 띄우는 로더 1개의 본체. pg-osc/_loader-body.sh 와
# 완전히 같은 패턴(그 파일에서 실측으로 찾은 "배치 숨김 버그" 수정 포함) —
# coproc 로 연결 하나를 열어 두고, 매 statement 마다 결과를 실제로 읽어
# 확인한 뒤에야 다음 걸 보낸다.
#
# 환경변수: LOADER_ROWS, LOADER_HOST, LOADER_PORT, LOADER_PW, LOADER_IDX, LOADER_LOG
set -uo pipefail
marker="ok_${LOADER_IDX}_$$"
coproc LC { stdbuf -oL -eL env PGPASSWORD="$LOADER_PW" psql -h "$LOADER_HOST" -p "$LOADER_PORT" -U postgres -d idxtest -v ON_ERROR_STOP=0 -Atq; }
IN=${LC[1]}; OUT=${LC[0]}
while true; do
  id=$(( (RANDOM * RANDOM) % LOADER_ROWS + 1 ))
  printf "UPDATE orders SET cust_id=cust_id+1 WHERE id=%d; SELECT '%s';\n" "$id" "$marker" >&"$IN"
  while IFS= read -r line <&"$OUT"; do
    [ "$line" = "$marker" ] && break
  done
  date +%s%3N >> "$LOADER_LOG"
done
