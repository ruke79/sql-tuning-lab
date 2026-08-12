-- TPC-H 인덱스 세트 - PostgreSQL
-- 실습 순서 제안:
--   1) 인덱스 없이 run --explain 으로 Seq Scan / Hash Join 계획 확인
--   2) 본 스크립트 적용 후 동일 쿼리 재실행 → Index Scan / Merge Join 변화 관찰
--   3) 개별 인덱스를 DROP 해가며 어떤 쿼리가 영향을 받는지 확인

ALTER TABLE region   ADD PRIMARY KEY (r_regionkey);
ALTER TABLE nation   ADD PRIMARY KEY (n_nationkey);
ALTER TABLE supplier ADD PRIMARY KEY (s_suppkey);
ALTER TABLE customer ADD PRIMARY KEY (c_custkey);
ALTER TABLE part     ADD PRIMARY KEY (p_partkey);
ALTER TABLE partsupp ADD PRIMARY KEY (ps_partkey, ps_suppkey);
ALTER TABLE orders   ADD PRIMARY KEY (o_orderkey);
ALTER TABLE lineitem ADD PRIMARY KEY (l_orderkey, l_linenumber);

-- 조인 키 보조 인덱스
CREATE INDEX idx_nation_regionkey    ON nation (n_regionkey);
CREATE INDEX idx_supplier_nationkey  ON supplier (s_nationkey);
CREATE INDEX idx_customer_nationkey  ON customer (c_nationkey);
CREATE INDEX idx_partsupp_suppkey    ON partsupp (ps_suppkey);
CREATE INDEX idx_orders_custkey      ON orders (o_custkey);
CREATE INDEX idx_lineitem_partkey    ON lineitem (l_partkey, l_suppkey);
CREATE INDEX idx_lineitem_suppkey    ON lineitem (l_suppkey);

-- 범위 검색 인덱스 (Q1, Q3, Q5, Q6의 날짜 필터)
CREATE INDEX idx_orders_orderdate    ON orders (o_orderdate);
CREATE INDEX idx_lineitem_shipdate   ON lineitem (l_shipdate);

-- 통계 갱신
ANALYZE;
