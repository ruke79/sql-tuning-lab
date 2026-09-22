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
# 두 비율이 '사실상 같은가' — 절대차 2%p 안이면 같다고 본다.
# (HOT 비율은 0.1 과 0.2 처럼 작은 값도, 68 과 70 처럼 큰 값도 오므로 상대비는 안 맞는다.)
near2() { [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "$1" != "?" ] && [ "$2" != "?" ] && \
          awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=2)}'; }

# pgbench 는 컨테이너 경로에서도 쓸 수 있다(postgres 이미지에 들어 있다) — 아래 pg_precheck 이 본다.
# 클라이언트가 호스트에 있을 수도, 컨테이너 안에만 있을 수도 있다. 없다고 그냥 두면
# psql 호출이 전부 빈 값을 돌려주고, 그 빈 값이 **다른 진단으로 둔갑한다** —
# 실제로 "psql: command not found" 뒤에 "lineitem 에 인덱스가 없습니다"가 찍혀,
# 사용자가 멀쩡한 DB 에 index 를 다시 돌렸다. 그래서 여기서 갈라 두고,
# 아래 pg_precheck 이 '클라이언트 없음'과 '접속 불가'와 '인덱스 없음'을 구분해 말한다.
CONTAINER="${CONTAINER:-tuninglab-postgres}"
if command -v psql >/dev/null 2>&1; then
  PG_VIA=host
else
  PG_VIA=docker
fi
if [ "$PG_VIA" = host ]; then
  q()  { psql -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -d "$DB" -X -q -tAc "$1" 2>&1; }
  PGBENCH(){ pgbench -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" "$@"; }
else
  q()  { docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="${PGOPTIONS:-}" "$CONTAINER" psql -U "$PGUSER_" -d "$DB" -X -q -tAc "$1" 2>&1; }
  PGBENCH(){ docker exec -i -e PGPASSWORD=tuner -e PGOPTIONS="${PGOPTIONS:-}" "$CONTAINER" pgbench -U "$PGUSER_" "$@"; }
fi
# 진단을 섞지 않는다 — 원인마다 다른 문장을 준다.
pg_precheck() {
  if [ "$PG_VIA" = docker ] && ! command -v docker >/dev/null 2>&1; then
    echo "  [중단] psql 도 docker 도 없습니다. 둘 중 하나:"
    echo "         sudo apt install postgresql-client"
    echo "         docker compose -f docker/docker-compose.yml up -d postgres"
    exit 1
  fi
  # 이 시점에 sql() 은 아직 정의 전일 수 있다(스크립트마다 순서가 다르다).
  # 정의돼 있는 쪽을 골라 직접 찔러 본다.
  local ok=""
  if declare -f PSQL >/dev/null 2>&1; then ok=$(PSQL -tAc "SELECT 1" 2>/dev/null)
  elif declare -f q >/dev/null 2>&1;    then ok=$(q "SELECT 1" 2>/dev/null); fi
  if ! printf %s "$ok" | grep -q 1; then
    echo "  [중단] PostgreSQL 에 접속할 수 없습니다 (경로: $PG_VIA)."
    [ "$PG_VIA" = docker ] && echo "         docker start $CONTAINER   # 컨테이너 이름이 다르면 CONTAINER=... 로 준다"
    echo "         ./scripts/restore-lab.sh --check"
    exit 1
  fi
}
# 컨테이너 경로에서는 -f 로 줄 파일이 **컨테이너 안에** 있어야 한다. 경로를 바꿔 준다.
pg_stage() {
  if [ "$PG_VIA" = host ]; then printf %s "$1"; return; fi
  docker cp "$1" "$CONTAINER:/tmp/$(basename "$1")" >/dev/null 2>&1
  printf %s "/tmp/$(basename "$1")"
}
pg_precheck

# 준비 단계용 — 실패를 삼키지 않는다. 조용히 안 돈 준비 단계는 측정을 통째로 무의미하게 만든다.
qx() { local o; o=$(q "$1"); case "$o" in *ERROR*) echo "  [중단] 준비 단계 실패: $1"; echo "         $o"; exit 1;; esac; }
# postgres DB 로 붙는 별도 헬퍼도 래퍼를 타야 한다 — 여기만 직접 부르면 클라이언트가
# 없는 환경에서 조용히 빈 값을 돌려준다.
if [ "$PG_VIA" = host ]; then
  qp() { psql -h "$PGHOST_" -p "$PGPORT_" -U "$PGUSER_" -d postgres -X -q -tAc "$1" 2>&1; }
else
  qp() { docker exec -i -e PGPASSWORD=tuner "$CONTAINER" psql -U "$PGUSER_" -d postgres -X -q -tAc "$1" 2>&1; }
fi

# 준비 — 없으면 만든다. 있으면 건드리지 않는다.
if [ "$(qp "SELECT count(*) FROM pg_database WHERE datname='$DB'")" != "1" ]; then
  echo "pgbench_lab 을 만든다 (-s $SCALE)"
  qp "CREATE DATABASE $DB OWNER $PGUSER_" >/dev/null
fi
NACC=$(q "SELECT count(*) FROM pgbench_accounts" 2>/dev/null)
case "$NACC" in ''|*[!0-9]*) NACC=0;; esac
if [ "$NACC" -lt 1000 ]; then
  echo "pgbench_accounts 를 적재한다 (-s $SCALE, 약 3초)"
  PGBENCH -i -s "$SCALE" -q "$DB" 2>&1 | tail -1
  NACC=$(q "SELECT count(*) FROM pgbench_accounts")
fi

# ── 규모 가드 ─────────────────────────────────────────────────────────
# **이 스크립트의 비용은 벤치마크가 아니라 VACUUM FULL 이 정한다.**
# measure() 가 매번 테이블을 통째로 다시 쓴다(fillfactor 를 적용하려면 재작성이 필요하다).
# 호출 횟수는 ① ROUNDS×4 + ② ROUNDS×3 + ③ ROUNDS×4×2 = ROUNDS×15 이다.
# ROUNDS=2 면 30회. 테이블이 크면 이게 그대로 시간이 된다.
#
# 실측: pgbench_accounts 152MB(scale=10) VACUUM FULL 2,457ms → 약 61 MB/s.
# 이 값으로 scale=2000(총 약 30GB)을 외삽하면 회당 503초 = 8.4분이고,
# 실제로 그 규모를 돌린 사용자의 ①②(14회)가 2시간 걸렸다 — 외삽이 맞았다.
VF_RATE=60                                  # MB/s, 보수적으로 낮춰 잡는다
NPER=0
want 1 && NPER=$(( NPER + 4 ))      # ① 조건 4개
want 2 && NPER=$(( NPER + 3 ))      # ② fillfactor 3개
want 3 && NPER=$(( NPER + 8 ))      # ③ 클라이언트 4단계 × 조건 2개
NMEAS=$(( ROUNDS * NPER ))
TOTMB=$(q "SELECT round(pg_total_relation_size('pgbench_accounts')/1048576.0)" 2>/dev/null)
case "$TOTMB" in ''|*[!0-9]*) TOTMB=0;; esac
if [ "$TOTMB" -gt 0 ] && [ "${NMEAS:-0}" -gt 0 ]; then
  EST=$(( TOTMB * NMEAS / VF_RATE ))        # 초
  if [ "$EST" -gt 1800 ] && [ "${FORCE:-0}" != "1" ]; then
    echo "  [중단] pgbench_accounts 가 ${TOTMB}MB 다(행 ${NACC})."
    echo "         이 스크립트는 measure() 마다 **VACUUM FULL** 로 테이블을 통째로 다시 쓴다."
    echo "         지금 설정(ROUNDS=$ROUNDS, ONLY=$ONLY)이면 **${NMEAS}회** 재작성한다."
    echo "         실측 ${VF_RATE}MB/s 로 잡으면 **약 $(( EST / 60 ))분** 걸린다 — 벤치마크(${SECS}초×${NMEAS})는 그중 일부일 뿐이다."
    echo
    echo "         그리고 큰 규모에서는 **측정 자체가 무너진다.** 행이 많아 갱신이 흩어지면"
    echo "         UPDATE 마다 새 페이지를 건드려 WAL 이 거의 전부 FPI 가 되고,"
    echo "         'FPI 제외' 열이 큰 두 수의 차가 되어 신호를 못 담는다(음수까지 나온다)."
    echo
    echo "         작은 규모에서 재라 — 이 실습이 보이려는 것(HOT, fillfactor, WAL)은"
    echo "         규모가 아니라 **갱신 컬럼과 페이지 여유**가 정한다:"
    echo "           dropdb pgbench_lab && SCALE=10 $0      # 100만 행, 수 분"
    echo "         지금 규모 그대로 강행하려면: FORCE=1 $0"
    exit 1
  fi
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
  tps=$(PGBENCH -c "$CLIENTS" -j "$JOBS" -T "$SECS" "$DB" 2>&1 \
        | grep -oE "tps = [0-9.]+" | head -1 | grep -oE "[0-9.]+")
  # tps|HOT비율|UPDATE당 WAL 전체|그중 FPI 를 뺀 레코드 몫
  #
  # FPI(전체 페이지 이미지)를 왜 빼는가 — 체크포인트 직후 각 페이지의 첫 변경은 8KB 를 통째로
  # 싣는다. 위에서 CHECKPOINT 를 고정했으므로 그 몫이 모든 조건에 **똑같이** 크게 붙어
  # (여기서는 WAL 의 약 90%) 정작 보려는 인덱스 유지 비용을 덮어 버린다.
  # 빼고 남는 것이 "이 UPDATE 가 실제로 기록한 변경량"이다.
  #
  # **이 뺄셈에는 한계가 있다.** wal_fpi 는 '몇 장'이고 바이트가 아니다. PostgreSQL 은
  # FPI 를 쓸 때 페이지 가운데 빈 공간(hole)을 떼고 싣는다. 그래서 wal_fpi*8192 는
  # 실제 FPI 바이트의 **상한**이고 항상 조금 과대평가다.
  # 평소엔 무해한데, FPI 비중이 100% 에 가까워지면 '거의 같은 두 수의 차'가 되어
  # 과대평가분이 신호보다 커진다 — **실제로 음수가 찍혔다**(전체 16084B / 제외 -338B).
  # 그 조건은 규모가 크고 갱신이 흩어질 때 온다: 매 UPDATE 가 새 힙 페이지 + 새 인덱스
  # 리프를 건드려 둘 다 FPI 가 되므로 UPDATE 당 FPI 2장(16384B)이 그대로 전체 WAL 이 된다.
  # 그래서 FPI 비중을 같이 돌려주고, 아래 표가 그걸 보고 판단한다.
  q "SELECT round(${tps:-0}::numeric,0) || '|' ||
            coalesce(round(100.0*t.n_tup_hot_upd/NULLIF(t.n_tup_upd,0),1)::text,'?') || '|' ||
            coalesce(round(w.wal_bytes / NULLIF(t.n_tup_upd,0))::text,'?') || '|' ||
            coalesce(round((w.wal_bytes - w.wal_fpi::bigint*8192) / NULLIF(t.n_tup_upd,0))::text,'?') || '|' ||
            coalesce(round(100.0*w.wal_fpi::bigint*8192 / NULLIF(w.wal_bytes,0),1)::text,'?')
       FROM pg_stat_user_tables t, pg_stat_wal w WHERE t.relname='pgbench_accounts'"
}

# 라벨 폭 맞추기 — 이 컨테이너는 로케일이 UTF-8 이 아니라 printf 가 바이트를 센다.
dispw() { local b k; b=$(printf %s "$1" | wc -c); k=$(printf %s "$1" | LC_ALL=C tr -dc '\200-\277' | wc -c)
          echo $(( b - k / 2 )); }
padr()  { local n; n=$(dispw "$1"); printf "%s" "$1"; while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; }
padl()  { local n; n=$(dispw "$1"); while [ "$n" -lt "$2" ]; do printf " "; n=$((n+1)); done; printf "%s" "$1"; }

# 여러 라운드의 최대 TPS(=간섭이 가장 적었던 회)와, 그 회의 HOT/WAL 을 같이 남긴다.
# 평균이 아니라 최대를 쓰는 이유는 §T-0 과 같다 — 느린 쪽은 잡음이 섞인 쪽이다.
declare -A BEST_T BEST_H BEST_W BEST_F BEST_P

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
    R=$(measure); IFS='|' read -r T H W F P <<<"$R"
    prev="${BEST_T[$L]:-0}"
    if awk -v a="$T" -v b="$prev" 'BEGIN{exit !(a>b)}'; then
      BEST_T[$L]="$T"; BEST_H[$L]="$H"; BEST_W[$L]="$W"; BEST_F[$L]="$F"; BEST_P[$L]="$P"
    fi
    printf "."
  done
done
echo; echo
printf "  %s%10s %9s %13s %13s %8s %9s\n" "$(padr 조건 38)" "$(padl TPS 10)" "$(padl HOT비율 9)" "$(padl "UPDATE당 WAL" 13)" "$(padl "FPI 제외" 13)" "$(padl "FPI몫" 8)" "$(padl 인덱스 9)"
printf "  %s\n" "--------------------------------------------------------------------------------------------------"
BASE=""
for c in "${CONDS[@]}"; do
  L="${c%%|*}"; DDL="${c#*|}"
  clean_idx; [ -n "$DDL" ] && q "$DDL" >/dev/null
  SZ=$(idx_size)
  [ -z "$BASE" ] && BASE="${BEST_T[$L]}"
  REL=$(awk -v a="${BEST_T[$L]:-0}" -v b="$BASE" 'BEGIN{ if(b>0) printf "%.2fx", a/b }')
  printf "  %s%10s %8s%% %11s B %11s B %7s%% %9s  %s\n" "$(padr "$L" 38)" \
     "${BEST_T[$L]:-?}" "${BEST_H[$L]:-?}" "${BEST_W[$L]:-?}" "${BEST_F[$L]:-?}" "${BEST_P[$L]:-?}" "$SZ" "$REL"
done
clean_idx
echo
L1="① 기준 (기본키만)"; L2="② + (filler) — 갱신 안 되는 컬럼"
L3="③ + (abalance) — 갱신되는 컬럼"; L4="④ 문서의 3개 전부"
H1="${BEST_H[$L1]:-?}"; H2="${BEST_H[$L2]:-?}"; H3="${BEST_H[$L3]:-?}"
P1="${BEST_P[$L1]:-0}"; F1="${BEST_F[$L1]:-0}"; F2="${BEST_F[$L2]:-0}"
echo "  읽는 법 —"
# "기준선에서 이미 HOT 이 아니던 몫(약 1/3)" 이라고 박아 뒀었다. 그건 작은 scale 의 값이고,
# 2억 행에서는 기준선 HOT 이 0.1% 였다 — 1/3 이 아니라 거의 전부가 이미 HOT 이 아니었다.
# 기준선 HOT 을 재서 말한다.
NONHOT=$(awk -v h="$H1" 'BEGIN{ if(h=="?") print "?"; else printf "%.0f", 100-h }')
echo "   · 기준선(①)의 HOT 은 **${H1}%** 다 — 즉 UPDATE 의 ${NONHOT}% 가 이미 HOT 이 아니다."
echo "     이 값이 아래 두 항목의 전제다(②에서 fillfactor 로 이걸 움직인다)."
if [ "$H2" = "$H1" ] || near2 "$H2" "$H1"; then
  echo "   · ②는 인덱스를 하나 늘렸는데 **HOT 비율이 안 움직인다**(${H1}% → ${H2}%)."
  echo "     UPDATE 가 filler 를 안 건드려 HOT 을 깨지 않기 때문이다."
  echo "     '인덱스 개수'만으로는 설명되지 않는다."
else
  echo "   · ②에서 HOT 이 ${H1}% → ${H2}% 로 움직였다 — filler 는 갱신 컬럼이 아닌데도 그렇다면"
  echo "     인덱스 때문이 아니라 페이지 여유가 달라진 것이다(②절을 보라)."
fi
echo "     다만 공짜는 아니다 — 이미 HOT 이 아니던 ${NONHOT}% 의 UPDATE 에 대해서는 이 인덱스도"
echo "     갱신 대상이다. **깨뜨리는 것과 얹히는 것은 다르다.**"
echo "   · ③은 인덱스 수가 ②와 같은데 HOT 이 **${H3}% 로 무너진다.** abalance 가 갱신 컬럼이라서다."
echo "   · ④는 ③에 두 개를 더 얹은 것이다. 한 번 HOT 이 깨지면 **그 행의 모든 인덱스**가"
echo "     새 엔트리를 받으므로, ②에서 조금이던 (filler) 의 몫이 여기서는 온전히 붙는다."
# **FPI 몫이 100% 에 가까우면 'FPI 제외' 열은 신호를 못 담는다.**
# wal_fpi 는 장수이고 바이트가 아니다. PostgreSQL 은 FPI 에서 페이지의 빈 공간을 떼고 싣기
# 때문에 wal_fpi*8192 는 상한이다. 거의 같은 두 수를 빼면 그 과대평가분만 남고, 실제로
# 음수가 찍혔다. 그때는 열을 신호라고 말하지 않는다.
if awk -v p="$P1" 'BEGIN{exit !(p+0>=95)}'; then
  echo "   · ⚠️ **'FPI 제외' 열을 믿지 마라 — 이 실행에서는 WAL 의 ${P1}% 가 FPI 다.**"
  echo "     wal_fpi 는 장수이지 바이트가 아니고, PostgreSQL 은 FPI 에서 페이지의 빈 공간을"
  echo "     떼고 싣는다. 그래서 wal_fpi×8192 는 **상한**이고 항상 조금 과대평가다."
  echo "     FPI 가 거의 전부면 뺄셈이 '거의 같은 두 수의 차'가 되어 그 오차만 남는다"
  echo "     (기준선 ${F1}B — 음수면 그게 증거다)."
  echo "     왜 이렇게 되나: 행이 많아 갱신이 흩어지면 UPDATE 마다 새 힙 페이지 + 새 인덱스"
  echo "     리프를 건드리고, CHECKPOINT 직후라 둘 다 첫 변경이라 둘 다 FPI 가 된다."
  echo "     → **작은 규모에서 다시 재라.** 같은 갱신이 좁은 페이지 집합을 반복해서 치면"
  echo "       FPI 비중이 내려가고 이 열이 의미를 갖는다. 이 실행에서는 HOT 비율만 보라."
else
  echo "   · **FPI 제외 열이 이 실습의 신호다**(FPI 몫 ${P1}%). 전체 WAL 은 체크포인트 직후의"
  echo "     전체 페이지 이미지가 상당 부분을 차지해 조건 차이를 덮는다. 빼고 나면 인덱스"
  echo "     유지 비용이 드러난다 — 기준 ${F1}B 대 ② ${F2}B."
  echo "     (TPS 하락은 결과고, 인덱스 갱신이 WAL 에 실리는 것이 원인이다 — 원인 지표가 먼저 움직인다.)"
fi
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
    R=$(measure); IFS='|' read -r T H W F P <<<"$R"
    awk -v a="$T" -v b="$BT" 'BEGIN{exit !(a>b)}' && { BT="$T"; BH="$H"; BW="$W"; }
  done
  printf "  %s%10s %9s%% %11s B\n" "$(padr "fillfactor=$ff (인덱스 없음)" 40)" "$BT" "$BH" "$BW"
  [ "$ff" = 100 ] && FF100_H="$BH"
done
q "ALTER TABLE pgbench_accounts SET (fillfactor=${FF_ORIG:-100})" >/dev/null
echo
echo "  fillfactor 를 낮추면 테이블이 커지는 대신 HOT 이 살아난다 — **공간을 주고 쓰기를 산다.**"
echo "  그리고 이 축은 ①과 달리 **포화가 있다.** 100→90 에서 HOT 이 다 올라가면 70 까지 더 낮춰도"
echo "  남는 이득이 없다. 공간을 두 배로 더 내주고 사 올 것이 없다는 뜻이다."
echo
# "①의 HOT 이 ~68% 였다 / 1/3 이 이미 HOT 이 아니었다"고 박아 뒀었다.
# 2억 행 실행에서는 기준선 HOT 이 0.1% 였다 — 1/3 이 아니라 거의 전부다.
# ①이 돌았으면 그 값을, 안 돌았으면 ②의 fillfactor=100 행을 쓴다.
BH100="${BEST_H[① 기준 (기본키만)]:-${FF100_H:-?}}"
echo "  이 절은 ①의 기준선도 설명한다 — ①의 HOT 이 100% 가 아닌 것은"
echo "  pgbench 기본값 fillfactor=100 때문이다(이 실행의 기준선 HOT: ${BH100}%)."
echo "  그래서 ②의 (filler) 인덱스가 완전히 공짜가 아니었다:"
echo "  **이미 HOT 이 아니던 UPDATE 는 그 인덱스도 갱신해야 한다.**"
echo "  그 몫은 규모에 따라 크게 달라진다 — 행이 많아 갱신이 흩어질수록 100% 에 가까워진다."
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
