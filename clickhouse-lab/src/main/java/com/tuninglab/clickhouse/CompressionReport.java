package com.tuninglab.clickhouse;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Map;

/** LZ4 vs ZSTD 압축률/스캔 성능 비교 리포트. */
public class CompressionReport {

    private static final Logger log = LoggerFactory.getLogger(CompressionReport.class);

    private final JdbcTemplate jdbc;

    public CompressionReport(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public void report() {
        log.info("---- Table sizes (compressed vs uncompressed) ----");
        List<Map<String, Object>> tables = jdbc.queryForList("""
                SELECT table,
                       formatReadableSize(sum(data_compressed_bytes)) AS compressed,
                       formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
                       round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS ratio,
                       sum(rows) AS rows
                FROM system.parts
                WHERE database = 'gharchive' AND active
                GROUP BY table
                ORDER BY table
                """);
        tables.forEach(r -> log.info("{}", r));

        log.info("---- Column-level compression (github_events_lz4 vs _zstd) ----");
        List<Map<String, Object>> columns = jdbc.queryForList("""
                SELECT table, name AS column,
                       formatReadableSize(data_compressed_bytes) AS compressed,
                       formatReadableSize(data_uncompressed_bytes) AS uncompressed,
                       round(data_uncompressed_bytes / nullif(data_compressed_bytes, 0), 2) AS ratio
                FROM system.columns
                WHERE database = 'gharchive'
                  AND table IN ('github_events_lz4', 'github_events_zstd')
                ORDER BY name, table
                """);
        columns.forEach(r -> log.info("{}", r));

        log.info("---- Full scan timing (cold cache는 SYSTEM DROP UNCOMPRESSED CACHE 후) ----");
        for (String t : List.of("github_events_lz4", "github_events_zstd")) {
            try {
                long start = System.nanoTime();
                Long cnt = jdbc.queryForObject(
                        "SELECT count() FROM gharchive." + t + " WHERE title != ''", Long.class);
                log.info("{}: scan {} rows-with-title in {} ms", t, cnt,
                        String.format("%.0f", (System.nanoTime() - start) / 1_000_000.0));
            } catch (Exception e) {
                log.warn("{}: {}", t, e.getMessage());
            }
        }
    }
}
