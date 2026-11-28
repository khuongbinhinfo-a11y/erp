-- T5-D: delivery execution, physical return and COD custody on canonical ledgers.
-- Additive schema; DO NOT migrate production without owner approval and restore rehearsal.
ALTER TABLE sales_fulfillment DROP CONSTRAINT sales_fulfillment_mode_check;
ALTER TABLE sales_fulfillment ADD CONSTRAINT sales_fulfillment_mode_check
 CHECK(mode IN ('PICKUP','MANUAL','TRIP'));

CREATE TABLE delivery_trip_departure (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,trip_id uuid NOT NULL,
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 departed_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,trip_id),
 FOREIGN KEY(installation_id,branch_id,trip_id) REFERENCES delivery_trip(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);
CREATE TABLE delivery_trip_attempt (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),trip_id uuid NOT NULL,order_id uuid NOT NULL,
 attempt_no integer NOT NULL CHECK(attempt_no BETWEEN 1 AND 1000),
 result text NOT NULL CHECK(result IN ('DELIVERED_FULL','DELIVERED_PARTIAL','FAILED','RESCHEDULED')),
 reason_code text,rescheduled_for timestamptz,
 amount numeric(20,0) NOT NULL CHECK(amount>=0),
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 occurred_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,trip_id,order_id,attempt_no),
 FOREIGN KEY(installation_id,branch_id,trip_id,order_id)
  REFERENCES delivery_trip_stop(installation_id,branch_id,trip_id,order_id),
 FOREIGN KEY(installation_id,branch_id,trip_id)
  REFERENCES delivery_trip_departure(installation_id,branch_id,trip_id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id),
 CHECK ((result IN ('FAILED','RESCHEDULED'))=(reason_code IS NOT NULL)),
 CHECK(reason_code IS NULL OR reason_code ~ '^[A-Z][A-Z0-9_]{0,47}$'),
 CHECK ((result='RESCHEDULED')=(rescheduled_for IS NOT NULL))
);
CREATE INDEX delivery_trip_attempt_stop_idx ON delivery_trip_attempt
 (installation_id,branch_id,trip_id,order_id,attempt_no);
CREATE TABLE delivery_trip_attempt_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,attempt_id uuid NOT NULL,
 dispatch_id uuid NOT NULL,source_line integer NOT NULL CHECK(source_line BETWEEN 1 AND 10000),
 quantity_base numeric(24,6) NOT NULL CHECK(quantity_base>=0 AND quantity_base<>'NaN'::numeric),
 PRIMARY KEY(installation_id,branch_id,attempt_id,dispatch_id,source_line),
 FOREIGN KEY(installation_id,branch_id,attempt_id)
  REFERENCES delivery_trip_attempt(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,dispatch_id,source_line)
  REFERENCES sales_trip_dispatch_line(installation_id,branch_id,dispatch_id,source_line)
);
CREATE INDEX delivery_trip_attempt_line_source ON delivery_trip_attempt_line
 (installation_id,branch_id,dispatch_id,source_line);

CREATE TABLE delivery_trip_return (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),trip_id uuid NOT NULL,order_id uuid NOT NULL,
 reason text NOT NULL CHECK(length(trim(reason)) BETWEEN 3 AND 500),
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 returned_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,trip_id,order_id)
  REFERENCES delivery_trip_stop(installation_id,branch_id,trip_id,order_id),
 FOREIGN KEY(installation_id,branch_id,trip_id)
  REFERENCES delivery_trip_departure(installation_id,branch_id,trip_id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);
CREATE TABLE delivery_trip_return_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,return_id uuid NOT NULL,
 source_line integer NOT NULL CHECK(source_line BETWEEN 1 AND 10000),
 dispatch_id uuid NOT NULL,dispatch_source_line integer NOT NULL CHECK(dispatch_source_line BETWEEN 1 AND 10000),
 product_id uuid NOT NULL,location_id uuid,lot_id uuid,
 quantity_base numeric(24,6) NOT NULL CHECK(quantity_base>0 AND quantity_base<>'NaN'::numeric),
 PRIMARY KEY(installation_id,branch_id,return_id,source_line),
 FOREIGN KEY(installation_id,branch_id,return_id)
  REFERENCES delivery_trip_return(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,dispatch_id,dispatch_source_line)
  REFERENCES sales_trip_dispatch_line(installation_id,branch_id,dispatch_id,source_line),
 FOREIGN KEY(installation_id,branch_id,product_id)
  REFERENCES catalog_product(installation_id,branch_id,id)
);
CREATE INDEX delivery_trip_return_line_source ON delivery_trip_return_line
 (installation_id,branch_id,dispatch_id,dispatch_source_line);

CREATE TABLE delivery_cod_collection (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),trip_id uuid NOT NULL,order_id uuid NOT NULL,
 receipt_id uuid NOT NULL,driver_id uuid NOT NULL,
 amount numeric(20,0) NOT NULL CHECK(amount>0),
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 collected_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,receipt_id),
 FOREIGN KEY(installation_id,branch_id,trip_id,order_id)
  REFERENCES delivery_trip_stop(installation_id,branch_id,trip_id,order_id),
 FOREIGN KEY(installation_id,branch_id,receipt_id)
  REFERENCES payment_receipt(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,driver_id)
  REFERENCES delivery_driver(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);
CREATE TABLE delivery_cod_handover (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),trip_id uuid NOT NULL,driver_id uuid NOT NULL,
 receiver_id uuid NOT NULL,actor_id uuid NOT NULL,
 request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 handed_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,trip_id)
  REFERENCES delivery_trip_departure(installation_id,branch_id,trip_id),
 FOREIGN KEY(installation_id,branch_id,driver_id)
  REFERENCES delivery_driver(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,receiver_id) REFERENCES app_user(installation_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);
CREATE TABLE delivery_cod_handover_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 handover_id uuid NOT NULL,collection_id uuid NOT NULL,
 amount numeric(20,0) NOT NULL CHECK(amount>0),
 PRIMARY KEY(installation_id,branch_id,handover_id,collection_id),
 FOREIGN KEY(installation_id,branch_id,handover_id)
  REFERENCES delivery_cod_handover(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,collection_id)
  REFERENCES delivery_cod_collection(installation_id,branch_id,id)
);

-- No updates/deletes of posted facts, including corrections (new facts only).
CREATE TRIGGER t5d_departure_immutable BEFORE UPDATE OR DELETE ON delivery_trip_departure
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER t5d_attempt_immutable BEFORE UPDATE OR DELETE ON delivery_trip_attempt
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER t5d_attempt_line_immutable BEFORE UPDATE OR DELETE ON delivery_trip_attempt_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER t5d_return_immutable BEFORE UPDATE OR DELETE ON delivery_trip_return
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER t5d_return_line_immutable BEFORE UPDATE OR DELETE ON delivery_trip_return_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER t5d_collection_immutable BEFORE UPDATE OR DELETE ON delivery_cod_collection
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER t5d_handover_immutable BEFORE UPDATE OR DELETE ON delivery_cod_handover
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER t5d_handover_line_immutable BEFORE UPDATE OR DELETE ON delivery_cod_handover_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();

-- Serializes direct SQL additions with departure, which locks order rows.
CREATE FUNCTION erp_t5d_no_late_dispatch() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source_order uuid;
BEGIN
 IF TG_TABLE_NAME='sales_trip_dispatch_line' THEN
  SELECT order_id INTO source_order FROM sales_trip_dispatch
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id AND id=NEW.dispatch_id;
 ELSE source_order:=NEW.order_id; END IF;
 PERFORM 1 FROM sales_order WHERE installation_id=NEW.installation_id AND
  branch_id=NEW.branch_id AND id=source_order FOR UPDATE;
 IF EXISTS (SELECT 1 FROM delivery_trip_stop s JOIN delivery_trip_departure d
  ON d.installation_id=s.installation_id AND d.branch_id=s.branch_id AND d.trip_id=s.trip_id
  WHERE s.installation_id=NEW.installation_id AND s.branch_id=NEW.branch_id
   AND s.order_id=source_order)
 THEN RAISE EXCEPTION 'Cannot add dispatch after trip departure'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER t5d_no_late_dispatch_header BEFORE INSERT ON sales_trip_dispatch
 FOR EACH ROW EXECUTE FUNCTION erp_t5d_no_late_dispatch();
CREATE TRIGGER t5d_no_late_dispatch_line BEFORE INSERT ON sales_trip_dispatch_line
 FOR EACH ROW EXECUTE FUNCTION erp_t5d_no_late_dispatch();

-- Existing return guard is broadened to accept ONLY exact matching trip returns.
-- Manual branch remains unchanged.
CREATE OR REPLACE FUNCTION erp_t5a_return_ledger_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.kind='RETURN' THEN
  IF NEW.source_type<>'FULFILLMENT' OR NOT (
   EXISTS(SELECT 1 FROM sales_manual_return h JOIN sales_manual_return_line l
     ON l.installation_id=h.installation_id AND l.branch_id=h.branch_id
     AND l.return_id=h.id
     WHERE h.installation_id=NEW.installation_id AND h.branch_id=NEW.branch_id
     AND h.id=NEW.source_id AND h.warehouse_id=NEW.warehouse_id
     AND l.source_line=NEW.source_line AND l.product_id=NEW.product_id
     AND l.quantity_base=NEW.delta_base)
   OR EXISTS(SELECT 1 FROM delivery_trip_return h
     JOIN delivery_trip_return_line l ON l.installation_id=h.installation_id
     AND l.branch_id=h.branch_id AND l.return_id=h.id
     JOIN delivery_trip t ON t.installation_id=h.installation_id
     AND t.branch_id=h.branch_id AND t.id=h.trip_id
     WHERE h.installation_id=NEW.installation_id AND h.branch_id=NEW.branch_id
     AND h.id=NEW.source_id AND t.warehouse_id=NEW.warehouse_id
     AND l.source_line=NEW.source_line AND l.product_id=NEW.product_id
     AND l.quantity_base=NEW.delta_base)
  ) THEN RAISE EXCEPTION 'Return ledger must match immutable return line'; END IF;
 ELSIF NEW.source_type='FULFILLMENT' AND EXISTS(
  SELECT 1 FROM sales_manual_return h WHERE h.installation_id=NEW.installation_id
   AND h.branch_id=NEW.branch_id AND h.id=NEW.source_id
  UNION ALL SELECT 1 FROM delivery_trip_return h WHERE h.installation_id=NEW.installation_id
   AND h.branch_id=NEW.branch_id AND h.id=NEW.source_id
 ) THEN RAISE EXCEPTION 'Return must use RETURN ledger kind'; END IF;
 RETURN NEW;
END $$;

-- Preserve existing lot/location balance and add exact trip returns.
CREATE OR REPLACE VIEW inventory_scope_balance AS
 SELECT installation_id,branch_id,warehouse_id,product_id,location_id,lot_id,
 sum(delta)::numeric(24,6) AS quantity_base FROM (
  SELECT a.installation_id,a.branch_id,a.warehouse_id,a.product_id,
   a.location_id,a.lot_id,a.quantity_base AS delta FROM inventory_scope_assignment a
  UNION ALL SELECT d.installation_id,d.branch_id,d.warehouse_id,l.product_id,
   l.location_id,l.lot_id,-l.quantity_base FROM sales_direct_issue_line l
   JOIN sales_direct_issue d ON d.installation_id=l.installation_id AND d.branch_id=l.branch_id
    AND d.id=l.issue_id WHERE l.location_id IS NOT NULL OR l.lot_id IS NOT NULL
  UNION ALL SELECT d.installation_id,d.branch_id,d.warehouse_id,l.product_id,
   l.location_id,l.lot_id,-l.quantity_base FROM sales_trip_dispatch_line l
   JOIN sales_trip_dispatch d ON d.installation_id=l.installation_id AND d.branch_id=l.branch_id
    AND d.id=l.dispatch_id WHERE l.location_id IS NOT NULL OR l.lot_id IS NOT NULL
  UNION ALL SELECT d.installation_id,d.branch_id,d.warehouse_id,l.product_id,
   l.location_id,l.lot_id,l.quantity_base FROM sales_manual_return_line l
   JOIN sales_manual_return d ON d.installation_id=l.installation_id AND d.branch_id=l.branch_id
    AND d.id=l.return_id WHERE l.location_id IS NOT NULL OR l.lot_id IS NOT NULL
  UNION ALL SELECT d.installation_id,d.branch_id,t.warehouse_id,l.product_id,
   l.location_id,l.lot_id,l.quantity_base FROM delivery_trip_return_line l
   JOIN delivery_trip_return d ON d.installation_id=l.installation_id
     AND d.branch_id=l.branch_id AND d.id=l.return_id
   JOIN delivery_trip t ON t.installation_id=d.installation_id
     AND t.branch_id=d.branch_id AND t.id=d.trip_id
   WHERE l.location_id IS NOT NULL OR l.lot_id IS NOT NULL
 ) facts GROUP BY installation_id,branch_id,warehouse_id,product_id,location_id,lot_id;

-- Protect stock custody even against direct SQL callers; lock canonical order.
CREATE FUNCTION erp_t5d_quantity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE order_ref uuid;source_qty numeric;delivered numeric;returned numeric;
        trip_ref uuid;product_ref uuid;location_ref uuid;lot_ref uuid;
        version_ref integer;wh_ref uuid;header_trip uuid;header_order uuid;
        dispatch_ref uuid;line_ref integer;qty numeric;
BEGIN
 IF TG_TABLE_NAME='delivery_trip_attempt_line' THEN
  SELECT trip_id,order_id INTO header_trip,header_order FROM delivery_trip_attempt
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id AND id=NEW.attempt_id;
  dispatch_ref:=NEW.dispatch_id;line_ref:=NEW.source_line;qty:=NEW.quantity_base;
 ELSE
  SELECT trip_id,order_id INTO header_trip,header_order FROM delivery_trip_return
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id AND id=NEW.return_id;
  dispatch_ref:=NEW.dispatch_id;line_ref:=NEW.dispatch_source_line;qty:=NEW.quantity_base;
 END IF;
 PERFORM 1 FROM sales_order WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND id=header_order FOR UPDATE;
 SELECT h.order_id,h.version_no,h.warehouse_id,l.quantity_base,l.product_id,l.location_id,l.lot_id
 INTO order_ref,version_ref,wh_ref,source_qty,product_ref,location_ref,lot_ref
 FROM sales_trip_dispatch h JOIN sales_trip_dispatch_line l
 ON l.installation_id=h.installation_id AND l.branch_id=h.branch_id AND l.dispatch_id=h.id
 WHERE h.installation_id=NEW.installation_id AND h.branch_id=NEW.branch_id
 AND h.id=dispatch_ref AND l.source_line=line_ref;
 IF source_qty IS NULL OR order_ref<>header_order OR NOT EXISTS(
  SELECT 1 FROM delivery_trip_stop s JOIN delivery_trip t
  ON t.installation_id=s.installation_id AND t.branch_id=s.branch_id AND t.id=s.trip_id
  WHERE s.installation_id=NEW.installation_id AND s.branch_id=NEW.branch_id
  AND s.trip_id=header_trip AND s.order_id=header_order
  AND s.order_version=version_ref AND t.warehouse_id=wh_ref
 ) THEN RAISE EXCEPTION 'Delivery quantity source out of scope'; END IF;
 IF TG_TABLE_NAME='delivery_trip_return_line' AND
  (NEW.product_id<>product_ref OR NEW.location_id IS DISTINCT FROM location_ref
   OR NEW.lot_id IS DISTINCT FROM lot_ref)
 THEN RAISE EXCEPTION 'Returned goods must preserve exact issue identity'; END IF;
 SELECT coalesce(sum(l.quantity_base),0) INTO delivered
 FROM delivery_trip_attempt_line l JOIN delivery_trip_attempt a
 ON a.installation_id=l.installation_id AND a.branch_id=l.branch_id AND a.id=l.attempt_id
 WHERE l.installation_id=NEW.installation_id AND l.branch_id=NEW.branch_id
 AND a.trip_id=header_trip AND a.order_id=header_order
 AND l.dispatch_id=dispatch_ref AND l.source_line=line_ref;
 SELECT coalesce(sum(l.quantity_base),0) INTO returned
 FROM delivery_trip_return_line l JOIN delivery_trip_return r
 ON r.installation_id=l.installation_id AND r.branch_id=l.branch_id AND r.id=l.return_id
 WHERE l.installation_id=NEW.installation_id AND l.branch_id=NEW.branch_id
 AND r.trip_id=header_trip AND r.order_id=header_order
 AND l.dispatch_id=dispatch_ref AND l.dispatch_source_line=line_ref;
 IF delivered+returned+qty>source_qty THEN
  RAISE EXCEPTION 'Delivered + returned exceeds physical issue'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER t5d_attempt_quantity BEFORE INSERT ON delivery_trip_attempt_line
 FOR EACH ROW EXECUTE FUNCTION erp_t5d_quantity_guard();
CREATE TRIGGER t5d_return_quantity BEFORE INSERT ON delivery_trip_return_line
 FOR EACH ROW EXECUTE FUNCTION erp_t5d_quantity_guard();

CREATE FUNCTION erp_t5d_return_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM delivery_trip_return h
  JOIN delivery_trip t ON t.installation_id=h.installation_id
   AND t.branch_id=h.branch_id AND t.id=h.trip_id
  JOIN inventory_ledger m ON m.installation_id=h.installation_id
   AND m.branch_id=h.branch_id AND m.warehouse_id=t.warehouse_id
   AND m.source_type='FULFILLMENT' AND m.kind='RETURN' AND m.source_id=h.id
  WHERE h.installation_id=NEW.installation_id AND h.branch_id=NEW.branch_id
   AND h.id=NEW.return_id AND m.source_line=NEW.source_line
   AND m.product_id=NEW.product_id AND m.delta_base=NEW.quantity_base)
 THEN RAISE EXCEPTION 'Trip return requires matching inventory RETURN fact'; END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER t5d_return_commit AFTER INSERT ON delivery_trip_return_line
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION erp_t5d_return_commit_guard();

-- Existing payment receipt guard now recognizes TRIP fulfillment; the same
-- shared payment_allocation and customer AR checks still apply.
CREATE OR REPLACE FUNCTION erp_t5a_receipt_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE matching_order uuid;payment_count integer;payment_amount numeric;allocated_amount numeric;
BEGIN
 IF NEW.fulfillment_id IS NULL THEN RETURN NULL; END IF;
 SELECT order_id INTO matching_order FROM sales_fulfillment WHERE
 installation_id=NEW.installation_id AND branch_id=NEW.branch_id
 AND id=NEW.fulfillment_id AND mode IN ('MANUAL','TRIP');
 IF matching_order IS NULL OR matching_order<>NEW.order_id
 THEN RAISE EXCEPTION 'Payment receipt must match fulfilled order'; END IF;
 SELECT coalesce(sum(allocated),0) INTO allocated_amount FROM payment_allocation
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id AND receipt_id=NEW.id;
 SELECT count(*),coalesce(-sum(amount),0) INTO payment_count,payment_amount
 FROM customer_receivable_ledger WHERE installation_id=NEW.installation_id
 AND branch_id=NEW.branch_id AND order_id=NEW.order_id AND kind='PAYMENT' AND source_id=NEW.id;
 IF allocated_amount<>NEW.amount OR payment_count<>1 OR payment_amount<>NEW.amount
 THEN RAISE EXCEPTION 'Receipt must match one posted payment and allocation'; END IF;
 RETURN NULL;
END $$;

-- COD handover is a custody change, not another customer payment.
CREATE FUNCTION erp_t5d_handover_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source_trip uuid;source_driver uuid;collected numeric;handed numeric;
  target_trip uuid;target_driver uuid;
BEGIN
 SELECT trip_id,driver_id INTO target_trip,target_driver FROM delivery_cod_handover
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id AND id=NEW.handover_id;
 SELECT trip_id,driver_id,amount INTO source_trip,source_driver,collected
 FROM delivery_cod_collection WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND id=NEW.collection_id FOR UPDATE;
 IF source_trip IS NULL OR source_trip<>target_trip OR source_driver<>target_driver
 THEN RAISE EXCEPTION 'COD handover must match driver and trip custody'; END IF;
 SELECT coalesce(sum(amount),0) INTO handed FROM delivery_cod_handover_line
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
 AND collection_id=NEW.collection_id;
 IF handed+NEW.amount>collected THEN RAISE EXCEPTION 'COD handover exceeds collected'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER t5d_handover_guard BEFORE INSERT ON delivery_cod_handover_line
 FOR EACH ROW EXECUTE FUNCTION erp_t5d_handover_guard();
CREATE FUNCTION erp_t5d_handover_nonempty() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM delivery_cod_handover_line l
  WHERE l.installation_id=NEW.installation_id AND l.branch_id=NEW.branch_id
   AND l.handover_id=NEW.id) THEN RAISE EXCEPTION 'Empty COD handover forbidden'; END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER t5d_handover_nonempty AFTER INSERT ON delivery_cod_handover
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION erp_t5d_handover_nonempty();

-- New owner rights, no automatic driver wide privileges.
INSERT INTO role_permission(installation_id,role_id,permission_code)
 SELECT r.installation_id,r.id,'delivery.execute' FROM app_role r
 WHERE r.code='PRIMARY_OWNER_MAIN' OR r.code LIKE 'OWNER_BRANCH_%'
 ON CONFLICT DO NOTHING;
INSERT INTO role_permission(installation_id,role_id,permission_code)
 SELECT r.installation_id,r.id,'delivery.cod.handover' FROM app_role r
 WHERE r.code='PRIMARY_OWNER_MAIN' OR r.code LIKE 'OWNER_BRANCH_%'
 ON CONFLICT DO NOTHING;
