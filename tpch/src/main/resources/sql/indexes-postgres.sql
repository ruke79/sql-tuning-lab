-- TPC-H 인덱스 세트 - PostgreSQL
-- 실습 순서 제안:
--   1) 인덱스 없이 run --explain 으로 Seq Scan / Hash Join 계획 확인
--   2) 본 스크립트 적용 후 동일 쿼리 재실행 → Index Scan / Merge Join 변화 관찰
--   3) 개별 인덱스를 DROP 해가며 어떤 쿼리가 영향을 받는지 확인

-- **다시 돌려도 되게 한다.** PostgreSQL 에는 ADD PRIMARY KEY IF NOT EXISTS 가 없어서,
-- 예전에는 이미 인덱스가 있는 DB 에 index 를 돌리면 첫 문장에서 바로 죽었다:
--   ERROR: multiple primary keys for table "region" are not allowed
-- 그런데 restore-lab.sh 는 "행은 있는데 인덱스가 모자란" 상태를 고치려고 바로 이 명령을
-- 부른다 — 일부만 있는 상태에서는 복구가 통째로 실패했다. 그래서 있으면 건너뛴다.
DO $$ DECLARE t text; c text;
BEGIN
  FOR t, c IN VALUES
      ('region','r_regionkey'), ('nation','n_nationkey'), ('supplier','s_suppkey'),
      ('customer','c_custkey'), ('part','p_partkey'), ('partsupp','ps_partkey, ps_suppkey'),
      ('orders','o_orderkey'), ('lineitem','l_orderkey, l_linenumber')
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = t::regclass AND contype = 'p') THEN
      EXECUTE format('ALTER TABLE %I ADD PRIMARY KEY (%s)', t, c);
    END IF;
  END LOOP;
END $$;

-- 조인 키 보조 인덱스
CREATE INDEX IF NOT EXISTS idx_nation_regionkey    ON nation (n_regionkey);
CREATE INDEX IF NOT EXISTS idx_supplier_nationkey  ON supplier (s_nationkey);
CREATE INDEX IF NOT EXISTS idx_customer_nationkey  ON customer (c_nationkey);
CREATE INDEX IF NOT EXISTS idx_partsupp_suppkey    ON partsupp (ps_suppkey);
CREATE INDEX IF NOT EXISTS idx_orders_custkey      ON orders (o_custkey);
CREATE INDEX IF NOT EXISTS idx_lineitem_partkey    ON lineitem (l_partkey, l_suppkey);
CREATE INDEX IF NOT EXISTS idx_lineitem_suppkey    ON lineitem (l_suppkey);

-- 범위 검색 인덱스 (Q1, Q3, Q5, Q6의 날짜 필터)
CREATE INDEX IF NOT EXISTS idx_orders_orderdate    ON orders (o_orderdate);
CREATE INDEX IF NOT EXISTS idx_lineitem_shipdate   ON lineitem (l_shipdate);

-- 통계 갱신
ANALYZE;
