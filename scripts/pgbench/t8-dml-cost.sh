#!/usr/bin/env bash
# §T-8 후반: **인덱스는 공짜가 아니다** — 조회 이득과 맞바꾼 쓰기 비용을 잰다.
#
# §T-8 본편은 결합 인덱스가 조인 방식의 판정을 뒤집는 것(500,750 → 349,914 buffers)까지 갔다.
# 그 이득의 청구서가 이 실습이다. 매핑 문서 §T-8 후반에 절차만 적혀 있고 수치가 비어 있었다.
#
# 다만 "인덱스를 늘리면 TPS 가 떨어진다"는 결론은 절반만 맞다. 이 실습은 그보다 정확한 것을 잰다 —
# **어떤 인덱스가 떨어뜨리는가.**
#
#   PostgreSQL 의 HOT(Heap Only Tuple): UPDATE 가 **인덱스에 들어 있는 컬럼을 하나도 안 건드리고**
#   같은 페이지에 새 버전을 놓을 수 있으면, 인덱스를 갱신하지 않는다.
#   pgbench 의 tpcb-like 는 pgbench_accounts 의 abalance 만 UPDATE 한다. 그러므로:
#     · (filler) 인덱스   — 갱신 안 되는 컬럼. HOT 을 깨지 않는다.
#     · (abalance) 인덱스 — 갱신되는 컬럼. **HOT 이 깨진다.**
#   그리고 한 번 깨지면 **그 행의 모든 인덱스**가 새 엔트리를 받아야 한다.
#   → 인덱스 개수가 아니라 "갱신 컬럼을 담았는가"가 먼저다. 개수는 그다음 문제다.
#
# 재는 것: TPS / HOT 비율 / 트랜잭션당 WAL 바이트 / 인덱스 크기.
#   WAL 을 같이 재는 이유: TPS 하락은 결과고, HOT 이 깨져 **인덱스 갱신이 WAL 에 실리는 것**이
#   원인이다. 원인 지표가 같이 움직이는 걸 봐야 인과를 주장할 수 있다(§T-0).
#
# 사용법:
#   ./t8-dml-cost.sh              # 전부 (약 6분)
#   ROUNDS=3 ./t8-dml-cost.sh     # 라운드 수(기본 2). 라운드마다 조건을 **교차**한다
#   SECS=20   ./t8-dml-cost.sh    # 조건당 부하 시간(기본 12초)
#   CLIENTS=8 ./t8-dml-cost.sh
#   ONLY=2 ./t8-dml-cost.sh       # ②(fillfactor) 절만
#
#   ①은 '어떤 인덱스가 깨뜨리는가', ②는 'HOT 의 다른 전제(빈자리)',
#   ③은 '그 비용이 언제 TPS 로 나타나는가' 다. ③이 이 실습의 결론을 정한다.
#
# 선행 조건: pgbench 바이너리. pgbench_lab DB 가 없으면 만들고 -s 10 으로 적재한다.
set -uo pipefail

ROUNDS="${ROUNDS:-2}"
SECS="${SECS:-12}"
CLIENTS="${CLIENTS:-8}"
JOBS="${JOBS:-4}"
SCALE="${SCALE:-10}"
ONLY="${ONLY:-123}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
export PGPASSWORD="${PGPASSWORD:-tuner}"
PGUSER_="${PGUSER:-tuner}"
DB=pgbench_lab

want() { case "$ONLY" in *"$1"*) return 0;; *) return 1;; esac; }

command -v pgbench >/dev/null 2>&1 || { echo "pgbench 가 없습니다."; exit 1; }
q()  { psql -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -d "$DB" -X -q -tAc "$1" 2>&1; }
# 준비 단계용 — 실패를 삼키지 않는다. 조용히 안 돈 준비 단계는 측정을 통째로 무의미하게 만든다.
qx() { local o; o=$(q "$1"); case "$o" in *ERROR*) echo "  [중단] 준비 단계 실패: $1"; echo "         $o"; exit 1;; esac; }
qp() { psql -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -d postgres -X -q -tAc "$1" 2>&1; }

# 준비 — 없으면 만든다. 있으면 건드리지 않는다.
if [ "$(qp "SELECT count(*) FROM pg_database WHERE datname='$DB'")" != "1" ]; then
  echo "pgbench_lab 을 만든다 (-s $SCALE)"
  qp "CREATE DATABASE $DB OWNER $PGUSER_" >/dev/null
fi
NACC=$(q "SELECT count(*) FROM pgbench_accounts" 2>/dev/null)
case "$NACC" in ''|*[!0-9]*) NACC=0;; esac
if [ "$NACC" -lt 1000 ]; then
  echo "pgbench_accounts 를 적재한다 (-s $SCALE, 약 3초)"
  pgbench -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -i -s "$SCALE" -q "$DB" 2>&1 | tail -1
  NACC=$(q "SELECT count(*) FROM pgbench_accounts")
fi

# 실험용 인덱스만 지운다(기본키는 남긴다).
clean_idx() {
  for i in $(q "SELECT indexname FROM pg_indexes
                 WHERE tablename='pgbench_accounts' AND indexname LIKE 'x_%'"); do
    q "DROP INDEX IF EXISTS $i" >/dev/null
  done
}
FF_ORIG=$(q "SELECT coalesce((SELECT option_value FROM pg_options_to_table(reloptions)
                               WHERE option_name='fillfactor'), '100')
              FROM pg_class WHERE relname='pgbench_accounts'")

cleanup() {
  clean_idx
  q "ALTER TABLE pgbench_accounts SET (fillfactor=${FF_ORIG:-100})" >/dev/null
  q "TRUNCATE pgbench_history" >/dev/null
}
trap cleanup EXIT

idx_size() { q "SELECT pg_size_pretty(coalesce(sum(pg_relation_size(indexrelid)),0))
                 FROM pg_stat_user_indexes WHERE relname='pgbench_accounts'"; }

# 한 조건 1회 측정.
# 조건 사이에 VACUUM FULL 을 돌려 **앞 조건이 남긴 부풀음을 물려주지 않는다** —
# 안 그러면 뒤에 오는 조건이 불리해져서, 그 차이를 인덱스 탓으로 착각한다(§T-0 원칙 6).
measure() {
  # VACUUM 은 **혼자 보내야 한다.** 다른 문장과 한 -c 에 묶으면 psql 이 암묵적 트랜잭션으로
  # 감싸서 "VACUUM cannot run inside a transaction block" 으로 거부된다 —
  # 그런데 >/dev/null 로 삼키면 조용히 안 돌고, 앞 조건의 부풀음이 뒤 조건에 그대로 넘어간다.
  # (이 스크립트를 처음 돌렸을 때 실제로 그랬다. 그래서 qx 로 실패를 드러낸다.)
  qx "TRUNCATE pgbench_history"
  qx "VACUUM FULL pgbench_accounts"
  qx "ANALYZE pgbench_accounts"
  # **체크포인트를 고정한다.** 체크포인트 직후 각 페이지의 첫 변경은 전체 페이지 이미지(FPI)를
  # WAL 에 통째로 싣는다(8KB). 체크포인트가 측정 구간 안에 걸리느냐 마느냐로 UPDATE 당 WAL 이
  # 6배까지 흔들린다 — 처음 재 보고 ②가 3037B, 다시 재니 432B 가 나와서 알았다.
  # 여기서 한 번 돌려 모든 조건이 같은 지점에서 출발하게 하고, FPI 를 따로 보고한다.
  qx "CHECKPOINT"
  q "SELECT pg_stat_reset_single_table_counters('pgbench_accounts'::regclass)" >/dev/null
  q "SELECT pg_stat_reset_shared('wal')" >/dev/null
  local tps
  tps=$(pgbench -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -c "$CLIENTS" -j "$JOBS" -T "$SECS" "$DB" 2>&1 \
        | grep -oE "tps = [0-9.]+" | head -1 | grep -oE "[0-9.]+")
  # tps|HOT비율|UPDATE당 WAL 전체|그중 FPI 를 뺀 레코드 몫
  #
  # FPI(전체 페이지 이미지)를 왜 빼는가 — 체크포인트 직후 각 페이지의 첫 변경은 8KB 를 통째로
  # 싣는다. 위에서 CHECKPOINT 를 고정했으므로 그 몫이 모든 조건에 **똑같이** 크게 붙어
  # (여기서는 WAL 의 약 90%) 정작 보려는 인덱스 유지 비용을 덮어 버린다.
  # 빼고 남는 것이 "이 UPDATE 가 실제로 기록한 변경량"이다.
  q "SELECT round(${tps:-0}::numeric,0) || '|' ||
            coalesce(round(100.0*t.n_tup_hot_upd/NULLIF(t.n_tup_upd,0),1)::text,'?') || '|' ||
            coalesce(round(w.wal_bytes / NULLIF(t.n_tup_upd,0))::text,'?') || '|' ||
            coalesce(round((w.wal_bytes - w.wal_fpi::bigint*8192) / NULLIF(t.n_tup_upd,0))::text,'?')
       FROM pg_stat_user_tables t, pg_stat_wal w WHERE t.relname='pgbench_accounts'"
}

# 라벨 폭 맞추기 — 이 컨테이너는 로케일이 UTF-8 이 아니라 printf 가 바이트를 센다.
dispw() { local b k; b=$(printf %s "$1" | wc -c); k=$(printf %s "$1" | LC_ALL=C tr -dc '\200-\277' | wc -c)
          echo $(( b - k / 2 )); }
padr()  { local n; n=$(dispw "$1"); printf "%s" "$1"; while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; }
padl()  { local n; n=$(dispw "$1"); while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; printf "%s" "$1"; }

# 여러 라운드의 최대 TPS(=간섭이 가장 적었던 회)와, 그 회의 HOT/WAL 을 같이 남긴다.
# 평균이 아니라 최대를 쓰는 이유는 §T-0 과 같다 — 느린 쪽은 잡음이 섞인 쪽이다.
declare -A BEST_T BEST_H BEST_W BEST_F

echo "§T-8 후반 — 인덱스의 쓰기 비용 (HOT 이 깨지는 지점)"
echo "  pgbench_accounts ${NACC}행 / 클라이언트 ${CLIENTS} / 조건당 ${SECS}초 × ${ROUNDS}라운드 (교차)"
echo "  fillfactor=$FF_ORIG"
echo

# ══════════════════════════════════════════════════════════════════════
if want 1; then
# 조건 정의: 라벨|인덱스 DDL(여러 개면 ; 로)
CONDS=(
 "① 기준 (기본키만)|"
 "② + (filler) — 갱신 안 되는 컬럼|CREATE INDEX x_f ON pgbench_accounts(filler)"
 "③ + (abalance) — 갱신되는 컬럼|CREATE INDEX x_a ON pgbench_accounts(abalance)"
 "④ 문서의 3개 전부|CREATE INDEX x_a ON pgbench_accounts(abalance); CREATE INDEX x_ba ON pgbench_accounts(bid,abalance); CREATE INDEX x_f ON pgbench_accounts(filler)"
)
echo "── ① 어떤 인덱스가 TPS 를 떨어뜨리는가 ──"
echo
for r in $(seq 1 "$ROUNDS"); do
  for c in "${CONDS[@]}"; do
    L="${c%%|*}"; DDL="${c#*|}"
    clean_idx
    [ -n "$DDL" ] && q "$DDL" >/dev/null
    R=$(measure); IFS='|' read -r T H W F <<<"$R"
    prev="${BEST_T[$L]:-0}"
    if awk -v a="$T" -v b="$prev" 'BEGIN{exit !(a>b)}'; then
      BEST_T[$L]="$T"; BEST_H[$L]="$H"; BEST_W[$L]="$W"; BEST_F[$L]="$F"
    fi
    printf "."
  done
done
echo; echo
printf "  %s%10s %10s %14s %14s %10s\n" "$(padr 조건 38)" "$(padl TPS 10)" "$(padl HOT비율 10)" "$(padl "UPDATE당 WAL" 14)" "$(padl "FPI 제외" 14)" "$(padl 인덱스 10)"
printf "  %s\n" "--------------------------------------------------------------------------------------------------"
BASE=""
for c in "${CONDS[@]}"; do
  L="${c%%|*}"; DDL="${c#*|}"
  clean_idx; [ -n "$DDL" ] && q "$DDL" >/dev/null
  SZ=$(idx_size)
  [ -z "$BASE" ] && BASE="${BEST_T[$L]}"
  REL=$(awk -v a="${BEST_T[$L]:-0}" -v b="$BASE" 'BEGIN{ if(b>0) printf "%.2fx", a/b }')
  printf "  %s%10s %9s%% %12s B %12s B %10s  %s\n" "$(padr "$L" 38)" \
     "${BEST_T[$L]:-?}" "${BEST_H[$L]:-?}" "${BEST_W[$L]:-?}" "${BEST_F[$L]:-?}" "$SZ" "$REL"
done
clean_idx
echo
echo "  읽는 법 —"
echo "   · ②는 인덱스를 하나 늘렸는데 **HOT 비율이 안 움직인다.** UPDATE 가 filler 를 안 건드려"
echo "     HOT 을 깨지 않기 때문이다. '인덱스 개수'만으로는 설명되지 않는다."
echo "     다만 공짜는 아니다 — 기준선에서 이미 HOT 이 아니었던 몫(약 1/3)에 대해서는"
echo "     이 인덱스도 갱신 대상이라, FPI 제외 WAL 이 조금 는다. **깨뜨리는 것과 얹히는 것은 다르다.**"
echo "   · ③은 인덱스 수가 ②와 같은데 HOT 이 **0% 로 무너진다.** abalance 가 갱신 컬럼이라서다."
echo "   · ④는 ③에 두 개를 더 얹은 것이다. 한 번 HOT 이 깨지면 **그 행의 모든 인덱스**가"
echo "     새 엔트리를 받으므로, ②에서 조금이던 (filler) 의 몫이 여기서는 온전히 붙는다."
echo "   · **FPI 제외 열이 이 실습의 신호다.** 전체 WAL 은 체크포인트 직후의 전체 페이지 이미지가"
echo "     90% 가까이 차지해 조건 차이를 덮는다. 빼고 나면 인덱스 유지 비용이 그대로 드러난다."
echo "     (TPS 하락은 결과고, 인덱스 갱신이 WAL 에 실리는 것이 원인이다 — 원인 지표가 먼저 움직인다.)"
echo
echo "  → §T-8 본편의 결론을 이렇게 다듬는다: **인덱스를 더 만들지 말라가 아니라,"
echo "     갱신되는 컬럼을 인덱스에 넣을 때만 쓰기 비용을 따로 계산하라.**"
echo "     §T-8 의 결합 인덱스 (l_orderkey, l_shipdate) 는 둘 다 사실상 불변이므로 이 청구서가 없다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 2; then
echo "── ② HOT 의 전제 — 같은 페이지에 빈자리가 있어야 한다 ──"
echo
echo "  HOT 은 '인덱스 컬럼을 안 건드림' 말고 조건이 하나 더 있다: **새 버전이 같은 페이지에**"
echo "  들어가야 한다. 자리가 없으면 다른 페이지로 가고, 그러면 인덱스를 고쳐야 한다."
echo "  pgbench 가 만드는 테이블은 fillfactor=100 이다 — 빈자리를 안 남긴다."
echo
printf "  %s%10s %10s %14s\n" "$(padr 조건 40)" "$(padl TPS 10)" "$(padl HOT비율 10)" "$(padl "UPDATE당 WAL" 14)"
printf "  %s\n" "-----------------------------------------------------------------------"
for ff in 100 90 70; do
  clean_idx
  q "ALTER TABLE pgbench_accounts SET (fillfactor=$ff)" >/dev/null
  BT=0; BH="?"; BW="?"
  for r in $(seq 1 "$ROUNDS"); do
    R=$(measure); IFS='|' read -r T H W F <<<"$R"
    awk -v a="$T" -v b="$BT" 'BEGIN{exit !(a>b)}' && { BT="$T"; BH="$H"; BW="$W"; }
  done
  printf "  %s%10s %9s%% %11s B\n" "$(padr "fillfactor=$ff (인덱스 없음)" 40)" "$BT" "$BH" "$BW"
done
q "ALTER TABLE pgbench_accounts SET (fillfactor=${FF_ORIG:-100})" >/dev/null
echo
echo "  fillfactor 를 낮추면 테이블이 커지는 대신 HOT 이 살아난다 — **공간을 주고 쓰기를 산다.**"
echo "  그리고 이 축은 ①과 달리 **포화가 있다.** 100→90 에서 HOT 이 다 올라가면 70 까지 더 낮춰도"
echo "  남는 이득이 없다. 공간을 두 배로 더 내주고 사 올 것이 없다는 뜻이다."
echo
echo "  이 절은 ①의 기준선도 설명한다 — ①의 HOT 이 100% 가 아니라 ~68% 였던 것은"
echo "  pgbench 기본값 fillfactor=100 때문이다. 그래서 ②의 (filler) 인덱스가 완전히 공짜가"
echo "  아니었다: 이미 HOT 이 아니던 1/3 의 UPDATE 가 그 인덱스를 갱신해야 했다."
echo "  **fillfactor 를 먼저 고치면 ②의 비용도 같이 사라진다** — 두 축이 독립이 아니다."
echo
fi

# ══════════════════════════════════════════════════════════════════════
if want 3; then
echo "── ③ 그 비용은 언제 TPS 로 나타나는가 ──"
echo
echo "  ①에서 HOT 이 무너지고 WAL 이 두 배가 되는데도 TPS 는 거의 그대로다."
echo "  **그게 이 절의 주제다** — 비용은 실재하는데 전역 지표가 그걸 삼킨다(Millsap 8장)."
echo "  삼키는 이유는 병목이 딴 데 있어서다. 부하를 올려 병목을 옮기면 드러나는지 본다."
echo
DDL3="CREATE INDEX x_a ON pgbench_accounts(abalance); CREATE INDEX x_ba ON pgbench_accounts(bid,abalance); CREATE INDEX x_f ON pgbench_accounts(filler)"
printf "  %s%12s %12s %10s %14s\n" "$(padr "동시 클라이언트" 18)" "$(padl 기준 12)" "$(padl 인덱스3개 12)" "$(padl 배수 10)" "$(padl "기준의 편차" 14)"
printf "  %s\n" "-------------------------------------------------------------------------"
for c in 8 16 32 64; do
  CLIENTS="$c"; A=0; B=0; Amin=""
  # 라운드마다 두 조건을 **교차**한다. 한 조건을 몰아서 재면 시간대 드리프트가 섞인다.
  # 그리고 기준 조건의 라운드 간 **편차**를 같이 남긴다 — 조건 차이가 그 폭 안이면
  # "차이가 있다"고 말할 수 없기 때문이다. 배수만 찍으면 노이즈를 발견으로 읽게 된다.
  for r in $(seq 1 "$ROUNDS"); do
    clean_idx;                       x=$(measure); x="${x%%|*}"
    awk -v a="$x" -v b="$A" 'BEGIN{exit !(a>b)}' && A="$x"
    { [ -z "$Amin" ] || awk -v a="$x" -v b="$Amin" 'BEGIN{exit !(a<b)}'; } && Amin="$x"
    clean_idx; q "$DDL3" >/dev/null;  y=$(measure); y="${y%%|*}"
    awk -v a="$y" -v b="$B" 'BEGIN{exit !(a>b)}' && B="$y"
  done
  printf "  %s%12s %12s %10s %14s\n" "$(padr "clients=$c" 18)" "$A" "$B" \
    "$(awk -v a="$A" -v b="$B" 'BEGIN{ if(a>0) printf "%.2fx", b/a }')" \
    "$(awk -v hi="$A" -v lo="${Amin:-0}" 'BEGIN{ if(lo>0) printf "±%.0f%%", 100*(hi-lo)/hi }')"
done
clean_idx
echo
echo "  CPU $(nproc 2>/dev/null || echo '?') 개짜리 장비다. **배수를 오른쪽 편차와 나란히 읽어야 한다** —"
echo "  차이가 편차 안이면 '차이가 있다'고 말할 수 없다."
echo
echo "  이 환경에서 네 번 돌려 본 결과: clients 8~32 의 배수는 회차마다 순서가 뒤바뀌어"
echo "  **추세로 읽을 수 없었다.** clients=64 가 매번 가장 낮긴 했지만(0.89~0.93),"
echo "  클라이언트를 늘릴수록 기준 자체의 편차도 같이 커져서(±1% → ±10%) 그 차이마저"
echo "  노이즈 폭 안이다. CPU 4개에 64 클라이언트면 16배 과다구독이니 당연한 일이다."
echo
echo "  → 그래서 이 절의 결론은 '부하를 올리면 드러난다'가 아니라 그 반대다:"
echo "     **TPS 로는 이 비용을 잡을 수 없다.** HOT 은 68%→0%, 레코드 WAL 은 +75% 인데"
echo "     같은 변화가 TPS 에는 3~10% 로만 비친다. 전역 지표가 국소 변화를 삼킨 것이다(Millsap 8장)."
echo "     'TPS 안 떨어지던데요'는 측정이 아니라 **지표를 잘못 고른 것**이다."
echo "     인덱스의 청구서는 HOT 비율과 WAL 에 찍힌다. 거기를 봐야 한다."
echo
fi

echo "정리: 인덱스의 쓰기 비용은 **개수가 아니라 갱신 컬럼을 담았는가**에서 시작한다."
echo "  EXPLAIN 에는 안 나온다 — pg_stat_user_tables 의 n_tup_hot_upd / n_tup_upd 로 본다."
echo
echo "  실험 인덱스를 지웠다. 남은 x_* 인덱스: $(q "SELECT count(*) FROM pg_indexes
       WHERE tablename='pgbench_accounts' AND indexname LIKE 'x\\_%'")  (0 이어야 한다)"
echo "  fillfactor = $(q "SELECT coalesce((SELECT option_value FROM pg_options_to_table(reloptions)
       WHERE option_name='fillfactor'),'100') FROM pg_class WHERE relname='pgbench_accounts'")  (원래 $FF_ORIG)"
