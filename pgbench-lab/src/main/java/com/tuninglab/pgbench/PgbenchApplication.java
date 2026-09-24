package com.tuninglab.pgbench;

import com.tuninglab.common.Args;
import com.tuninglab.common.DataSources;
import com.tuninglab.common.SqlScriptRunner;
import com.zaxxer.hikari.HikariDataSource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration;
import org.springframework.core.env.Environment;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;

import java.sql.PreparedStatement;

/**
 * pgbench (OLTP / TPC-B 계열) 튜닝 실습 CLI.
 *
 * 사용 예)
 *   ./gradlew :pgbench-lab:bootRun --args="init    --scale=10"       # accounts 100만 건
 *   ./gradlew :pgbench-lab:bootRun --args="run     --clients=8 --seconds=30 --scale=10"
 *   ./gradlew :pgbench-lab:bootRun --args="monitor"
 *   ./gradlew :pgbench-lab:bootRun --args="reset-stats"
 *
 * 1억 건 구성: --scale=1000 (accounts 1억 건, RAW 약 15GB) — 공식 pgbench -i -s 1000 권장
 */
@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)
public class PgbenchApplication implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(PgbenchApplication.class);

    private final Environment env;

    public PgbenchApplication(Environment env) {
        this.env = env;
    }

    public static void main(String[] args) {
        System.exit(SpringApplication.exit(SpringApplication.run(PgbenchApplication.class, args)));
    }

    @Override
    public void run(String... rawArgs) throws Exception {
        Args args = new Args(rawArgs);
        int scale = args.getInt("scale", 10);

        try (HikariDataSource ds = DataSources.create(
                env.getRequiredProperty("pgbench.datasource.url"),
                env.getRequiredProperty("pgbench.datasource.username"),
                env.getRequiredProperty("pgbench.datasource.password"),
                Math.max(4, args.getInt("clients", 8) + 2))) {

            JdbcTemplate jdbc = new JdbcTemplate(ds);

            switch (args.command()) {
                case "init" -> {
                    new SqlScriptRunner(jdbc).run(new ClassPathResource("sql/schema.sql"));
                    fill(jdbc, scale);
                }
                case "run" -> {
                    // --scale 은 **적재 규모가 아니라 키를 뽑는 범위**다. 적재된 것과 다르면
                    // 에러 없이 다른 것을 재게 되므로, 다르면 여기서 멈추고 뜻을 물어본다.
                    if (checkScale(jdbc, scale, args.getInt("force", 0) == 1)
                            && checkConnections(jdbc, args.getInt("clients", 8),
                                                args.getInt("force", 0) == 1)) {
                        // --sync-commit=on|off 를 주면 그 값으로 세션에 건다(안 주면 서버 기본값).
                        // 서버 설정은 건드리지 않으므로 재시작도 원복도 필요 없다.
                        String sc = args.get("sync-commit", null);
                        Boolean syncCommit = (sc == null) ? null : sc.equalsIgnoreCase("on");
                        new TpcbWorkload(ds, scale, syncCommit)
                                .run(args.getInt("clients", 8), args.getInt("seconds", 30));
                    }
                }
                case "monitor" -> new PgMonitor(jdbc).report();
                case "reset-stats" -> {
                    jdbc.execute("SELECT pg_stat_reset()");
                    try {
                        jdbc.execute("SELECT pg_stat_statements_reset()");
                    } catch (Exception e) {
                        log.warn("pg_stat_statements_reset failed: {}", e.getMessage());
                    }
                    log.info("statistics reset");
                }
                default -> log.info("""

                        Commands:
                          init        --scale=10                pgbench 스키마 생성 + 데이터 적재 (scale x 10만 accounts)
                          run         --clients=8 --seconds=30 --scale=10   TPC-B 트랜잭션 부하 실행
                                      --sync-commit=on|off   세션 단위 synchronous_commit (WAL flush 실험)
                                      --force=1              --scale 이 적재 규모와 달라도 강행
                          monitor                               buffer hit/HOT/checkpoint/락 대기 지표 출력
                          reset-stats                           통계 초기화 (실험 전 실행 권장)
                        """);
            }
        }
    }

    /**
     * run 의 --scale 이 실제 적재 규모와 맞는지 본다. 맞으면 true.
     *
     * <p>--scale 은 적재량이 아니라 <b>키를 뽑는 범위</b>다:
     * {@code aid = 1 + rnd(scale*100000)}, {@code tid = 1 + rnd(scale*10)}, {@code bid = 1 + rnd(scale)}.
     * 그래서 적재된 것과 다르면 <b>에러 하나 없이 다른 것을 재게 된다</b> — 어느 방향이든 나쁘다:
     *
     * <ul>
     *   <li>준 값이 더 크면 → 대부분의 UPDATE 가 0행을 맞춘다. 0행 UPDATE 는 에러가 아니므로
     *       {@code errors=0} 에 TPS 도 멀쩡히 찍히는데, 사실상 아무 일도 안 한 것이다.</li>
     *   <li>준 값이 더 작으면 → 워크로드가 앞쪽 일부에만 몰린다. 캐시에 다 들어가서 빨라지고,
     *       branches 행이 적어져 <b>행 락 경합</b>이 생긴다. 유효한 실험이지만 <b>다른 실험</b>이고,
     *       규모를 맞춘 실행과 나란히 놓고 비교하면 안 된다.</li>
     * </ul>
     *
     * <p>적재 규모는 pgbench_branches 의 행 수와 같다(fill 이 scale 개를 넣는다).
     */
    /**
     * **돌리기 전에 붙을 수 있는지 본다.** clients 를 늘리면 풀도 같이 커지는데(clients+2),
     * 서버의 max_connections 를 넘으면 Hikari 가 커넥션을 못 채우고 남은 워커들이
     * connectionTimeout(10초) 뒤에 죽는다. 그런데 **그 죽음은 errors 에 안 잡힌다** —
     * 실측(32코어, clients=256, max_connections=200): 워커 56개가 죽었는데 errors=0,
     * TPS=12,820 이 찍혔고 표에서는 '256 에서 꺾였다'처럼 보였다. 20초를 다 쓰고 나서야
     * 알게 되는 일이라, 먼저 재고 먼저 말한다.
     *
     * max_connections 는 PostgreSQL 에서 **재시작이 필요한** 설정이라 여기서 올릴 수 없다.
     * 그래서 올려 주는 대신 멈추고, 무엇을 해야 하는지 말한다.
     */
    private boolean checkConnections(JdbcTemplate jdbc, int clients, boolean force) {
        Integer max, used;
        try {
            max = jdbc.queryForObject("SELECT setting::int FROM pg_settings WHERE name='max_connections'",
                    Integer.class);
            used = jdbc.queryForObject("SELECT count(*)::int FROM pg_stat_activity", Integer.class);
        } catch (Exception e) {
            log.warn("max_connections 를 못 읽었습니다 — 커넥션 사전 점검을 건너뜁니다 ({})", e.getMessage());
            return true;
        }
        if (max == null) return true;
        int need = clients + 2;
        // superuser_reserved_connections 만큼은 일반 사용자가 못 쓴다.
        Integer reserved = null;
        try {
            reserved = jdbc.queryForObject(
                    "SELECT setting::int FROM pg_settings WHERE name='superuser_reserved_connections'",
                    Integer.class);
        } catch (Exception ignore) { /* 없으면 0 으로 본다 */ }
        int usable = max - (reserved == null ? 0 : reserved) - (used == null ? 0 : used);
        if (need <= usable) return true;

        log.error("clients={} 이면 커넥션이 {}개 필요한데 지금 쓸 수 있는 것은 약 {}개입니다.",
                clients, need, Math.max(0, usable));
        log.error("  max_connections={} / 이미 사용 중 {} / superuser 예약 {}",
                max, used, reserved == null ? 0 : reserved);
        log.error("  이대로 돌리면 남는 워커가 커넥션을 못 얻어 10초 뒤에 죽습니다.");
        log.error("  **그리고 죽은 워커는 errors 에 안 잡힙니다** — errors=0 에 TPS 가 멀쩡히 찍히고,");
        log.error("  표에서는 '이 지점에서 꺾였다'처럼 보입니다. 측정이 아니라 풀이 막힌 것입니다.");
        log.error("  늘리려면 (재시작 필요): ALTER SYSTEM SET max_connections = {}; 뒤 서버 재시작",
                need + (reserved == null ? 0 : reserved) + 20);
        log.error("  그냥 돌려 보려면: --force=1  (결과는 측정으로 쓰지 마세요)");
        return force;
    }

    private boolean checkScale(JdbcTemplate jdbc, int scale, boolean force) {
        Integer loaded;
        try {
            loaded = jdbc.queryForObject("SELECT count(*) FROM pgbench_branches", Integer.class);
        } catch (Exception e) {
            log.error("pgbench_branches 를 읽지 못했습니다 — 먼저 적재하세요: init --scale=N ({})", e.getMessage());
            return false;
        }
        if (loaded == null || loaded == 0) {
            log.error("pgbench_branches 가 비어 있습니다 — 먼저 적재하세요: init --scale=N");
            return false;
        }
        if (loaded == scale) return true;

        log.error("--scale={} 인데 적재된 규모는 {} 입니다. --scale 은 적재량이 아니라 키 범위입니다.",
                scale, loaded);
        if (scale > loaded) {
            log.error("  준 값이 더 큽니다 → UPDATE 의 약 {}% 가 0행을 맞춥니다.",
                    String.format("%.1f", 100.0 * (scale - loaded) / scale));
            log.error("  0행 UPDATE 는 에러가 아니라서 errors=0 에 TPS 도 찍히지만, 사실상 아무 일도 안 합니다.");
        } else {
            log.error("  준 값이 더 작습니다 → 워크로드가 앞쪽 1/{} 에만 몰립니다.", loaded / scale);
            log.error("  캐시에 다 들어가 빨라지고, branches 행이 {}개뿐이라 행 락 경합이 생깁니다.", scale);
            log.error("  유효한 실험이지만 **다른 실험**입니다 — 규모를 맞춘 실행과 나란히 비교하지 마세요.");
        }
        log.error("  맞추려면: run --scale={}", loaded);
        log.error("  일부러 어긋나게 돌리려면: run --scale={} --force=1", scale);
        return force;
    }

    /** pgbench -i 와 동일한 비율로 데이터 적재: branches=scale, tellers=scale*10, accounts=scale*100000 */
    private void fill(JdbcTemplate jdbc, int scale) {
        log.info("Filling scale={} (accounts {} rows)...", scale, scale * 100_000L);
        long start = System.currentTimeMillis();

        for (int b = 1; b <= scale; b++) {
            jdbc.update("INSERT INTO pgbench_branches (bid, bbalance) VALUES (?, 0)", b);
        }
        for (int t = 1; t <= scale * 10; t++) {
            jdbc.update("INSERT INTO pgbench_tellers (tid, bid, tbalance) VALUES (?, ?, 0)",
                    t, (t - 1) / 10 + 1);
        }

        long total = scale * 100_000L;
        int batchSize = 10_000;
        for (long offset = 0; offset < total; offset += batchSize) {
            long from = offset + 1;
            long to = Math.min(offset + batchSize, total);
            java.util.List<Long> ids = java.util.stream.LongStream.rangeClosed(from, to)
                    .boxed().toList();
            jdbc.batchUpdate("INSERT INTO pgbench_accounts (aid, bid, abalance, filler) VALUES (?, ?, 0, '')",
                    ids, batchSize, (PreparedStatement ps, Long aid) -> {
                        ps.setLong(1, aid);
                        ps.setInt(2, (int) ((aid - 1) / 100_000) + 1);
                    });
            if (to % 1_000_000 == 0) {
                log.info("accounts: {}/{}", to, total);
            }
        }
        jdbc.execute("VACUUM ANALYZE");
        log.info("init done in {} s", (System.currentTimeMillis() - start) / 1000);
    }
}
