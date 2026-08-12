package com.tuninglab.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.jdbc.core.JdbcTemplate;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

/**
 * classpath:queries/*.sql 을 찾아 벤치마크 실행 + 실행계획 수집을 한 번에 처리한다.
 * 각 벤치마크 모듈이 공유하는 공통 CLI 백엔드.
 */
public class QueryResourceRunner {

    private static final Logger log = LoggerFactory.getLogger(QueryResourceRunner.class);

    private final JdbcTemplate jdbc;
    private final Dialect dialect;
    private final String queryLocationPattern;

    public QueryResourceRunner(JdbcTemplate jdbc, Dialect dialect, String queryLocationPattern) {
        this.jdbc = jdbc;
        this.dialect = dialect;
        this.queryLocationPattern = queryLocationPattern;
    }

    public List<Resource> listQueries() {
        try {
            Resource[] resources = new PathMatchingResourcePatternResolver()
                    .getResources(queryLocationPattern);
            List<Resource> sorted = new ArrayList<>(Arrays.asList(resources));
            sorted.sort(Comparator.comparing(Resource::getFilename,
                    Comparator.nullsLast(Comparator.naturalOrder())));
            return sorted;
        } catch (IOException e) {
            throw new RuntimeException("Cannot list " + queryLocationPattern, e);
        }
    }

    /** query 이름(확장자 제외)이 일치하는 것만, null이면 전체 실행 */
    public void runAll(String onlyQuery, int warmup, int iterations, boolean explain) {
        QueryBenchmark benchmark = new QueryBenchmark(jdbc);
        ExplainService explainService = new ExplainService(jdbc, dialect);
        List<BenchmarkResult> results = new ArrayList<>();

        for (Resource r : listQueries()) {
            String name = baseName(r);
            if (onlyQuery != null && !onlyQuery.equalsIgnoreCase(name)) continue;
            String sql = read(r);
            log.info("==== {} ====", name);
            if (explain) {
                log.info("--- EXPLAIN ANALYZE ---\n{}", explainService.analyze(sql));
            }
            BenchmarkResult result = benchmark.run(name, sql, warmup, iterations);
            log.info(result.summaryLine());
            results.add(result);
        }

        log.info("========== SUMMARY ({}, {} queries) ==========", dialect, results.size());
        results.forEach(r -> log.info(r.summaryLine()));
    }

    private String baseName(Resource r) {
        String f = r.getFilename() == null ? "query" : r.getFilename();
        int dot = f.lastIndexOf('.');
        return dot > 0 ? f.substring(0, dot) : f;
    }

    private String read(Resource r) {
        try {
            return r.getContentAsString(StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new RuntimeException("Cannot read " + r, e);
        }
    }
}
