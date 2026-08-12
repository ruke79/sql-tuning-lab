package com.tuninglab.tpch;

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
import java.util.Map;

/**
 * TPC-H (OLAP / DSS) 튜닝 실습 CLI.
 *
 * 사용 예)
 *   ./gradlew :tpch:bootRun --args="schema   --db=postgres"
 *   ./gradlew :tpch:bootRun --args="generate --sf=0.1 --dir=./data/tpch"
 *   ./gradlew :tpch:bootRun --args="load     --db=postgres --dir=./data/tpch"
 *   ./gradlew :tpch:bootRun --args="run      --db=postgres --warmup=1 --iterations=3"
 *   ./gradlew :tpch:bootRun --args="run      --db=postgres --query=q03 --explain=true"
 *   ./gradlew :tpch:bootRun --args="index    --db=postgres"
 */
@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)
public class TpchApplication implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(TpchApplication.class);

    // 로딩 순서 중요(FK 참조 순) : table -> column count
    private static final Map<String, Integer> TABLES = new LinkedHashMap<>();
    static {
        TABLES.put("region", 3);
        TABLES.put("nation", 4);
        TABLES.put("supplier", 7);
        TABLES.put("customer", 8);
        TABLES.put("part", 9);
        TABLES.put("partsupp", 5);
        TABLES.put("orders", 9);
        TABLES.put("lineitem", 16);
    }

    private final Environment env;

    public TpchApplication(Environment env) {
        this.env = env;
    }

    public static void main(String[] args) {
        System.exit(SpringApplication.exit(SpringApplication.run(TpchApplication.class, args)));
    }

    @Override
    public void run(String... rawArgs) throws Exception {
        Args args = new Args(rawArgs);
        String db = args.get("db", "postgres");

        switch (args.command()) {
            case "generate" -> {
                double sf = args.getDouble("sf", 0.1);
                Path dir = Path.of(args.get("dir", "./data/tpch"));
                new TpchDataGenerator(sf, dir).generateAll();
            }
            case "schema" -> withJdbc(db, jdbc ->
                    new SqlScriptRunner(jdbc).run(new ClassPathResource("sql/schema-" + db + ".sql")));
            case "index" -> withJdbc(db, jdbc -> {
                if (!SchemaCheck.ready(jdbc, dialect(db), TABLES.keySet(), "tpch", db, "lineitem")) {
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
                Path dir = Path.of(args.get("dir", "./data/tpch"));
                int batch = args.getInt("batch", 5000);
                withJdbc(db, jdbc -> {
                    DelimitedFileLoader loader = new DelimitedFileLoader(jdbc, dialect(db), '|', batch);
                    TABLES.forEach((table, cols) -> {
                        // dbgen -C n -S i 로 쪼개진 lineitem.tbl.1 같은 파일도 모두 적재
                        java.util.List<Path> files = DataFiles.findTbl(dir, table);
                        if (files.isEmpty()) {
                            log.warn("Skip {} (no {}.tbl in {})", table, table, dir);
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
                            "tpch", db, "lineitem")) {
                        return;
                    }
                    new QueryResourceRunner(jdbc, dialect(db), "classpath:queries/*.sql")
                            .runAll(query, warmup, iterations, explain);
                });
            }
            default -> log.info("""

                    Commands:
                      generate --sf=0.1 --dir=./data/tpch        데이터 파일(.tbl) 생성
                      schema   --db=postgres|mysql               스키마 생성(DROP 후 재생성, 인덱스 없음)
                      load     --db=postgres|mysql --dir=...     데이터 적재
                      analyze  --db=postgres|mysql               통계만 갱신 (인덱스 효과와 분리 측정용)
                      vacuum   --db=postgres|mysql               VACUUM ANALYZE (통계 + visibility map)
                      index    --db=postgres|mysql               PK/보조 인덱스 생성 + 통계 갱신
                      run      --db=... [--query=q03] [--warmup=1] [--iterations=3] [--explain=true]
                    """);
        }
    }

    private Dialect dialect(String db) {
        return "mysql".equals(db) ? Dialect.MYSQL : Dialect.POSTGRES;
    }

    private void withJdbc(String db, java.util.function.Consumer<JdbcTemplate> work) {
        String prefix = "tpch.datasource." + db + ".";
        String url = env.getRequiredProperty(prefix + "url");
        try (HikariDataSource ds = DataSources.create(url,
                env.getRequiredProperty(prefix + "username"),
                env.getRequiredProperty(prefix + "password"), 4)) {
            work.accept(new JdbcTemplate(ds));
        }
    }
}
