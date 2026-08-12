package com.tuninglab.sysbench;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * sysbench oltp_read_write 와 유사한 트랜잭션 믹스:
 *   point select x10, range select x1, index update x1, non-index update x1,
 *   delete+insert x1  (모두 한 트랜잭션)
 *
 * 튜닝 관찰 포인트:
 *  - innodb_buffer_pool_size 대비 데이터 크기 → hit ratio, 디스크 read
 *  - hot-row 모드(--hot=true)로 특정 행에 갱신 집중 → row lock 경합 관찰
 *  - innodb_flush_log_at_trx_commit 0/1/2 에 따른 TPS 차이
 */
public class OltpWorkload {

    private static final Logger log = LoggerFactory.getLogger(OltpWorkload.class);

    private final DataSource dataSource;
    private final int tables;
    private final long tableSize;
    private final boolean hotRow;

    public OltpWorkload(DataSource dataSource, int tables, long tableSize, boolean hotRow) {
        this.dataSource = dataSource;
        this.tables = tables;
        this.tableSize = tableSize;
        this.hotRow = hotRow;
    }

    public void run(int threads, int seconds) throws InterruptedException {
        AtomicBoolean stop = new AtomicBoolean(false);
        AtomicLong committed = new AtomicLong();
        AtomicLong errors = new AtomicLong();
        List<Long> latenciesMicro = java.util.Collections.synchronizedList(new ArrayList<>());

        ExecutorService pool = Executors.newFixedThreadPool(threads);
        for (int i = 0; i < threads; i++) {
            pool.submit(() -> {
                try (Connection conn = dataSource.getConnection()) {
                    conn.setAutoCommit(false);
                    while (!stop.get()) {
                        long start = System.nanoTime();
                        try {
                            transaction(conn);
                            conn.commit();
                            committed.incrementAndGet();
                            latenciesMicro.add((System.nanoTime() - start) / 1000);
                        } catch (SQLException e) {
                            try { conn.rollback(); } catch (SQLException ignore) { }
                            errors.incrementAndGet();
                        }
                    }
                } catch (SQLException e) {
                    log.error("worker died: {}", e.getMessage());
                }
                return null;
            });
        }

        long t0 = System.currentTimeMillis();
        Thread.sleep(seconds * 1000L);
        stop.set(true);
        pool.shutdown();
        pool.awaitTermination(30, TimeUnit.SECONDS);
        double elapsed = (System.currentTimeMillis() - t0) / 1000.0;

        List<Long> lat = new ArrayList<>(latenciesMicro);
        lat.sort(Long::compareTo);
        log.info("========== OLTP_RW RESULT ==========");
        log.info("threads={}, duration={}s, tables={}, tableSize={}, hotRow={}",
                threads, seconds, tables, tableSize, hotRow);
        log.info("committed={}, errors(incl. lock wait)={}, TPS={}", committed.get(), errors.get(),
                String.format("%.1f", committed.get() / elapsed));
        if (!lat.isEmpty()) {
            log.info("latency avg={}ms p50={}ms p95={}ms p99={}ms max={}ms",
                    ms(lat.stream().mapToLong(Long::longValue).sum() / lat.size()),
                    ms(lat.get(lat.size() / 2)),
                    ms(lat.get((int) (lat.size() * 0.95))),
                    ms(lat.get((int) (lat.size() * 0.99))),
                    ms(lat.get(lat.size() - 1)));
        }
    }

    private void transaction(Connection conn) throws SQLException {
        ThreadLocalRandom rnd = ThreadLocalRandom.current();
        String table = "sbtest" + (1 + rnd.nextInt(tables));

        // point selects x10
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT c FROM " + table + " WHERE id = ?")) {
            for (int i = 0; i < 10; i++) {
                ps.setLong(1, nextId(rnd));
                try (ResultSet rs = ps.executeQuery()) { rs.next(); }
            }
        }
        // range select
        long rangeStart = nextId(rnd);
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT c FROM " + table + " WHERE id BETWEEN ? AND ?")) {
            ps.setLong(1, rangeStart);
            ps.setLong(2, rangeStart + 99);
            try (ResultSet rs = ps.executeQuery()) { while (rs.next()) { rs.getString(1); } }
        }
        // index update (k 컬럼: 보조 인덱스 갱신 비용)
        try (PreparedStatement ps = conn.prepareStatement(
                "UPDATE " + table + " SET k = k + 1 WHERE id = ?")) {
            ps.setLong(1, nextId(rnd));
            ps.executeUpdate();
        }
        // non-index update
        try (PreparedStatement ps = conn.prepareStatement(
                "UPDATE " + table + " SET c = ? WHERE id = ?")) {
            ps.setString(1, "updated-" + rnd.nextInt(1_000_000));
            ps.setLong(2, nextId(rnd));
            ps.executeUpdate();
        }
        // delete + insert (same id)
        long id = nextId(rnd);
        try (PreparedStatement ps = conn.prepareStatement(
                "DELETE FROM " + table + " WHERE id = ?")) {
            ps.setLong(1, id);
            ps.executeUpdate();
        }
        try (PreparedStatement ps = conn.prepareStatement(
                "INSERT IGNORE INTO " + table + " (id, k, c, pad) VALUES (?, ?, 'reinserted', '')")) {
            ps.setLong(1, id);
            ps.setLong(2, rnd.nextLong(tableSize) + 1);
            ps.executeUpdate();
        }
    }

    private long nextId(ThreadLocalRandom rnd) {
        if (hotRow) {
            // 상위 100개 행에 90% 집중 → row lock 경합 유발
            return rnd.nextInt(10) < 9 ? 1 + rnd.nextLong(100) : 1 + rnd.nextLong(tableSize);
        }
        return 1 + rnd.nextLong(tableSize);
    }

    private String ms(long micros) {
        return String.format("%.2f", micros / 1000.0);
    }
}
