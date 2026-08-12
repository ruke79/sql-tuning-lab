-- TPC-DS 인덱스 세트 - PostgreSQL
-- Star Join 튜닝의 핵심: 팩트 테이블(store_sales)의 각 차원 FK 인덱스

ALTER TABLE date_dim               ADD PRIMARY KEY (d_date_sk);
ALTER TABLE item                   ADD PRIMARY KEY (i_item_sk);
ALTER TABLE store                  ADD PRIMARY KEY (s_store_sk);
ALTER TABLE customer_address       ADD PRIMARY KEY (ca_address_sk);
ALTER TABLE customer_demographics  ADD PRIMARY KEY (cd_demo_sk);
ALTER TABLE household_demographics ADD PRIMARY KEY (hd_demo_sk);
ALTER TABLE customer               ADD PRIMARY KEY (c_customer_sk);
ALTER TABLE promotion              ADD PRIMARY KEY (p_promo_sk);
ALTER TABLE store_sales            ADD PRIMARY KEY (ss_item_sk, ss_ticket_number);

-- 팩트 테이블 FK 인덱스
CREATE INDEX idx_ss_sold_date ON store_sales (ss_sold_date_sk);
CREATE INDEX idx_ss_customer  ON store_sales (ss_customer_sk);
CREATE INDEX idx_ss_cdemo     ON store_sales (ss_cdemo_sk);
CREATE INDEX idx_ss_store     ON store_sales (ss_store_sk);
CREATE INDEX idx_ss_promo     ON store_sales (ss_promo_sk);

-- 차원 필터 인덱스
CREATE INDEX idx_dd_year_moy  ON date_dim (d_year, d_moy);
CREATE INDEX idx_item_manufact ON item (i_manufact_id);
CREATE INDEX idx_item_manager  ON item (i_manager_id);
CREATE INDEX idx_cust_addr     ON customer (c_current_addr_sk);

ANALYZE;
