# shellcheck shell=bash
# §T-9 계열 공용 규모 가드. 단독 실행용이 아니라 source 해서 쓴다.
#
# **왜 필요한가.** §T-9 의 스크립트들은 lineitem 전체를 조인해 파생 테이블
# (lineitem_denorm)을 만들고, 구성을 바꿀 때마다 **그걸 다시 만든다.**
# t9-change-queue 는 한 번 도는 동안 17회 다시 만든다.
#
#   SF=0.5 (lineitem 300만) : refill 1회 6.5초 (실측) → 17회 약 110초
#   SF=10  (lineitem 6,000만): 같은 일이 20배 → **선형이어도 37분, 실제로는 2시간대**
#
# 사용자가 SF=10 에서 2시간을 기다리다 "멈춘 건가" 물었다. 멈춘 게 아니라 갈고 있었다.
#
# **그리고 그 시간을 들여 얻는 것이 없다.** §T-9 가 재는 것은
# 쓰기 지연 · 피해 반경 · 정합성 지연의 트레이드오프이고, 이것들은 오늘 SF=0.5 와
# SF=10 양쪽에서 같은 방향으로 재현됐다(§T-9 격리수준 절의 재현 표 참고).
# 규모를 키워서 새로 배우는 것이 없다 — 그래서 막지 않고 **말해 준다.**

# scale_guard <lineitem행수> <refill횟수> [스크립트경로]
scale_guard() {
  local n="${1:-0}" refills="${2:-1}" self="${3:-$0}"
  local base=3000491 secs est_s
  [ "$n" -le $(( base * 2 )) ] && return 0          # SF=1 수준까지는 그냥 돈다
  [ "${FORCE:-0}" = "1" ] && {
    echo "  ※ FORCE=1 — 규모 가드를 건너뛴다. lineitem ${n} 행이면 오래 걸린다."
    echo; return 0; }

  # 파생 테이블 재생성 1회 6.5초(SF=0.5 실측)를 행수에 비례시킨 어림수.
  # **선형 가정이고, 데이터가 RAM 을 넘으면 그보다 나빠진다** — 그래서 '이상'이라고 쓴다.
  est_s=$(( n * 65 / base / 10 * refills ))
  echo "  [중단] lineitem 이 ${n} 행이다 (SF=0.5 기준의 $(( n / base ))배)."
  echo "         이 스크립트는 파생 테이블을 **${refills}회** 다시 만든다."
  echo "         SF=0.5 에서 1회 6.5초였으므로 여기서는 **약 $(( est_s / 60 ))분 이상** 걸린다."
  echo "         (선형 가정이다. 데이터가 RAM 을 넘으면 그보다 나빠진다.)"
  echo
  echo "  **§T-9 는 SF=0.5 로 도는 것을 권한다.** 이 절이 재는 것은 쓰기 지연·피해 반경·"
  echo "  정합성 지연의 트레이드오프이고, 그 결론은 SF=0.5 와 SF=10 에서 같았다"
  echo "  (문서 §T-9 의 재현 표). **규모를 키워서 새로 배우는 것이 없다.**"
  echo
  echo "  둘 중 하나:"
  echo "    ./scripts/restore-lab.sh --force-tpch     # SF=0.5 로 되돌린다(데이터 파일이 SF=10 이면"
  echo "                                              #  SF=0.5 ./scripts/restore-lab.sh --force-tpch)"
  echo "    FORCE=1 $self                             # 그대로 — 위 시간을 감수한다"
  exit 1
}
