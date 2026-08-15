package io.webboy.verify.labs.sink;

import io.webboy.verify.core.VerificationResult;
import io.webboy.verify.core.VerificationRunner;
import io.webboy.verify.core.Verdict;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * 전체 검증을 실행하고 결과를 verify_result 테이블에 적재하는 엔드포인트.
 *
 * <p>verify-core 의 {@code /verify/run} 은 결과를 응답으로만 돌려준다 — 그건 코어가
 * 어떤 저장소에도 붙지 않기 위해서다. 적재는 랩의 결정이므로 랩 쪽 컨트롤러로 분리했다.
 *
 * <pre>
 *   curl -X POST localhost:8080/verify/run-and-store
 *   curl -X POST "localhost:8080/verify/run-and-store?category=db"
 * </pre>
 */
@RestController
@RequestMapping("${verify.base-path:/verify}")
public class StoredRunController {

    private final VerificationRunner runner;
    private final VerificationResultJdbcSink sink;

    public StoredRunController(VerificationRunner runner, VerificationResultJdbcSink sink) {
        this.runner = runner;
        this.sink = sink;
    }

    @PostMapping("/run-and-store")
    public Map<String, Object> runAndStore(@RequestParam(required = false) String category) {
        List<VerificationResult> results =
                (category == null) ? runner.runAll() : runner.runCategory(category);
        sink.record(results, "web");
        Map<Verdict, Long> byVerdict = results.stream()
                .collect(Collectors.groupingBy(VerificationResult::verdict, Collectors.counting()));
        return Map.of(
                "cases", results.size(),
                "verdicts", byVerdict,
                "acceptable", results.stream().filter(VerificationResult::acceptable).count());
    }
}
