package com.tuninglab.tpcds;

import com.tuninglab.common.Args;
import com.tuninglab.common.DataFiles;
import com.tuninglab.common.DataSources;
import com.tuninglab.common.DelimitedFileLoader;
import com.tuninglab.common.Dialect;
import com.tuninglab.common.QueryResourceRunner;
import com.tuninglab.common.SchemaCheck;
import com.tuninglab.common.SqlScriptRunner;
import com.tuninglab.common.Statistics;
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

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * TPC-DS (OLAP / DW) 튜닝 실습 CLI.
 *
 * 사용 예)
 *   ./gradlew :tpcds:bootRun --args="schema   --db=postgres"
 *   ./gradlew :tpcds:bootRun --args="generate --sales=1000000 --dir=./data/tpcds"
 *   ./gradlew :tpcds:bootRun --args="load     --db=postgres --dir=./data/tpcds"
 *   ./gradlew :tpcds:bootRun --args="index    --db=postgres"
 *   ./gradlew :tpcds:bootRun --args="run      --db=postgres --explain=true"
 */
@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)
public class TpcdsApplication implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(TpcdsApplication.class);

    // 로딩 순서(차원 → 팩트) : table -> column count
    private static final Map<String, Integer> TABLES = new LinkedHashMap<>();
    static {
        TABLES.put("date_dim", 28);
        TABLES.put("item", 22);
        TABLES.put("store", 29);
        TABLES.put("customer_address", 13);
        TABLES.put("customer_demographics", 9);
        TABLES.put("household_demographics", 5);
        TABLES.put("customer", 18);
        TABLES.put("promotion", 19);
        TABLES.put("store_sales", 23);
    }

    private final Environment env;

    public TpcdsApplication(Environment env) {
        this.env = env;
    }

    public static void main(String[] args) {
        System.exit(SpringApplication.exit(SpringApplication.run(TpcdsApplication.class, args)));
    }

    @Override
    public void run(String... rawArgs) throws Exception {
        Args args = new Args(rawArgs);
        String db = args.get("db", "postgres");

        switch (args.command()) {
            case "generate" -> {
                long sales = (long) args.getDouble("sales", 1_000_000);
                Path dir = Path.of(args.get("dir", "./data/tpcds"));
                new TpcdsDataGenerator(sales, dir).generateAll();
            }
            case "schema" -> withJdbc(db, jdbc ->
                    new SqlScriptRunner(jdbc).run(new ClassPathResource("sql/schema-" + db + ".sql")));
            case "index" -> withJdbc(db, jdbc -> {
                if (!SchemaCheck.ready(jdbc, dialect(db), TABLES.keySet(), "tpcds", db, "store_sales")) {
                    return;
                }
                log.warn("주의: 이 명령은 '인덱스 생성'과 '통계 갱신(ANALYZE)'을 함께 수행한다.");
                log.warn("      두 효과를 분리하려면 analyze 명령으로 통계만 먼저 갱신하고 측정할 것.");
                new SqlScriptRunner(jdbc).run(new ClassPathResource("sql/indexes-" + db + ".sql"));
            });
            case "analyze" -> withJdbc(db, jdbc ->
                    Statistics.analyze(jdbc, dialect(db), TABLES.keySet()));
            case "vacuum" -> withJdbc(db, jdbc ->
                    Statistics.vacuumAnalyze(jdbc, dialect(db), TABLES.keySet()));
            case "load" -> {
                Path dir = Path.of(args.get("dir", "./data/tpcds"));
                int batch = args.getInt("batch", 5000);
                withJdbc(db, jdbc -> {
                    DelimitedFileLoader loader = new DelimitedFileLoader(jdbc, dialect(db), '|', batch);
                    TABLES.forEach((table, cols) -> {
                        // dsdgen -parallel 로 쪼개진 store_sales_1_4.dat 같은 파일도 모두 적재
                        List<Path> files = DataFiles.findDat(dir, table);
                        if (files.isEmpty()) {
                            log.warn("Skip {} (no {}*.dat in {})", table, table, dir);
                            return;
                        }
                        long rows = 0;
                        for (Path file : files) {
                            rows += loader.load(file, table, cols);
                        }
                        if (files.size() > 1) {
                            log.info("{} <- {} rows total from {} files", table, rows, files.size());
                        }
                    });
                });
            }
            case "run" -> {
                String query = args.get("query", null);
                int warmup = args.getInt("warmup", 1);
                int iterations = args.getInt("iterations", 3);
                boolean explain = args.getBool("explain", false);
                withJdbc(db, jdbc -> {
                    if (!SchemaCheck.ready(jdbc, dialect(db), TABLES.keySet(),
                            "tpcds", db, "store_sales")) {
                        return;
                    }
                    new QueryResourceRunner(jdbc, dialect(db), "classpath:queries/*.sql")
                            .runAll(query, warmup, iterations, explain);
                });
            }
            default -> log.info("""

                    Commands:
                      generate --sales=1000000 --dir=./data/tpcds   샘플 데이터(.dat) 생성
                      schema   --db=postgres|mysql                  스키마 생성(DROP 후 재생성)
                      load     --db=postgres|mysql --dir=...        데이터 적재 (dsdgen .dat 도 호환)
                      analyze  --db=postgres|mysql                  통계만 갱신 (인덱스 효과와 분리 측정용)
                      vacuum   --db=postgres|mysql                  VACUUM ANALYZE (통계 + visibility map)
                      index    --db=postgres|mysql                  인덱스 생성 + 통계 갱신
                      run      --db=... [--query=q03_brand_by_year] [--warmup=1] [--iterations=3] [--explain=true]
                    """);
        }
    }

    private Dialect dialect(String db) {
        return "mysql".equals(db) ? Dialect.MYSQL : Dialect.POSTGRES;
    }

    private void withJdbc(String db, java.util.function.Consumer<JdbcTemplate> work) {
        String prefix = "tpcds.datasource." + db + ".";
        try (HikariDataSource ds = DataSources.create(
                env.getRequiredProperty(prefix + "url"),
                env.getRequiredProperty(prefix + "username"),
                env.getRequiredProperty(prefix + "password"), 4)) {
            work.accept(new JdbcTemplate(ds));
        }
    }
}
