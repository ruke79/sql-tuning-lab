package com.tuninglab.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.Resource;
import org.springframework.jdbc.core.JdbcTemplate;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

/** 클래스패스의 .sql 스크립트를 세미콜론 단위로 실행한다. */
public class SqlScriptRunner {

    private static final Logger log = LoggerFactory.getLogger(SqlScriptRunner.class);

    private final JdbcTemplate jdbc;

    public SqlScriptRunner(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public void run(Resource resource) {
        String script;
        try {
            script = resource.getContentAsString(StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new RuntimeException("Cannot read " + resource, e);
        }
        for (String statement : split(script)) {
            String sql = stripComments(statement).trim();
            if (sql.isEmpty()) continue;
            log.info("DDL: {}", firstLine(sql));
            jdbc.execute(sql);
        }
    }

    /**
     * 세미콜론으로 나누되 <b>달러 인용 블록({@code $$ ... $$}) 안의 세미콜론은 건너뛴다.</b>
     * 단순히 {@code split(";")} 하면 PostgreSQL 의 {@code DO $$ ... END $$} 가 조각나서
     * 문법 오류가 난다. 인덱스 스크립트가 "이미 있으면 건너뛴다"를 DO 블록으로 표현하므로
     * 이 처리가 필요하다.
     */
    static java.util.List<String> split(String script) {
        java.util.List<String> out = new java.util.ArrayList<>();
        StringBuilder cur = new StringBuilder();
        boolean inDollar = false;
        for (int i = 0; i < script.length(); i++) {
            char c = script.charAt(i);
            if (c == '$' && i + 1 < script.length() && script.charAt(i + 1) == '$') {
                inDollar = !inDollar;
                cur.append("$$");
                i++;
                continue;
            }
            if (c == ';' && !inDollar) {
                out.add(cur.toString());
                cur.setLength(0);
                continue;
            }
            cur.append(c);
        }
        if (!cur.toString().isBlank()) out.add(cur.toString());
        return out;
    }

    private String stripComments(String sql) {
        return sql.lines()
                .filter(l -> !l.trim().startsWith("--"))
                .reduce((a, b) -> a + "\n" + b)
                .orElse("");
    }

    private String firstLine(String sql) {
        String line = sql.lines().findFirst().orElse(sql);
        return line.length() > 80 ? line.substring(0, 80) + "..." : line;
    }
}
