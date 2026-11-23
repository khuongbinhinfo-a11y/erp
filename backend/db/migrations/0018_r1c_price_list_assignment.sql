-- R1-C: effective date window and deterministic scope assignment for price lists.
-- Forward-only. Existing lists stay valid without an explicit assignment;
-- legacy callers passing priceListId keep their historical API contract.
ALTER TABLE catalog_price_list
  ADD COLUMN effective_from timestamptz,
  ADD COLUMN effective_to timestamptz,
  ADD COLUMN priority integer NOT NULL DEFAULT 0
    CHECK (priority BETWEEN -100000 AND 100000),
  ADD CONSTRAINT catalog_price_list_valid_period
    CHECK (effective_from IS NULL OR effective_to IS NULL
      OR effective_from<effective_to);

CREATE TABLE catalog_price_list_assignment (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  price_list_id uuid NOT NULL,
  scope_kind text NOT NULL
    CHECK (scope_kind IN ('DEFAULT','CUSTOMER','CUSTOMER_GROUP','CHANNEL')),
  customer_id uuid,
  customer_group_id uuid,
  channel_id uuid,
  priority integer NOT NULL DEFAULT 0
    CHECK (priority BETWEEN -100000 AND 100000),
  effective_from timestamptz,
  effective_to timestamptz,
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision>=0),
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  PRIMARY KEY(installation_id,branch_id,id),
  FOREIGN KEY(installation_id,branch_id,price_list_id)
    REFERENCES catalog_price_list(installation_id,branch_id,id),
  FOREIGN KEY(installation_id,branch_id,customer_id)
    REFERENCES catalog_customer(installation_id,branch_id,id),
  FOREIGN KEY(installation_id,branch_id,customer_group_id)
    REFERENCES catalog_customer_group(installation_id,branch_id,id),
  FOREIGN KEY(installation_id,branch_id,channel_id)
    REFERENCES catalog_sales_channel(installation_id,branch_id,id),
  CONSTRAINT catalog_assignment_scope_match CHECK (
    (scope_kind='DEFAULT'
      AND customer_id IS NULL AND customer_group_id IS NULL AND channel_id IS NULL)
    OR (scope_kind='CUSTOMER'
      AND customer_id IS NOT NULL AND customer_group_id IS NULL AND channel_id IS NULL)
    OR (scope_kind='CUSTOMER_GROUP'
      AND customer_id IS NULL AND customer_group_id IS NOT NULL AND channel_id IS NULL)
    OR (scope_kind='CHANNEL'
      AND customer_id IS NULL AND customer_group_id IS NULL AND channel_id IS NOT NULL)),
  CONSTRAINT catalog_assignment_valid_period CHECK (
    effective_from IS NULL OR effective_to IS NULL OR effective_from<effective_to)
);
CREATE INDEX catalog_price_list_assignment_select_idx
  ON catalog_price_list_assignment
    (installation_id,branch_id,active,scope_kind,priority DESC,price_list_id);
CREATE INDEX catalog_price_list_effective_idx
  ON catalog_price_list(installation_id,branch_id,active,priority DESC);
