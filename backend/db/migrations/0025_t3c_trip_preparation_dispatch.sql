-- T3-C2/C3: TRIP pack and physical dispatch against the canonical warehouse ledger.
-- Forward-only. No production execution without backup, restore, reconciliation and approval.
-- Legacy characterization: NPP-Platform sales-fulfillment-operations.js / phase 6D2 and 6D3.
-- Packaging is NOT an inventory OUT, customer delivery, payment or receivable fact.
CREATE TABLE sales_trip_preparation (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),order_id uuid NOT NULL,
 version_no integer NOT NULL,warehouse_id uuid NOT NULL,
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 prepared_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,order_id,version_no)
   REFERENCES sales_order_version(installation_id,branch_id,order_id,version_no),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
   REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);
CREATE INDEX sales_trip_preparation_order_idx ON sales_trip_preparation
 (installation_id,branch_id,order_id,version_no,prepared_at);
CREATE TABLE sales_trip_preparation_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 preparation_id uuid NOT NULL,source_line integer NOT NULL CHECK(source_line BETWEEN 1 AND 10000),
 order_line_no integer NOT NULL CHECK(order_line_no BETWEEN 1 AND 10000),
 reservation_id uuid NOT NULL,product_id uuid NOT NULL,
 picked_base numeric(24,6) NOT NULL CHECK(picked_base>=0 AND picked_base<>'NaN'::numeric),
 packed_base numeric(24,6) NOT NULL CHECK(packed_base>=0 AND packed_base<>'NaN'::numeric),
 location_id uuid,lot_id uuid,
 PRIMARY KEY(installation_id,branch_id,preparation_id,source_line),
 FOREIGN KEY(installation_id,branch_id,preparation_id)
  REFERENCES sales_trip_preparation(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,reservation_id)
  REFERENCES inventory_reservation(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id)
  REFERENCES catalog_product(installation_id,branch_id,id),
 CHECK(picked_base+packed_base>0)
);
CREATE INDEX sales_trip_preparation_line_hold_idx ON sales_trip_preparation_line
 (installation_id,branch_id,reservation_id,order_line_no);
CREATE TABLE sales_trip_dispatch (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),order_id uuid NOT NULL,
 version_no integer NOT NULL,warehouse_id uuid NOT NULL,
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 dispatched_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,order_id,version_no)
  REFERENCES sales_order_version(installation_id,branch_id,order_id,version_no),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);
CREATE INDEX sales_trip_dispatch_order_idx ON sales_trip_dispatch
 (installation_id,branch_id,order_id,version_no,dispatched_at);
CREATE TABLE sales_trip_dispatch_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 dispatch_id uuid NOT NULL,source_line integer NOT NULL CHECK(source_line BETWEEN 1 AND 10000),
 preparation_id uuid NOT NULL,preparation_line_no integer NOT NULL,
 order_line_no integer NOT NULL, reservation_id uuid NOT NULL,product_id uuid NOT NULL,
 quantity_base numeric(24,6) NOT NULL CHECK(quantity_base>0 AND quantity_base<>'NaN'::numeric),
 location_id uuid,lot_id uuid,
 PRIMARY KEY(installation_id,branch_id,dispatch_id,source_line),
 FOREIGN KEY(installation_id,branch_id,dispatch_id)
  REFERENCES sales_trip_dispatch(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,preparation_id,preparation_line_no)
  REFERENCES sales_trip_preparation_line(installation_id,branch_id,preparation_id,source_line),
 FOREIGN KEY(installation_id,branch_id,reservation_id)
  REFERENCES inventory_reservation(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id)
  REFERENCES catalog_product(installation_id,branch_id,id)
);
CREATE INDEX sales_trip_dispatch_line_pack_idx ON sales_trip_dispatch_line
 (installation_id,branch_id,preparation_id,preparation_line_no);

CREATE TRIGGER trip_preparation_immutable BEFORE UPDATE OR DELETE ON sales_trip_preparation
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER trip_preparation_line_immutable BEFORE UPDATE OR DELETE ON sales_trip_preparation_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER trip_dispatch_immutable BEFORE UPDATE OR DELETE ON sales_trip_dispatch
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER trip_dispatch_line_immutable BEFORE UPDATE OR DELETE ON sales_trip_dispatch_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();

-- The existing reservation row is an immutable quantity snapshot. Reduce its
-- ACTIVE *projection* by posted trip issue lines; never mutate its history.
-- Insert the dispatch line BEFORE its matching ledger movement. The deferred
-- commit guard below prevents fictitious availability from unpaired lines.
CREATE OR REPLACE VIEW inventory_stock_balance AS
 SELECT installation_id,branch_id,warehouse_id,product_id,
        sum(on_hand)::numeric(24,6) AS on_hand,
        sum(reserved)::numeric(24,6) AS reserved,
        (sum(on_hand)-sum(reserved))::numeric(24,6) AS available
 FROM (
  SELECT installation_id,branch_id,warehouse_id,product_id,
    delta_base AS on_hand,0::numeric AS reserved FROM inventory_ledger
  UNION ALL
  SELECT r.installation_id,r.branch_id,r.warehouse_id,r.product_id,
    0::numeric AS on_hand,
    greatest(r.quantity_base-coalesce(issued.total,0),0)::numeric AS reserved
  FROM inventory_reservation r
  LEFT JOIN LATERAL (
    SELECT sum(dl.quantity_base) AS total FROM sales_trip_dispatch_line dl
     WHERE dl.installation_id=r.installation_id AND dl.branch_id=r.branch_id
       AND dl.reservation_id=r.id
  ) issued ON true
  WHERE r.state='ACTIVE'
 ) facts
 GROUP BY installation_id,branch_id,warehouse_id,product_id;

CREATE OR REPLACE VIEW inventory_scope_balance AS
 SELECT installation_id,branch_id,warehouse_id,product_id,location_id,lot_id,
   sum(delta)::numeric(24,6) AS quantity_base FROM (
  SELECT a.installation_id,a.branch_id,a.warehouse_id,a.product_id,
   a.location_id,a.lot_id,a.quantity_base AS delta
   FROM inventory_scope_assignment a
  UNION ALL
  SELECT d.installation_id,d.branch_id,d.warehouse_id,l.product_id,
   l.location_id,l.lot_id,-l.quantity_base AS delta
   FROM sales_direct_issue_line l JOIN sales_direct_issue d
    ON d.installation_id=l.installation_id AND d.branch_id=l.branch_id AND d.id=l.issue_id
   WHERE l.location_id IS NOT NULL OR l.lot_id IS NOT NULL
  UNION ALL
  SELECT d.installation_id,d.branch_id,d.warehouse_id,l.product_id,
   l.location_id,l.lot_id,-l.quantity_base AS delta
   FROM sales_trip_dispatch_line l JOIN sales_trip_dispatch d
    ON d.installation_id=l.installation_id AND d.branch_id=l.branch_id
     AND d.id=l.dispatch_id
   WHERE l.location_id IS NOT NULL OR l.lot_id IS NOT NULL
 ) facts GROUP BY installation_id,branch_id,warehouse_id,product_id,location_id,lot_id;

-- Never allow the old general release command to discard a prepared TRIP hold.
-- All changes remain append-only; hold replenishment may replace only unprepared holds.
CREATE OR REPLACE FUNCTION erp_inventory_reservation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Inventory reservation cannot be deleted'; END IF;
 IF OLD.state<>'ACTIVE' OR NEW.state<>'RELEASED'
    OR NEW.revision<>OLD.revision+1 OR NEW.released_at IS NULL
    OR EXISTS (SELECT 1 FROM sales_trip_preparation_line p
     WHERE p.installation_id=OLD.installation_id AND p.branch_id=OLD.branch_id
      AND p.reservation_id=OLD.id)
    OR (NEW.installation_id,NEW.branch_id,NEW.warehouse_id,NEW.id,NEW.product_id,
        NEW.order_id,NEW.version_no,NEW.line_no,NEW.quantity_base,NEW.backordered_base,
        NEW.actor_id,NEW.request_id,NEW.created_at)
       IS DISTINCT FROM
       (OLD.installation_id,OLD.branch_id,OLD.warehouse_id,OLD.id,OLD.product_id,
        OLD.order_id,OLD.version_no,OLD.line_no,OLD.quantity_base,OLD.backordered_base,
        OLD.actor_id,OLD.request_id,OLD.created_at)
 THEN RAISE EXCEPTION 'Prepared inventory reservation cannot be rewritten or released'; END IF;
 RETURN NEW;
END; $$;

-- Prevent a forged picked/packed quantity even from direct SQL.
CREATE FUNCTION erp_t3c_prepare_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE h sales_trip_preparation%ROWTYPE; r inventory_reservation%ROWTYPE;
 ostatus text; vstate text; ver integer; mode text; chosen uuid;
 prior_pick numeric;prior_pack numeric;scoped numeric;prior_scoped numeric;
 classified numeric;physical numeric;
BEGIN
 SELECT * INTO h FROM sales_trip_preparation WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND id=NEW.preparation_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Trip preparation header missing'; END IF;
 PERFORM 1 FROM warehouse WHERE installation_id=h.installation_id
  AND branch_id=h.branch_id AND id=h.warehouse_id FOR UPDATE;
 SELECT o.status,v.state,o.current_version,c.delivery_choice,c.warehouse_id
  INTO ostatus,vstate,ver,mode,chosen
  FROM sales_order o JOIN sales_order_version v
   ON v.installation_id=o.installation_id AND v.branch_id=o.branch_id
    AND v.order_id=o.id AND v.version_no=h.version_no
  JOIN sales_order_version_context c ON c.installation_id=v.installation_id
   AND c.branch_id=v.branch_id AND c.order_id=v.order_id AND c.version_no=v.version_no
  WHERE o.installation_id=h.installation_id AND o.branch_id=h.branch_id
   AND o.id=h.order_id FOR UPDATE OF o;
 IF ostatus IS DISTINCT FROM 'CONFIRMED' OR vstate IS DISTINCT FROM 'CONFIRMED'
   OR ver IS DISTINCT FROM h.version_no OR mode IS DISTINCT FROM 'TRIP'
   OR chosen IS DISTINCT FROM h.warehouse_id THEN
  RAISE EXCEPTION 'Current confirmed TRIP order required'; END IF;
 SELECT * INTO r FROM inventory_reservation
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
    AND id=NEW.reservation_id FOR SHARE;
 IF NOT FOUND OR r.state<>'ACTIVE' OR r.warehouse_id<>h.warehouse_id
    OR r.order_id<>h.order_id OR r.version_no<>h.version_no
    OR r.line_no<>NEW.order_line_no OR r.product_id<>NEW.product_id THEN
  RAISE EXCEPTION 'Trip preparation must use one active matching hold'; END IF;
 SELECT coalesce(sum(p.picked_base),0),coalesce(sum(p.packed_base),0)
  INTO prior_pick,prior_pack FROM sales_trip_preparation_line p
  WHERE p.installation_id=NEW.installation_id AND p.branch_id=NEW.branch_id
    AND p.reservation_id=NEW.reservation_id;
 IF prior_pick+NEW.picked_base>r.quantity_base
    OR prior_pack+NEW.packed_base>prior_pick+NEW.picked_base
 THEN RAISE EXCEPTION 'Trip picked/packed quantity exceeds reservation'; END IF;
 PERFORM erp_t3b_validate_scope(h.installation_id,h.branch_id,h.warehouse_id,
  NEW.product_id,NEW.location_id,NEW.lot_id);
 -- Picked stock is protected by its *physical* location/lot, even across orders.
 -- Remaining picked excludes physically dispatched units; a dispatch also
 -- decrements physical scope_balance and stock ledger by that same amount.
 IF NEW.picked_base>0 THEN
  -- One aggregate per preparation, even when an item was dispatched in many batches.
  SELECT coalesce(sum(x.picked_base-coalesce(x.issued,0)),0) INTO prior_scoped
   FROM (SELECT p.picked_base,
      (SELECT sum(d.quantity_base) FROM sales_trip_dispatch_line d
       WHERE d.installation_id=p.installation_id AND d.branch_id=p.branch_id
        AND d.preparation_id=p.preparation_id AND d.preparation_line_no=p.source_line) AS issued
     FROM sales_trip_preparation_line p
      JOIN sales_trip_preparation ph ON ph.installation_id=p.installation_id
       AND ph.branch_id=p.branch_id AND ph.id=p.preparation_id
     WHERE ph.installation_id=h.installation_id AND ph.branch_id=h.branch_id
      AND ph.warehouse_id=h.warehouse_id AND p.product_id=NEW.product_id
      AND p.location_id IS NOT DISTINCT FROM NEW.location_id
      AND p.lot_id IS NOT DISTINCT FROM NEW.lot_id) x;
  IF NEW.location_id IS NOT NULL OR NEW.lot_id IS NOT NULL THEN
   SELECT coalesce(sum(quantity_base),0) INTO physical FROM inventory_scope_balance
    WHERE installation_id=h.installation_id AND branch_id=h.branch_id
      AND warehouse_id=h.warehouse_id AND product_id=NEW.product_id
      AND location_id IS NOT DISTINCT FROM NEW.location_id
      AND lot_id IS NOT DISTINCT FROM NEW.lot_id;
  ELSE
   SELECT coalesce((SELECT on_hand FROM inventory_stock_balance
     WHERE installation_id=h.installation_id AND branch_id=h.branch_id
      AND warehouse_id=h.warehouse_id AND product_id=NEW.product_id),0)
    INTO physical;
   SELECT coalesce(sum(quantity_base),0) INTO classified FROM inventory_scope_balance
    WHERE installation_id=h.installation_id AND branch_id=h.branch_id
      AND warehouse_id=h.warehouse_id AND product_id=NEW.product_id;
   physical:=physical-classified;
  END IF;
  IF physical-prior_scoped<NEW.picked_base THEN
   RAISE EXCEPTION 'Trip pick would overcommit physical lot/location stock'; END IF;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER t3c_prepare_line_guard BEFORE INSERT ON sales_trip_preparation_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3c_prepare_line_guard();

CREATE FUNCTION erp_t3c_dispatch_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE h sales_trip_dispatch%ROWTYPE;prep sales_trip_preparation_line%ROWTYPE;
 ph sales_trip_preparation%ROWTYPE;r inventory_reservation%ROWTYPE;
 previous numeric;used_hold numeric;ostatus text;vstate text;ver integer;mode text;chosen uuid;
BEGIN
 SELECT * INTO h FROM sales_trip_dispatch WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND id=NEW.dispatch_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Trip dispatch header missing'; END IF;
 PERFORM 1 FROM warehouse WHERE installation_id=h.installation_id
  AND branch_id=h.branch_id AND id=h.warehouse_id FOR UPDATE;
 SELECT o.status,v.state,o.current_version,c.delivery_choice,c.warehouse_id
 INTO ostatus,vstate,ver,mode,chosen
 FROM sales_order o JOIN sales_order_version v ON v.installation_id=o.installation_id
  AND v.branch_id=o.branch_id AND v.order_id=o.id AND v.version_no=h.version_no
 JOIN sales_order_version_context c ON c.installation_id=v.installation_id
  AND c.branch_id=v.branch_id AND c.order_id=v.order_id AND c.version_no=v.version_no
 WHERE o.installation_id=h.installation_id AND o.branch_id=h.branch_id AND o.id=h.order_id
 FOR UPDATE OF o;
 IF ostatus IS DISTINCT FROM 'CONFIRMED' OR vstate IS DISTINCT FROM 'CONFIRMED'
   OR ver IS DISTINCT FROM h.version_no OR mode IS DISTINCT FROM 'TRIP'
   OR chosen IS DISTINCT FROM h.warehouse_id THEN
  RAISE EXCEPTION 'Current confirmed TRIP dispatch required'; END IF;
 SELECT * INTO prep FROM sales_trip_preparation_line WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND preparation_id=NEW.preparation_id
  AND source_line=NEW.preparation_line_no FOR SHARE;
 SELECT * INTO ph FROM sales_trip_preparation WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND id=NEW.preparation_id;
 SELECT * INTO r FROM inventory_reservation WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND id=NEW.reservation_id FOR SHARE;
 IF prep.preparation_id IS NULL OR ph.id IS NULL OR r.id IS NULL
  OR ph.order_id<>h.order_id OR ph.version_no<>h.version_no OR ph.warehouse_id<>h.warehouse_id
  OR r.state<>'ACTIVE' OR r.id<>prep.reservation_id OR prep.product_id<>NEW.product_id
  OR prep.order_line_no<>NEW.order_line_no OR prep.reservation_id<>NEW.reservation_id
  OR prep.location_id IS DISTINCT FROM NEW.location_id
  OR prep.lot_id IS DISTINCT FROM NEW.lot_id THEN
  RAISE EXCEPTION 'Trip dispatch must match packed lineage'; END IF;
 SELECT coalesce(sum(quantity_base),0) INTO previous FROM sales_trip_dispatch_line
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND preparation_id=NEW.preparation_id AND preparation_line_no=NEW.preparation_line_no;
 IF previous+NEW.quantity_base>prep.packed_base THEN
  RAISE EXCEPTION 'Trip dispatch exceeds packed quantity'; END IF;
 SELECT coalesce(sum(quantity_base),0) INTO used_hold FROM sales_trip_dispatch_line
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND reservation_id=NEW.reservation_id;
 IF used_hold+NEW.quantity_base>r.quantity_base THEN
  RAISE EXCEPTION 'Trip dispatch exceeds reserved quantity'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER t3c_dispatch_line_guard BEFORE INSERT ON sales_trip_dispatch_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3c_dispatch_line_guard();

-- Retain T3-B direct issue guard, adding a strictly-scoped alternative TRIP source.
CREATE OR REPLACE FUNCTION erp_t3b_ledger_scope_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE h sales_direct_issue%ROWTYPE;line sales_direct_issue_line%ROWTYPE;
 th sales_trip_dispatch%ROWTYPE;tl sales_trip_dispatch_line%ROWTYPE;
 available_now numeric;classified numeric;scoped_now numeric;physical_now numeric;
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
 ELSE
  SELECT * INTO th FROM sales_trip_dispatch WHERE installation_id=NEW.installation_id
   AND branch_id=NEW.branch_id AND id=NEW.source_id;
  IF FOUND THEN
   IF NEW.kind<>'ISSUE' OR NEW.source_type<>'FULFILLMENT'
    OR th.warehouse_id<>NEW.warehouse_id THEN
    RAISE EXCEPTION 'Trip dispatch source mismatch'; END IF;
   SELECT * INTO tl FROM sales_trip_dispatch_line WHERE installation_id=NEW.installation_id
    AND branch_id=NEW.branch_id AND dispatch_id=NEW.source_id
    AND source_line=NEW.source_line;
   IF NOT FOUND OR tl.product_id<>NEW.product_id
    OR tl.quantity_base<>-NEW.delta_base THEN
    RAISE EXCEPTION 'Trip dispatch ledger line mismatch'; END IF;
  END IF;
 END IF;
 SELECT coalesce(sum(quantity_base),0) INTO classified FROM inventory_scope_balance
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id;
 SELECT coalesce((SELECT available FROM inventory_stock_balance
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id),0)
 INTO available_now;
 IF th.id IS NOT NULL THEN
  IF tl.location_id IS NOT NULL OR tl.lot_id IS NOT NULL THEN
   SELECT coalesce(sum(quantity_base),0) INTO scoped_now FROM inventory_scope_balance
    WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
     AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id
     AND location_id IS NOT DISTINCT FROM tl.location_id
     AND lot_id IS NOT DISTINCT FROM tl.lot_id;
   IF scoped_now<0 THEN RAISE EXCEPTION 'Trip lot/location stock insufficient'; END IF;
  ELSE
   SELECT coalesce((SELECT on_hand FROM inventory_stock_balance WHERE
    installation_id=NEW.installation_id AND branch_id=NEW.branch_id
     AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id),0)
   INTO physical_now;
   IF physical_now-classified<(-NEW.delta_base) THEN
    RAISE EXCEPTION 'Trip unscoped physical stock insufficient'; END IF;
  END IF;
 ELSIF h.id IS NOT NULL AND (line.location_id IS NOT NULL OR line.lot_id IS NOT NULL) THEN
  SELECT coalesce(sum(quantity_base),0) INTO scoped_now FROM inventory_scope_balance
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
    AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id
    AND location_id IS NOT DISTINCT FROM line.location_id
    AND lot_id IS NOT DISTINCT FROM line.lot_id;
  IF scoped_now<0 THEN RAISE EXCEPTION 'Insufficient stock at lot/location'; END IF;
 ELSE
  IF classified>0 AND available_now-classified<(-NEW.delta_base) THEN
   RAISE EXCEPTION 'Assigned stock cannot be consumed without lot/location'; END IF;
 END IF;
 RETURN NEW;
END; $$;

-- Bidirectional cryptographic-identity-free DB lineage: every trip issue
-- must have exactly one immutable movement, and vice versa at COMMIT.
CREATE FUNCTION erp_t3c_dispatch_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS (
  SELECT 1 FROM sales_trip_dispatch d JOIN inventory_ledger m
   ON m.installation_id=d.installation_id AND m.branch_id=d.branch_id
    AND m.warehouse_id=d.warehouse_id AND m.source_type='FULFILLMENT'
    AND m.kind='ISSUE' AND m.source_id=d.id AND m.source_line=NEW.source_line
    AND m.product_id=NEW.product_id AND m.delta_base=-NEW.quantity_base
  WHERE d.installation_id=NEW.installation_id AND d.branch_id=NEW.branch_id
    AND d.id=NEW.dispatch_id
 ) THEN RAISE EXCEPTION 'Trip dispatch line missing matching posted inventory movement'; END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER trip_dispatch_line_commit AFTER INSERT ON sales_trip_dispatch_line
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION erp_t3c_dispatch_commit_guard();

CREATE FUNCTION erp_t3c_ledger_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.kind='ISSUE' AND NEW.source_type='FULFILLMENT'
  AND EXISTS (SELECT 1 FROM sales_trip_dispatch d
   WHERE d.installation_id=NEW.installation_id AND d.branch_id=NEW.branch_id
     AND d.id=NEW.source_id)
  AND NOT EXISTS (SELECT 1 FROM sales_trip_dispatch d JOIN sales_trip_dispatch_line l
    ON l.installation_id=d.installation_id AND l.branch_id=d.branch_id
     AND l.dispatch_id=d.id
   WHERE d.installation_id=NEW.installation_id AND d.branch_id=NEW.branch_id
    AND d.id=NEW.source_id AND d.warehouse_id=NEW.warehouse_id
    AND l.source_line=NEW.source_line AND l.product_id=NEW.product_id
    AND l.quantity_base=-NEW.delta_base)
 THEN RAISE EXCEPTION 'Trip ledger movement has no matching dispatch line'; END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER trip_ledger_commit AFTER INSERT ON inventory_ledger
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION erp_t3c_ledger_commit_guard();
CREATE FUNCTION erp_t3c_header_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM sales_trip_dispatch_line l
  WHERE l.installation_id=NEW.installation_id AND l.branch_id=NEW.branch_id
   AND l.dispatch_id=NEW.id) THEN RAISE EXCEPTION 'Trip dispatch requires lines'; END IF;
 IF EXISTS (SELECT 1 FROM inventory_ledger m WHERE m.installation_id=NEW.installation_id
  AND m.branch_id=NEW.branch_id AND m.kind='ISSUE' AND m.source_type='FULFILLMENT'
  AND m.source_id=NEW.id AND NOT EXISTS (
    SELECT 1 FROM sales_trip_dispatch_line l WHERE l.installation_id=m.installation_id
     AND l.branch_id=m.branch_id AND l.dispatch_id=NEW.id
     AND l.source_line=m.source_line AND l.product_id=m.product_id
     AND l.quantity_base=-m.delta_base AND m.warehouse_id=NEW.warehouse_id))
 THEN RAISE EXCEPTION 'Trip dispatch header has unmatched inventory movements'; END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER trip_dispatch_header_commit AFTER INSERT ON sales_trip_dispatch
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION erp_t3c_header_commit_guard();
