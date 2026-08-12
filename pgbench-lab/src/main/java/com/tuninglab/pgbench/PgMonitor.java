package com.tuninglab.pgbench;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Map;

/** OLTP 튜닝 관찰 지표 조회 (buffer hit / HOT update / checkpoint / index bloat). */
public class PgMonitor {

    private static final Logger log = LoggerFactory.getLogger(PgMonitor.class);

    private final JdbcTemplate jdbc;

    public PgMonitor(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public void report() {
        section("Buffer cache hit ratio (blks_hit / (blks_hit+blks_read))", """
                SELECT datname,
                       blks_read, blks_hit,
                       round(blks_hit * 100.0 / nullif(blks_hit + blks_read, 0), 2) AS hit_pct
                FROM pg_stat_database WHERE datname = current_database()
                """);

        section("HOT update ratio per table (fillfactor 튜닝 효과)", """
                SELECT relname, n_tup_upd, n_tup_hot_upd,
                       round(n_tup_hot_upd * 100.0 / nullif(n_tup_upd, 0), 2) AS hot_pct,
                       n_dead_tup, last_autovacuum
                FROM pg_stat_user_tables ORDER BY n_tup_upd DESC
                """);

        section("Checkpoint / bgwriter (WAL flush 압력, PG16 기준)", """
                SELECT checkpoints_timed, checkpoints_req,
                       checkpoint_write_time, checkpoint_sync_time,
                       buffers_checkpoint, buffers_clean, buffers_backend
                FROM pg_stat_bgwriter
                """);

        section("Index sizes & usage", """
                SELECT relname AS table, indexrelname AS index,
                       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
                       idx_scan, idx_tup_read
                FROM pg_stat_user_indexes ORDER BY pg_relation_size(indexrelid) DESC
                """);

        section("Top 10 queries by total time (pg_stat_statements)", """
                SELECT round(total_exec_time::numeric, 1) AS total_ms, calls,
                       round(mean_exec_time::numeric, 3) AS mean_ms,
                       left(query, 80) AS query
                FROM pg_stat_statements
                ORDER BY total_exec_time DESC LIMIT 10
                """);

        section("Lock waits (실행 중 다른 세션에서 조회해야 잡힘)", """
                SELECT pid, wait_event_type, wait_event, state, left(query, 60) AS query
                FROM pg_stat_activity
                WHERE wait_event_type IS NOT NULL AND pid <> pg_backend_pid()
                """);
    }

    private void section(String title, String sql) {
        log.info("---- {} ----", title);
        try {
            List<Map<String, Object>> rows = jdbc.queryForList(sql);
            if (rows.isEmpty()) {
                log.info("(no rows)");
            }
            rows.forEach(r -> log.info("{}", r));
        } catch (Exception e) {
            log.warn("query failed: {}", e.getMessage());
        }
    }
}
