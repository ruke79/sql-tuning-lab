-- pgbench (TPC-B 계열) 은행 거래 스키마 - 공식 pgbench -i 와 동일한 구조
-- fillfactor로 HOT(Heap Only Tuple) 업데이트 여지를 확보하는 것까지 동일하게 재현

DROP TABLE IF EXISTS pgbench_history;
DROP TABLE IF EXISTS pgbench_accounts;
DROP TABLE IF EXISTS pgbench_tellers;
DROP TABLE IF EXISTS pgbench_branches;

CREATE TABLE pgbench_branches (
    bid      INTEGER NOT NULL PRIMARY KEY,
    bbalance INTEGER,
    filler   CHAR(88)
) WITH (fillfactor = 100);

CREATE TABLE pgbench_tellers (
    tid      INTEGER NOT NULL PRIMARY KEY,
    bid      INTEGER,
    tbalance INTEGER,
    filler   CHAR(84)
) WITH (fillfactor = 100);

CREATE TABLE pgbench_accounts (
    aid      BIGINT NOT NULL PRIMARY KEY,
    bid      INTEGER,
    abalance INTEGER,
    filler   CHAR(84)
) WITH (fillfactor = 100);

CREATE TABLE pgbench_history (
    tid    INTEGER,
    bid    INTEGER,
    aid    BIGINT,
    delta  INTEGER,
    mtime  TIMESTAMP,
    filler CHAR(22)
);
