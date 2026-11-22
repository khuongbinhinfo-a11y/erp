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
  delta_base numeric(24,6) NOT NULL CHECK (delta_base <> 0 AND delta_base <> 'NaN'::numeric),
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
  ON inventory_ledger(installation_id,branch_id,warehouse_id,source_type,source_id,source_line)
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
  quantity_base numeric(24,6) NOT NULL CHECK (quantity_base > 0 AND quantity_base <> 'NaN'::numeric),
  state text NOT NULL DEFAULT 'ACTIVE' CHECK (state IN ('ACTIVE','RELEASED')),
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  actor_id uuid NOT NULL,
  request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
  created_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz,
  PRIMARY KEY (installation_id,branch_id,id),
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
-- Released holds remain audit history but must not permanently block a new hold.
CREATE UNIQUE INDEX inventory_reservation_one_active_orderline
 ON inventory_reservation(installation_id,branch_id,order_id,version_no,line_no)
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

-- DB backstop: all movement writers, including future domains, share the warehouse lock.
-- Direct INSERT cannot create negative stock, consume held stock, or forge a reversal.
CREATE FUNCTION erp_inventory_movement_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  available_now numeric;
  prior_delta numeric;
  prior_product uuid;
  prior_kind text;
BEGIN
  PERFORM 1 FROM warehouse WHERE installation_id=NEW.installation_id
   AND branch_id=NEW.branch_id AND id=NEW.warehouse_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Warehouse scope invalid'; END IF;
  IF (NEW.kind='OPENING' AND NEW.source_type<>'OPENING')
    OR (NEW.kind='RECEIPT' AND NEW.source_type<>'PURCHASE_RECEIPT')
    OR (NEW.kind='ISSUE' AND NEW.source_type<>'FULFILLMENT')
    OR (NEW.kind IN ('TRANSFER_IN','TRANSFER_OUT') AND NEW.source_type<>'TRANSFER')
    OR (NEW.kind='REVERSAL' AND NEW.source_type<>'REVERSAL') THEN
    RAISE EXCEPTION 'Inventory source domain invalid';
  END IF;
  IF NEW.kind='OPENING' AND EXISTS (
    SELECT 1 FROM inventory_ledger WHERE installation_id=NEW.installation_id
    AND branch_id=NEW.branch_id AND warehouse_id=NEW.warehouse_id
    AND product_id=NEW.product_id
  ) THEN
    RAISE EXCEPTION 'Opening must be first inventory movement';
  END IF;
  IF NEW.kind='REVERSAL' THEN
    SELECT delta_base,product_id,kind INTO prior_delta,prior_product,prior_kind FROM inventory_ledger WHERE
     installation_id=NEW.installation_id AND branch_id=NEW.branch_id
     AND warehouse_id=NEW.warehouse_id AND id=NEW.reversal_of FOR SHARE;
    IF prior_delta IS NULL OR NEW.delta_base<>-prior_delta OR prior_kind='REVERSAL' THEN
      RAISE EXCEPTION 'Reversal delta must negate one original posted movement';
    END IF;
    IF prior_product IS DISTINCT FROM NEW.product_id THEN
      RAISE EXCEPTION 'Reversal product must match original movement';
    END IF;
  END IF;
  SELECT COALESCE((SELECT available FROM inventory_stock_balance WHERE
    installation_id=NEW.installation_id AND branch_id=NEW.branch_id
    AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id),0)
    INTO available_now;
  IF NEW.delta_base<0 AND available_now+NEW.delta_base<0 THEN
    RAISE EXCEPTION 'Inventory insufficient available stock';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER inventory_movement_insert_guard BEFORE INSERT ON inventory_ledger
 FOR EACH ROW EXECUTE FUNCTION erp_inventory_movement_insert_guard();

-- A reservation always matches the immutable confirmed Sales line base quantity;
-- a direct INSERT cannot reserve more than the warehouse has available.
CREATE FUNCTION erp_inventory_reservation_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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
  IF demand IS NULL OR demand<=0 OR NEW.quantity_base<>demand THEN
    RAISE EXCEPTION 'Reservation base quantity differs from snapshot';
  END IF;
  SELECT COALESCE((SELECT available FROM inventory_stock_balance WHERE
    installation_id=NEW.installation_id AND branch_id=NEW.branch_id
    AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id),0)
  INTO available_now;
  IF available_now<NEW.quantity_base THEN
    RAISE EXCEPTION 'Reservation exceeds available stock';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER inventory_reservation_insert_guard BEFORE INSERT ON inventory_reservation
 FOR EACH ROW EXECUTE FUNCTION erp_inventory_reservation_insert_guard();

INSERT INTO role_permission(installation_id,role_id,permission_code)
 SELECT installation_id,id,'inventory.reserve' FROM app_role
 WHERE code='PRIMARY_OWNER_MAIN' ON CONFLICT DO NOTHING;
