package com.tuninglab.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;

import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.List;

/**
 * 쿼리를 반복 실행하여 latency 통계를 수집한다.
 * - warmup 실행으로 버퍼 캐시를 채운 뒤 측정 (cold/warm 비교를 원하면 warmup=0)
 * - 결과 행을 전부 소비(fetch)하여 실제 전송 비용까지 포함
 */
public class QueryBenchmark {

    private static final Logger log = LoggerFactory.getLogger(QueryBenchmark.class);

    private final JdbcTemplate jdbc;

    public QueryBenchmark(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public BenchmarkResult run(String name, String sql, int warmup, int iterations) {
        for (int i = 0; i < warmup; i++) {
            consume(sql);
        }
        List<Double> times = new ArrayList<>(iterations);
        long rows = 0;
        for (int i = 0; i < iterations; i++) {
            long start = System.nanoTime();
            rows = consume(sql);
            double ms = (System.nanoTime() - start) / 1_000_000.0;
            times.add(ms);
            log.debug("{} run {}/{}: {} ms", name, i + 1, iterations, String.format("%.1f", ms));
        }
        return new BenchmarkResult(name, iterations, rows, times);
    }

    private long consume(String sql) {
        Long count = jdbc.query(sql, rs -> {
            long n = 0;
            int cols = rs.getMetaData().getColumnCount();
            while (rs.next()) {
                // 모든 컬럼을 실제로 읽어 lazy fetch 최적화 방지
                for (int c = 1; c <= cols; c++) {
                    rs.getObject(c);
                }
                n++;
            }
            return n;
        });
        return count == null ? 0 : count;
    }

    /** ResultSet 소비 없이 DML/DDL 실행 시간 측정 */
    public double executeTimed(String sql) {
        long start = System.nanoTime();
        jdbc.execute(sql);
        return (System.nanoTime() - start) / 1_000_000.0;
    }
}
