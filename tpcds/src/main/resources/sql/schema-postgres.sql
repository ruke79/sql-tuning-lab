-- TPC-DS 스노우플레이크 스키마 핵심 서브셋 (store_sales 채널, 9 테이블) - PostgreSQL
-- 전체 24+ 테이블 공식 DDL은 tpcds-kit(tools/tpcds.sql) 참고.
-- 인덱스는 index 명령(sql/indexes-postgres.sql)으로 추가한다.

-- CASCADE 를 붙이는 이유: 실습 스크립트가 만든 **매트뷰·뷰가 원본 테이블에 의존한다.**
-- 실제로 t9-preaggregation 이 남긴 mv_q03 때문에 재적재가 통째로 막혔다:
--   ERROR: cannot drop table lineitem because other objects depend on it
--   Detail: materialized view mv_q03 depends on table lineitem
-- 그리고 schema 가 실패한 줄 모르고 load 를 이어 돌리면 '중복 키' 라는 엉뚱한 에러가 난다.
-- 여기서 CASCADE 로 지우는 것은 실습 잔여물이므로 없어져야 맞다.
DROP TABLE IF EXISTS store_sales CASCADE;
DROP TABLE IF EXISTS promotion CASCADE;
DROP TABLE IF EXISTS customer CASCADE;
DROP TABLE IF EXISTS customer_demographics CASCADE;
DROP TABLE IF EXISTS household_demographics CASCADE;
DROP TABLE IF EXISTS customer_address CASCADE;
DROP TABLE IF EXISTS store CASCADE;
DROP TABLE IF EXISTS item CASCADE;
DROP TABLE IF EXISTS date_dim CASCADE;

CREATE TABLE date_dim (
    d_date_sk           INTEGER      NOT NULL,
    d_date_id           CHAR(16)     NOT NULL,
    d_date              DATE,
    d_month_seq         INTEGER,
    d_week_seq          INTEGER,
    d_quarter_seq       INTEGER,
    d_year              INTEGER,
    d_dow               INTEGER,
    d_moy               INTEGER,
    d_dom               INTEGER,
    d_qoy               INTEGER,
    d_fy_year           INTEGER,
    d_fy_quarter_seq    INTEGER,
    d_fy_week_seq       INTEGER,
    d_day_name          CHAR(9),
    d_quarter_name      CHAR(6),
    d_holiday           CHAR(1),
    d_weekend           CHAR(1),
    d_following_holiday CHAR(1),
    d_first_dom         INTEGER,
    d_last_dom          INTEGER,
    d_same_day_ly       INTEGER,
    d_same_day_lq       INTEGER,
    d_current_day       CHAR(1),
    d_current_week      CHAR(1),
    d_current_month     CHAR(1),
    d_current_quarter   CHAR(1),
    d_current_year      CHAR(1)
);

CREATE TABLE item (
    i_item_sk        INTEGER      NOT NULL,
    i_item_id        CHAR(16)     NOT NULL,
    i_rec_start_date DATE,
    i_rec_end_date   DATE,
    i_item_desc      VARCHAR(200),
    i_current_price  DECIMAL(7,2),
    i_wholesale_cost DECIMAL(7,2),
    i_brand_id       INTEGER,
    i_brand          CHAR(50),
    i_class_id       INTEGER,
    i_class          CHAR(50),
    i_category_id    INTEGER,
    i_category       CHAR(50),
    i_manufact_id    INTEGER,
    i_manufact       CHAR(50),
    i_size           CHAR(20),
    i_formulation    CHAR(20),
    i_color          CHAR(20),
    i_units          CHAR(10),
    i_container      CHAR(10),
    i_manager_id     INTEGER,
    i_product_name   CHAR(50)
);

CREATE TABLE store (
    s_store_sk         INTEGER      NOT NULL,
    s_store_id         CHAR(16)     NOT NULL,
    s_rec_start_date   DATE,
    s_rec_end_date     DATE,
    s_closed_date_sk   INTEGER,
    s_store_name       VARCHAR(50),
    s_number_employees INTEGER,
    s_floor_space      INTEGER,
    s_hours            CHAR(20),
    s_manager          VARCHAR(40),
    s_market_id        INTEGER,
    s_geography_class  VARCHAR(100),
    s_market_desc      VARCHAR(100),
    s_market_manager   VARCHAR(40),
    s_division_id      INTEGER,
    s_division_name    VARCHAR(50),
    s_company_id       INTEGER,
    s_company_name     VARCHAR(50),
    s_street_number    VARCHAR(10),
    s_street_name      VARCHAR(60),
    s_street_type      CHAR(15),
    s_suite_number     CHAR(10),
    s_city             VARCHAR(60),
    s_county           VARCHAR(30),
    s_state            CHAR(2),
    s_zip              CHAR(10),
    s_country          VARCHAR(20),
    s_gmt_offset       DECIMAL(5,2),
    s_tax_precentage   DECIMAL(5,2)
);

CREATE TABLE customer_address (
    ca_address_sk    INTEGER      NOT NULL,
    ca_address_id    CHAR(16)     NOT NULL,
    ca_street_number CHAR(10),
    ca_street_name   VARCHAR(60),
    ca_street_type   CHAR(15),
    ca_suite_number  CHAR(10),
    ca_city          VARCHAR(60),
    ca_county        VARCHAR(30),
    ca_state         CHAR(2),
    ca_zip           CHAR(10),
    ca_country       VARCHAR(20),
    ca_gmt_offset    DECIMAL(5,2),
    ca_location_type CHAR(20)
);

CREATE TABLE customer_demographics (
    cd_demo_sk            INTEGER  NOT NULL,
    cd_gender             CHAR(1),
    cd_marital_status     CHAR(1),
    cd_education_status   CHAR(20),
    cd_purchase_estimate  INTEGER,
    cd_credit_rating      CHAR(10),
    cd_dep_count          INTEGER,
    cd_dep_employed_count INTEGER,
    cd_dep_college_count  INTEGER
);

CREATE TABLE household_demographics (
    hd_demo_sk        INTEGER  NOT NULL,
    hd_income_band_sk INTEGER,
    hd_buy_potential  CHAR(15),
    hd_dep_count      INTEGER,
    hd_vehicle_count  INTEGER
);

CREATE TABLE customer (
    c_customer_sk          INTEGER      NOT NULL,
    c_customer_id          CHAR(16)     NOT NULL,
    c_current_cdemo_sk     INTEGER,
    c_current_hdemo_sk     INTEGER,
    c_current_addr_sk      INTEGER,
    c_first_shipto_date_sk INTEGER,
    c_first_sales_date_sk  INTEGER,
    c_salutation           CHAR(10),
    c_first_name           CHAR(20),
    c_last_name            CHAR(30),
    c_preferred_cust_flag  CHAR(1),
    c_birth_day            INTEGER,
    c_birth_month          INTEGER,
    c_birth_year           INTEGER,
    c_birth_country        VARCHAR(20),
    c_login                CHAR(13),
    c_email_address        CHAR(50),
    c_last_review_date_sk  INTEGER
);

CREATE TABLE promotion (
    p_promo_sk        INTEGER      NOT NULL,
    p_promo_id        CHAR(16)     NOT NULL,
    p_start_date_sk   INTEGER,
    p_end_date_sk     INTEGER,
    p_item_sk         INTEGER,
    p_cost            DECIMAL(15,2),
    p_response_target INTEGER,
    p_promo_name      CHAR(50),
    p_channel_dmail   CHAR(1),
    p_channel_email   CHAR(1),
    p_channel_catalog CHAR(1),
    p_channel_tv      CHAR(1),
    p_channel_radio   CHAR(1),
    p_channel_press   CHAR(1),
    p_channel_event   CHAR(1),
    p_channel_demo    CHAR(1),
    p_channel_details VARCHAR(100),
    p_purpose         CHAR(15),
    p_discount_active CHAR(1)
);

CREATE TABLE store_sales (
    ss_sold_date_sk       INTEGER,
    ss_sold_time_sk       INTEGER,
    ss_item_sk            INTEGER       NOT NULL,
    ss_customer_sk        INTEGER,
    ss_cdemo_sk           INTEGER,
    ss_hdemo_sk           INTEGER,
    ss_addr_sk            INTEGER,
    ss_store_sk           INTEGER,
    ss_promo_sk           INTEGER,
    ss_ticket_number      BIGINT        NOT NULL,
    ss_quantity           INTEGER,
    ss_wholesale_cost     DECIMAL(7,2),
    ss_list_price         DECIMAL(7,2),
    ss_sales_price        DECIMAL(7,2),
    ss_ext_discount_amt   DECIMAL(7,2),
    ss_ext_sales_price    DECIMAL(7,2),
    ss_ext_wholesale_cost DECIMAL(7,2),
    ss_ext_list_price     DECIMAL(7,2),
    ss_ext_tax            DECIMAL(7,2),
    ss_coupon_amt         DECIMAL(7,2),
    ss_net_paid           DECIMAL(7,2),
    ss_net_paid_inc_tax   DECIMAL(7,2),
    ss_net_profit         DECIMAL(7,2)
);
