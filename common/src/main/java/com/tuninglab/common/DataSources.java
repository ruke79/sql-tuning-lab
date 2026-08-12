package com.tuninglab.common;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

/** 벤치마크용 HikariCP DataSource 팩토리. */
public final class DataSources {

    private DataSources() {}

    public static HikariDataSource create(String url, String username, String password, int poolSize) {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(url);
        config.setUsername(username);
        config.setPassword(password);
        config.setMaximumPoolSize(poolSize);
        config.setMinimumIdle(Math.min(2, poolSize));
        config.setAutoCommit(true);
        config.setConnectionTimeout(10_000);
        return new HikariDataSource(config);
    }
}
