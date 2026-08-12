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
                case "run" -> new TpcbWorkload(ds, scale)
                        .run(args.getInt("clients", 8), args.getInt("seconds", 30));
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
                          monitor                               buffer hit/HOT/checkpoint/락 대기 지표 출력
                          reset-stats                           통계 초기화 (실험 전 실행 권장)
                        """);
            }
        }
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
