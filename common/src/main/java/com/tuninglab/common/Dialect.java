package com.tuninglab.common;

/** 대상 DBMS 방언. EXPLAIN 문법과 로딩 전략이 달라진다. */
public enum Dialect {
    POSTGRES,
    MYSQL,
    CLICKHOUSE;

    public static Dialect fromJdbcUrl(String url) {
        if (url.startsWith("jdbc:postgresql")) return POSTGRES;
        if (url.startsWith("jdbc:mysql")) return MYSQL;
        if (url.startsWith("jdbc:clickhouse") || url.startsWith("jdbc:ch")) return CLICKHOUSE;
        throw new IllegalArgumentException("Unknown JDBC url: " + url);
    }
}
