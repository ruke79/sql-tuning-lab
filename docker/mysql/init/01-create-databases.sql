-- 벤치마크별 데이터베이스 분리
CREATE DATABASE IF NOT EXISTS tpch CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS tpcds CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS sysbench_lab CHARACTER SET utf8mb4;

GRANT ALL PRIVILEGES ON tpch.* TO 'tuner'@'%';
GRANT ALL PRIVILEGES ON tpcds.* TO 'tuner'@'%';
GRANT ALL PRIVILEGES ON sysbench_lab.* TO 'tuner'@'%';
-- performance_schema 조회 권한 (락 모니터링용)
GRANT SELECT, PROCESS ON *.* TO 'tuner'@'%';
FLUSH PRIVILEGES;
