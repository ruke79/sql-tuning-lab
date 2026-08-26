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

        List<Resource> queries = listQueries();

        // --query 에 없는 이름을 주면 예전에는 아무것도 실행하지 않고 조용히 끝났다
        // ("SUMMARY (POSTGRES, 0 queries)" 만 INFO 로 찍혀 눈에 띄지 않는다).
        // 모듈마다 쿼리 이름이 다르므로(tpch=q03, tpcds=q03_brand_by_year) 오타가 잦은 지점이고,
        // 돌지도 않은 것을 돌았다고 착각하게 만든다. 그래서 여기서 걸러 목록을 보여준다.
        if (onlyQuery != null) {
            boolean known = queries.stream().anyMatch(r -> onlyQuery.equalsIgnoreCase(baseName(r)));
            if (!known) {
                String available = queries.stream().map(this::baseName).sorted()
                        .collect(java.util.stream.Collectors.joining(", "));
                throw new IllegalArgumentException(
                        "이런 쿼리가 없다: '" + onlyQuery + "'\n  사용 가능: "
                        + (available.isEmpty() ? "(없음)" : available));
            }
        }

        for (Resource r : queries) {
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
