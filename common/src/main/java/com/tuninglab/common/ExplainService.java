package com.tuninglab.common;

import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;

/** DBMS별 실행계획을 수집한다. */
public class ExplainService {

    private final JdbcTemplate jdbc;
    private final Dialect dialect;

    public ExplainService(JdbcTemplate jdbc, Dialect dialect) {
        this.jdbc = jdbc;
        this.dialect = dialect;
    }

    /** 실행 없이 추정 계획만 조회 */
    public String plan(String sql) {
        return switch (dialect) {
            case POSTGRES -> collect("EXPLAIN " + sql);
            case MYSQL -> collect("EXPLAIN FORMAT=TREE " + sql);
            case CLICKHOUSE -> collect("EXPLAIN indexes = 1 " + sql);
        };
    }

    /** 실제 실행 후 계획 + 실측 비용 조회 (ClickHouse는 PIPELINE으로 대체) */
    public String analyze(String sql) {
        return switch (dialect) {
            case POSTGRES -> collect("EXPLAIN (ANALYZE, BUFFERS) " + sql);
            case MYSQL -> collect("EXPLAIN ANALYZE " + sql);
            case CLICKHOUSE -> collect("EXPLAIN PIPELINE " + sql);
        };
    }

    private String collect(String explainSql) {
        List<String> lines = jdbc.query(explainSql, (rs, i) -> rs.getString(1));
        return String.join(System.lineSeparator(), lines);
    }
}
