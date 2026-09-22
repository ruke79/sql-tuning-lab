#!/usr/bin/env bash
# §T-9 실습 (TPC-DS 판) — 인덱스로 못 넘는 벽을 모델 변경으로 넘고, **그 대가를 같이 잰다.**
#
# Dan Tow 10장: 선택적 필터가 조인 트리의 서로 다른 가지에 흩어져 있으면, 그 조합에
# 도달하기 전에 이미 큰 테이블을 헤집게 된다. 처방은 두 가지다.
#   A. 필터 컬럼을 팩트 쪽으로 끌어올려 한 테이블에 모은다 (반정규화)
#   B. 결과 자체를 미리 계산해 둔다 (사전 집계 / Materialized View)
#
# tpch 판과 결정적으로 다른 점 — **전파 팬아웃이 비대칭이다.**
#   tpch: customer 1행 변경 → 그 고객의 lineitem 들 (수십~수백 행)
#   tpcds: item 1행 변경   → 그 상품의 store_sales 전부
#          차원이 작고 팩트가 클수록 차원 한 행의 파급이 커진다. 스타 스키마의 구조적 성질이다.
#   그래서 "빨라졌다"만 보고 끝내면 스타 스키마에서는 특히 위험하다.
#
# §T-8 에서 커버링 인덱스로 probe 를 1,543 buffers 까지 줄였다. 그것이 인덱스의 하한이다
# (196회 B-tree 하강 자체). 여기서부터는 접근 경로가 아니라 쿼리와 모델을 바꿔야 한다.
#
# 사용법:
#   ./t9-preaggregation.sh          # 기본 6라운드
#   ./t9-preaggregation.sh 10
#
# 선행 조건: tpcds schema → load → index (§0-4)
set -uo pipefail

ROUNDS="${1:-6}"
PGHOST_="${PGHOST:-localhost}"
PGPORT_="${PGPORT:-5432}"
CONTAINER="${CONTAINER:-tuninglab-postgres}"

# work_mem — 큰 해시·정렬이 디스크로 넘치지 않게 **이 스크립트가 여는 세션에만** 건다.
# PGOPTIONS 는 libpq 환경변수라 psql 과 pgbench 모두에 전달된다.
# 서버 기본값은 건드리지 않는다 — 다른 실습의 측정 조건을 바꾸지 않기 위해서다.
#
# work_mem 은 **미리 잡아 두는 양이 아니라 상한**이다. 넘칠 일이 없으면 올려도
# 아무 일도 안 일어나고(200만 행 tpcds·SF=0.5 tpch 에서 64MB 와 4GB 가 동일),
# **넘기는 순간부터 지배적이 된다** — 해시가 디스크로 흘러 비용이 계단처럼 뛴다.
# 그 경계는 생각보다 낮다: t7 의 UNION 은 팩트 200만 행당 약 28.7MB 를 쓰므로
# 기본값 64MB 를 넘기는 지점이 약 457만 행이다(억 단위가 아니다).
# 넘치는지는 EXPLAIN 의 'Batches: N(N>1)' / 'Disk Usage' 로 판별한다.
#
# 다만 연산 노드당·병렬 워커당 붙으므로 RAM 이 작은 장비에서는 낮춰 잡을 것:
#   WORK_MEM=512MB ./<script>.sh
WORK_MEM="${WORK_MEM:-4096MB}"
export PGOPTIONS="-c work_mem=$WORK_MEM"

if command -v psql >/dev/null 2>&1; then
  sql()  { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -X -q -tAc "$1"; }
  sqlv() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -X -q -c "$1"; }
else
  sql()  { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -X -q -tAc "$1"; }
  sqlv() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -X -q -c "$1"; }
fi

if ! sql "SELECT 1 FROM store_sales LIMIT 1" >/dev/null 2>&1; then
  echo "  store_sales 가 없습니다. §0-4 의 tpcds 준비 명령을 먼저 실행하세요."
  exit 1
fi

ms()  { sql "EXPLAIN (ANALYZE) $1" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+'; }
# **hit=0 이면 PostgreSQL 이 그 항목을 아예 생략한다.** 그래서 'shared hit=' 로 긁으면
# top 노드 줄을 건너뛰고 더 깊은 노드 값을 집는다 — 테이블이 shared_buffers 보다 크면
# (SF=10 등) 늘 그렇게 되고, buffers 열이 시간과 전혀 안 맞는 작은 값으로 찍힌다.
# 첫 'Buffers: shared' 줄을 잡고 두 항목을 각각 0 기본값으로 읽는다.
buf() { sql "EXPLAIN (ANALYZE, BUFFERS) $1" | awk '/Buffers: shared/{h=0;r=0; if (match($0,/hit=[0-9]+/)) h=substr($0,RSTART+4,RLENGTH-4); if (match($0,/read=[0-9]+/)) r=substr($0,RSTART+5,RLENGTH-5); printf "hit=%d read=%d", h, r; exit}'; }

# 원본: 3개 차원에 필터가 흩어진 스타 조인
Q="select i_brand_id, i_brand, d_year, sum(ss_ext_sales_price) as ext_price
   from store_sales, item, date_dim
   where ss_item_sk = i_item_sk and ss_sold_date_sk = d_date_sk
     and i_manager_id = 8 and d_moy = 11 and d_year = 1999
   group by i_brand_id, i_brand, d_year"

echo "§T-9 사전 집계 / 필터 끌어올리기 (TPC-DS) — ${ROUNDS}라운드"
echo

# ── 1) 문제를 정량화한다 ──────────────────────────────────────────────
echo "── 분산된 필터: 필터가 두 차원에 흩어져 있고 팩트에는 하나도 없다 ──"
sqlv "SELECT 'item.i_manager_id=8'   AS 위치,
             round(count(*) FILTER (WHERE i_manager_id=8)::numeric/count(*),4) AS 선택도 FROM item
      UNION ALL
      SELECT 'date_dim.d_moy=11 AND d_year=1999',
             round(count(*) FILTER (WHERE d_moy=11 AND d_year=1999)::numeric/count(*),4) FROM date_dim;"
TOTAL=$(sql "SELECT count(*) FROM store_sales")
HIT=$(sql "SELECT count(*) FROM store_sales s JOIN item i ON s.ss_item_sk=i.i_item_sk
           JOIN date_dim d ON s.ss_sold_date_sk=d.d_date_sk
           WHERE i.i_manager_id=8 AND d.d_moy=11 AND d.d_year=1999")
echo "  store_sales ${TOTAL} 행 중 최종적으로 필요한 행: ${HIT} 행 ($(sql "SELECT round(100.0*$HIT/$TOTAL,3)")%)"
echo "  그런데 그 ${HIT} 행을 **팩트만 보고는 지목할 수 없다.** 두 차원을 모두 거쳐야"
echo "  비로소 알 수 있고, 그때는 이미 팩트를 헤집은 뒤다 — 이것이 '분산된 필터'다."
echo

# ── 2) 해법 A: 필터를 팩트로 끌어올린다 ───────────────────────────────
echo "── 해법 A: 반정규화 (차원의 필터 컬럼을 팩트에 상속) ──"
sql "SET client_min_messages=warning; DROP TABLE IF EXISTS ss_denorm;" >/dev/null 2>&1
sql "CREATE TABLE ss_denorm AS
     SELECT s.ss_item_sk, s.ss_ticket_number, s.ss_ext_sales_price,
            i.i_manager_id, i.i_brand_id, i.i_brand, d.d_year, d.d_moy
     FROM store_sales s JOIN item i ON s.ss_item_sk=i.i_item_sk
                        JOIN date_dim d ON s.ss_sold_date_sk=d.d_date_sk;" >/dev/null 2>&1
sql "CREATE INDEX idx_ssd_filters ON ss_denorm (i_manager_id, d_year, d_moy);
     ANALYZE ss_denorm;" >/dev/null 2>&1

QD="select i_brand_id, i_brand, d_year, sum(ss_ext_sales_price) as ext_price
    from ss_denorm where i_manager_id=8 and d_moy=11 and d_year=1999
    group by i_brand_id, i_brand, d_year"
ms "$QD" >/dev/null
sql "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) $QD" \
  | grep -E "Bitmap Index Scan|Index Cond|Index Scan|Buffers: shared" | head -3 | sed 's/^ */  /'
echo "  ↑ 세 필터가 하나의 Index Cond 로 합쳐졌다. 조인은 0개."
echo

# ── 3) 해법 B: 결과를 사전 집계한다 ───────────────────────────────────
echo "── 해법 B: 사전 집계 (Materialized View) ──"
sql "SET client_min_messages=warning; DROP MATERIALIZED VIEW IF EXISTS mv_brand_month;" >/dev/null 2>&1
sql "CREATE MATERIALIZED VIEW mv_brand_month AS
     select i.i_manager_id, i.i_brand_id, i.i_brand, d.d_year, d.d_moy,
            sum(s.ss_ext_sales_price) as ext_price
     from store_sales s join item i on s.ss_item_sk=i.i_item_sk
                        join date_dim d on s.ss_sold_date_sk=d.d_date_sk
     group by i.i_manager_id, i.i_brand_id, i.i_brand, d.d_year, d.d_moy;" >/dev/null 2>&1
sql "CREATE INDEX ON mv_brand_month (i_manager_id, d_year, d_moy); ANALYZE mv_brand_month;" >/dev/null 2>&1
QM="select i_brand_id, i_brand, d_year, ext_price
    from mv_brand_month where i_manager_id=8 and d_moy=11 and d_year=1999"
MVROWS=$(sql "SELECT count(*) FROM mv_brand_month")
echo "  범용 MV 행수: ${MVROWS}  (팩트 ${TOTAL} 행 → $(sql "SELECT round(${TOTAL}::numeric/${MVROWS},1)")분의 1로만 접힘)"
echo "  이 MV 에는 **파라미터가 박혀 있지 않다.** 필터 컬럼을 group by 에 남겨 뒀으므로"
echo "  manager/year/moy 를 바꿔도 그대로 쓸 수 있다 — tpch 판 MV(mv_q03)와 반대 설계다."
echo "  그런데 그 범용성의 대가가 바로 위 숫자다. 얼마인지 파라미터를 박은 MV 와 나란히 잰다."
echo
sql "SET client_min_messages=warning; DROP MATERIALIZED VIEW IF EXISTS mv_baked;
     CREATE MATERIALIZED VIEW mv_baked AS
     select i.i_brand_id, i.i_brand, d.d_year, sum(s.ss_ext_sales_price) as ext_price
     from store_sales s join item i on s.ss_item_sk=i.i_item_sk
                        join date_dim d on s.ss_sold_date_sk=d.d_date_sk
     where i.i_manager_id=8 and d.d_moy=11 and d.d_year=1999
     group by i.i_brand_id, i.i_brand, d.d_year;" >/dev/null 2>&1
RB=$( { time -p sql "REFRESH MATERIALIZED VIEW mv_brand_month;" >/dev/null; } 2>&1 | awk '/real/{printf "%.0f", $2*1000}')
RK=$( { time -p sql "REFRESH MATERIALIZED VIEW mv_baked;"       >/dev/null; } 2>&1 | awk '/real/{printf "%.0f", $2*1000}')
printf "  %-34s %10s %10s %10s\n" "" "행수" "크기" "REFRESH"
printf "  %-34s %10s %10s %8s ms\n" "범용 (파라미터 없음)" "$MVROWS" \
       "$(sql "SELECT pg_size_pretty(pg_total_relation_size('mv_brand_month'))")" "$RB"
printf "  %-34s %10s %10s %8s ms\n" "파라미터 박음 (이 질문 전용)" \
       "$(sql "SELECT count(*) FROM mv_baked")" \
       "$(sql "SELECT pg_size_pretty(pg_total_relation_size('mv_baked'))")" "$RK"
echo "  → 사전 집계의 진짜 손잡이는 '집계했는가'가 아니라 **어느 입도로 접었는가**다."
echo "     i_brand_id 가 $(sql "SELECT count(DISTINCT i_brand_id) FROM item")종 × 연월 $(sql "SELECT count(*) FROM (SELECT DISTINCT d_year,d_moy FROM date_dim) x")개라 조합이 팩트 행수에 육박해서"
echo "     범용 MV 는 거의 접히지 않는다. 범용성은 공짜가 아니다."
echo

# ── 4) 정합성 먼저 검증한다 ───────────────────────────────────────────
echo "── 정합성 검증: 세 방식의 결과가 같은가 ──"
hash_of() { sql "SELECT md5(string_agg(i_brand_id||':'||i_brand||':'||d_year||':'||round(ext_price,2), '|' ORDER BY i_brand_id, i_brand)) FROM ( $1 ) x"; }
H1=$(hash_of "$Q"); H2=$(hash_of "$QD"); H3=$(hash_of "$QM")
printf "  원본     %s\n  반정규화 %s\n  사전집계 %s\n" "$H1" "$H2" "$H3"
if [ "$H1" = "$H2" ] && [ "$H2" = "$H3" ]; then
  echo "  ✓ 일치 — 아래 측정에 의미가 있다"
else
  echo "  ✗ 불일치 — 아래 측정은 의미 없다. 먼저 정의를 고쳐야 한다."
fi
echo

# ── 5) 시간 측정 (교차) ───────────────────────────────────────────────
BQ=$(buf "$Q"); BD=$(buf "$QD"); BM=$(buf "$QM")
A=""; B=""; C=""
for r in $(seq 1 "$ROUNDS"); do
  A="$A $(ms "$Q")"; B="$B $(ms "$QD")"; C="$C $(ms "$QM")"; printf "."
done
echo; echo
stat(){ echo "$1"|tr ' ' '\n'|grep -v '^$'|sort -g \
  |awk -v l="$2" -v b="$3" '{a[NR]=$1}
     END{printf "%-26s %-22s min=%8.2f  median=%8.2f\n", l, b, a[1], (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }
printf "%-26s %-22s %s\n" "방식" "buffers" "실행시간(ms)"
printf "%s\n" "--------------------------------------------------------------------------------"
stat "$A" "① 스타 조인 (원본)"   "$BQ"
stat "$B" "② 반정규화 (조인 0)"  "$BD"
stat "$C" "③ 사전 집계 MV"       "$BM"
echo

# ── 6) 대가를 잰다 — 스타 스키마에서 특히 중요한 부분 ─────────────────
echo "── 대가 ①: 저장 공간 ──"
sqlv "SELECT pg_size_pretty(pg_total_relation_size('store_sales'))    AS 원본_팩트,
             pg_size_pretty(pg_total_relation_size('ss_denorm'))      AS 반정규화,
             pg_size_pretty(pg_total_relation_size('mv_brand_month')) AS MV;"

echo "── 대가 ②: 전파 팬아웃 (스타 스키마 고유의 위험) ──"
TARGET=$(sql "SELECT i_item_sk FROM item WHERE i_manager_id=8 ORDER BY i_item_sk LIMIT 1")
FAN=$(sql "SELECT count(*) FROM store_sales WHERE ss_item_sk=$TARGET")
echo "  상품 1건(i_item_sk=$TARGET)의 담당자가 바뀌었다고 하자."
echo "    정규화 모델   : item 1행만 UPDATE"
echo "    반정규화 모델 : ss_denorm ${FAN} 행을 따라 고쳐야 한다 (팬아웃 ${FAN}배)"
T1=$( { time -p sql "BEGIN; UPDATE item SET i_manager_id=99 WHERE i_item_sk=$TARGET; ROLLBACK;" >/dev/null; } 2>&1 | awk '/real/{printf "%.0f", $2*1000}')
T2=$( { time -p sql "BEGIN; UPDATE ss_denorm SET i_manager_id=99 WHERE ss_item_sk=$TARGET; ROLLBACK;" >/dev/null; } 2>&1 | awk '/real/{printf "%.0f", $2*1000}')
printf "    정규화(1행)      %5s ms\n" "$T1"
printf "    반정규화(전파)   %5s ms\n" "$T2"
echo
echo "  담당자 한 명을 통째로 재배정하면:"
ALLITEM=$(sql "SELECT count(*) FROM item WHERE i_manager_id=8")
ALLFAN=$(sql "SELECT count(*) FROM ss_denorm WHERE i_manager_id=8")
echo "    item ${ALLITEM} 행 변경 → ss_denorm ${ALLFAN} 행 갱신 (팬아웃 $(sql "SELECT round(${ALLFAN}::numeric/${ALLITEM},0)")배)"
echo

echo "── 대가 ③: MV 갱신 — 점 변경 하나에 전량 재계산이다 ──"
T3=$( { time -p sql "REFRESH MATERIALIZED VIEW mv_brand_month;" >/dev/null; } 2>&1 | awk '/real/{printf "%.0f", $2*1000}')
printf "    반정규화 전파 (1상품)   %6s ms   ← 바뀐 %s 행만 건드린다\n" "$T2" "$FAN"
printf "    MV REFRESH (범용)       %6s ms   ← 팩트 %s 행을 통째로 다시 읽는다\n" "$T3" "$TOTAL"
awk -v a="$T2" -v b="$T3" 'BEGIN{printf "    → 점 변경 하나를 반영하는 비용은 MV 쪽이 %.0f배 비싸다.\n", b/a}'
echo "    PostgreSQL 의 REFRESH 는 증분이 아니다(CONCURRENTLY 도 전량 재계산 후 교체다)."
echo "    이 시간 동안 MV 는 이전 값을 그대로 보여준다. 즉 **지연창**이 생긴다."
echo "    그 지연창을 관리하는 방법이 §T-9 뒷부분(트리거 동기화 / 변경 큐)의 주제다."
echo

echo "해석:"
echo "  §T-8 이 인덱스로 1,543 buffers 에서 멈춘 벽을, 모델을 바꾸니 한 번에 넘는다."
echo "  다만 순서를 지켜야 한다 — 인덱스로 되는 것을 반정규화로 풀면"
echo "  쓰기 비용 수백 배를 내고 몇 밀리초를 사는 나쁜 거래가 된다."
echo "  스타 스키마에서 이 거래가 tpch 보다 나쁜 이유는 팬아웃이다 — 차원이 작아서"
echo "  차원 한 행의 변경이 팩트 여러 행으로 번진다. 위에서 잰 값이 그 크기다."
echo "  Tow 가 반정규화를 책 맨 마지막에 '다른 방법이 없을 때만'으로 못박은 이유다."
echo
echo "  ②와 ③ 중 무엇이 나은가 — **읽기만 보면 ③, 쓰기까지 보면 ②다.**"
echo "  ③이 읽기는 가장 빠르지만 점 변경 하나에 전량 재계산이라 유지비가 몇십 배 비싸다."
echo "  ②는 바뀐 행만 고치면 된다. 시작할 때 '③이 접혀 있으니 유지도 싸겠지'라고 적어 뒀다가"
echo "  실측에서 뒤집혔다 — 접힘은 **저장량**의 성질이지 **갱신 비용**의 성질이 아니다."
echo "  ③을 쓰려면 REFRESH 주기를 정해야 하고, 그 주기가 곧 답이 틀려 있는 시간이다."
echo "  그리고 ③은 원본 그대로의 상세 조회에 못 쓴다. 무엇을 포기하는지 알고 골라야 한다."
echo
echo "정리:"
if [ "${KEEP:-0}" = "1" ]; then
  echo "  KEEP=1 — 남겨 둔다. ⚠️ 매트뷰가 남으면 schema 재적재가 막힌다:"
  echo "     psql -d tpcds -c 'DROP MATERIALIZED VIEW IF EXISTS mv_brand_month, mv_baked; DROP TABLE IF EXISTS ss_denorm;'"
else
  sql "DROP MATERIALIZED VIEW IF EXISTS mv_brand_month, mv_baked; DROP TABLE IF EXISTS ss_denorm;" >/dev/null 2>&1
  LMV=$(sql "SELECT count(*) FROM pg_matviews WHERE matviewname IN ('mv_brand_month','mv_baked')")
  echo "  매트뷰 2종·ss_denorm 을 지웠다.  남은 매트뷰 ${LMV}   (0 이어야 한다)"
fi
