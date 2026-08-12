#!/usr/bin/env bash
# §T-3 실습: 같은 쿼리를 조인 방식만 바꿔가며 강제 실행하고 비교한다.
#
# Dan Tow 2·6·9장: NL 은 소량+인덱스에 로바스트, Hash 는 작은 쪽이 메모리에 들어갈 때 최고,
# 필터 없는 대량 조인은 Hash/Merge 가 유리.
# 그 주장을 내 데이터에서 직접 확인하는 것이 목적이다.
#
# 사용법:
#   ./join-method-compare.sh q03            # 좁은 필터 3-way 조인
#   ./join-method-compare.sh q05            # 6-way 조인
#   ./join-method-compare.sh q09            # 필터 약한 대량 조인 (NL 이 참혹해지는 사례)
#   ./join-method-compare.sh q03 5          # 반복 5회 (기본 4)
#   TIMEOUT=5min ./join-method-compare.sh q03   # 개별 실행 제한 시간 (기본 60s)
#
# 조인 방식을 강제하면 옵티마이저가 절대 고르지 않았을 계획이 나오므로
# 수십 분~무한정 걸릴 수 있다. statement_timeout 으로 잘라내고 '중단'으로 표시한다.
# 중단 자체가 결과다 — "이 방식은 이 데이터에서 쓸 수 없다"는 뜻이기 때문이다.
#
# 선행 조건: schema → load → index 완료
set -uo pipefail

QNAME="${1:-q03}"
REPEAT="${2:-4}"
TIMEOUT="${TIMEOUT:-60s}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

# 쿼리 파일 위치 (프로젝트 루트 기준 / 스크립트 위치 기준 모두 시도)
HERE="$(cd "$(dirname "$0")" && pwd)"
for CAND in "$HERE/../../tpch/src/main/resources/queries/$QNAME.sql" \
            "./tpch/src/main/resources/queries/$QNAME.sql"; do
  [ -f "$CAND" ] && QFILE="$CAND" && break
done
if [ -z "${QFILE:-}" ]; then
  echo "쿼리 파일을 찾을 수 없습니다: $QNAME.sql"
  echo "사용 가능: $(ls "$HERE/../../tpch/src/main/resources/queries/" 2>/dev/null | tr '\n' ' ')"
  exit 1
fi
QUERY=$(grep -v '^\s*--' "$QFILE" | sed 's/;\s*$//')

if command -v psql >/dev/null 2>&1; then
  run_file() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -q -f "$1"; }
  run_sql()  { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpch -tAc "$1"; }
else
  run_file() { docker exec -i -e PGPASSWORD=tuner "$CONTAINER" psql -U tuner -d tpch -q < "$1"; }
  run_sql()  { docker exec -e PGPASSWORD=tuner "$CONTAINER" psql -U tuner -d tpch -tAc "$1"; }
fi

echo "쿼리: $QNAME   (반복 ${REPEAT}회, 최소값 기준, 개별 제한시간 ${TIMEOUT})"

# 사전 점검: 인덱스가 없으면 NL 강제가 반드시 폭주한다. 미리 알려준다.
NIDX=$(run_sql "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND tablename IN ('lineitem','orders','customer')" 2>/dev/null | tr -d ' ')
if [ "${NIDX:-0}" -eq 0 ]; then
  echo
  echo "  [경고] lineitem/orders/customer 에 인덱스가 하나도 없습니다."
  echo "         NL 강제는 반복 풀스캔이 되어 반드시 제한시간에 걸립니다."
  echo "         먼저 실행하세요:  ./gradlew :tpch:bootRun --args=\"index --db=postgres\""
fi
echo
printf "%-26s %-42s %12s %10s\n" "강제 조건" "실제 사용된 조인" "buffers" "시간(ms)"
printf "%s\n" "------------------------------------------------------------------------------------------------"

compare() {  # $1 = 라벨, $2 = SET 구문
  local tmp=/tmp/_t3.sql out MS PLAN JOINS BUF

  # 계획을 먼저 본다 (EXPLAIN 만 하면 실행하지 않으므로 안전하고 즉시 끝난다)
  local PLANONLY
  PLANONLY=$(run_sql "$2 EXPLAIN $QUERY" 2>&1 || true)
  JOINS=$(echo "$PLANONLY" | grep -oE '(Nested Loop|Hash Join|Merge Join)' \
          | sort | uniq -c | awk '{printf "%s x%s  ", $2" "$3, $1}')

  # 실측: statement_timeout 으로 폭주하는 계획을 잘라낸다.
  # ON_ERROR_STOP 으로 첫 타임아웃에서 즉시 중단 → 반복 횟수만큼 기다리지 않는다.
  { echo "\set ON_ERROR_STOP on";
    echo "\timing on";
    echo "SET statement_timeout = '${TIMEOUT}';";
    echo "$2";
    for _ in $(seq "$REPEAT"); do echo "$QUERY;"; done; } > "$tmp"
  out=$(run_file "$tmp" 2>&1 || true)

  if echo "$out" | grep -q "statement timeout"; then
    printf "%-26s %-42s %12s %10s\n" "$1" "${JOINS:-?}" "-" ">${TIMEOUT} 중단"
    return
  fi

  MS=$(echo "$out" | grep -oE '^Time: [0-9.]+' | awk '{print $2}' \
        | tail -n $((REPEAT - 1)) | sort -n | head -1)

  PLAN=$(run_sql "$2 SET statement_timeout='${TIMEOUT}'; EXPLAIN (ANALYZE, BUFFERS) $QUERY" 2>&1 || true)
  BUF=$(echo "$PLAN" | grep -m1 -oE 'shared hit=[0-9]+( read=[0-9]+)?' | sed 's/shared //')
  printf "%-26s %-42s %12s %10s\n" "$1" "${JOINS:-?}" "${BUF:-?}" "${MS:-?}"
}

compare "옵티마이저 자율선택"  ""
compare "Hash 금지"           "SET enable_hashjoin=off;"
compare "Hash+Merge 금지(NL만)" "SET enable_hashjoin=off; SET enable_mergejoin=off;"
compare "NL 금지"             "SET enable_nestloop=off;"

echo
echo "읽는 법:"
echo "  · '옵티마이저 자율선택' 이 다른 행보다 느리면 비용 모델이 어긋난 것이다."
echo "  · '>${TIMEOUT} 중단' 은 실패가 아니라 결과다. 그 조인 방식이 이 데이터에서"
echo "    쓸 수 없다는 뜻이며, 보통 안쪽 테이블에 쓸 만한 인덱스가 없을 때 발생한다."
echo "    (NL 이 '로바스트'하려면 안쪽 조인키 인덱스가 전제되어야 한다 — 책 6·9장)"
echo "  · buffers(LIO)와 시간이 같은 방향으로 움직이는지도 함께 본다."
echo "    LIO 가 늘었는데 더 빠르다면, 접근 횟수보다 접근 단가가 중요한 상황이다."
echo "  · 자율선택이 Hash 인데 NL 이 중단된다면, lineitem 의 l_orderkey 클러스터링이"
echo "    깨져 있을 수 있다(§T-2 의 CLUSTER 실습 이후 상태). 아래로 확인:"
echo "      SELECT attname, correlation FROM pg_stats"
echo "      WHERE tablename='lineitem' AND attname IN ('l_orderkey','l_shipdate');"
