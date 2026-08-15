package io.webboy.verify.labs.kafka.sink;

import io.webboy.verify.core.VerificationResult;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * Kafka 검증 결과를 verify-lab 과 <b>같은</b> {@code verify_result} 테이블에 적재한다.
 * Grafana 대시보드의 모든 패널이 category 로 묶으므로, 이 모듈의 "kafka" 분류는
 * 대시보드 수정 없이 그대로 나타난다.
 *
 * <p>verify-lab 의 sink 와 달리 Spring DataSource 를 쓰지 않는다 — 이 모듈은 브로커가 없어도
 * 컨텍스트가 떠야 해서 DataSourceAutoConfiguration 을 꺼 두었기 때문이다(application.yml 참고).
 * 그래서 DriverManager 로 직접 붙고, DB 가 없으면 경고만 남기고 삼킨다.
 */
@Component
public class PlainJdbcResultSink {

    private static final org.slf4j.Logger log =
            org.slf4j.LoggerFactory.getLogger(PlainJdbcResultSink.class);

    private final String url;
    private final String user;
    private final String password;
    private final boolean enabled;

    public PlainJdbcResultSink(
            @Value("${verify.sink.url:jdbc:postgresql://${DB_HOST:localhost}:${DB_PORT:5432}/verifylab}") String url,
            @Value("${verify.sink.username:verifylab}") String user,
            @Value("${verify.sink.password:verifylab}") String password,
            @Value("${verify.sink.enabled:true}") boolean enabled) {
        this.url = url;
        this.user = user;
        this.password = password;
        this.enabled = enabled;
    }

    public void record(List<VerificationResult> results, String trigger) {
        if (!enabled || results.isEmpty()) {
            return;
        }
        try (Connection c = DriverManager.getConnection(url, user, password)) {
            ensureTable(c);
            String runId = UUID.randomUUID().toString();
            Timestamp now = Timestamp.from(Instant.now());
            try (PreparedStatement ps = c.prepareStatement("""
                    INSERT INTO verify_result
                      (run_id, run_at, trigger_kind, case_id, category, question, claim,
                       verdict, acceptable, nondeterministic, elapsed_ms, expectations, facts, error)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """)) {
                for (VerificationResult r : results) {
                    int i = 1;
                    ps.setString(i++, runId);
                    ps.setTimestamp(i++, now);
                    ps.setString(i++, trigger);
                    ps.setString(i++, r.id());
                    ps.setString(i++, r.category());
                    ps.setString(i++, r.question());
                    ps.setString(i++, r.claim());
                    ps.setString(i++, r.verdict().name());
                    ps.setBoolean(i++, r.acceptable());
                    ps.setBoolean(i++, r.nondeterministic());
                    ps.setLong(i++, r.elapsedMillis());
                    ps.setString(i++, r.expectations().stream()
                            .map(e -> (e.satisfied() ? "✔ " : "✘ ") + e.description() + (e.flaky() ? " (flaky)" : ""))
                            .collect(Collectors.joining("\n")));
                    ps.setString(i++, r.facts().entrySet().stream()
                            .map(e -> e.getKey() + " = " + e.getValue())
                            .collect(Collectors.joining("\n")));
                    ps.setString(i, r.error());
                    ps.addBatch();
                }
                ps.executeBatch();
            }
            log.info("verify_result 적재: run_id={} cases={} trigger={}", runId, results.size(), trigger);
        } catch (Exception e) {
            log.warn("verify_result 적재 실패(검증 판정에는 영향 없음): {}", e.getMessage());
        }
    }

    /** verify-lab 의 VerificationResultJdbcSink 와 동일한 DDL — 어느 쪽이 먼저 돌든 같은 테이블. */
    private void ensureTable(Connection c) throws Exception {
        try (var st = c.createStatement()) {
            st.execute("""
                    CREATE TABLE IF NOT EXISTS verify_result (
                        id               BIGSERIAL PRIMARY KEY,
                        run_id           TEXT        NOT NULL,
                        run_at           TIMESTAMPTZ NOT NULL,
                        trigger_kind     TEXT        NOT NULL,
                        case_id          TEXT        NOT NULL,
                        category         TEXT        NOT NULL,
                        question         TEXT        NOT NULL,
                        claim            TEXT        NOT NULL,
                        verdict          TEXT        NOT NULL,
                        acceptable       BOOLEAN     NOT NULL,
                        nondeterministic BOOLEAN     NOT NULL,
                        elapsed_ms       BIGINT      NOT NULL,
                        expectations     TEXT,
                        facts            TEXT,
                        error            TEXT
                    )""");
            st.execute("CREATE INDEX IF NOT EXISTS ix_vr_run ON verify_result(run_id)");
            st.execute("CREATE INDEX IF NOT EXISTS ix_vr_at  ON verify_result(run_at)");
        }
    }
}
