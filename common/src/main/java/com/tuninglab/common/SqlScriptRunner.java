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
        for (String statement : script.split(";\\s*(\\r?\\n|$)")) {
            String sql = stripComments(statement).trim();
            if (sql.isEmpty()) continue;
            log.info("DDL: {}", firstLine(sql));
            jdbc.execute(sql);
        }
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
