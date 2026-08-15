# verify-lab — 면접 답변 검증 랩 (51케이스)

`ruke79/problem-solving` 의 verify-core / verify-labs 에서 다섯 분류를 이식했다.
케이스 1개 = 면접 질문 1개 = "내 답변의 명제를 실제 실행으로 재현할 수 있는가".

| 분류 | 건수 | 주제 |
|---|---|---|
| spring | 7 | 프록시와 트랜잭션 경계 (SPRING-01~07) |
| jpa | 7 | 영속성 컨텍스트 (JPA-01~07) |
| concurrency | 5 | 자바 동시성 기본기 (CON-01~05) |
| jvm | 7 | 언어·런타임 (JVM-01~07) |
| db | 25 | PostgreSQL 16 실물 (DB-01~25) |

판정: `CONFIRMED`(재현됨) / `REFUTED`(답변이 틀렸다 — 고쳐야 한다) /
`INCONCLUSIVE`(환경·타이밍 의존) / `ERROR`(검증 코드 자체의 문제).
비결정 케이스(`nondeterministic=true`)의 INCONCLUSIVE 는 실패로 치지 않는다.

## 실행

```bash
# 1) DB 준비 (한 번만) — verifylab DB/계정 생성. tpch 실습 데이터와 완전히 분리된다.
./scripts/verify/setup-verifylab.sh

# 2) (선택) DB-24 용 스트리밍 레플리카 — 없으면 DB-24 만 INCONCLUSIVE 로 남는다
./scripts/verify/setup-replica.sh

# 3) 전건 실행 (51건, 약 1분)
./gradlew :verify-lab:test

# 골라 돌리기
./gradlew :verify-lab:test -Dverify.only=DB-14        # 케이스 하나 (판정 근거가 콘솔에 나온다)
./gradlew :verify-lab:test -Dverify.only=jpa          # 분류 전체
./gradlew :verify-lab:test -Dverify.only=DB-14,JPA-01 # 여러 개
```

결과물 3곳:
- **콘솔/Gradle 리포트** — 케이스마다 테스트 노드가 생겨 개별 통과/실패가 보인다
- **`verify-lab/build/reports/verification.md`** — 사람이 읽는 판정 근거(관측값·검증 항목·메모)
- **PostgreSQL `verify_result` 테이블** — Grafana 가 읽는 시계열 (아래)

## Grafana 대시보드

```bash
docker compose -f docker/verify/compose.yaml up -d
./gradlew :verify-lab:test          # 실행할 때마다 run_id 단위로 적재된다
# http://localhost:3000  (admin/admin) → "Verification Lab"
```

대시보드 구성: 판정별 stat(CONFIRMED/REFUTED/INCONCLUSIVE/ERROR) · 합격률 ·
분류별 판정 막대 · 실행별 합격률 추이 · 케이스별 결과 테이블(필터 가능) ·
느린 케이스 Top 10 · 실행 이력.

로컬 PostgreSQL 을 쓰는 경우 Grafana 만 띄운다:

```bash
GF_DS_HOST=host.docker.internal docker compose -f docker/verify/compose.yaml up -d grafana
```

웹으로 실행하며 적재하려면:

```bash
./gradlew :verify-lab:bootRun
curl -X POST localhost:8080/verify/run-and-store              # 전건
curl -X POST "localhost:8080/verify/run-and-store?category=db" # 분류만
```

## 환경 요구사항 (스크립트가 처리하는 것)

| 요구 | 이유 | 없으면 |
|---|---|---|
| `verifylab` DB/계정 | 케이스가 테이블을 만들고 지운다 — tpch 와 분리 필수 | 전건 실패 |
| `CREATEROLE` + `createrole_self_grant='set,inherit'` | DB-13(RLS)이 테넌트 롤을 만들어 `SET ROLE` 한다. PG16 부터 CREATEROLE 은 SET 권한을 자동으로 받지 못한다 | DB-13 만 판정 불가 |
| `wal_level=logical` | DB-10(CDC) 논리 디코딩 | DB-10 만 판정 불가 |
| 스트리밍 레플리카 (`scripts/verify/setup-replica.sh`, 기본 5433) | DB-24(복제 지연 / read-your-writes) | DB-24 가 INCONCLUSIVE 로 남는다 (비결정 케이스라 실패는 아니다) |

## :verify-lab-kafka — Kafka 실물 검증 8케이스 (별도 모듈)

MSA 답변을 흉내가 아니라 **실물 브로커**로 검증한다 — 파티션 순서 보증, 컨슈머 랙,
DLQ 재처리, Exactly-Once, 리밸런스와 오토스케일 한계, 핫 파티션, Avro 스키마 호환성.

```bash
# 브로커: 도커 또는 로컬 KRaft (둘 중 하나)
docker compose -f docker/verify/compose.yaml up -d kafka
./scripts/verify/kafka-local.sh start          # Docker 없이 (이 세션의 검증 방식)

./gradlew :verify-lab-kafka:test               # 브로커 없으면 실패가 아니라 '건너뜀'
```

이 환경 실행 결과: **7건 전부 CONFIRMED** (로컬 KRaft 3.9.1).
결과는 같은 `verify_result` 테이블에 적재되므로 Grafana 대시보드에
`kafka` 분류가 수정 없이 그대로 나타난다.

## 원본과 달라진 것

- 원본 verify-labs 의 11개 분류 중 5개만 이식 — security/graphql/redis/wiremock/otel 의존성 제거
- 도커 포트 자동감지 제거 — 로컬 PG(5432) 기본, `DB_URL`/`DB_PORT` 환경변수로 덮어쓴다
- **`VerificationResultJdbcSink` 추가** — 결과를 `verify_result` 테이블에 run_id 단위로 적재 (Grafana 원천).
  md 리포트를 대체하지 않는다 — 리포트는 판정 근거, 테이블은 시계열이다.
  적재 실패는 검증을 실패시키지 않는다(경고만 남기고 삼킨다). `VERIFY_SINK=false` 로 끈다.
- `POST /verify/run-and-store` 추가 — 코어의 `/verify/run` 은 저장하지 않는다(코어를 저장소에 안 붙이기 위해).

## 이 환경에서의 검증 결과

PostgreSQL 16.13 (로컬 프라이머리 5432 + 스트리밍 레플리카 5433) —
**51건 전부 CONFIRMED. REFUTED 0 / INCONCLUSIVE 0 / ERROR 0.**

레플리카를 붙이기 전에는 DB-24 가 INCONCLUSIVE 였다. `setup-replica.sh` 로
`pg_basebackup` 스탠바이를 만들고 `recovery_min_apply_delay=2s` 를 걸자
"쓰기 직후 레플리카에서 0행 → LSN 까지 따라온 뒤 1행"이 관측되며 CONFIRMED 로 바뀌었다.
그 2초 지연은 결과를 만든 것이 아니라, 같은 호스트에서는 수 ms 만에 따라잡혀
**관측 창 자체가 열리지 않는 현상을 볼 수 있는 크기로 고정**한 것이다(PostgreSQL 정식 기능).
