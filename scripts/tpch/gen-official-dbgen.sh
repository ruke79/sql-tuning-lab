#!/usr/bin/env bash
# 공식 TPC-H dbgen 으로 데이터 생성 (정확한 분포가 필요할 때)
#
# 사용법: ./gen-official-dbgen.sh <SF> [출력디렉토리] [병렬도]
#   ./gen-official-dbgen.sh 1                  # lineitem 약 600만 건 (~1GB)
#   ./gen-official-dbgen.sh 17 ./data/tpch 4   # lineitem 약 1억 건 (~17GB)
#   ./gen-official-dbgen.sh 100 ./data/tpch 8  # lineitem 약 6억 건 (~100GB) ← 표 기준
#
# GCC 10+ 는 기본값이 -fno-common 이라 옛 벤치마크 킷이 링크 단계에서
# "multiple definition of ..." 로 실패한다. 아래에서 -fcommon 으로 해결한다.
# WSL 사용 시 /mnt/c, /mnt/d 등 Windows 드라이브는 I/O 가 매우 느리니
# 리눅스 네이티브 경로(~/data 등)에 생성하는 것을 권장한다.
set -euo pipefail

SF="${1:-1}"
OUT="${2:-./data/tpch}"
PARALLEL="${3:-1}"

mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

echo "SF=$SF  OUT=$OUT_ABS  PARALLEL=$PARALLEL"
case "$OUT_ABS" in
  /mnt/[a-z]/*) echo "[경고] Windows 드라이브 경로입니다. WSL 네이티브 경로가 훨씬 빠릅니다." ;;
esac
echo "[정보] lineitem 예상 행수: 약 $((SF * 6000000)) 건"
echo

docker run --rm -v "$OUT_ABS":/out gcc:13 bash -c "
  set -e
  apt-get update -qq && apt-get install -y -qq git > /dev/null

  # GCC 10+ 대응: -fcommon 을 주입하는 gcc 래퍼를 PATH 우선순위에 배치
  REAL_GCC=\$(command -v gcc)
  for w in gcc cc; do
    printf '#!/bin/sh\nexec %s -fcommon \"\$@\"\n' \"\$REAL_GCC\" > /usr/local/sbin/\$w
    chmod +x /usr/local/sbin/\$w
  done
  hash -r

  git clone --depth 1 https://github.com/gregrahn/tpch-kit.git /tpch-kit
  cd /tpch-kit/dbgen
  make MACHINE=LINUX DATABASE=POSTGRESQL > /tmp/build.log 2>&1 \
    || { tail -30 /tmp/build.log; exit 1; }
  test -x ./dbgen || { echo '[실패] dbgen 이 생성되지 않았습니다'; tail -30 /tmp/build.log; exit 1; }
  echo '[빌드] dbgen OK'

  # dbgen 은 dists.dss 를 현재 디렉토리에서 찾으므로 DSS_CONFIG 로 위치를 알려준다
  export DSS_CONFIG=/tpch-kit/dbgen
  export DSS_PATH=/out

  if [ '$PARALLEL' -gt 1 ]; then
    # 병렬 생성: lineitem.tbl.1, lineitem.tbl.2 ... 로 분할된다 (로더가 자동 인식)
    for c in \$(seq 1 $PARALLEL); do
      ./dbgen -s $SF -C $PARALLEL -S \$c -f &
    done
    wait
  else
    ./dbgen -s $SF -f
  fi

  # DSS_PATH 를 못 쓰는 버전 대비: 현재 디렉토리에 남은 결과물을 옮긴다
  mv -f *.tbl* /out/ 2>/dev/null || true
  chmod -R a+rw /out
"

echo
echo '생성 완료:'
ls -lh "$OUT_ABS" | head -20
echo
echo "적재 (분할 파일 lineitem.tbl.1 등도 자동 인식):"
echo "  ./gradlew :tpch:bootRun --args=\"schema --db=postgres\""
echo "  ./gradlew :tpch:bootRun --args=\"load   --db=postgres --dir=$OUT\""
echo "  ./gradlew :tpch:bootRun --args=\"index  --db=postgres\""
echo
echo "대용량(SF>=10)은 COPY 가 5~10배 빠릅니다:"
echo "  scripts/tpch/load-postgres-copy.sh $OUT"
