package com.tuninglab.sysbench;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Map;

/** InnoDB Buffer Pool / Redo / Lock 경합 관찰 지표. */
public class InnodbMonitor {

    private static final Logger log = LoggerFactory.getLogger(InnodbMonitor.class);

    private final JdbcTemplate jdbc;

    public InnodbMonitor(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public void report() {
        section("Buffer pool stats (hit rate = 1 - reads/read_requests)", """
                SELECT POOL_ID, POOL_SIZE, FREE_BUFFERS, DATABASE_PAGES,
                       NUMBER_PAGES_READ, NUMBER_PAGES_WRITTEN,
                       PAGES_MADE_YOUNG, HIT_RATE
                FROM information_schema.INNODB_BUFFER_POOL_STATS
                """);

        section("Buffer pool read ratio (global status)", """
                SELECT VARIABLE_NAME, VARIABLE_VALUE
                FROM performance_schema.global_status
                WHERE VARIABLE_NAME IN
                  ('Innodb_buffer_pool_read_requests', 'Innodb_buffer_pool_reads',
                   'Innodb_log_waits', 'Innodb_os_log_written',
                   'Innodb_row_lock_waits', 'Innodb_row_lock_time_avg',
                   'Innodb_row_lock_current_waits')
                """);

        section("Current lock waits (부하 실행 중 별도 셸에서 monitor 실행 시 관찰)", """
                SELECT r.trx_id AS waiting_trx, r.trx_mysql_thread_id AS waiting_thread,
                       LEFT(r.trx_query, 60) AS waiting_query,
                       b.trx_id AS blocking_trx, b.trx_mysql_thread_id AS blocking_thread,
                       LEFT(b.trx_query, 60) AS blocking_query
                FROM performance_schema.data_lock_waits w
                JOIN information_schema.innodb_trx b
                  ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID
                JOIN information_schema.innodb_trx r
                  ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID
                """);

        section("Redo log settings", """
                SELECT VARIABLE_NAME, VARIABLE_VALUE
                FROM performance_schema.global_variables
                WHERE VARIABLE_NAME IN
                  ('innodb_redo_log_capacity', 'innodb_flush_log_at_trx_commit',
                   'innodb_buffer_pool_size', 'transaction_isolation')
                """);

        section("Table/index sizes", """
                SELECT TABLE_NAME,
                       ROUND(DATA_LENGTH / 1024 / 1024, 1) AS data_mb,
                       ROUND(INDEX_LENGTH / 1024 / 1024, 1) AS index_mb,
                       TABLE_ROWS
                FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = DATABASE()
                ORDER BY DATA_LENGTH DESC
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
