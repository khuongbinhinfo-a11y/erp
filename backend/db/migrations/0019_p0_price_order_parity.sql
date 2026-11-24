-- P0 pricing/order parity: forward-only; historical posted orders remain untouched.
-- A line can be split into multiple separately priced lines of the same SKU.
-- The canonical sales_order_line primary key (order/version/line_no) remains unique.
DROP INDEX sales_line_r1_sku_unique;
CREATE INDEX sales_line_r1_sku_lookup ON sales_order_line
 (installation_id,branch_id,order_id,version_no,sell_sku_id)
 WHERE pricing_engine='R1';

-- 0008 originally locked VAT at zero until pricing and tax were implemented.
-- Retain the independently defined 0..100 tax rate check.
ALTER TABLE sales_order_line DROP CONSTRAINT sales_order_line_tax_rate_check1;

-- Preserve gross-price/discount inputs from SKU Excel imports alongside the
-- exact net fixed-price rule, without altering or deleting old policy history.
ALTER TABLE catalog_sku_price_rule
 ADD COLUMN imported_gross_amount numeric(18,4)
   CHECK(imported_gross_amount IS NULL OR imported_gross_amount>=0),
 ADD COLUMN imported_discount_rate numeric(5,2)
   CHECK(imported_discount_rate IS NULL OR imported_discount_rate BETWEEN 0 AND 100),
 ADD CONSTRAINT sku_price_import_pair_ck CHECK (
  (imported_gross_amount IS NULL AND imported_discount_rate IS NULL) OR
  (imported_gross_amount IS NOT NULL AND imported_discount_rate IS NOT NULL
   AND scope_kind='BASE' AND adjustment='FIXED_PRICE')
 );

-- Price rule history is immutable; new import metadata is inserted atomically
-- by the same audited R1 mutation, never patched into a posted rule.
