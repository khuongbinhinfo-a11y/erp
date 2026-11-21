-- R3.1 inventory facts. PostgreSQL inventory is authoritative; no client stock balance writes.
-- This migration is for CI/review only until separately approved backup/restore production gate.
CREATE TABLE inventory_ledger (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('OPENING','RECEIPT','ISSUE','TRANSFER_IN','TRANSFER_OUT','REVERSAL')),
  source_type text NOT NULL CHECK (source_type IN ('OPENING','PURCHASE_RECEIPT','FULFILLMENT','TRANSFER','REVERSAL')),
  source_id uuid NOT NULL,
  source_line integer NOT NULL CHECK (source_line BETWEEN 1 AND 10000),
  delta_base numeric(24,6) NOT NULL CHECK (delta_base <> 0),
  reversal_of uuid,
  actor_id uuid NOT NULL,
  request_id text NOT NULL CHECK (length(request_id) BETWEEN 1 AND 80),
  posted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id,branch_id,warehouse_id,id),
  FOREIGN KEY (installation_id,branch_id,warehouse_id)
    REFERENCES warehouse(installation_id,branch_id,id),
  FOREIGN KEY (installation_id,branch_id,product_id)
    REFERENCES catalog_product(installation_id,branch_id,id),
  FOREIGN KEY (installation_id,actor_id) REFERENCES app_user(installation_id,id),
  FOREIGN KEY (installation_id,branch_id,warehouse_id,reversal_of)
    REFERENCES inventory_ledger(installation_id,branch_id,warehouse_id,id),
  CHECK ((kind='REVERSAL') = (reversal_of IS NOT NULL)),
  CHECK ((kind IN ('OPENING','RECEIPT','TRANSFER_IN') AND delta_base > 0)
      OR (kind IN ('ISSUE','TRANSFER_OUT') AND delta_base < 0)
      OR kind='REVERSAL')
);
CREATE UNIQUE INDEX inventory_ledger_source_once
  ON inventory_ledger(installation_id,branch_id,source_type,source_id,source_line)
  WHERE kind <> 'REVERSAL';
CREATE UNIQUE INDEX inventory_ledger_reversal_once
  ON inventory_ledger(installation_id,branch_id,warehouse_id,reversal_of)
  WHERE reversal_of IS NOT NULL;
CREATE INDEX inventory_ledger_stock_idx
  ON inventory_ledger(installation_id,branch_id,warehouse_id,product_id,posted_at,id);

CREATE FUNCTION erp_inventory_ledger_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Posted inventory ledger is immutable';
END; $$;
CREATE TRIGGER inventory_ledger_immutable BEFORE UPDATE OR DELETE ON inventory_ledger
 FOR EACH ROW EXECUTE FUNCTION erp_inventory_ledger_immutable();

-- Warehouse-level sales demand. ACTIVE reservations do not post a movement.
-- Partial allocation, lots/locations, FEFO, pick/pack and consumption are later R3 slices.
CREATE TABLE inventory_reservation (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL,
  order_id uuid NOT NULL,
  version_no integer NOT NULL,
  line_no integer NOT NULL,
  quantity_base numeric(24,6) NOT NULL CHECK (quantity_base > 0),
  state text NOT NULL DEFAULT 'ACTIVE' CHECK (state IN ('ACTIVE','RELEASED')),
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  actor_id uuid NOT NULL,
  request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
  created_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz,
  PRIMARY KEY (installation_id,branch_id,id),
  UNIQUE (installation_id,branch_id,order_id,version_no,line_no),
  FOREIGN KEY (installation_id,branch_id,warehouse_id)
    REFERENCES warehouse(installation_id,branch_id,id),
  FOREIGN KEY (installation_id,branch_id,product_id)
    REFERENCES catalog_product(installation_id,branch_id,id),
  FOREIGN KEY (installation_id,branch_id,order_id,version_no,line_no)
    REFERENCES sales_order_line(installation_id,branch_id,order_id,version_no,line_no),
  FOREIGN KEY (installation_id,actor_id) REFERENCES app_user(installation_id,id),
  CHECK ((state='ACTIVE' AND released_at IS NULL)
      OR (state='RELEASED' AND released_at IS NOT NULL AND revision=1))
);
CREATE INDEX inventory_reservation_active_idx
 ON inventory_reservation(installation_id,branch_id,warehouse_id,product_id)
 WHERE state='ACTIVE';
CREATE FUNCTION erp_inventory_reservation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Inventory reservation cannot be deleted'; END IF;
 IF OLD.state <> 'ACTIVE'
    OR NEW.state <> 'RELEASED'
    OR NEW.revision <> OLD.revision+1
    OR NEW.released_at IS NULL
    OR (NEW.installation_id,NEW.branch_id,NEW.warehouse_id,NEW.id,NEW.product_id,
        NEW.order_id,NEW.version_no,NEW.line_no,NEW.quantity_base,NEW.actor_id,
        NEW.request_id,NEW.created_at)
       IS DISTINCT FROM
       (OLD.installation_id,OLD.branch_id,OLD.warehouse_id,OLD.id,OLD.product_id,
        OLD.order_id,OLD.version_no,OLD.line_no,OLD.quantity_base,OLD.actor_id,
        OLD.request_id,OLD.created_at)
 THEN RAISE EXCEPTION 'Inventory reservation transition invalid'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER inventory_reservation_guard BEFORE UPDATE OR DELETE ON inventory_reservation
 FOR EACH ROW EXECUTE FUNCTION erp_inventory_reservation_guard();

-- Projection only: fully rebuildable from immutable movement facts and active demands.
CREATE VIEW inventory_stock_balance AS
 SELECT installation_id,branch_id,warehouse_id,product_id,
        sum(on_hand)::numeric(24,6) AS on_hand,
        sum(reserved)::numeric(24,6) AS reserved,
        (sum(on_hand)-sum(reserved))::numeric(24,6) AS available
 FROM (
   SELECT installation_id,branch_id,warehouse_id,product_id,delta_base AS on_hand,
      0::numeric AS reserved FROM inventory_ledger
   UNION ALL
   SELECT installation_id,branch_id,warehouse_id,product_id,0::numeric AS on_hand,
      quantity_base AS reserved FROM inventory_reservation WHERE state='ACTIVE'
 ) f
 GROUP BY installation_id,branch_id,warehouse_id,product_id;

INSERT INTO role_permission(installation_id,role_id,permission_code)
 SELECT installation_id,id,'inventory.reserve' FROM app_role
 WHERE code='PRIMARY_OWNER_MAIN' ON CONFLICT DO NOTHING;
