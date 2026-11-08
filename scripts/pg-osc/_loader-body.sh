#!/usr/bin/env bash
# start_load() 가 setsid 로 띄우는 로더 1개의 본체. 환경변수로 받는다:
#   LOADER_ROWS, LOADER_HOST, LOADER_PORT, LOADER_PW, LOADER_IDX, LOADER_LOG
#
# 매 UPDATE 마다 그 결과를 실제로 읽어서 확인한 뒤에야 다음 UPDATE 를
# 보낸다(bash coproc) — 한 번에 하나만 "비행 중"이게 강제해야 psql/mysql
# 클라이언트가 여러 statement 를 묶어 배치로 보내는 걸 막을 수 있다.
# ⚠️ ★치명적 버그, 실측으로 발견★ — 원래의 "생성기 | psql | while read"
# 구조는 **클라이언트가 statement 마다 결과를 flush 하지 않을 수 있다는
# 것**을 놓쳤다(mysql 클라이언트는 아예 flush 를 안 한다, psql 은 조건에
# 따라 다르다 — 둘 다 입력이 출력 처리보다 빠르면 여러 statement 를 한
# 번에 보내고 그 결과도 한꺼번에 뱉는다). 그 사이 실제로는 수백 ms 가
# 막혀 있어도 로그엔 "거의 동시에 여러 줄"로 찍혀서 공백이 안 보인다.
# max_gap_ms() 로 뽑는 "cutover 블록(ms)"/"쓰기 로그 최대 공백"이 전부
# 이 버그에 노출돼 있었다.
set -uo pipefail
marker="ok_${LOADER_IDX}_$$"
coproc LC { stdbuf -oL -eL env PGPASSWORD="$LOADER_PW" psql -h "$LOADER_HOST" -p "$LOADER_PORT" -U postgres -d pgosctest -v ON_ERROR_STOP=0 -Atq; }
IN=${LC[1]}; OUT=${LC[0]}
while true; do
  id=$(( (RANDOM * RANDOM) % LOADER_ROWS + 1 ))
  printf "UPDATE orders SET amount=amount+1 WHERE id=%d; SELECT '%s';\n" "$id" "$marker" >&"$IN"
  while IFS= read -r line <&"$OUT"; do
    [ "$line" = "$marker" ] && break
  done
  date +%s%3N >> "$LOADER_LOG"
done
