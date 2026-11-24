-- T0: adapt legacy deterministic partial reservation/backorder without a second ledger.
-- Provenance: legacy sales-fulfillment.js allocateWarehouseDemand (read-only source).
-- Negative stock ISSUE remains BLOCK until a trusted direct-issue service validates
-- warehouse policy, actor permission, source lineage, accounting and audit.
CREATE TABLE inventory_guard_policy (
 installation_id uuid NOT NULL,
 branch_id uuid NOT NULL,
 warehouse_id uuid NOT NULL,
 reserve_shortage_mode text NOT NULL DEFAULT 'WARN'
   CHECK (reserve_shortage_mode IN ('BLOCK','WARN','ALLOW')),
 negative_issue_mode text NOT NULL DEFAULT 'BLOCK'
   CHECK (negative_issue_mode IN ('BLOCK','WARN','ALLOW')),
 revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
 updated_by uuid NOT NULL,
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (installation_id,branch_id,warehouse_id),
 FOREIGN KEY (installation_id,branch_id,warehouse_id)
   REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY (installation_id,updated_by)
   REFERENCES app_user(installation_id,id)
);

ALTER TABLE inventory_reservation ADD COLUMN backordered_base numeric(24,6)
 NOT NULL DEFAULT 0 CHECK (backordered_base >= 0 AND backordered_base <> 'NaN'::numeric);
ALTER TABLE inventory_reservation DROP CONSTRAINT inventory_reservation_quantity_base_check;
ALTER TABLE inventory_reservation ADD CONSTRAINT inventory_reservation_quantity_base_check
 CHECK (quantity_base >= 0 AND quantity_base <> 'NaN'::numeric
   AND quantity_base + backordered_base > 0);

-- The backorder snapshot is immutable alongside the reserved quantity.
CREATE OR REPLACE FUNCTION erp_inventory_reservation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Inventory reservation cannot be deleted'; END IF;
 IF OLD.state <> 'ACTIVE' OR NEW.state <> 'RELEASED'
    OR NEW.revision <> OLD.revision+1 OR NEW.released_at IS NULL
    OR (NEW.installation_id,NEW.branch_id,NEW.warehouse_id,NEW.id,NEW.product_id,
        NEW.order_id,NEW.version_no,NEW.line_no,NEW.quantity_base,NEW.backordered_base,
        NEW.actor_id,NEW.request_id,NEW.created_at)
       IS DISTINCT FROM
       (OLD.installation_id,OLD.branch_id,OLD.warehouse_id,OLD.id,OLD.product_id,
        OLD.order_id,OLD.version_no,OLD.line_no,OLD.quantity_base,OLD.backordered_base,
        OLD.actor_id,OLD.request_id,OLD.created_at)
 THEN RAISE EXCEPTION 'Inventory reservation transition invalid'; END IF;
 RETURN NEW;
END; $$;

-- DB backstop: cannot claim a false backorder or reserve beyond availability,
-- including with direct SQL or during a concurrent reservation.
CREATE OR REPLACE FUNCTION erp_inventory_reservation_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  order_status text;
  version_status text;
  current_ver integer;
  pricing text;
  qty numeric;
  unit_code text;
  base_unit text;
  snapshot jsonb;
  demand numeric;
  available_now numeric;
  shortage_mode text;
BEGIN
  PERFORM 1 FROM warehouse WHERE installation_id=NEW.installation_id
   AND branch_id=NEW.branch_id AND id=NEW.warehouse_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Warehouse scope invalid'; END IF;
  SELECT o.status,v.state,o.current_version,l.pricing_engine,l.quantity,
         l.unit_code,p.base_unit,l.price_snapshot
  INTO order_status,version_status,current_ver,pricing,qty,unit_code,base_unit,snapshot
  FROM sales_order o
   JOIN sales_order_version v ON v.installation_id=o.installation_id
     AND v.branch_id=o.branch_id AND v.order_id=o.id AND v.version_no=NEW.version_no
   JOIN sales_order_line l ON l.installation_id=v.installation_id
     AND l.branch_id=v.branch_id AND l.order_id=v.order_id AND l.version_no=v.version_no
     AND l.line_no=NEW.line_no AND l.product_id=NEW.product_id
   JOIN catalog_product p ON p.installation_id=l.installation_id
     AND p.branch_id=l.branch_id AND p.id=l.product_id
  WHERE o.installation_id=NEW.installation_id AND o.branch_id=NEW.branch_id
    AND o.id=NEW.order_id FOR SHARE OF o;
  IF order_status IS DISTINCT FROM 'CONFIRMED'
     OR version_status IS DISTINCT FROM 'CONFIRMED'
     OR current_ver IS DISTINCT FROM NEW.version_no THEN
    RAISE EXCEPTION 'Reservation requires current confirmed Sales version';
  END IF;
  IF pricing='R1' THEN
    demand := (snapshot->>'normalizedBaseQuantity')::numeric;
  ELSIF pricing='LEGACY' AND unit_code=base_unit THEN
    demand := qty;
  ELSE
    RAISE EXCEPTION 'Reservation lacks immutable base quantity';
  END IF;
  IF demand IS NULL OR demand<=0
    OR NEW.quantity_base+NEW.backordered_base<>demand THEN
    RAISE EXCEPTION 'Reservation base quantity differs from snapshot';
  END IF;
  SELECT COALESCE((SELECT available FROM inventory_stock_balance WHERE
    installation_id=NEW.installation_id AND branch_id=NEW.branch_id
    AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id),0)
  INTO available_now;
  IF available_now<NEW.quantity_base THEN
    RAISE EXCEPTION 'Reservation exceeds available stock';
  END IF;
  SELECT reserve_shortage_mode INTO shortage_mode FROM inventory_guard_policy
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
     AND warehouse_id=NEW.warehouse_id FOR SHARE;
  IF NEW.backordered_base>0 AND COALESCE(shortage_mode,'WARN')='BLOCK' THEN
    RAISE EXCEPTION 'Reservation backorder blocked by warehouse policy';
  END IF;
  RETURN NEW;
END; $$;

-- Explicit opt-in role permission; the negative ISSUE trigger remains hard BLOCK.
INSERT INTO role_permission(installation_id,role_id,permission_code)
 SELECT installation_id,id,'inventory.policy.manage' FROM app_role
 WHERE code='PRIMARY_OWNER_MAIN' ON CONFLICT DO NOTHING;
