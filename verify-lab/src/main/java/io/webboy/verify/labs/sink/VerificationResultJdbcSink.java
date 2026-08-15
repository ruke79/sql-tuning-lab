package io.webboy.verify.labs.sink;

import io.webboy.verify.core.VerificationResult;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 검증 결과를 PostgreSQL 테이블에 적재한다 — Grafana 가 읽는 원천.
 *
 * <p>설계 결정:
 * <ul>
 *   <li><b>md 리포트를 대체하지 않는다.</b> 리포트는 사람이 읽는 판정 근거이고,
 *       이 테이블은 대시보드가 읽는 시계열이다. 목적이 다르므로 둘 다 남긴다.</li>
 *   <li><b>run_id 로 실행 단위를 묶는다.</b> Grafana 의 "최근 실행" 패널이
 *       {@code WHERE run_id = (SELECT ... ORDER BY run_at DESC LIMIT 1)} 로 잘라 쓴다.</li>
 *   <li><b>expectations/notes 는 텍스트로 펴서 넣는다.</b> 대시보드에서 근거를 보여 주는
 *       용도라 구조화가 필요 없고, JSONB 로 하면 케이스 쪽 직렬화 의존이 생긴다.</li>
 *   <li><b>적재 실패가 검증을 실패시키면 안 된다.</b> 테이블이 없거나 권한이 없어도
 *       검증 자체는 유효하다 — 경고만 남기고 삼킨다.</li>
 * </ul>
 */
@Component
public class VerificationResultJdbcSink {

    private static final org.slf4j.Logger log =
            org.slf4j.LoggerFactory.getLogger(VerificationResultJdbcSink.class);

    private final JdbcTemplate jdbc;
    private final boolean enabled;

    public VerificationResultJdbcSink(JdbcTemplate jdbc,
                                      @Value("${verify.sink.enabled:true}") boolean enabled) {
        this.jdbc = jdbc;
        this.enabled = enabled;
    }

    /** @param trigger 무엇이 이 실행을 만들었는가 — {@code test-suite} | {@code web} */
    public void record(List<VerificationResult> results, String trigger) {
        if (!enabled || results.isEmpty()) {
            return;
        }
        try {
            ensureTable();
            String runId = UUID.randomUUID().toString();
            Timestamp now = Timestamp.from(Instant.now());
            for (VerificationResult r : results) {
                jdbc.update("""
                        INSERT INTO verify_result
                          (run_id, run_at, trigger_kind, case_id, category, question, claim,
                           verdict, acceptable, nondeterministic, elapsed_ms, expectations, facts, error)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """,
                        runId, now, trigger, r.id(), r.category(), r.question(), r.claim(),
                        r.verdict().name(), r.acceptable(), r.nondeterministic(), r.elapsedMillis(),
                        expectationsText(r), factsText(r), r.error());
            }
            log.info("verify_result 적재: run_id={} cases={} trigger={}", runId, results.size(), trigger);
        } catch (Exception e) {
            log.warn("verify_result 적재 실패(검증 판정에는 영향 없음): {}", e.getMessage());
        }
    }

    /**
     * 스키마를 코드가 소유한다. Grafana 프로비저닝(docker/verify/grafana)과 이 DDL 이
     * 같은 컬럼명을 보므로, 바꿀 때는 대시보드 JSON 도 같이 바꿔야 한다.
     */
    private void ensureTable() {
        jdbc.execute("""
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
        jdbc.execute("CREATE INDEX IF NOT EXISTS ix_vr_run ON verify_result(run_id)");
        jdbc.execute("CREATE INDEX IF NOT EXISTS ix_vr_at  ON verify_result(run_at)");
    }

    private String expectationsText(VerificationResult r) {
        return r.expectations().stream()
                .map(e -> (e.satisfied() ? "✔ " : "✘ ") + e.description() + (e.flaky() ? " (flaky)" : ""))
                .collect(Collectors.joining("\n"));
    }

    private String factsText(VerificationResult r) {
        return r.facts().entrySet().stream()
                .map(e -> e.getKey() + " = " + e.getValue())
                .collect(Collectors.joining("\n"));
    }
}
