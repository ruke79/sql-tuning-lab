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

        String url = env.getRequiredProperty("sysbench.datasource.url");
        String user = env.getRequiredProperty("sysbench.datasource.username");
        String pass = env.getRequiredProperty("sysbench.datasource.password");
        // **DB 가 없으면 Hikari 가 스택 트레이스만 남기고 죽는다.**
        //   PoolInitializationException: Failed to initialize pool: Unknown database 'sysbench_lab'
        // 무엇을 하라는 말이 없어서 막힌다. 게다가 sysbench 바이너리도 DB 를 만들어 주지
        // 않으므로(실측: error 1049) "prepare 를 돌려라"는 안내가 막다른 길이 된다.
        // 없으면 여기서 만든다 — 만들 권한이 없으면 무엇을 하라는지 말하고 멈춘다.
        if (!ensureDatabase(url, user, pass)) return;

        try (HikariDataSource ds = DataSources.create(url, user, pass,
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

    /**
     * JDBC URL 이 가리키는 데이터베이스가 없으면 만든다. 쓸 수 있으면 true.
     *
     * <p>URL 에서 DB 이름을 떼어 서버에만 붙은 뒤 {@code CREATE DATABASE IF NOT EXISTS} 를 한다.
     * MySQL 은 <b>권한이 없는 DB 에도 {@code Unknown database} 를 낸다</b>(존재를 숨긴다) —
     * 그래서 '없다'와 '안 보인다'가 같은 에러로 보이고, 둘 다 여기서 걸러 말해 준다.
     */
    private boolean ensureDatabase(String url, String user, String pass) {
        java.util.regex.Matcher m =
                java.util.regex.Pattern.compile("^(jdbc:mysql://[^/]+)/([^?]+)(\\?.*)?$").matcher(url);
        if (!m.matches()) {
            log.warn("JDBC URL 에서 DB 이름을 못 읽었습니다 — 그대로 접속을 시도합니다: {}", url);
            return true;
        }
        String serverUrl = m.group(1) + "/" + (m.group(3) == null ? "" : m.group(3));
        String db = m.group(2);
        try (java.sql.Connection c = java.sql.DriverManager.getConnection(serverUrl, user, pass);
             java.sql.Statement st = c.createStatement()) {
            try (java.sql.ResultSet rs = st.executeQuery(
                    "SELECT count(*) FROM information_schema.schemata WHERE schema_name = '" + db + "'")) {
                if (rs.next() && rs.getInt(1) == 1) return true;
            }
            log.info("데이터베이스 {} 가 없습니다 — 만듭니다.", db);
            st.executeUpdate("CREATE DATABASE `" + db + "` CHARACTER SET utf8mb4");
            log.info("만들었습니다. 데이터는 sysbench 바이너리가 채웁니다:");
            log.info("  sysbench oltp_read_write --mysql-user={} --mysql-password=*** --mysql-db={} \\", user, db);
            log.info("    --tables=4 --table-size=1000000 prepare");
            return true;
        } catch (Exception e) {
            log.error("데이터베이스 {} 를 준비하지 못했습니다: {}", db, e.getMessage());
            log.error("  MySQL 이 떠 있는지, 계정 {} 에 CREATE 권한이 있는지 보세요.", user);
            log.error("  한 번에 맞추려면: ./scripts/restore-lab.sh --mysql");
            return false;
        }
    }
}
