-- Issue #7 catalog management follow-up. Versioned and reversible through rehearsed restore, never destructive.
ALTER TABLE catalog_product_group
  ADD COLUMN active boolean NOT NULL DEFAULT true,
  ADD COLUMN revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0);
-- Allow generated quote reads to use indexed product/effective-time selection.
CREATE INDEX catalog_price_product_effective_idx ON catalog_price_entry
  (installation_id,branch_id,product_id,price_list_id,effective_at DESC,id DESC);
