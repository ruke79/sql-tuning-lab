-- TPC-DS 인덱스 세트 - PostgreSQL
-- Star Join 튜닝의 핵심: 팩트 테이블(store_sales)의 각 차원 FK 인덱스

-- 다시 돌려도 되게 한다 — PostgreSQL 에는 ADD PRIMARY KEY IF NOT EXISTS 가 없다.
-- (tpch 판과 같은 이유다. restore-lab.sh 가 '인덱스가 모자란' 상태를 고치려고 부르는데,
--  일부만 있는 상태에서 첫 문장이 죽으면 복구가 통째로 실패한다.)
DO $$ DECLARE t text; c text;
BEGIN
  FOR t, c IN VALUES
      ('date_dim','d_date_sk'), ('item','i_item_sk'), ('store','s_store_sk'),
      ('customer_address','ca_address_sk'), ('customer_demographics','cd_demo_sk'),
      ('household_demographics','hd_demo_sk'), ('customer','c_customer_sk'),
      ('promotion','p_promo_sk'), ('store_sales','ss_item_sk, ss_ticket_number')
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = t::regclass AND contype = 'p') THEN
      EXECUTE format('ALTER TABLE %I ADD PRIMARY KEY (%s)', t, c);
    END IF;
  END LOOP;
END $$;

-- 팩트 테이블 FK 인덱스
CREATE INDEX IF NOT EXISTS idx_ss_sold_date ON store_sales (ss_sold_date_sk);
CREATE INDEX IF NOT EXISTS idx_ss_customer  ON store_sales (ss_customer_sk);
CREATE INDEX IF NOT EXISTS idx_ss_cdemo     ON store_sales (ss_cdemo_sk);
CREATE INDEX IF NOT EXISTS idx_ss_store     ON store_sales (ss_store_sk);
CREATE INDEX IF NOT EXISTS idx_ss_promo     ON store_sales (ss_promo_sk);

-- 차원 필터 인덱스
CREATE INDEX IF NOT EXISTS idx_dd_year_moy  ON date_dim (d_year, d_moy);
CREATE INDEX IF NOT EXISTS idx_item_manufact ON item (i_manufact_id);
CREATE INDEX IF NOT EXISTS idx_item_manager  ON item (i_manager_id);
CREATE INDEX IF NOT EXISTS idx_cust_addr     ON customer (c_current_addr_sk);

ANALYZE;
