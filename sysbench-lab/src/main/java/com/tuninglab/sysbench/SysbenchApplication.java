package com.tuninglab.sysbench;

import com.tuninglab.common.Args;
import com.tuninglab.common.DataSources;
import com.zaxxer.hikari.HikariDataSource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * sysbench (MySQL OLTP) 튜닝 실습 CLI.
 *
 * 사용 예)
 *   ./gradlew :sysbench-lab:bootRun --args="prepare --tables=4 --table-size=100000"
 *   ./gradlew :sysbench-lab:bootRun --args="run     --threads=8 --seconds=30 --tables=4 --table-size=100000"
 *   ./gradlew :sysbench-lab:bootRun --args="run     --threads=16 --hot=true ..."   # 핫로우 락 경합
 *   ./gradlew :sysbench-lab:bootRun --args="monitor"
 *
 * 1억 건 구성: --tables=10 --table-size=10000000 (RAW 약 24GB) — 공식 sysbench prepare 권장
 */
@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)
public class SysbenchApplication implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(SysbenchApplication.class);

    private final Environment env;

    public SysbenchApplication(Environment env) {
        this.env = env;
    }

    public static void main(String[] args) {
        System.exit(SpringApplication.exit(SpringApplication.run(SysbenchApplication.class, args)));
    }

    @Override
    public void run(String... rawArgs) throws Exception {
        Args args = new Args(rawArgs);
        int tables = args.getInt("tables", 4);
        long tableSize = (long) args.getDouble("table-size", 100_000);

        try (HikariDataSource ds = DataSources.create(
                env.getRequiredProperty("sysbench.datasource.url"),
                env.getRequiredProperty("sysbench.datasource.username"),
                env.getRequiredProperty("sysbench.datasource.password"),
                Math.max(4, args.getInt("threads", 8) + 2))) {

            JdbcTemplate jdbc = new JdbcTemplate(ds);

            switch (args.command()) {
                case "prepare" -> new SysbenchTables(jdbc).prepare(tables, tableSize);
                case "run" -> new OltpWorkload(ds, tables, tableSize, args.getBool("hot", false))
                        .run(args.getInt("threads", 8), args.getInt("seconds", 30));
                case "monitor" -> new InnodbMonitor(jdbc).report();
                default -> log.info("""

                        Commands:
                          prepare --tables=4 --table-size=100000       sbtest1..N 테이블 생성 + 적재
                          run     --threads=8 --seconds=30 [--hot=true]  oltp_read_write 부하 실행
                          monitor                                      buffer pool/락/redo 지표 출력
                        """);
            }
        }
    }
}
