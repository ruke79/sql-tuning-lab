#!/usr/bin/env bash
# §T-6 실습 — 쿼리 다이어그램의 예측을 계획으로 검증한다 (TPC-DS q19, 6-way 스노우플레이크)
#
# Dan Tow 5·6장의 규칙: 다이어그램을 그리고 **가장 강한 필터(F가 가장 작은 노드)** 에서
# 출발해 조인 트리를 타고 내려가라. 옵티마이저가 그 규칙을 따르는지, 그리고
# **필터를 약화시키면 진입점이 실제로 옮겨가는지**를 눈으로 확인하는 것이 이 실습이다.
#
# q19 의 다이어그램:
#     store_sales (루트/디테일, 200만)
#        ↓ ss_item_sk        → item        [i_manager_id = 8         F ≈ 1/100]
#        ↓ ss_sold_date_sk   → date_dim    [d_year=1998, d_moy=11    F ≈ 1/60 ]
#        ↓ ss_customer_sk    → customer
#                                ↓ c_current_addr_sk → customer_address
#        ↓ ss_store_sk       → store       [substr(ca_zip)<>substr(s_zip) : 조인 후 필터]
#
# item 의 필터만 단계적으로 약화시키고 나머지는 고정한다 — §T-0 원칙 ①(한 번에 하나).
#
# 사용법:
#   ./t6-query-diagram.sh          # 기본 5회 측정
#   ./t6-query-diagram.sh 8
#
# 선행 조건: tpcds schema → load → index (§0-4)
set -uo pipefail

REPEAT="${1:-5}"
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
  sql() { PGPASSWORD=tuner psql -h "$PGHOST_" -p "$PGPORT_" -U tuner -d tpcds -X -q -tAc "$1"; }
else
  sql() { docker exec -e PGPASSWORD=tuner -e PGOPTIONS="$PGOPTIONS" "$CONTAINER" psql -U tuner -d tpcds -X -q -tAc "$1"; }
fi

if ! sql "SELECT 1 FROM date_dim LIMIT 1" >/dev/null 2>&1; then
  echo "  date_dim 이 없습니다. 먼저:"
  echo "    ./gradlew :tpcds:bootRun --args=\"generate --sales=2000000\""
  echo "    ./gradlew :tpcds:bootRun --args=\"schema --db=postgres\""
  echo "    ./gradlew :tpcds:bootRun --args=\"load   --db=postgres\""
  echo "    ./gradlew :tpcds:bootRun --args=\"index  --db=postgres\""
  exit 1
fi

q() {  # $1 = item 필터
  cat <<EOF
select i_brand_id, i_brand, i_manufact_id, i_manufact, sum(ss_ext_sales_price) ext_price
from date_dim, store_sales, item, customer, customer_address, store
where d_date_sk = ss_sold_date_sk and ss_item_sk = i_item_sk
  and $1 and d_moy = 11 and d_year = 1998
  and ss_customer_sk = c_customer_sk and c_current_addr_sk = ca_address_sk
  and substr(ca_zip,1,5) <> substr(s_zip,1,5) and ss_store_sk = s_store_sk
group by i_brand_id, i_brand, i_manufact_id, i_manufact
order by ext_price desc, i_brand limit 100
EOF
}

ms_of() { echo "$1" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+'; }

# 최소값(N회) — 1회 측정은 캐시 상태를 재는 것이지 쿼리를 재는 게 아니다(§T-0 원칙 ④·⑤).
best_ms() {
  local Q="$1" b="" v
  sql "EXPLAIN (ANALYZE) $Q" >/dev/null 2>&1        # 워밍업
  for _ in $(seq "$REPEAT"); do
    v=$(ms_of "$(sql "EXPLAIN (ANALYZE) $Q")")
    [ -z "$b" ] && b="$v" || b=$(awk -v a="$b" -v c="$v" 'BEGIN{print (c+0<a+0)?c:a}')
  done
  echo "$b"
}

# 계획의 **가장 깊은(=처음 접근하는) 스캔 노드** = 옵티마이저가 고른 진입점
driver_of() {
  sql "EXPLAIN (COSTS OFF) $1" \
    | grep -oE '(Parallel Seq Scan|Seq Scan|Bitmap Heap Scan|Index Only Scan|Index Scan) on [a-z_]+' \
    | head -1
}
methods_of() {
  sql "EXPLAIN (COSTS OFF) $1" | grep -oE '(Nested Loop|Hash Join|Merge Join)' \
    | sort | uniq -c | awk '{printf "%s×%s ", $3" "$4, $1}'
}

FILTERS=(
  "i_manager_id = 8|= 8"
  "i_manager_id between 1 and 5|1~5"
  "i_manager_id between 1 and 10|1~10"
  "i_manager_id between 1 and 25|1~25"
  "i_manager_id between 1 and 50|1~50"
  "i_manager_id between 1 and 100|1~100(무필터)"
)

NITEM=$(sql "SELECT count(*) FROM item")
echo "§T-6 쿼리 다이어그램 — q19 의 진입점은 필터가 정한다"
echo "item ${NITEM} 행 / store_sales $(sql "SELECT count(*) FROM store_sales") 행 · 각 조건 ${REPEAT}회 최소값"
echo

printf "%-14s %8s %10s  %-34s %-26s %10s\n" "i_manager_id" "item행" "F(item)" "진입점(가장 깊은 스캔)" "조인 방식" "시간(ms)"
printf "%s\n" "-------------------------------------------------------------------------------------------------------------"
for pair in "${FILTERS[@]}"; do
  F="${pair%%|*}"; L="${pair##*|}"
  M=$(sql "SELECT count(*) FROM item WHERE $F")
  P=$(sql "SELECT round(100.0*$M/$NITEM,1)")
  Q="$(q "$F")"
  printf "%-14s %8s %9s%%  %-34s %-26s %10s\n" \
    "$L" "$M" "$P" "$(driver_of "$Q")" "$(methods_of "$Q")" "$(best_ms "$Q")"
done
echo

# ── 다이어그램이 예측한 진입점을 강제로 막아본다 ──────────────────────
# 강한 필터에서만 손해가 나는지 확인하려면 **약한 필터 쪽도 같이 재야** 한다.
# 강한 쪽만 재고 "약한 쪽은 어차피 같겠지"라고 쓰면 그건 측정이 아니라 추측이다.
best_noNL() {
  local Q="$1" b="" v
  sql "SET enable_nestloop=off; EXPLAIN (ANALYZE) $Q" >/dev/null 2>&1
  for _ in $(seq "$REPEAT"); do
    v=$(ms_of "$(sql "SET enable_nestloop=off; EXPLAIN (ANALYZE) $Q")")
    [ -z "$b" ] && b="$v" || b=$(awk -v a="$b" -v c="$v" 'BEGIN{print (c+0<a+0)?c:a}')
  done
  echo "$b"
}

echo "── 검증: NL 진입을 막으면 어디서 손해가 나는가 ──"
printf "%-24s %12s %12s %8s\n" "필터" "자연 계획" "NL 금지" "배수"
printf "%s\n" "-----------------------------------------------------------"
for pair in "i_manager_id = 8|= 8 (1%)" \
            "i_manager_id between 1 and 10|1~10 (10%)" \
            "i_manager_id between 1 and 100|1~100 (100%)"; do
  F="${pair%%|*}"; L="${pair##*|}"
  QS="$(q "$F")"
  NAT=$(best_ms "$QS"); BLK=$(best_noNL "$QS")
  printf "%-24s %10s ms %10s ms %7sx\n" "$L" "$NAT" "$BLK" \
         "$(awk -v a="$NAT" -v b="$BLK" 'BEGIN{printf "%.2f", b/a}')"
done
echo

echo "해석:"
echo "  · 필터가 강할 때(1%) 옵티마이저는 item 에서 출발해 NL 로 store_sales 를 찔러 들어간다."
echo "    이때 쓰이는 인덱스는 store_sales_pkey(ss_item_sk, ss_ticket_number) 의 선행 컬럼이다 —"
echo "    다이어그램이 '아이템에서 내려가라'고 말한 그 경로가 실재한다."
echo "  · 필터를 약화시키면 진입점이 **date_dim 으로 옮겨가고**, 더 약화되면 NL 이 전부"
echo "    Hash 로 바뀌며 차원 테이블들이 Seq Scan 이 된다."
echo "    → '조인 순서는 필터 비율이 정한다'(Tow 6장)의 직접 관측."
echo "  · 다만 NL 이 **완전히 사라지지는 않는다.** 무필터 구간에서도 조인 방식 열에"
echo "    'Loop ×1' 이 남는다 — date_dim(60행) → store_sales 를 idx_ss_sold_date 로"
echo "    찔러 들어가는 그 하나다. 그래서 NL 을 금지하면 무필터에서도 손해가 난다."
echo "    손해 배수는 5.4x → 3.5x → 2.0x 로 **줄어들 뿐 0 이 되지 않는다.**"
echo "    (\"약한 구간에서는 어차피 Hash 니 차이 없겠지\"라고 먼저 써 뒀다가 측정에서 뒤집혔다)"
echo "  · 주의: 이 표의 시간은 **최소값**이다. 1회 측정은 캐시 상태를 재는 것이라"
echo "    최강 필터 구간이 오히려 제일 느리게 나오는 착시가 생긴다(실제로 겪었다, §T-0 원칙 ④)."
