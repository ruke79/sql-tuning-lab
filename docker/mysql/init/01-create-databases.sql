-- 벤치마크별 데이터베이스 분리
CREATE DATABASE IF NOT EXISTS tpch CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS tpcds CHARACTER SET utf8mb4;
CREATE DATABASE IF NOT EXISTS sysbench_lab CHARACTER SET utf8mb4;

GRANT ALL PRIVILEGES ON tpch.* TO 'tuner'@'%';
GRANT ALL PRIVILEGES ON tpcds.* TO 'tuner'@'%';
GRANT ALL PRIVILEGES ON sysbench_lab.* TO 'tuner'@'%';
-- performance_schema 조회 권한 (락 모니터링용)
GRANT SELECT, PROCESS ON *.* TO 'tuner'@'%';

-- 위의 DB 한정 권한으로는 부족하다. scripts/tpch|tpcds/mt-tenant-isolation-mysql.sh 는
-- mt_n0..24 / mt_s1..12 라는 **새 데이터베이스**와 계정 mt_app 을 만들었다 지운다 —
-- 그 권한이 없으면 준비 단계에서 죽는다(실제로 그렇게 막혔다). 실습용 로컬 컨테이너다.
GRANT ALL PRIVILEGES ON *.* TO 'tuner'@'%' WITH GRANT OPTION;
-- SET GLOBAL(§M-7 의 redo·내구성 조절)은 동적 권한이라 ALL PRIVILEGES 에 안 들어간다.
GRANT SYSTEM_VARIABLES_ADMIN ON *.* TO 'tuner'@'%';

-- 주의: 이 파일은 **볼륨이 비어 있는 첫 기동에만** 돈다. 이미 만들어진 mysqldata 볼륨에는
-- 소급 적용되지 않는다 — 그 경우 ./scripts/restore-lab.sh --mysql 이 같은 일을 한다.
FLUSH PRIVILEGES;
