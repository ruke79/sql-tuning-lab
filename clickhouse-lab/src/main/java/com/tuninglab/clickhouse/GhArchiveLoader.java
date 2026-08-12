package com.tuninglab.clickhouse;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import javax.sql.DataSource;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.util.zip.GZIPInputStream;

/**
 * GH Archive(https://data.gharchive.org) 시간별 이벤트 파일을 다운로드하여
 * ClickHouse에 스트리밍 적재한다.
 *
 * 파일 하나(1시간) ≈ 10~20만 이벤트. 1억 건 ≈ 약 30일치(720시간).
 * 30억 건+ 전체 이력은 ClickHouse 공식 github_events 데이터셋(s3) 참고 (README).
 */
public class GhArchiveLoader {

    private static final Logger log = LoggerFactory.getLogger(GhArchiveLoader.class);

    private static final String INSERT_SQL = """
            INSERT INTO gharchive.github_events
            (event_id, event_type, actor_login, repo_name, created_at, action,
             number, title, language, ref, ref_type, push_size, comment_len)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """;

    private final DataSource dataSource;
    private final String baseUrl;
    private final ObjectMapper mapper = new ObjectMapper();
    private final HttpClient http = HttpClient.newBuilder()
            .followRedirects(HttpClient.Redirect.NORMAL)
            .build();

    public GhArchiveLoader(DataSource dataSource, String baseUrl) {
        this.dataSource = dataSource;
        this.baseUrl = baseUrl;
    }

    /** from(포함) ~ to(포함) 날짜의 hourFrom~hourTo 시간대 파일들을 적재 */
    public void load(LocalDate from, LocalDate to, int hourFrom, int hourTo, int batchSize)
            throws Exception {
        long total = 0;
        try (Connection conn = dataSource.getConnection()) {
            for (LocalDate d = from; !d.isAfter(to); d = d.plusDays(1)) {
                for (int h = hourFrom; h <= hourTo; h++) {
                    total += loadHour(conn, d, h, batchSize);
                }
            }
        }
        log.info("TOTAL loaded: {} events", total);
    }

    private long loadHour(Connection conn, LocalDate date, int hour, int batchSize)
            throws IOException, InterruptedException, SQLException {
        String url = String.format("%s/%s-%d.json.gz", baseUrl, date, hour);
        log.info("Downloading {}", url);

        HttpRequest request = HttpRequest.newBuilder(URI.create(url)).GET().build();
        HttpResponse<InputStream> response =
                http.send(request, HttpResponse.BodyHandlers.ofInputStream());
        if (response.statusCode() != 200) {
            log.warn("Skip {} (HTTP {})", url, response.statusCode());
            return 0;
        }

        long rows = 0;
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                new GZIPInputStream(response.body()), StandardCharsets.UTF_8));
             PreparedStatement ps = conn.prepareStatement(INSERT_SQL)) {

            int inBatch = 0;
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.isEmpty()) continue;
                JsonNode e;
                try {
                    e = mapper.readTree(line);
                } catch (Exception parseError) {
                    continue;
                }
                bind(ps, e);
                ps.addBatch();
                if (++inBatch >= batchSize) {
                    ps.executeBatch();
                    rows += inBatch;
                    inBatch = 0;
                }
            }
            if (inBatch > 0) {
                ps.executeBatch();
                rows += inBatch;
            }
        }
        log.info("{}-{}h: {} events loaded", date, hour, rows);
        return rows;
    }

    private void bind(PreparedStatement ps, JsonNode e) throws SQLException {
        JsonNode payload = e.path("payload");
        JsonNode prOrIssue = payload.has("pull_request")
                ? payload.path("pull_request") : payload.path("issue");

        long id = e.path("id").asLong(0);
        LocalDateTime createdAt;
        try {
            createdAt = OffsetDateTime.parse(e.path("created_at").asText()).toLocalDateTime();
        } catch (Exception ex) {
            createdAt = LocalDateTime.of(1970, 1, 1, 0, 0);
        }

        ps.setLong(1, id);
        ps.setString(2, e.path("type").asText(""));
        ps.setString(3, e.path("actor").path("login").asText(""));
        ps.setString(4, e.path("repo").path("name").asText(""));
        ps.setTimestamp(5, Timestamp.valueOf(createdAt));
        ps.setString(6, payload.path("action").asText(""));
        ps.setInt(7, prOrIssue.path("number").asInt(0));
        ps.setString(8, truncate(prOrIssue.path("title").asText(""), 512));
        ps.setString(9, prOrIssue.path("base").path("repo").path("language").asText(""));
        ps.setString(10, truncate(payload.path("ref").asText(""), 256));
        ps.setString(11, payload.path("ref_type").asText(""));
        ps.setInt(12, Math.min(65535, payload.path("size").asInt(0)));
        ps.setInt(13, payload.path("comment").path("body").asText("").length());
    }

    private String truncate(String s, int max) {
        return s.length() <= max ? s : s.substring(0, max);
    }
}
