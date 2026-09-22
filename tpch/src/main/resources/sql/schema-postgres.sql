-- TPC-H 3NF 스키마 (8 테이블) - PostgreSQL
-- 인덱스 없이 생성된다. 인덱스는 index 명령(sql/indexes-postgres.sql)으로 추가하여
-- "인덱스 전/후" 실행계획 차이를 비교하는 것이 이 실습의 핵심이다.

-- CASCADE 를 붙이는 이유: 실습 스크립트가 만든 **매트뷰·뷰가 원본 테이블에 의존한다.**
-- 실제로 t9-preaggregation 이 남긴 mv_q03 때문에 재적재가 통째로 막혔다:
--   ERROR: cannot drop table lineitem because other objects depend on it
--   Detail: materialized view mv_q03 depends on table lineitem
-- 그리고 schema 가 실패한 줄 모르고 load 를 이어 돌리면 '중복 키' 라는 엉뚱한 에러가 난다.
-- 여기서 CASCADE 로 지우는 것은 실습 잔여물이므로 없어져야 맞다.
DROP TABLE IF EXISTS lineitem CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS partsupp CASCADE;
DROP TABLE IF EXISTS part CASCADE;
DROP TABLE IF EXISTS customer CASCADE;
DROP TABLE IF EXISTS supplier CASCADE;
DROP TABLE IF EXISTS nation CASCADE;
DROP TABLE IF EXISTS region CASCADE;

CREATE TABLE region (
    r_regionkey  INTEGER       NOT NULL,
    r_name       CHAR(25)      NOT NULL,
    r_comment    VARCHAR(152)
);

CREATE TABLE nation (
    n_nationkey  INTEGER       NOT NULL,
    n_name       CHAR(25)      NOT NULL,
    n_regionkey  INTEGER       NOT NULL,
    n_comment    VARCHAR(152)
);

CREATE TABLE supplier (
    s_suppkey    BIGINT        NOT NULL,
    s_name       CHAR(25)      NOT NULL,
    s_address    VARCHAR(40)   NOT NULL,
    s_nationkey  INTEGER       NOT NULL,
    s_phone      CHAR(15)      NOT NULL,
    s_acctbal    DECIMAL(15,2) NOT NULL,
    s_comment    VARCHAR(101)  NOT NULL
);

CREATE TABLE customer (
    c_custkey    BIGINT        NOT NULL,
    c_name       VARCHAR(25)   NOT NULL,
    c_address    VARCHAR(40)   NOT NULL,
    c_nationkey  INTEGER       NOT NULL,
    c_phone      CHAR(15)      NOT NULL,
    c_acctbal    DECIMAL(15,2) NOT NULL,
    c_mktsegment CHAR(10)      NOT NULL,
    c_comment    VARCHAR(117)  NOT NULL
);

CREATE TABLE part (
    p_partkey     BIGINT        NOT NULL,
    p_name        VARCHAR(55)   NOT NULL,
    p_mfgr        CHAR(25)      NOT NULL,
    p_brand       CHAR(10)      NOT NULL,
    p_type        VARCHAR(25)   NOT NULL,
    p_size        INTEGER       NOT NULL,
    p_container   CHAR(10)      NOT NULL,
    p_retailprice DECIMAL(15,2) NOT NULL,
    p_comment     VARCHAR(23)   NOT NULL
);

CREATE TABLE partsupp (
    ps_partkey    BIGINT        NOT NULL,
    ps_suppkey    BIGINT        NOT NULL,
    ps_availqty   INTEGER       NOT NULL,
    ps_supplycost DECIMAL(15,2) NOT NULL,
    ps_comment    VARCHAR(199)  NOT NULL
);

CREATE TABLE orders (
    o_orderkey      BIGINT        NOT NULL,
    o_custkey       BIGINT        NOT NULL,
    o_orderstatus   CHAR(1)       NOT NULL,
    o_totalprice    DECIMAL(15,2) NOT NULL,
    o_orderdate     DATE          NOT NULL,
    o_orderpriority CHAR(15)      NOT NULL,
    o_clerk         CHAR(15)      NOT NULL,
    o_shippriority  INTEGER       NOT NULL,
    o_comment       VARCHAR(79)   NOT NULL
);

CREATE TABLE lineitem (
    l_orderkey      BIGINT        NOT NULL,
    l_partkey       BIGINT        NOT NULL,
    l_suppkey       BIGINT        NOT NULL,
    l_linenumber    INTEGER       NOT NULL,
    l_quantity      DECIMAL(15,2) NOT NULL,
    l_extendedprice DECIMAL(15,2) NOT NULL,
    l_discount      DECIMAL(15,2) NOT NULL,
    l_tax           DECIMAL(15,2) NOT NULL,
    l_returnflag    CHAR(1)       NOT NULL,
    l_linestatus    CHAR(1)       NOT NULL,
    l_shipdate      DATE          NOT NULL,
    l_commitdate    DATE          NOT NULL,
    l_receiptdate   DATE          NOT NULL,
    l_shipinstruct  CHAR(25)      NOT NULL,
    l_shipmode      CHAR(10)      NOT NULL,
    l_comment       VARCHAR(44)   NOT NULL
);
