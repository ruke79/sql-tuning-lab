package com.tuninglab.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.Collection;

/**
 * 옵티마이저 통계만 따로 갱신한다.
 *
 * 실습 설계상 중요: index 명령은 "인덱스 생성 + 통계 갱신(ANALYZE)"을 한 번에 하므로,
 * 인덱스 전/후만 비교하면 두 변수가 동시에 바뀌어 원인을 분리할 수 없다.
 * 통계의 효과와 인덱스의 효과를 나눠 보려면 이 명령으로 통계만 먼저 갱신하고 측정한다.
 *
 * 반대로 "통계 없는 상태"로 되돌리는 깔끔한 방법은 없다.
 * schema → load 를 다시 실행하는 것이 가장 정확하다.
 */
public final class Statistics {

    private static final Logger log = LoggerFactory.getLogger(Statistics.class);

    private Statistics() {}

    public static void analyze(JdbcTemplate jdbc, Dialect dialect, Collection<String> tables) {
        long start = System.currentTimeMillis();
        switch (dialect) {
            case POSTGRES -> {
                log.info("ANALYZE (현재 DB 전체 테이블)");
                jdbc.execute("ANALYZE");
            }
            case MYSQL -> tables.forEach(t -> {
                log.info("ANALYZE TABLE {}", t);
                jdbc.execute("ANALYZE TABLE " + t);
            });
            case CLICKHOUSE ->
                log.info("ClickHouse는 별도 통계 갱신이 필요 없다 (MergeTree 파트 메타데이터 사용)");
        }
        log.info("통계 갱신 완료 ({} ms)", System.currentTimeMillis() - start);
    }

    /**
     * VACUUM ANALYZE: 통계 갱신 + visibility map 설정.
     *
     * visibility map 이 비어 있으면 Index Only Scan 이 불리하게 평가되어,
     * 적재 직후 테이블은 운영 중인 테이블과 다른 실행계획을 낸다.
     * '통계만'의 효과와 'visibility map'의 효과를 나누려면 analyze 와 이 명령을 구분해 쓴다.
     */
    public static void vacuumAnalyze(JdbcTemplate jdbc, Dialect dialect, Collection<String> tables) {
        long start = System.currentTimeMillis();
        switch (dialect) {
            case POSTGRES -> tables.forEach(t -> {
                log.info("VACUUM ANALYZE {}", t);
                jdbc.execute("VACUUM ANALYZE " + t);
            });
            case MYSQL -> {
                log.warn("MySQL 에는 visibility map 개념이 없다. ANALYZE TABLE 로 대체한다.");
                analyze(jdbc, dialect, tables);
                return;
            }
            case CLICKHOUSE -> {
                log.info("ClickHouse 는 해당 없음");
                return;
            }
        }
        log.info("VACUUM ANALYZE 완료 ({} ms)", System.currentTimeMillis() - start);
    }
}
