package com.tuninglab.pgbench;

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
 * pgbench 기본 스크립트(TPC-B 계열)와 동일한 트랜잭션을 멀티스레드로 실행한다.
 *
 *   BEGIN;
 *   UPDATE pgbench_accounts SET abalance = abalance + :delta WHERE aid = :aid;
 *   SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
 *   UPDATE pgbench_tellers  SET tbalance = tbalance + :delta WHERE tid = :tid;
 *   UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
 *   INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (...);
 *   COMMIT;
 *
 * 튜닝 관찰 포인트:
 *  - clients 를 늘리면 branches(스케일당 1행) UPDATE 에서 row lock 경합 발생
 *  - synchronous_commit off/on 에 따른 TPS 차이 (WAL flush)
 *  - fillfactor 와 n_tup_hot_upd (HOT 업데이트 비율)
 */
public class TpcbWorkload {

    private static final Logger log = LoggerFactory.getLogger(TpcbWorkload.class);

    private final DataSource dataSource;
    private final int scale;
    /** null 이면 서버 기본값을 그대로 쓴다. 실험 때만 세션에 건다. */
    private final Boolean syncCommit;

    public TpcbWorkload(DataSource dataSource, int scale) {
        this(dataSource, scale, null);
    }

    public TpcbWorkload(DataSource dataSource, int scale, Boolean syncCommit) {
        this.dataSource = dataSource;
        this.scale = scale;
        this.syncCommit = syncCommit;
    }

    public void run(int clients, int seconds) throws InterruptedException {
        AtomicBoolean stop = new AtomicBoolean(false);
        AtomicLong committed = new AtomicLong();
        AtomicLong errors = new AtomicLong();
        // **죽은 워커를 센다.** 예전에는 catch 에서 로그만 찍고 끝이라, 워커가 절반 죽어도
        // errors=0 에 TPS 가 멀쩡히 찍혔다. 실측(32코어, clients=256): 56개가
        // "Connection is not available" 로 죽었는데 errors=0, TPS=12,820 이었다.
        AtomicLong died = new AtomicLong();
        List<Long> latenciesMicro = java.util.Collections.synchronizedList(new ArrayList<>());

        ExecutorService pool = Executors.newFixedThreadPool(clients);
        for (int c = 0; c < clients; c++) {
            pool.submit(() -> {
                try (Connection conn = dataSource.getConnection()) {
                    // 세션 단위로만 건다 — 서버 설정을 바꾸지 않으므로 재시작도 원복도 없다.
                    // (shared_buffers 와 달리 synchronous_commit 은 세션에서 바꿀 수 있다.)
                    if (syncCommit != null) {
                        try (var st = conn.createStatement()) {
                            st.execute("SET synchronous_commit = " + (syncCommit ? "on" : "off"));
                        }
                    }
                    conn.setAutoCommit(false);
                    while (!stop.get()) {
                        long start = System.nanoTime();
                        try {
                            transaction(conn);
                            conn.commit();
                            committed.incrementAndGet();
                            latenciesMicro.add((System.nanoTime() - start) / 1000);
                        } catch (SQLException e) {
                            conn.rollback();
                            errors.incrementAndGet();
                        }
                    }
                } catch (SQLException e) {
                    died.incrementAndGet();
                    // 워커마다 한 줄씩 찍으면 수백 줄이 쏟아져 결과가 파묻힌다. 첫 줄만 남긴다.
                    if (died.get() == 1) log.error("worker died: {}", e.getMessage());
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
        log.info("========== TPC-B RESULT ==========");
        log.info("clients={}, duration={}s, scale={}, synchronous_commit={}", clients, seconds, scale,
                syncCommit == null ? "(서버 기본값)" : (syncCommit ? "on" : "off"));
        log.info("committed={}, errors={}, TPS={}", committed.get(), errors.get(),
                String.format("%.1f", committed.get() / elapsed));
        // 죽은 워커가 있으면 **이 줄은 측정이 아니다.** 살아 있던 워커 수가 중간에 줄었으므로
        // 'clients=N 의 처리량'이라고 부를 수 없고, 그대로 표에 넣으면 무릎처럼 보인다.
        if (died.get() > 0) {
            log.error("[무효] 워커 {}/{} 가 도중에 죽었다 — 위 TPS 는 clients={} 의 측정이 아니다.",
                    died.get(), clients, clients);
            log.error("       죽은 워커는 errors 에 안 잡힌다(커넥션을 못 얻어 트랜잭션을 시작도 못 했다).");
            log.error("       대개 원인은 커넥션 풀/서버 상한이다: SHOW max_connections;");
        }
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
        long aid = 1 + rnd.nextLong(scale * 100_000L);
        int tid = 1 + rnd.nextInt(scale * 10);
        int bid = 1 + rnd.nextInt(scale);
        int delta = rnd.nextInt(-5000, 5001);

        try (PreparedStatement ps = conn.prepareStatement(
                "UPDATE pgbench_accounts SET abalance = abalance + ? WHERE aid = ?")) {
            ps.setInt(1, delta);
            ps.setLong(2, aid);
            ps.executeUpdate();
        }
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT abalance FROM pgbench_accounts WHERE aid = ?")) {
            ps.setLong(1, aid);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
            }
        }
        try (PreparedStatement ps = conn.prepareStatement(
                "UPDATE pgbench_tellers SET tbalance = tbalance + ? WHERE tid = ?")) {
            ps.setInt(1, delta);
            ps.setInt(2, tid);
            ps.executeUpdate();
        }
        try (PreparedStatement ps = conn.prepareStatement(
                "UPDATE pgbench_branches SET bbalance = bbalance + ? WHERE bid = ?")) {
            ps.setInt(1, delta);
            ps.setInt(2, bid);
            ps.executeUpdate();
        }
        try (PreparedStatement ps = conn.prepareStatement(
                "INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (?, ?, ?, ?, now())")) {
            ps.setInt(1, tid);
            ps.setInt(2, bid);
            ps.setLong(3, aid);
            ps.setInt(4, delta);
            ps.executeUpdate();
        }
    }

    private String ms(long micros) {
        return String.format("%.2f", micros / 1000.0);
    }
}
