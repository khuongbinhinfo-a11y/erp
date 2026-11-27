-- T5-A: MANUAL delivery, partial warehouse return, and repeated canonical AR payments.
-- Forward-only, append-only facts. CI/fresh-DB only until separate owner-approved
-- Codespaces preflight + durable backup/restore/reconciliation for production.
-- A fully returned shipment is a closed, non-revenue terminal state.
ALTER TABLE sales_order DROP CONSTRAINT sales_order_delivery_status_check;
ALTER TABLE sales_order ADD CONSTRAINT sales_order_delivery_status_check
 CHECK(delivery_status IN ('NOT_DISPATCHED','PARTIAL','DELIVERED','RETURNED'));

ALTER TABLE sales_fulfillment DROP CONSTRAINT sales_fulfillment_mode_check;
ALTER TABLE sales_fulfillment ADD CONSTRAINT sales_fulfillment_mode_check
 CHECK(mode IN ('PICKUP','MANUAL'));

CREATE TABLE sales_manual_return (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL,version_no integer NOT NULL,warehouse_id uuid NOT NULL,
 reason text NOT NULL CHECK(length(trim(reason)) BETWEEN 3 AND 500),
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 returned_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,order_id,version_no)
  REFERENCES sales_order_version(installation_id,branch_id,order_id,version_no),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);
CREATE INDEX sales_manual_return_order_idx ON sales_manual_return
 (installation_id,branch_id,order_id,version_no,returned_at);

CREATE TABLE sales_manual_return_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 return_id uuid NOT NULL,source_line integer NOT NULL CHECK(source_line BETWEEN 1 AND 10000),
 issue_id uuid NOT NULL,issue_source_line integer NOT NULL CHECK(issue_source_line BETWEEN 1 AND 10000),
 order_line_no integer NOT NULL CHECK(order_line_no BETWEEN 1 AND 10000),
 product_id uuid NOT NULL,quantity_base numeric(24,6) NOT NULL
  CHECK(quantity_base>0 AND quantity_base<>'NaN'::numeric),
 location_id uuid,lot_id uuid,
 PRIMARY KEY(installation_id,branch_id,return_id,source_line),
 FOREIGN KEY(installation_id,branch_id,return_id)
  REFERENCES sales_manual_return(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,issue_id,issue_source_line)
  REFERENCES sales_direct_issue_line(installation_id,branch_id,issue_id,source_line)
);
CREATE INDEX sales_manual_return_source_idx ON sales_manual_return_line
 (installation_id,branch_id,issue_id,issue_source_line);

-- Confirmed on-hand comes exclusively from inventory_ledger RETURN events.
ALTER TABLE inventory_ledger DROP CONSTRAINT inventory_ledger_kind_check;
ALTER TABLE inventory_ledger ADD CONSTRAINT inventory_ledger_kind_check
 CHECK(kind IN ('OPENING','RECEIPT','ISSUE','TRANSFER_IN','TRANSFER_OUT',
  'REVERSAL','ADJUSTMENT','RETURN'));
ALTER TABLE inventory_ledger DROP CONSTRAINT inventory_ledger_check1;
ALTER TABLE inventory_ledger ADD CONSTRAINT inventory_ledger_check1
 CHECK ((kind IN ('OPENING','RECEIPT','TRANSFER_IN','RETURN') AND delta_base>0)
  OR (kind IN ('ISSUE','TRANSFER_OUT') AND delta_base<0)
  OR kind IN ('REVERSAL','ADJUSTMENT'));

-- Returned classified goods restore their exact original lot/bin. Do not
-- convert a lot-specific return into unscoped available stock.
CREATE OR REPLACE VIEW inventory_scope_balance AS
 SELECT installation_id,branch_id,warehouse_id,product_id,location_id,lot_id,
  sum(delta)::numeric(24,6) AS quantity_base FROM (
  SELECT a.installation_id,a.branch_id,a.warehouse_id,a.product_id,
   a.location_id,a.lot_id,a.quantity_base AS delta FROM inventory_scope_assignment a
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
   ON d.installation_id=l.installation_id AND d.branch_id=l.branch_id AND d.id=l.dispatch_id
  WHERE l.location_id IS NOT NULL OR l.lot_id IS NOT NULL
  UNION ALL
  SELECT d.installation_id,d.branch_id,d.warehouse_id,l.product_id,
   l.location_id,l.lot_id,l.quantity_base AS delta
  FROM sales_manual_return_line l JOIN sales_manual_return d
   ON d.installation_id=l.installation_id AND d.branch_id=l.branch_id AND d.id=l.return_id
  WHERE l.location_id IS NOT NULL OR l.lot_id IS NOT NULL
 ) facts GROUP BY installation_id,branch_id,warehouse_id,product_id,location_id,lot_id;

CREATE FUNCTION erp_t5a_return_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE issue_row sales_direct_issue_line%ROWTYPE;source_order uuid;
 source_version integer;source_wh uuid;return_order uuid;
 return_version integer;return_wh uuid;returned numeric;
BEGIN
 SELECT l.* INTO issue_row
 FROM sales_direct_issue_line l
 WHERE l.installation_id=NEW.installation_id AND l.branch_id=NEW.branch_id
  AND l.issue_id=NEW.issue_id AND l.source_line=NEW.issue_source_line
 FOR UPDATE OF l;
 SELECT h.order_id,h.version_no,h.warehouse_id
 INTO source_order,source_version,source_wh
 FROM sales_direct_issue h WHERE h.installation_id=NEW.installation_id
  AND h.branch_id=NEW.branch_id AND h.id=NEW.issue_id;
 SELECT order_id,version_no,warehouse_id INTO return_order,return_version,return_wh
 FROM sales_manual_return WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND id=NEW.return_id;
 IF issue_row.issue_id IS NULL OR source_order<>return_order OR
  source_version<>return_version OR source_wh<>return_wh OR
  NEW.order_line_no<>issue_row.order_line_no OR
  NEW.product_id<>issue_row.product_id OR
  NEW.location_id IS DISTINCT FROM issue_row.location_id OR
  NEW.lot_id IS DISTINCT FROM issue_row.lot_id
 THEN RAISE EXCEPTION 'Return must match original issued stock scope'; END IF;
 SELECT coalesce(sum(quantity_base),0) INTO returned FROM sales_manual_return_line
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND issue_id=NEW.issue_id AND issue_source_line=NEW.issue_source_line;
 IF returned+NEW.quantity_base>issue_row.quantity_base THEN
  RAISE EXCEPTION 'Return exceeds original issued quantity'; END IF;
 IF EXISTS(
  SELECT 1 FROM sales_fulfillment f
  WHERE f.installation_id=NEW.installation_id AND f.branch_id=NEW.branch_id
   AND f.order_id=return_order AND f.mode='MANUAL'
 ) THEN RAISE EXCEPTION 'Cannot return stock after MANUAL completion'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER t5a_return_line_guard BEFORE INSERT ON sales_manual_return_line
 FOR EACH ROW EXECUTE FUNCTION erp_t5a_return_line_guard();

CREATE FUNCTION erp_t5a_return_ledger_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.kind='RETURN' THEN
  IF NEW.source_type<>'FULFILLMENT' OR NOT EXISTS(
   SELECT 1 FROM sales_manual_return h JOIN sales_manual_return_line l
    ON l.installation_id=h.installation_id AND l.branch_id=h.branch_id
    AND l.return_id=h.id
   WHERE h.installation_id=NEW.installation_id AND h.branch_id=NEW.branch_id
    AND h.id=NEW.source_id AND h.warehouse_id=NEW.warehouse_id
    AND l.source_line=NEW.source_line AND l.product_id=NEW.product_id
    AND l.quantity_base=NEW.delta_base
  ) THEN RAISE EXCEPTION 'Return ledger must match immutable return line'; END IF;
 ELSIF NEW.source_type='FULFILLMENT' AND EXISTS (
  SELECT 1 FROM sales_manual_return h WHERE h.installation_id=NEW.installation_id
   AND h.branch_id=NEW.branch_id AND h.id=NEW.source_id
 ) THEN RAISE EXCEPTION 'Manual return cannot post a different ledger kind'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER t5a_return_ledger_guard BEFORE INSERT ON inventory_ledger
 FOR EACH ROW EXECUTE FUNCTION erp_t5a_return_ledger_guard();
CREATE FUNCTION erp_t5a_return_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(
  SELECT 1 FROM sales_manual_return h JOIN inventory_ledger m
   ON m.installation_id=h.installation_id AND m.branch_id=h.branch_id
   AND m.warehouse_id=h.warehouse_id
  WHERE h.installation_id=NEW.installation_id AND h.branch_id=NEW.branch_id
   AND h.id=NEW.return_id AND m.source_type='FULFILLMENT' AND m.kind='RETURN'
   AND m.source_id=h.id AND m.source_line=NEW.source_line
   AND m.product_id=NEW.product_id AND m.delta_base=NEW.quantity_base
 ) THEN RAISE EXCEPTION 'Manual return requires matching posted stock movement'; END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER t5a_return_commit_guard AFTER INSERT ON sales_manual_return_line
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION erp_t5a_return_commit_guard();

CREATE TRIGGER t5a_return_immutable BEFORE UPDATE OR DELETE ON sales_manual_return
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();
CREATE TRIGGER t5a_return_line_immutable BEFORE UPDATE OR DELETE ON sales_manual_return_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();

CREATE TABLE sales_manual_delivery_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 fulfillment_id uuid NOT NULL,order_line_no integer NOT NULL CHECK(order_line_no BETWEEN 1 AND 10000),
 product_id uuid NOT NULL,
 ordered_base numeric(24,6) NOT NULL CHECK(ordered_base>0),
 issued_base numeric(24,6) NOT NULL CHECK(issued_base>=0),
 returned_base numeric(24,6) NOT NULL CHECK(returned_base>=0),
 delivered_base numeric(24,6) NOT NULL CHECK(delivered_base>=0),
 amount numeric(20,0) NOT NULL CHECK(amount>=0),
 PRIMARY KEY(installation_id,branch_id,fulfillment_id,order_line_no),
 FOREIGN KEY(installation_id,branch_id,fulfillment_id)
  REFERENCES sales_fulfillment(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id)
  REFERENCES catalog_product(installation_id,branch_id,id),
 CHECK(issued_base=returned_base+delivered_base AND issued_base<=ordered_base)
);
CREATE TRIGGER t5a_delivery_line_immutable BEFORE UPDATE OR DELETE ON sales_manual_delivery_line
 FOR EACH ROW EXECUTE FUNCTION erp_t3b_immutable();

-- Preserve the existing POS receipt contract, while allowing arbitrarily
-- many separately auditable MANUAL payment receipts against one fulfillment.
ALTER TABLE payment_receipt ALTER COLUMN checkout_id DROP NOT NULL;
ALTER TABLE payment_receipt ADD COLUMN fulfillment_id uuid;
ALTER TABLE payment_receipt ADD CONSTRAINT t5a_payment_source_exactly_one CHECK(
 (checkout_id IS NOT NULL) <> (fulfillment_id IS NOT NULL));
ALTER TABLE payment_receipt ADD CONSTRAINT t5a_payment_fulfillment_fk
 FOREIGN KEY(installation_id,branch_id,fulfillment_id)
 REFERENCES sales_fulfillment(installation_id,branch_id,id);
CREATE INDEX t5a_manual_payment_idx ON payment_receipt
 (installation_id,branch_id,fulfillment_id,posted_at,id)
 WHERE fulfillment_id IS NOT NULL;

-- Every allocation must belong to the same canonical order/tenant. Totals
-- remain reconstructible from immutable payment and AR ledger.
CREATE FUNCTION erp_t5a_allocation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE receipt_order uuid;sale_order uuid;receipt_amount numeric;
 sale_amount numeric;receipt_sum numeric;sale_sum numeric;
BEGIN
 -- Serialize concurrent direct SQL writers on the shared SALE row, then
 -- the child receipt in the same lock order. Otherwise two transactions can
 -- both observe each other's uncommitted allocations as missing.
 SELECT order_id,amount INTO sale_order,sale_amount FROM customer_receivable_ledger
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND id=NEW.sale_ledger_id AND kind='SALE' FOR UPDATE;
 SELECT order_id,amount INTO receipt_order,receipt_amount FROM payment_receipt
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND id=NEW.receipt_id FOR UPDATE;
 SELECT coalesce(sum(allocated),0) INTO receipt_sum FROM payment_allocation
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND receipt_id=NEW.receipt_id;
 SELECT coalesce(sum(allocated),0) INTO sale_sum FROM payment_allocation
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND sale_ledger_id=NEW.sale_ledger_id;
 IF receipt_order IS NULL OR sale_order IS NULL OR receipt_order<>sale_order
  OR receipt_sum>receipt_amount OR sale_sum>sale_amount THEN
  RAISE EXCEPTION 'Payment allocation not reconcilable to same order'; END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER t5a_allocation_guard AFTER INSERT ON payment_allocation
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION erp_t5a_allocation_guard();

-- Database-level integrity: a posted MANUAL fulfillment MUST reconcile to
-- every canonical sale line, physical issue, return and exactly one SALE debit.
-- Deferred checks work for a single atomic transaction without transient gaps.
CREATE FUNCTION erp_t5a_manual_fulfillment_commit_guard() RETURNS trigger
 LANGUAGE plpgsql AS $$
DECLARE ctx record; l record; issue_qty numeric;return_qty numeric;
 expected_amount numeric;posted_amount numeric;line_count integer;
 posted_count integer;real_qty numeric:=0;total_issued numeric:=0;total_amount numeric:=0;
BEGIN
 IF NEW.mode<>'MANUAL' THEN RETURN NULL; END IF;
 SELECT o.status,v.delivery_choice,v.warehouse_id INTO ctx
 FROM sales_order o JOIN sales_order_version_context v
 ON v.installation_id=o.installation_id AND v.branch_id=o.branch_id
 AND v.order_id=o.id AND v.version_no=NEW.version_no
 WHERE o.installation_id=NEW.installation_id AND o.branch_id=NEW.branch_id
 AND o.id=NEW.order_id;
 IF ctx IS NULL OR ctx.status<>'CONFIRMED' OR ctx.delivery_choice<>'MANUAL'
 OR ctx.warehouse_id<>NEW.warehouse_id THEN
 RAISE EXCEPTION 'Manual fulfillment must match confirmed delivery context'; END IF;
 SELECT count(*) INTO line_count FROM sales_order_line
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
 AND order_id=NEW.order_id AND version_no=NEW.version_no;
 SELECT count(*) INTO posted_count FROM sales_manual_delivery_line
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
 AND fulfillment_id=NEW.id;
 IF line_count<1 OR posted_count<>line_count THEN
 RAISE EXCEPTION 'Manual fulfillment requires all actual delivery lines'; END IF;
 FOR l IN SELECT d.order_line_no,d.product_id,d.ordered_base,d.issued_base,
       d.returned_base,d.delivered_base,d.amount,s.line_total,
       s.pricing_engine,s.price_snapshot,s.quantity,s.unit_code,p.base_unit
 FROM sales_manual_delivery_line d
 JOIN sales_order_line s ON s.installation_id=d.installation_id
  AND s.branch_id=d.branch_id AND s.order_id=NEW.order_id
  AND s.version_no=NEW.version_no AND s.line_no=d.order_line_no
 JOIN catalog_product p ON p.installation_id=s.installation_id
  AND p.branch_id=s.branch_id AND p.id=s.product_id
 WHERE d.installation_id=NEW.installation_id AND d.branch_id=NEW.branch_id
  AND d.fulfillment_id=NEW.id
 LOOP
  IF l.product_id IS DISTINCT FROM (
    SELECT product_id FROM sales_order_line WHERE installation_id=NEW.installation_id
    AND branch_id=NEW.branch_id AND order_id=NEW.order_id
    AND version_no=NEW.version_no AND line_no=l.order_line_no)
   OR l.ordered_base IS DISTINCT FROM (
    CASE WHEN l.pricing_engine='R1' THEN
      nullif(l.price_snapshot->>'normalizedBaseQuantity','')::numeric
      WHEN l.unit_code=l.base_unit THEN l.quantity
      ELSE NULL END)
  THEN RAISE EXCEPTION 'Manual delivery line violates confirmed SKU or base quantity'; END IF;
  SELECT coalesce(sum(k.quantity_base),0) INTO issue_qty
  FROM sales_direct_issue h JOIN sales_direct_issue_line k ON
   k.installation_id=h.installation_id AND k.branch_id=h.branch_id
   AND k.issue_id=h.id
  WHERE h.installation_id=NEW.installation_id AND h.branch_id=NEW.branch_id
   AND h.order_id=NEW.order_id AND h.version_no=NEW.version_no
   AND h.warehouse_id=NEW.warehouse_id AND k.order_line_no=l.order_line_no;
  SELECT coalesce(sum(k.quantity_base),0) INTO return_qty
  FROM sales_manual_return h JOIN sales_manual_return_line k ON
   k.installation_id=h.installation_id AND k.branch_id=h.branch_id
   AND k.return_id=h.id
  WHERE h.installation_id=NEW.installation_id AND h.branch_id=NEW.branch_id
   AND h.order_id=NEW.order_id AND h.version_no=NEW.version_no
   AND h.warehouse_id=NEW.warehouse_id AND k.order_line_no=l.order_line_no;
  IF l.issued_base<>issue_qty OR l.returned_base<>return_qty OR
   l.delivered_base<>issue_qty-return_qty OR issue_qty<return_qty THEN
   RAISE EXCEPTION 'Manual delivery line does not reconcile physical stock'; END IF;
  expected_amount:=round(l.line_total*l.delivered_base/l.ordered_base,0);
  IF l.amount<>expected_amount THEN
   RAISE EXCEPTION 'Manual delivered amount differs from confirmed price'; END IF;
  total_amount:=total_amount+l.amount;
  real_qty:=real_qty+l.delivered_base;
  total_issued:=total_issued+l.issued_base;
 END LOOP;
 IF real_qty<=0 AND total_issued<=0 THEN
  RAISE EXCEPTION 'Manual fulfillment requires issued/returned stock history'; END IF;
 SELECT coalesce(sum(amount),0),count(*) INTO posted_amount,posted_count
 FROM customer_receivable_ledger
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
 AND order_id=NEW.order_id AND kind='SALE' AND source_id=NEW.id;
 IF (total_amount>0 AND (posted_amount<>total_amount OR posted_count<>1)) OR
   (total_amount=0 AND posted_count<>0) THEN
   RAISE EXCEPTION 'Manual fulfillment must match exactly one AR debit'; END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER t5a_fulfillment_commit_guard
 AFTER INSERT ON sales_fulfillment DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION erp_t5a_manual_fulfillment_commit_guard();

CREATE FUNCTION erp_t5a_receipt_commit_guard() RETURNS trigger
 LANGUAGE plpgsql AS $$
DECLARE matching_order uuid;payment_count integer;payment_amount numeric;
 allocated_amount numeric;
BEGIN
 IF NEW.fulfillment_id IS NULL THEN RETURN NULL; END IF;
 SELECT order_id INTO matching_order FROM sales_fulfillment WHERE
 installation_id=NEW.installation_id AND branch_id=NEW.branch_id
 AND id=NEW.fulfillment_id AND mode='MANUAL';
 IF matching_order IS NULL OR matching_order<>NEW.order_id THEN
  RAISE EXCEPTION 'MANUAL payment receipt must match fulfilled order'; END IF;
 SELECT coalesce(sum(allocated),0) INTO allocated_amount
 FROM payment_allocation WHERE installation_id=NEW.installation_id
 AND branch_id=NEW.branch_id AND receipt_id=NEW.id;
 SELECT count(*),coalesce(-sum(amount),0) INTO payment_count,payment_amount
 FROM customer_receivable_ledger WHERE installation_id=NEW.installation_id
 AND branch_id=NEW.branch_id AND order_id=NEW.order_id
 AND kind='PAYMENT' AND source_id=NEW.id;
 IF allocated_amount<>NEW.amount OR payment_count<>1 OR
  payment_amount<>NEW.amount THEN
  RAISE EXCEPTION 'MANUAL receipt must match one posted payment and allocation'; END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER t5a_receipt_commit_guard
 AFTER INSERT ON payment_receipt DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION erp_t5a_receipt_commit_guard();

-- Reject empty return headers and orphan bookkeeping even when callers bypass
-- the HTTP mutation endpoint.
CREATE FUNCTION erp_t5a_return_header_commit_guard() RETURNS trigger
 LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM sales_manual_return_line l WHERE
   l.installation_id=NEW.installation_id AND l.branch_id=NEW.branch_id
   AND l.return_id=NEW.id)
 THEN RAISE EXCEPTION 'Posted manual return requires at least one line'; END IF;
 RETURN NULL;
END; $$;
CREATE CONSTRAINT TRIGGER t5a_return_header_commit_guard
 AFTER INSERT ON sales_manual_return DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION erp_t5a_return_header_commit_guard();
