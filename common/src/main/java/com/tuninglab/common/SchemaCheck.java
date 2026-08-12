package com.tuninglab.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * 쿼리 실행 전에 필요한 테이블이 준비되었는지 확인한다.
 *
 * 준비가 안 된 상태에서 쿼리를 던지면 JDBC 스택 트레이스만 잔뜩 나와
 * "무엇을 먼저 해야 하는지"가 묻혀버린다. 그래서 미리 확인하고 할 일을 알려준다.
 */
public final class SchemaCheck {

    private static final Logger log = LoggerFactory.getLogger(SchemaCheck.class);

    private SchemaCheck() {}

    /** 존재하지 않는 테이블 목록을 돌려준다. 확인이 불가능하면 빈 목록. */
    public static List<String> missingTables(JdbcTemplate jdbc, Dialect dialect,
                                             Collection<String> expected) {
        String sql = switch (dialect) {
            case POSTGRES -> """
                    SELECT tablename FROM pg_tables
                    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
                    """;
            case MYSQL -> """
                    SELECT table_name FROM information_schema.tables
                    WHERE table_schema = database()
                    """;
            case CLICKHOUSE -> null;   // 별도 데이터베이스 구조라 생략
        };
        if (sql == null) {
            return List.of();
        }
        List<String> present;
        try {
            present = jdbc.query(sql, (rs, i) -> rs.getString(1));
        } catch (Exception e) {
            log.debug("스키마 확인 실패(무시하고 진행): {}", e.getMessage());
            return List.of();
        }
        if (present == null) {
            return List.of();   // 확인 불가 → 막지 않는다
        }
        // DBMS/드라이버마다 테이블명 대소문자가 다르게 올 수 있으므로 비교 시점에 정규화한다
        Set<String> presentLower = new HashSet<>();
        for (String p : present) {
            if (p != null) {
                presentLower.add(p.toLowerCase(Locale.ROOT));
            }
        }
        List<String> missing = new ArrayList<>();
        for (String t : expected) {
            if (!presentLower.contains(t.toLowerCase(Locale.ROOT))) {
                missing.add(t);
            }
        }
        return missing;
    }

    /**
     * ClickHouse 전용 준비 확인. 데이터베이스/테이블 구조가 달라 별도로 다룬다.
     *
     * @param database 예: "gharchive"
     * @param table    예: "github_events"
     */
    public static boolean clickhouseReady(JdbcTemplate jdbc, String database, String table) {
        Long exists;
        try {
            exists = jdbc.queryForObject(
                    "SELECT count() FROM system.tables WHERE database = '" + database
                            + "' AND name = '" + table + "'", Long.class);
        } catch (Exception e) {
            log.debug("스키마 확인 실패(무시하고 진행): {}", e.getMessage());
            return true;
        }
        if (exists == null || exists == 0) {
            log.error("");
            log.error("{}.{} 테이블이 없습니다.", database, table);
            log.error("");
            log.error("먼저 아래를 실행하세요:");
            log.error("  ./gradlew :clickhouse-lab:bootRun --args=\"schema\"");
            log.error("  ./gradlew :clickhouse-lab:bootRun --args=\"load --from=2024-01-01 --to=2024-01-01 --hours=0-5\"");
            log.error("");
            return false;
        }
        try {
            Long rows = jdbc.queryForObject("SELECT count() FROM " + database + "." + table, Long.class);
            if (rows == null || rows == 0) {
                log.error("");
                log.error("{}.{} 이 비어 있습니다. 데이터를 먼저 적재하세요:", database, table);
                log.error("  ./gradlew :clickhouse-lab:bootRun --args=\"load --from=2024-01-01 --to=2024-01-01 --hours=0-5\"");
                log.error("");
                return false;
            }
            log.info("준비 확인: {}.{} {} 행", database, table, rows);
        } catch (Exception e) {
            log.warn("행수 확인 실패: {}", e.getMessage());
        }
        return true;
    }

    /**
     * 준비 상태를 점검하고, 문제가 있으면 무엇을 해야 하는지 출력한 뒤 false 를 돌려준다.
     *
     * @param module    gradle 모듈명 (예: "tpch", "tpcds")
     * @param db        --db 값 (예: "postgres")
     * @param factTable 비었는지 확인할 대표 테이블 (예: "lineitem")
     */
    public static boolean ready(JdbcTemplate jdbc, Dialect dialect, Collection<String> expected,
                                String module, String db, String factTable) {
        List<String> missing = missingTables(jdbc, dialect, expected);
        if (!missing.isEmpty()) {
            log.error("");
            log.error("테이블이 없습니다: {}", String.join(", ", missing));
            log.error("");
            log.error("먼저 아래를 순서대로 실행하세요:");
            log.error("  ./gradlew :{}:bootRun --args=\"generate\"", module);
            log.error("  ./gradlew :{}:bootRun --args=\"schema --db={}\"", module, db);
            log.error("  ./gradlew :{}:bootRun --args=\"load   --db={}\"", module, db);
            log.error("  ./gradlew :{}:bootRun --args=\"index  --db={}\"", module, db);
            log.error("");
            return false;
        }
        try {
            Long rows = jdbc.queryForObject("SELECT count(*) FROM " + factTable, Long.class);
            if (rows == null || rows == 0) {
                log.error("");
                log.error("{} 테이블이 비어 있습니다. 데이터를 먼저 적재하세요:", factTable);
                log.error("  ./gradlew :{}:bootRun --args=\"generate\"", module);
                log.error("  ./gradlew :{}:bootRun --args=\"load --db={}\"", module, db);
                log.error("");
                return false;
            }
            log.info("준비 확인: {} {} 행", factTable, rows);
        } catch (Exception e) {
            log.warn("{} 행수 확인 실패: {}", factTable, e.getMessage());
        }
        return true;
    }
}
