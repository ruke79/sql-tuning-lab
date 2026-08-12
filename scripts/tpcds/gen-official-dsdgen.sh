#!/usr/bin/env bash
# 공식 TPC-DS dsdgen 으로 데이터 생성
#
# 사용법: ./gen-official-dsdgen.sh <SCALE> [출력디렉토리] [병렬도]
#   ./gen-official-dsdgen.sh 1                    # store_sales 약 288만 건 (~1GB)
#   ./gen-official-dsdgen.sh 10  ./data/tpcds 4   # 약 2,880만 건 (~10GB)   ← 권장 시작점
#   ./gen-official-dsdgen.sh 100 ./data/tpcds 8   # 약 2.9억 건 (~40GB)     ← 표 기준 "1억 건 이상"
#
# 이 프로젝트 스키마는 store_sales 채널 9개 테이블만 사용하므로 해당 테이블만 생성한다.
# (전체 24개 테이블을 다 만들면 catalog_sales/web_sales 때문에 용량이 2배 이상 늘어난다)
#
# ── 중요 ──────────────────────────────────────────────────────────────
# * GCC 10+ 는 기본값이 -fno-common 이라 tpcds-kit 이 링크 단계에서
#   "multiple definition of 'nItemIndex'" 로 실패한다. 아래에서 -fcommon 으로 해결한다.
# * WSL 사용 시 /mnt/c, /mnt/d 같은 Windows 드라이브에 생성하면 I/O가 수 배 느리다.
#   리눅스 네이티브 경로(~/data 등)에 생성한 뒤 적재하는 것을 강력히 권장한다.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

SCALE="${1:-1}"
OUT="${2:-./data/tpcds}"
PARALLEL="${3:-1}"

mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

# 이 프로젝트가 적재하는 9개 테이블 (차원 → 팩트 순)
DIMENSIONS="date_dim item store customer_address customer_demographics household_demographics customer promotion"
FACT="store_sales"

echo "SCALE=$SCALE  OUT=$OUT_ABS  PARALLEL=$PARALLEL"
case "$OUT_ABS" in
  /mnt/[a-z]/*) echo "[경고] Windows 드라이브 경로입니다. WSL 네이티브 경로가 훨씬 빠릅니다." ;;
esac
echo "[정보] store_sales 예상 행수: 약 $((SCALE * 2880000)) 건"
echo

docker run --rm -v "$OUT_ABS":/out gcc:13 bash -c "
  set -e
  apt-get update -qq && apt-get install -y -qq flex bison git > /dev/null

  # GCC 10+ 대응: 실제 gcc 앞에 -fcommon 을 주입하는 래퍼를 PATH 우선순위에 배치.
  # (/usr/local/sbin 이 /usr/local/bin 보다 먼저 탐색된다)
  # makefile 을 건드리지 않으므로 킷의 빌드 로직에 영향이 없다.
  REAL_GCC=\$(command -v gcc)
  for w in gcc cc; do
    printf '#!/bin/sh\nexec %s -fcommon \"\$@\"\n' \"\$REAL_GCC\" > /usr/local/sbin/\$w
    chmod +x /usr/local/sbin/\$w
  done
  hash -r
  echo \"[빌드] gcc wrapper: \$(command -v gcc) -> \$REAL_GCC -fcommon\"

  git clone --depth 1 https://github.com/gregrahn/tpcds-kit.git /tpcds-kit
  cd /tpcds-kit/tools
  make OS=LINUX > /tmp/build.log 2>&1 || { tail -30 /tmp/build.log; exit 1; }
  test -x ./dsdgen || { echo '[실패] dsdgen 이 생성되지 않았습니다'; tail -30 /tmp/build.log; exit 1; }
  echo '[빌드] dsdgen OK'

  # 차원 테이블: 단일 프로세스로 충분히 빠르다
  for t in $DIMENSIONS; do
    echo \"[생성] \$t\"
    ./dsdgen -scale $SCALE -dir /out -table \$t -force -quiet
  done

  # 팩트 테이블: 병렬 생성 (결과는 store_sales_<child>_<parallel>.dat 로 분할됨)
  echo '[생성] $FACT (parallel=$PARALLEL)'
  if [ '$PARALLEL' -gt 1 ]; then
    for c in \$(seq 1 $PARALLEL); do
      ./dsdgen -scale $SCALE -dir /out -table $FACT -force -quiet \
               -parallel $PARALLEL -child \$c &
    done
    wait
  else
    ./dsdgen -scale $SCALE -dir /out -table $FACT -force -quiet
  fi

  chmod -R a+rw /out
"

echo
echo '생성 완료:'
ls -lh "$OUT_ABS" | head -20
echo
echo "적재 (분할 파일 store_sales_1_${PARALLEL}.dat 등도 자동 인식):"
echo "  ./gradlew :tpcds:bootRun --args=\"schema --db=postgres\""
echo "  ./gradlew :tpcds:bootRun --args=\"load   --db=postgres --dir=$OUT\""
echo "  ./gradlew :tpcds:bootRun --args=\"index  --db=postgres\""
echo
echo "대용량(SCALE>=10)은 JDBC 배치보다 COPY 가 5~10배 빠릅니다:"
echo "  scripts/tpcds/load-postgres-copy.sh $OUT"
