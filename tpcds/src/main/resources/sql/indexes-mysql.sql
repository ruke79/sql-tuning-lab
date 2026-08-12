-- TPC-DS 보조 인덱스 세트 - MySQL (PK는 스키마 생성 시 포함됨)

CREATE INDEX idx_ss_sold_date ON store_sales (ss_sold_date_sk);
CREATE INDEX idx_ss_customer  ON store_sales (ss_customer_sk);
CREATE INDEX idx_ss_cdemo     ON store_sales (ss_cdemo_sk);
CREATE INDEX idx_ss_store     ON store_sales (ss_store_sk);
CREATE INDEX idx_ss_promo     ON store_sales (ss_promo_sk);

CREATE INDEX idx_dd_year_moy  ON date_dim (d_year, d_moy);
CREATE INDEX idx_item_manufact ON item (i_manufact_id);
CREATE INDEX idx_item_manager  ON item (i_manager_id);
CREATE INDEX idx_cust_addr     ON customer (c_current_addr_sk);

ANALYZE TABLE date_dim, item, store, customer_address, customer_demographics,
              household_demographics, customer, promotion, store_sales;
