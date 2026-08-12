package com.tuninglab.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Types;
import java.util.ArrayList;
import java.util.List;

/**
 * 구분자 파일(.tbl/.dat/.csv)을 배치 INSERT로 적재한다.
 * - dbgen/dsdgen 이 만드는 라인 끝의 잉여 구분자('|')는 자동 제거
 * - MySQL은 JDBC URL에 rewriteBatchedStatements=true 필수 (multi-value insert로 재작성)
 *
 * 모든 필드는 파일에서 문자열로 읽으므로 드라이버에 형변환을 위임한다.
 * PostgreSQL은 setString()으로 넘기면 파라미터 타입이 varchar로 확정되어
 * integer/date 컬럼 INSERT가 "column is of type integer but expression is of type
 * character varying" 오류로 실패한다. 따라서 PG에서는 Types.OTHER로 바인딩하여
 * OID를 unspecified로 두고 서버가 대상 컬럼 타입을 추론하도록 한다.
 */
public class DelimitedFileLoader {

    private static final Logger log = LoggerFactory.getLogger(DelimitedFileLoader.class);

    private final JdbcTemplate jdbc;
    private final Dialect dialect;
    private final char delimiter;
    private final int batchSize;

    public DelimitedFileLoader(JdbcTemplate jdbc, Dialect dialect, char delimiter, int batchSize) {
        this.jdbc = jdbc;
        this.dialect = dialect;
        this.delimiter = delimiter;
        this.batchSize = batchSize;
    }

    public long load(Path file, String table, int columnCount) {
        String placeholders = String.join(",", java.util.Collections.nCopies(columnCount, "?"));
        String insertSql = "INSERT INTO " + table + " VALUES (" + placeholders + ")";

        long total = 0;
        long startMs = System.currentTimeMillis();
        try (BufferedReader reader = Files.newBufferedReader(file, StandardCharsets.UTF_8)) {
            List<String[]> batch = new ArrayList<>(batchSize);
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.isEmpty()) continue;
                batch.add(split(line, columnCount));
                if (batch.size() >= batchSize) {
                    flush(insertSql, batch);
                    total += batch.size();
                    batch.clear();
                    if (total % 500_000 == 0) {
                        log.info("{} <- {} rows ({} rows/s)", table, total,
                                total * 1000 / Math.max(1, System.currentTimeMillis() - startMs));
                    }
                }
            }
            if (!batch.isEmpty()) {
                flush(insertSql, batch);
                total += batch.size();
            }
        } catch (IOException e) {
            throw new RuntimeException("Failed to read " + file, e);
        }
        log.info("{} <- {} rows loaded in {} s", table, total,
                (System.currentTimeMillis() - startMs) / 1000);
        return total;
    }

    private String[] split(String line, int columnCount) {
        // dbgen 스타일: 라인 끝에 구분자가 하나 더 붙는다 → 제거
        if (!line.isEmpty() && line.charAt(line.length() - 1) == delimiter) {
            line = line.substring(0, line.length() - 1);
        }
        String[] parts = line.split(java.util.regex.Pattern.quote(String.valueOf(delimiter)), -1);
        if (parts.length != columnCount) {
            throw new IllegalStateException(
                    "Expected " + columnCount + " columns but got " + parts.length + ": " + line);
        }
        return parts;
    }

    private void flush(String insertSql, List<String[]> batch) {
        jdbc.batchUpdate(insertSql, batch, batch.size(), (PreparedStatement ps, String[] row) -> {
            for (int i = 0; i < row.length; i++) {
                setValue(ps, i + 1, row[i]);
            }
        });
    }

    private void setValue(PreparedStatement ps, int idx, String raw) throws SQLException {
        boolean isNull = raw == null || raw.isEmpty() || raw.equals("\\N");
        if (dialect == Dialect.POSTGRES) {
            // Oid.UNSPECIFIED 로 바인딩 → 서버가 대상 컬럼 타입으로 캐스팅
            ps.setObject(idx, isNull ? null : raw, Types.OTHER);
        } else if (isNull) {
            ps.setNull(idx, Types.VARCHAR);
        } else {
            ps.setString(idx, raw);   // MySQL은 문자열 → 숫자/날짜 암묵적 변환을 지원
        }
    }
}
