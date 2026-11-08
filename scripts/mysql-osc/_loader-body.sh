#!/usr/bin/env bash
# start_load() 가 setsid 로 띄우는 로더 1개의 본체. 환경변수로 받는다:
#   LOADER_ROWS, LOADER_HOST, LOADER_PORT, LOADER_PW, LOADER_IDX, LOADER_LOG
#
# 매 UPDATE 마다 그 결과를 실제로 읽어서 확인한 뒤에야 다음 UPDATE 를
# 보낸다(bash coproc) — 한 번에 하나만 "비행 중"이게 강제해야 mysql
# 클라이언트가 여러 statement 를 묶어 배치로 보내는 걸 막을 수 있다
# (t-online-ddl.sh 의 start_load() 주석 참조 — 이 배치 현상이 cutover
# 블로킹 측정을 완전히 숨겼던 실제 원인이다).
set -uo pipefail
marker="ok_${LOADER_IDX}_$$"
coproc LC { stdbuf -oL -eL mysql -h "$LOADER_HOST" -P "$LOADER_PORT" -uroot -p"$LOADER_PW" -N; }
IN=${LC[1]}; OUT=${LC[0]}
while true; do
  id=$(( (RANDOM * RANDOM) % LOADER_ROWS + 1 ))
  printf "UPDATE osctest.orders SET amount=amount+1 WHERE id=%d; SELECT '%s';\n" "$id" "$marker" >&"$IN"
  while IFS= read -r line <&"$OUT"; do
    [ "$line" = "$marker" ] && break
  done
  date +%s%3N >> "$LOADER_LOG"
done
