package io.webboy.verify.labs;

import io.webboy.verify.core.VerificationCase;
import io.webboy.verify.core.VerificationRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
class VerificationRegistryTest {

    @Autowired
    private VerificationRegistry registry;

    @Test
    void 케이스_메타데이터가_모두_채워져_있다() {
        List<VerificationCase> cases = registry.all();
        assertThat(cases).isNotEmpty();
        for (VerificationCase c : cases) {
            assertThat(c.id()).as("id").isNotBlank();
            assertThat(c.category()).as(c.id() + " category").isNotBlank();
            assertThat(c.question()).as(c.id() + " question").isNotBlank();
            assertThat(c.claim()).as(c.id() + " claim").isNotBlank();
        }
    }

    @Test
    void 케이스가_통째로_사라지지_않았다() {
        // 케이스별 실행으로 바꾸면서 '전건이 도는가'를 확인하던 자리가 없어졌다.
        // 등록이 통째로 빠지면 테스트가 조용히 0건을 돌고 초록이 되므로 하한을 여기서 지킨다.
        assertThat(registry.size()).as("등록된 케이스 수").isGreaterThanOrEqualTo(51);
    }

    @Test
    void 분류가_예상_범위_안에_있다() {
        // sql-tuning-lab 에는 원본 11개 분류 중 다섯을 이식했다
        // (spring 7 · jpa 7 · concurrency 5 · jvm 7 · db 25 = 51건)
        assertThat(registry.categories())
                .containsExactlyInAnyOrder("concurrency", "db", "jpa", "jvm", "spring");
    }
}
