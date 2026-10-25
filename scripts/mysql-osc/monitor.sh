#!/usr/bin/env bash
# scripts/mysql-osc 전용 — primary 를 몇 초마다 재서 실시간으로 찍는다.
#
# 왜 필요한가. gh-ost 의 진행률 로그(Copy/Applied/ETA)는 **백필이 얼마나 갔는지**는
# 보여주지만 **왜 느린지**는 안 보여준다. 버퍼풀이 모자란 건지(히트율이 낮다),
# fsync 가 병목인지(초당 fsync 수가 높다), 그냥 동시성이 많은 건지(Threads_running)
# 는 SHOW GLOBAL STATUS 를 구간별로 재야 보인다. 이 스크립트는 그 구간값을 찍는다.
#
# 사용법 — t-online-ddl.sh 와 **별도 터미널**에서:
#   ./scripts/mysql-osc/monitor.sh            # 2초 간격
#   INTERVAL=5 ./scripts/mysql-osc/monitor.sh # 5초 간격
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

INTERVAL="${INTERVAL:-2}"

# SHOW GLOBAL STATUS 를 한 번에 모아 받아서 필요한 키만 뽑는다 — 쿼리 왕복을 줄인다.
snap() {
  P "SHOW GLOBAL STATUS WHERE Variable_name IN (
    'Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads',
    'Innodb_buffer_pool_pages_total','Innodb_buffer_pool_pages_free',
    'Innodb_buffer_pool_pages_dirty','Innodb_os_log_fsyncs',
    'Innodb_data_fsyncs','Threads_running','Com_commit','Innodb_rows_updated'
  );" 2>/dev/null
}

get() { echo "$1" | awk -v k="$2" '$1==k{print $2}'; }

printf "%-8s %7s %7s %8s %10s %8s %8s %6s %8s\n" \
  "시각" "히트%" "버퍼풀%" "dirty%" "fsync/s" "로그fsync/s" "commit/s" "활성" "UPDATE/s"
printf "%s\n" "--------------------------------------------------------------------------"

prev="$(snap)"
prev_t=$(date +%s%N)
while true; do
  sleep "$INTERVAL"
  cur="$(snap)"
  cur_t=$(date +%s%N)
  dt=$(awk -v a="$prev_t" -v b="$cur_t" 'BEGIN{print (b-a)/1000000000}')

  rr_p=$(get "$prev" Innodb_buffer_pool_read_requests); rr_c=$(get "$cur" Innodb_buffer_pool_read_requests)
  pr_p=$(get "$prev" Innodb_buffer_pool_reads);          pr_c=$(get "$cur" Innodb_buffer_pool_reads)
  fs_p=$(get "$prev" Innodb_data_fsyncs);                fs_c=$(get "$cur" Innodb_data_fsyncs)
  lfs_p=$(get "$prev" Innodb_os_log_fsyncs);             lfs_c=$(get "$cur" Innodb_os_log_fsyncs)
  cm_p=$(get "$prev" Com_commit);                        cm_c=$(get "$cur" Com_commit)
  upd_p=$(get "$prev" Innodb_rows_updated);              upd_c=$(get "$cur" Innodb_rows_updated)
  total=$(get "$cur" Innodb_buffer_pool_pages_total)
  free=$(get "$cur" Innodb_buffer_pool_pages_free)
  dirty=$(get "$cur" Innodb_buffer_pool_pages_dirty)
  running=$(get "$cur" Threads_running)

  # 히트율 = 1 - (이번 구간 물리읽기 증가분 / 이번 구간 논리읽기 증가분)
  hit=$(awk -v rrp="$rr_p" -v rrc="$rr_c" -v prp="$pr_p" -v prc="$pr_c" \
    'BEGIN{ d=rrc-rrp; p=prc-prp; if(d>0) printf "%.1f", (1-p/d)*100; else print "?" }')
  bp_used=$(awk -v t="$total" -v f="$free" 'BEGIN{ if(t>0) printf "%.1f", (t-f)*100/t; else print "?" }')
  dirty_pct=$(awk -v t="$total" -v d="$dirty" 'BEGIN{ if(t>0) printf "%.1f", d*100/t; else print "?" }')
  fsync_s=$(awk -v a="$fs_p" -v b="$fs_c" -v dt="$dt" 'BEGIN{ if(dt>0) printf "%.0f", (b-a)/dt; else print "?" }')
  lfsync_s=$(awk -v a="$lfs_p" -v b="$lfs_c" -v dt="$dt" 'BEGIN{ if(dt>0) printf "%.0f", (b-a)/dt; else print "?" }')
  commit_s=$(awk -v a="$cm_p" -v b="$cm_c" -v dt="$dt" 'BEGIN{ if(dt>0) printf "%.0f", (b-a)/dt; else print "?" }')
  upd_s=$(awk -v a="$upd_p" -v b="$upd_c" -v dt="$dt" 'BEGIN{ if(dt>0) printf "%.0f", (b-a)/dt; else print "?" }')

  printf "%-8s %6s%% %6s%% %7s%% %10s %8s %8s %6s %8s\n" \
    "$(date +%H:%M:%S)" "$hit" "$bp_used" "$dirty_pct" "$fsync_s" "$lfsync_s" "$commit_s" "${running:-?}" "$upd_s"

  prev="$cur"; prev_t="$cur_t"
done
