-- T3-B: direct MANUAL ISSUE and scoped stock. Forward-only; no historical ledger rewrite.
-- Legacy source (read-only): sales-direct-stock-issue.js, d39e8a87.
-- Existing inventory_ledger remains the ONLY on-hand authority. Scoped assignments
-- classify existing unassigned stock; they NEVER increase warehouse on-hand.
CREATE TABLE inventory_storage_location (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,warehouse_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 code text NOT NULL CHECK(length(trim(code)) BETWEEN 1 AND 40),
 name text NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 120),
 active boolean NOT NULL DEFAULT true,
 created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,warehouse_id,id),
 UNIQUE(installation_id,branch_id,warehouse_id,code),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,created_by) REFERENCES app_user(installation_id,id)
);
CREATE TABLE inventory_product_lot (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,product_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 lot_code text NOT NULL CHECK(length(trim(lot_code)) BETWEEN 1 AND 80),
 expiry_date date,
 created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,product_id,id),
 UNIQUE(installation_id,branch_id,product_id,lot_code),
 FOREIGN KEY(installation_id,branch_id,product_id)
  REFERENCES catalog_product(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,created_by) REFERENCES app_user(installation_id,id)
);
CREATE TABLE inventory_product_tracking (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,warehouse_id uuid NOT NULL,
 product_id uuid NOT NULL,require_location boolean NOT NULL DEFAULT false,
 require_lot boolean NOT NULL DEFAULT false,
 revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 updated_by uuid NOT NULL,updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,warehouse_id,product_id),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id)
  REFERENCES catalog_product(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,updated_by) REFERENCES app_user(installation_id,id)
);
CREATE TABLE inventory_scope_assignment (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,warehouse_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),product_id uuid NOT NULL,
 location_id uuid,lot_id uuid,
 quantity_base numeric(24,6) NOT NULL CHECK(quantity_base>0 AND quantity_base<>'NaN'::numeric),
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 assigned_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id)
  REFERENCES catalog_product(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,warehouse_id,location_id)
  REFERENCES inventory_storage_location(installation_id,branch_id,warehouse_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id,lot_id)
  REFERENCES inventory_product_lot(installation_id,branch_id,product_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id),
 CHECK(location_id IS NOT NULL OR lot_id IS NOT NULL)
);
CREATE INDEX inventory_scope_assignment_product_idx
 ON inventory_scope_assignment(installation_id,branch_id,warehouse_id,product_id);
CREATE TABLE sales_direct_issue (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,id uuid NOT NULL DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL,version_no integer NOT NULL,warehouse_id uuid NOT NULL,
 allow_negative boolean NOT NULL DEFAULT false,
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 issued_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,order_id,version_no)
  REFERENCES sales_order_version(installation_id,branch_id,order_id,version_no),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);
CREATE INDEX sales_direct_issue_order_idx
 ON sales_direct_issue(installation_id,branch_id,order_id,version_no,issued_at);
CREATE TABLE sales_direct_issue_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,issue_id uuid NOT NULL,
 source_line integer NOT NULL CHECK(source_line BETWEEN 1 AND 10000),
 order_line_no integer NOT NULL CHECK(order_line_no BETWEEN 1 AND 10000),
 product_id uuid NOT NULL,
 quantity_base numeric(24,6) NOT NULL CHECK(quantity_base>0 AND quantity_base<>'NaN'::numeric),
 location_id uuid,lot_id uuid,
 PRIMARY KEY(installation_id,branch_id,issue_id,source_line),
 FOREIGN KEY(installation_id,branch_id,issue_id)
  REFERENCES sales_direct_issue(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id)
  REFERENCES catalog_product(installation_id,branch_id,id)
);
CREATE UNIQUE INDEX sales_direct_issue_line_scope_once
 ON sales_direct_issue_line(installation_id,branch_id,issue_id,order_line_no,location_id,lot_id)
 NULLS NOT DISTINCT;
-- Scope on-hand is a reconstructible classification of the warehouse ledger.
-- Assigned goods remain on-hand until the canonical inventory_ledger ISSUE.
CREATE VIEW inventory_scope_balance AS
 SELECT installation_id,branch_id,warehouse_id,product_id,location_id,lot_id,
   sum(delta)::numeric(24,6) AS quantity_base
 FROM (
  SELECT a.installation_id,a.branch_id,a.warehouse_id,a.product_id,
   a.location_id,a.lot_id,a.quantity_base AS delta FROM inventory_scope_assignment a
  UNION ALL
  SELECT d.installation_id,d.branch_id,d.warehouse_id,l.product_id,
   l.location_id,l.lot_id,-l.quantity_base AS delta
   FROM sales_direct_issue_line l
   JOIN sales_direct_issue d ON d.installation_id=l.installation_id
    AND d.branch_id=l.branch_id AND d.id=l.issue_id
   WHERE l.location_id IS NOT NULL OR l.lot_id IS NOT NULL
 ) facts
 GROUP BY installation_id,branch_id,warehouse_id,product_id,location_id,lot_id;

CREATE FUNCTION erp_t3b_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION 'T3-B posted stock facts are immutable';
END; $$;
CREATE TRIGGER inventory_scope_assignment_immutable BEFORE UPDATE OR DELETE ON inventory_scope_assignment
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER sales_direct_issue_immutable BEFORE UPDATE OR DELETE ON sales_direct_issue
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER sales_direct_issue_line_immutable BEFORE UPDATE OR DELETE ON sales_direct_issue_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER inventory_product_lot_immutable BEFORE UPDATE OR DELETE ON inventory_product_lot
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER inventory_storage_location_immutable BEFORE UPDATE OR DELETE ON inventory_storage_location
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();

CREATE FUNCTION erp_t3b_validate_scope(
 p_t uuid,p_b uuid,p_w uuid,p_product uuid,p_location uuid,p_lot uuid
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE req_location boolean;req_lot boolean;
BEGIN
 SELECT require_location,require_lot INTO req_location,req_lot
 FROM inventory_product_tracking WHERE installation_id=p_t AND branch_id=p_b
   AND warehouse_id=p_w AND product_id=p_product;
 IF coalesce(req_location,false) AND p_location IS NULL THEN
   RAISE EXCEPTION 'Required stock location missing'; END IF;
 IF coalesce(req_lot,false) AND p_lot IS NULL THEN
   RAISE EXCEPTION 'Required stock lot missing'; END IF;
 IF p_location IS NOT NULL AND NOT EXISTS(
  SELECT 1 FROM inventory_storage_location
  WHERE installation_id=p_t AND branch_id=p_b AND warehouse_id=p_w
   AND id=p_location AND active) THEN
  RAISE EXCEPTION 'Stock location unavailable'; END IF;
 IF p_lot IS NOT NULL AND NOT EXISTS(
  SELECT 1 FROM inventory_product_lot
  WHERE installation_id=p_t AND branch_id=p_b AND product_id=p_product
   AND id=p_lot AND (expiry_date IS NULL OR expiry_date>=CURRENT_DATE)) THEN
  RAISE EXCEPTION 'Stock lot unavailable or expired'; END IF;
END; $$;
CREATE FUNCTION erp_t3b_assignment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE available_now numeric;classified numeric;
BEGIN
 PERFORM 1 FROM warehouse WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND id=NEW.warehouse_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Warehouse scope invalid'; END IF;
 PERFORM erp_t3b_validate_scope(NEW.installation_id,NEW.branch_id,
  NEW.warehouse_id,NEW.product_id,NEW.location_id,NEW.lot_id);
 SELECT coalesce((SELECT available FROM inventory_stock_balance
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id),0) INTO available_now;
 SELECT coalesce(sum(quantity_base),0) INTO classified FROM inventory_scope_balance
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id;
 IF available_now-classified<NEW.quantity_base THEN
  RAISE EXCEPTION 'Insufficient unassigned available stock'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER inventory_scope_assignment_guard BEFORE INSERT ON inventory_scope_assignment
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_assignment_guard();

-- Guard direct-SQL fraud: issue header and order line must match current MANUAL
-- version and exact canonical six-decimal base snapshot. Pending issues are
-- serialized by warehouse -> order lock, the same order as sales HTTP and POS.
CREATE FUNCTION erp_t3b_issue_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE h sales_direct_issue%ROWTYPE; o_status text;v_state text;
 current_ver integer;choice text;ctx_wh uuid;expected_product uuid;
 requested numeric;previous numeric;pricing text;unit_code text;base_unit text;
 snapshot jsonb;ordered numeric;scoped_available numeric;
BEGIN
 SELECT * INTO h FROM sales_direct_issue
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND id=NEW.issue_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Direct issue header unavailable'; END IF;
 PERFORM 1 FROM warehouse WHERE installation_id=h.installation_id
  AND branch_id=h.branch_id AND id=h.warehouse_id FOR UPDATE;
 SELECT o.status,o.current_version,v.state,c.delivery_choice,c.warehouse_id,
        l.product_id,l.pricing_engine,l.unit_code,p.base_unit,l.price_snapshot,l.quantity
 INTO o_status,current_ver,v_state,choice,ctx_wh,expected_product,pricing,
      unit_code,base_unit,snapshot,requested
 FROM sales_order o JOIN sales_order_version v ON v.installation_id=o.installation_id
   AND v.branch_id=o.branch_id AND v.order_id=o.id AND v.version_no=h.version_no
 JOIN sales_order_version_context c ON c.installation_id=v.installation_id
  AND c.branch_id=v.branch_id AND c.order_id=v.order_id AND c.version_no=v.version_no
 JOIN sales_order_line l ON l.installation_id=v.installation_id AND l.branch_id=v.branch_id
  AND l.order_id=v.order_id AND l.version_no=v.version_no AND l.line_no=NEW.order_line_no
 JOIN catalog_product p ON p.installation_id=l.installation_id AND p.branch_id=l.branch_id
  AND p.id=l.product_id
 WHERE o.installation_id=h.installation_id AND o.branch_id=h.branch_id
  AND o.id=h.order_id FOR UPDATE OF o;
 IF o_status IS DISTINCT FROM 'CONFIRMED' OR v_state IS DISTINCT FROM 'CONFIRMED'
   OR current_ver IS DISTINCT FROM h.version_no
   OR choice IS DISTINCT FROM 'MANUAL' OR ctx_wh IS DISTINCT FROM h.warehouse_id
   OR expected_product IS DISTINCT FROM NEW.product_id THEN
  RAISE EXCEPTION 'Current confirmed MANUAL order line required'; END IF;
 IF pricing='R1' THEN ordered:=(snapshot->>'normalizedBaseQuantity')::numeric;
 ELSIF pricing='LEGACY' AND unit_code=base_unit THEN ordered:=requested;
 ELSE RAISE EXCEPTION 'Base quantity snapshot required'; END IF;
 IF ordered IS NULL OR ordered<=0 OR ordered<>round(ordered,6) THEN
  RAISE EXCEPTION 'Invalid snapshot base quantity'; END IF;
 SELECT coalesce(sum(x.quantity_base),0) INTO previous
 FROM sales_direct_issue_line x JOIN sales_direct_issue d
  ON d.installation_id=x.installation_id AND d.branch_id=x.branch_id AND d.id=x.issue_id
 WHERE d.installation_id=h.installation_id AND d.branch_id=h.branch_id
  AND d.order_id=h.order_id AND d.version_no=h.version_no
  AND x.order_line_no=NEW.order_line_no;
 IF previous+NEW.quantity_base>ordered THEN
  RAISE EXCEPTION 'Direct issue exceeds commercial line quantity'; END IF;
 PERFORM erp_t3b_validate_scope(h.installation_id,h.branch_id,h.warehouse_id,
  NEW.product_id,NEW.location_id,NEW.lot_id);
 IF NEW.location_id IS NOT NULL OR NEW.lot_id IS NOT NULL THEN
  -- BEFORE INSERT: scope balance still contains the unissued slice.
  -- Re-evaluate under warehouse lock even if someone inserted the warehouse
  -- ISSUE movement before creating the T3-B source header.
  SELECT coalesce(sum(quantity_base),0) INTO scoped_available
   FROM inventory_scope_balance
   WHERE installation_id=h.installation_id AND branch_id=h.branch_id
    AND warehouse_id=h.warehouse_id AND product_id=NEW.product_id
    AND location_id IS NOT DISTINCT FROM NEW.location_id
    AND lot_id IS NOT DISTINCT FROM NEW.lot_id;
  IF scoped_available<NEW.quantity_base THEN
   RAISE EXCEPTION 'Direct issue exceeds allocated stock at lot/location';
  END IF;
 END IF;
 IF h.allow_negative AND (NEW.location_id IS NOT NULL OR NEW.lot_id IS NOT NULL) THEN
  RAISE EXCEPTION 'Negative issue prohibited for tracked scope'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER sales_direct_issue_line_guard BEFORE INSERT ON sales_direct_issue_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_issue_line_guard();

-- The original R3 ledger guard stays authoritative. The *only* exception to
-- its negative BLOCK is a verifiable MANUAL source, explicit allow_negative,
-- existing warehouse ALLOW policy, and zero protected scope stock or holds.
CREATE OR REPLACE FUNCTION erp_inventory_movement_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE available_now numeric;prior_delta numeric;prior_product uuid;prior_kind text;
 approved_negative boolean;classified numeric;
BEGIN
 PERFORM 1 FROM warehouse WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND id=NEW.warehouse_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Warehouse scope invalid'; END IF;
 IF (NEW.kind='OPENING' AND NEW.source_type<>'OPENING')
  OR (NEW.kind='RECEIPT' AND NEW.source_type<>'PURCHASE_RECEIPT')
  OR (NEW.kind='ISSUE' AND NEW.source_type<>'FULFILLMENT')
  OR (NEW.kind IN ('TRANSFER_IN','TRANSFER_OUT') AND NEW.source_type<>'TRANSFER')
  OR (NEW.kind='REVERSAL' AND NEW.source_type<>'REVERSAL')
  OR (NEW.kind='STOCKTAKE' AND NEW.source_type<>'STOCKTAKE') THEN
  RAISE EXCEPTION 'Inventory source domain invalid'; END IF;
 IF NEW.kind='OPENING' AND EXISTS (
  SELECT 1 FROM inventory_ledger WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND warehouse_id=NEW.warehouse_id
  AND product_id=NEW.product_id) THEN
  RAISE EXCEPTION 'Opening must be first inventory movement'; END IF;
 IF NEW.kind='REVERSAL' THEN
  SELECT delta_base,product_id,kind INTO prior_delta,prior_product,prior_kind
  FROM inventory_ledger WHERE installation_id=NEW.installation_id
   AND branch_id=NEW.branch_id AND warehouse_id=NEW.warehouse_id
   AND id=NEW.reversal_of FOR SHARE;
  IF prior_delta IS NULL OR NEW.delta_base<>-prior_delta OR prior_kind='REVERSAL' THEN
   RAISE EXCEPTION 'Reversal delta must negate one original posted movement'; END IF;
  IF prior_product IS DISTINCT FROM NEW.product_id THEN
   RAISE EXCEPTION 'Reversal product must match original movement'; END IF;
 END IF;
 SELECT coalesce((SELECT available FROM inventory_stock_balance WHERE
  installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id),0)
 INTO available_now;
 IF NEW.delta_base<0 AND available_now+NEW.delta_base<0 THEN
  SELECT coalesce(sum(quantity_base),0) INTO classified FROM inventory_scope_balance
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
    AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id;
  SELECT EXISTS(
   SELECT 1 FROM sales_direct_issue d
   JOIN sales_direct_issue_line l ON l.installation_id=d.installation_id
    AND l.branch_id=d.branch_id AND l.issue_id=d.id AND l.source_line=NEW.source_line
   JOIN inventory_guard_policy p ON p.installation_id=d.installation_id
    AND p.branch_id=d.branch_id AND p.warehouse_id=d.warehouse_id
   WHERE d.installation_id=NEW.installation_id AND d.branch_id=NEW.branch_id
    AND d.id=NEW.source_id AND d.warehouse_id=NEW.warehouse_id
    AND d.allow_negative AND p.negative_issue_mode='ALLOW'
    AND NEW.kind='ISSUE' AND NEW.source_type='FULFILLMENT'
    AND l.product_id=NEW.product_id AND l.quantity_base=-NEW.delta_base
    AND l.location_id IS NULL AND l.lot_id IS NULL
    AND classified=0
    AND NOT EXISTS(SELECT 1 FROM inventory_reservation r
     WHERE r.installation_id=d.installation_id AND r.branch_id=d.branch_id
      AND r.warehouse_id=d.warehouse_id AND r.product_id=l.product_id
      AND r.state='ACTIVE' AND r.quantity_base>0)
  ) INTO approved_negative;
  IF NOT approved_negative THEN RAISE EXCEPTION 'Inventory insufficient available stock'; END IF;
 END IF;
 RETURN NEW;
END; $$;

-- Deferred reverse link: a movement can arrive before its issue header in one
-- transaction. At COMMIT, any movement whose source becomes a direct issue
-- must have exactly one matching line. Legacy POS and historical non-T3-B
-- inventory movements are not reclassified or rewritten.
CREATE FUNCTION erp_t3b_ledger_direct_source_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.kind='ISSUE' AND NEW.source_type='FULFILLMENT'
    AND EXISTS(SELECT 1 FROM sales_direct_issue d WHERE
     d.installation_id=NEW.installation_id AND d.branch_id=NEW.branch_id
     AND d.id=NEW.source_id) THEN
  IF NOT EXISTS(
   SELECT 1 FROM sales_direct_issue d JOIN sales_direct_issue_line l
    ON l.installation_id=d.installation_id AND l.branch_id=d.branch_id
    AND l.issue_id=d.id
   WHERE d.installation_id=NEW.installation_id
    AND d.branch_id=NEW.branch_id AND d.id=NEW.source_id
    AND d.warehouse_id=NEW.warehouse_id
    AND l.source_line=NEW.source_line AND l.product_id=NEW.product_id
    AND l.quantity_base=-NEW.delta_base
  ) THEN
   RAISE EXCEPTION 'Direct issue ledger movement has no matching source line';
  END IF;
 END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER t3b_inventory_ledger_direct_source_commit
 AFTER INSERT ON inventory_ledger DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_ledger_direct_source_commit_guard();

-- Protect physically assigned stock from all unscoped withdrawals including
-- POS, transfer, corrections and direct SQL. A tracked MANUAL withdrawal needs
-- enough exact scope balance (and also passes original warehouse-level guard).
CREATE FUNCTION erp_t3b_ledger_scope_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE h sales_direct_issue%ROWTYPE;line sales_direct_issue_line%ROWTYPE;
 available_now numeric;classified numeric;scoped_now numeric;
BEGIN
 IF NEW.delta_base>=0 THEN RETURN NEW; END IF;
 SELECT * INTO h FROM sales_direct_issue WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND id=NEW.source_id;
 IF FOUND THEN
  IF NEW.kind<>'ISSUE' OR NEW.source_type<>'FULFILLMENT'
    OR h.warehouse_id<>NEW.warehouse_id THEN
   RAISE EXCEPTION 'Direct issue source mismatch'; END IF;
  SELECT * INTO line FROM sales_direct_issue_line
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
     AND issue_id=NEW.source_id AND source_line=NEW.source_line;
  IF NOT FOUND OR line.product_id<>NEW.product_id
    OR line.quantity_base<>-NEW.delta_base THEN
   RAISE EXCEPTION 'Direct issue ledger line mismatch'; END IF;
 END IF;
 SELECT coalesce(sum(quantity_base),0) INTO classified FROM inventory_scope_balance
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id;
 SELECT coalesce((SELECT available FROM inventory_stock_balance
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id),0)
 INTO available_now;
 IF h.id IS NOT NULL AND (line.location_id IS NOT NULL OR line.lot_id IS NOT NULL) THEN
  SELECT coalesce(sum(quantity_base),0) INTO scoped_now FROM inventory_scope_balance
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
    AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id
    AND location_id IS NOT DISTINCT FROM line.location_id
    AND lot_id IS NOT DISTINCT FROM line.lot_id;
  -- The issue line is inserted before ledger and already removed from view:
  -- add it back to calculate pre-issue scope availability.
  IF scoped_now+line.quantity_base<line.quantity_base THEN
   RAISE EXCEPTION 'Insufficient stock at lot/location'; END IF;
 ELSE
  IF classified>0 AND available_now-classified<(-NEW.delta_base) THEN
   RAISE EXCEPTION 'Assigned stock cannot be consumed without lot/location'; END IF;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER t3b_inventory_ledger_scope_guard BEFORE INSERT ON inventory_ledger
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_ledger_scope_guard();

-- Deferred DB backstop: no orphan manual ISSUE without a matching canonical
-- ledger movement, and no movement can be posted with wrong source line.
CREATE FUNCTION erp_t3b_issue_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE issue_warehouse uuid;classified numeric;onhand_now numeric;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM inventory_ledger m JOIN sales_direct_issue d
   ON d.installation_id=NEW.installation_id AND d.branch_id=NEW.branch_id
    AND d.id=NEW.issue_id
  WHERE m.installation_id=NEW.installation_id AND m.branch_id=NEW.branch_id
   AND m.warehouse_id=d.warehouse_id AND m.source_type='FULFILLMENT'
   AND m.source_id=NEW.issue_id AND m.source_line=NEW.source_line
   AND m.kind='ISSUE' AND m.product_id=NEW.product_id
   AND m.delta_base=-NEW.quantity_base) THEN
  RAISE EXCEPTION 'Direct issue line missing matching posted inventory movement'; END IF;
 -- Deferred coverage is checked against FINAL warehouse availability. During
 -- a transaction the line decreases classified scope stock before its matching
 -- ledger movement decreases on-hand; otherwise an assignment in between can
 -- classify the same physical stock twice.
 SELECT warehouse_id INTO issue_warehouse FROM sales_direct_issue
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND id=NEW.issue_id;
 SELECT coalesce(sum(quantity_base),0) INTO classified
 FROM inventory_scope_balance
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND warehouse_id=issue_warehouse AND product_id=NEW.product_id;
 SELECT coalesce((SELECT on_hand FROM inventory_stock_balance
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND warehouse_id=issue_warehouse AND product_id=NEW.product_id),0)
 INTO onhand_now;
 IF classified>0 AND classified>greatest(onhand_now,0) THEN
  RAISE EXCEPTION 'Scoped stock classification exceeds final on-hand balance';
 END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER sales_direct_issue_posted_on_commit
 AFTER INSERT ON sales_direct_issue_line DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_issue_commit_guard();
CREATE FUNCTION erp_t3b_issue_header_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM sales_direct_issue_line WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND issue_id=NEW.id) THEN
  RAISE EXCEPTION 'Direct issue requires posted lines'; END IF;
 -- Check historic/precommitted orphan movements as well. The deferred
 -- ledger trigger alone cannot catch an orphan inserted in an earlier
 -- transaction and only later linked to a newly created direct-issue header.
 IF EXISTS(
   SELECT 1 FROM inventory_ledger m
   WHERE m.installation_id=NEW.installation_id AND m.branch_id=NEW.branch_id
    AND m.source_id=NEW.id AND m.source_type='FULFILLMENT' AND m.kind='ISSUE'
    AND NOT EXISTS(
     SELECT 1 FROM sales_direct_issue_line l
     WHERE l.installation_id=m.installation_id AND l.branch_id=m.branch_id
      AND l.issue_id=NEW.id AND l.source_line=m.source_line
      AND l.product_id=m.product_id AND l.quantity_base=-m.delta_base
      AND m.warehouse_id=NEW.warehouse_id
    )
 ) THEN
  RAISE EXCEPTION 'Direct issue header has unmatched historic ledger movement';
 END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER sales_direct_issue_header_on_commit
 AFTER INSERT ON sales_direct_issue DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_issue_header_commit_guard();

INSERT INTO role_permission(installation_id,role_id,permission_code)
 SELECT installation_id,id,'inventory.negative.issue' FROM app_role
 WHERE code='PRIMARY_OWNER_MAIN' ON CONFLICT DO NOTHING;

-- Commit-time coverage backstop: source lines classify stock before ledger
-- posts it. A second allocation in that gap must not survive COMMIT.
-- Warehouse insert guards have already serialized writes by warehouse lock.
CREATE FUNCTION erp_t3b_scope_coverage_commit_guard() RETURNS trigger
 LANGUAGE plpgsql AS $t3b$
DECLARE onhand_now numeric;classified numeric;has_negative_scope boolean;
BEGIN
 -- No physical bin/lot assignment: O(1) warehouse ledger post path.
 IF NOT EXISTS(SELECT 1 FROM inventory_scope_assignment a
   WHERE a.installation_id=NEW.installation_id AND a.branch_id=NEW.branch_id
   AND a.warehouse_id=NEW.warehouse_id AND a.product_id=NEW.product_id)
 THEN RETURN NULL; END IF;
 SELECT coalesce((SELECT on_hand FROM inventory_stock_balance
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id),0)
 INTO onhand_now;
 SELECT coalesce(sum(quantity_base),0),coalesce(bool_or(quantity_base<0),false)
 INTO classified,has_negative_scope
 FROM inventory_scope_balance
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id;
 IF has_negative_scope OR classified>greatest(onhand_now,0) THEN
   RAISE EXCEPTION 'Scoped stock classification exceeds final on-hand balance';
 END IF;
 RETURN NULL;
END; $t3b$;
CREATE CONSTRAINT TRIGGER t3b_assignment_coverage_on_commit
 AFTER INSERT ON inventory_scope_assignment
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 EXECUTE FUNCTION erp_t3b_scope_coverage_commit_guard();
CREATE CONSTRAINT TRIGGER t3b_ledger_coverage_on_commit
 AFTER INSERT ON inventory_ledger
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
 EXECUTE FUNCTION erp_t3b_scope_coverage_commit_guard();

-- Bound scope view aggregation by product; posting thousands of other orders
-- must not turn one lot/bin check into a whole-ledger scan.
CREATE INDEX sales_direct_issue_line_product_scope_idx
 ON sales_direct_issue_line(installation_id,branch_id,product_id,issue_id);
