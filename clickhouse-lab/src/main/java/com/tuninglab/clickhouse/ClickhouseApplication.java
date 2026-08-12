package com.tuninglab.clickhouse;

import com.tuninglab.common.Args;
import com.tuninglab.common.DataSources;
import com.tuninglab.common.Dialect;
import com.tuninglab.common.QueryResourceRunner;
import com.tuninglab.common.SchemaCheck;
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

import java.time.LocalDate;

/**
 * GitHub Archive (ClickHouse Columnar OLAP) 튜닝 실습 CLI.
 *
 * 사용 예)
 *   ./gradlew :clickhouse-lab:bootRun --args="schema"
 *   ./gradlew :clickhouse-lab:bootRun --args="load --from=2024-01-01 --to=2024-01-01 --hours=0-5"
 *   ./gradlew :clickhouse-lab:bootRun --args="run  --explain=true"
 *   ./gradlew :clickhouse-lab:bootRun --args="experiment --name=compression"
 *   ./gradlew :clickhouse-lab:bootRun --args="experiment --name=mv"
 *   ./gradlew :clickhouse-lab:bootRun --args="experiment --name=orderby"
 *   ./gradlew :clickhouse-lab:bootRun --args="compare-compression"
 *
 * 1억 건: 약 30일치 로드 (--from=2024-01-01 --to=2024-01-30 --hours=0-23)
 * 30억 건+: ClickHouse 공식 github_events s3 데이터셋 사용 (scripts/clickhouse 참고)
 */
@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)
public class ClickhouseApplication implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(ClickhouseApplication.class);

    private final Environment env;

    public ClickhouseApplication(Environment env) {
        this.env = env;
    }

    public static void main(String[] args) {
        System.exit(SpringApplication.exit(SpringApplication.run(ClickhouseApplication.class, args)));
    }

    @Override
    public void run(String... rawArgs) throws Exception {
        Args args = new Args(rawArgs);

        try (HikariDataSource ds = DataSources.create(
                env.getRequiredProperty("clickhouse.datasource.url"),
                env.getRequiredProperty("clickhouse.datasource.username"),
                env.getRequiredProperty("clickhouse.datasource.password"), 4)) {

            JdbcTemplate jdbc = new JdbcTemplate(ds);

            switch (args.command()) {
                case "schema" -> new SqlScriptRunner(jdbc).run(new ClassPathResource("sql/schema.sql"));
                case "load" -> {
                    LocalDate from = LocalDate.parse(args.get("from", "2024-01-01"));
                    LocalDate to = LocalDate.parse(args.get("to", from.toString()));
                    String[] hours = args.get("hours", "0-23").split("-");
                    int hourFrom = Integer.parseInt(hours[0]);
                    int hourTo = Integer.parseInt(hours[hours.length - 1]);
                    new GhArchiveLoader(ds, env.getProperty("gharchive.base-url",
                            "https://data.gharchive.org"))
                            .load(from, to, hourFrom, hourTo, args.getInt("batch", 20_000));
                }
                case "run" -> {
                    if (SchemaCheck.clickhouseReady(jdbc, "gharchive", "github_events")) {
                        new QueryResourceRunner(jdbc, Dialect.CLICKHOUSE, "classpath:queries/*.sql")
                                .runAll(args.get("query", null), args.getInt("warmup", 1),
                                        args.getInt("iterations", 3), args.getBool("explain", false));
                    }
                }
                case "experiment" -> {
                    if (!SchemaCheck.clickhouseReady(jdbc, "gharchive", "github_events")) {
                        break;
                    }
                    String name = args.get("name", "compression");
                    String script = switch (name) {
                        case "compression" -> "sql/compression-variants.sql";
                        case "mv" -> "sql/materialized-view.sql";
                        case "orderby" -> "sql/schema-orderby-variant.sql";
                        default -> throw new IllegalArgumentException("unknown experiment: " + name);
                    };
                    new SqlScriptRunner(jdbc).run(new ClassPathResource(script));
                    if (name.equals("orderby")) {
                        log.info("적재: INSERT INTO gharchive.github_events_by_time SELECT * FROM gharchive.github_events");
                        jdbc.execute("INSERT INTO gharchive.github_events_by_time SELECT * FROM gharchive.github_events");
                    }
                    log.info("experiment '{}' 준비 완료", name);
                }
                case "compare-compression" -> new CompressionReport(jdbc).report();
                default -> log.info("""

                        Commands:
                          schema                                        gharchive.github_events 테이블 생성
                          load  --from=2024-01-01 --to=2024-01-02 --hours=0-23   GH Archive 다운로드+적재
                          run   [--query=q01_top_starred_repos] [--explain=true]  분석 쿼리 벤치마크
                          experiment --name=compression|mv|orderby      비교 실험용 테이블 준비
                          compare-compression                           LZ4/ZSTD 압축률+스캔 시간 비교
                        """);
            }
        }
    }
}
