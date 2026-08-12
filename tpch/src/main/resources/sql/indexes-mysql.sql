-- TPC-H 보조 인덱스 세트 - MySQL
-- EXPLAIN FORMAT=TREE / EXPLAIN ANALYZE 로 인덱스 전/후 계획 변화를 관찰한다.

CREATE INDEX idx_nation_regionkey    ON nation (n_regionkey);
CREATE INDEX idx_supplier_nationkey  ON supplier (s_nationkey);
CREATE INDEX idx_customer_nationkey  ON customer (c_nationkey);
CREATE INDEX idx_partsupp_suppkey    ON partsupp (ps_suppkey);
CREATE INDEX idx_orders_custkey      ON orders (o_custkey);
CREATE INDEX idx_lineitem_partkey    ON lineitem (l_partkey, l_suppkey);
CREATE INDEX idx_lineitem_suppkey    ON lineitem (l_suppkey);
CREATE INDEX idx_orders_orderdate    ON orders (o_orderdate);
CREATE INDEX idx_lineitem_shipdate   ON lineitem (l_shipdate);

ANALYZE TABLE region, nation, supplier, customer, part, partsupp, orders, lineitem;
