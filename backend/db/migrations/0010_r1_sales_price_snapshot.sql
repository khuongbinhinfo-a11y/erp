-- R1 Sales bridge. New SKU pricing is snapshotted without rewriting historical B1 lines.
-- Forward-only: retains every confirmed order/version and original B1 price entry.
ALTER TABLE sales_order ADD COLUMN channel_id uuid;
ALTER TABLE sales_order ADD CONSTRAINT sales_order_channel_scope_fk
  FOREIGN KEY(installation_id,branch_id,channel_id)
  REFERENCES catalog_sales_channel(installation_id,branch_id,id);

CREATE FUNCTION erp_sales_order_channel_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status='CONFIRMED' AND NEW.channel_id IS DISTINCT FROM OLD.channel_id THEN
    RAISE EXCEPTION 'Confirmed sales channel is immutable';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER sales_order_channel_guard BEFORE UPDATE ON sales_order
  FOR EACH ROW EXECUTE FUNCTION erp_sales_order_channel_guard();

ALTER TABLE sales_order_line
  ALTER COLUMN price_entry_id DROP NOT NULL,
  ADD COLUMN sell_sku_id uuid,
  ADD COLUMN pricing_engine text NOT NULL DEFAULT 'LEGACY',
  ADD COLUMN price_snapshot jsonb,
  ADD COLUMN price_signature text;

ALTER TABLE sales_order_line
  ADD CONSTRAINT sales_order_line_sku_scope_fk
    FOREIGN KEY(installation_id,branch_id,sell_sku_id)
    REFERENCES catalog_sell_sku(installation_id,branch_id,id),
  ADD CONSTRAINT sales_order_line_price_source_ck CHECK (
    (pricing_engine='LEGACY' AND sell_sku_id IS NULL
      AND price_entry_id IS NOT NULL AND price_snapshot IS NULL AND price_signature IS NULL)
    OR
    (pricing_engine='R1' AND sell_sku_id IS NOT NULL AND price_entry_id IS NULL
      AND price_snapshot IS NOT NULL AND jsonb_typeof(price_snapshot)='object'
      AND price_signature ~ '^[0-9a-f]{64}$')
  );

-- Legacy B1 allowed a product once per commercial version. R1 permits distinct
-- selling units of the same product while rejecting repeated identical SKUs.
DO $$
DECLARE old_constraint text; matching_count integer;
BEGIN
  SELECT count(*),min(conname) INTO matching_count,old_constraint
    FROM pg_constraint
    WHERE conrelid='sales_order_line'::regclass AND contype='u'
      AND position('product_id)' IN pg_get_constraintdef(oid))>0;
  IF matching_count<>1 THEN
    RAISE EXCEPTION 'Unexpected sales line legacy product uniqueness constraint';
  END IF;
  EXECUTE format('ALTER TABLE sales_order_line DROP CONSTRAINT %I',old_constraint);
END; $$;
CREATE UNIQUE INDEX sales_line_legacy_product_unique
  ON sales_order_line(installation_id,branch_id,order_id,version_no,product_id)
  WHERE pricing_engine='LEGACY';
CREATE UNIQUE INDEX sales_line_r1_sku_unique
  ON sales_order_line(installation_id,branch_id,order_id,version_no,sell_sku_id)
  WHERE pricing_engine='R1';

-- A R1 unit cannot be detached or pointed at another product after it was used.
-- The SKU identity guard in 0009 already prevents identity/conversion changes.
CREATE INDEX sales_order_line_sku_lookup
  ON sales_order_line(installation_id,branch_id,sell_sku_id)
  WHERE sell_sku_id IS NOT NULL;

-- Promotions must be finite even if an API caller bypasses Flutter validation.
-- No R1 promotion can remain eligible indefinitely without an end time.
ALTER TABLE catalog_sku_price_rule
  ADD CONSTRAINT catalog_r1_promotion_expiry
  CHECK (scope_kind <> 'PROMOTION' OR effective_to IS NOT NULL);

-- Retirement is a separate immutable event; the original commercial rule remains
-- readable for historical quotes and audit reconciliation.
CREATE TABLE catalog_sku_price_retirement (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  rule_id uuid NOT NULL,
  retired_at timestamptz NOT NULL DEFAULT now(),
  reason text NOT NULL CHECK(length(trim(reason)) BETWEEN 3 AND 500),
  actor_id uuid NOT NULL,
  PRIMARY KEY(installation_id,branch_id,rule_id),
  FOREIGN KEY(installation_id,branch_id,rule_id)
    REFERENCES catalog_sku_price_rule(installation_id,branch_id,id),
  FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);
CREATE INDEX catalog_sku_price_retirement_time_idx
  ON catalog_sku_price_retirement(installation_id,branch_id,retired_at);
CREATE TRIGGER catalog_sku_price_retirement_immutable
  BEFORE UPDATE OR DELETE ON catalog_sku_price_retirement
  FOR EACH ROW EXECUTE FUNCTION erp_r1_price_rule_guard();
