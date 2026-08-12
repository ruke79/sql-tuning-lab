package com.tuninglab.sysbench;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;

import java.sql.PreparedStatement;
import java.util.List;
import java.util.concurrent.ThreadLocalRandom;
import java.util.stream.LongStream;

/**
 * sysbench oltp_* 와 동일한 구조의 테이블(sbtest1..N)을 생성/적재한다.
 *
 *   CREATE TABLE sbtest{n} (
 *     id  BIGINT NOT NULL AUTO_INCREMENT,
 *     k   BIGINT NOT NULL DEFAULT 0,
 *     c   CHAR(120) NOT NULL DEFAULT '',
 *     pad CHAR(60)  NOT NULL DEFAULT '',
 *     PRIMARY KEY (id), KEY k_{n} (k)
 *   )
 *
 * 1억 건 구성: --tables=10 --table-size=10000000 (RAW 약 24GB)
 */
public class SysbenchTables {

    private static final Logger log = LoggerFactory.getLogger(SysbenchTables.class);

    private final JdbcTemplate jdbc;

    public SysbenchTables(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public void prepare(int tables, long tableSize) {
        for (int t = 1; t <= tables; t++) {
            String table = "sbtest" + t;
            log.info("Creating {} ({} rows)...", table, tableSize);
            jdbc.execute("DROP TABLE IF EXISTS " + table);
            jdbc.execute("""
                    CREATE TABLE %s (
                      id  BIGINT NOT NULL AUTO_INCREMENT,
                      k   BIGINT NOT NULL DEFAULT 0,
                      c   CHAR(120) NOT NULL DEFAULT '',
                      pad CHAR(60)  NOT NULL DEFAULT '',
                      PRIMARY KEY (id),
                      KEY k_%d (k)
                    ) ENGINE=InnoDB
                    """.formatted(table, t));
            fill(table, tableSize);
            jdbc.execute("ANALYZE TABLE " + table);
        }
        log.info("prepare done ({} tables x {} rows)", tables, tableSize);
    }

    private void fill(String table, long tableSize) {
        long start = System.currentTimeMillis();
        int batchSize = 10_000;
        String sql = "INSERT INTO " + table + " (id, k, c, pad) VALUES (?, ?, ?, ?)";
        for (long offset = 0; offset < tableSize; offset += batchSize) {
            long from = offset + 1;
            long to = Math.min(offset + batchSize, tableSize);
            List<Long> ids = LongStream.rangeClosed(from, to).boxed().toList();
            jdbc.batchUpdate(sql, ids, batchSize, (PreparedStatement ps, Long id) -> {
                ThreadLocalRandom rnd = ThreadLocalRandom.current();
                ps.setLong(1, id);
                ps.setLong(2, rnd.nextLong(tableSize) + 1);
                ps.setString(3, randomString(rnd, 119));
                ps.setString(4, randomString(rnd, 59));
            });
            if (to % 1_000_000 == 0) {
                log.info("{}: {}/{} ({} rows/s)", table, to, tableSize,
                        to * 1000 / Math.max(1, System.currentTimeMillis() - start));
            }
        }
    }

    /** sysbench 스타일 '###########-###########-...' 숫자 문자열 */
    private String randomString(ThreadLocalRandom rnd, int len) {
        StringBuilder sb = new StringBuilder(len);
        for (int i = 0; i < len; i++) {
            sb.append(i % 12 == 11 ? '-' : (char) ('0' + rnd.nextInt(10)));
        }
        return sb.toString();
    }
}
