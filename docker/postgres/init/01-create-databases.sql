-- 벤치마크별 데이터베이스 분리
CREATE DATABASE tpch;
CREATE DATABASE tpcds;
CREATE DATABASE pgbench_lab;

\c tpch
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
\c tpcds
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
\c pgbench_lab
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
