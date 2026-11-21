-- R3.2 purchase order / multi-batch receipt. Independent installation and branch scope.
-- Only server ACK means a receipt posted; no client writes inventory ledger.
CREATE TABLE purchase_order_sequence (
 installation_id uuid NOT NULL, branch_id uuid NOT NULL, next_no bigint NOT NULL DEFAULT 1 CHECK(next_no>0),
 PRIMARY KEY(installation_id,branch_id),
 FOREIGN KEY(installation_id,branch_id) REFERENCES branch(installation_id,id)
);
CREATE TABLE purchase_order (
 installation_id uuid NOT NULL, branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 supplier_id uuid NOT NULL, warehouse_id uuid NOT NULL,
 status text NOT NULL DEFAULT 'DRAFT'
   CHECK(status IN ('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED','CANCELLED')),
 document_no text, revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 note text NOT NULL DEFAULT '' CHECK(length(note)<=500),
 created_by uuid NOT NULL, confirmed_by uuid, request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 created_at timestamptz NOT NULL DEFAULT now(), confirmed_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,document_no),
 FOREIGN KEY(installation_id,branch_id,supplier_id)
   REFERENCES catalog_supplier(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
   REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,created_by) REFERENCES app_user(installation_id,id),
 FOREIGN KEY(installation_id,confirmed_by) REFERENCES app_user(installation_id,id),
 CHECK ((status='DRAFT' AND document_no IS NULL AND confirmed_at IS NULL AND confirmed_by IS NULL)
   OR (status='CANCELLED' AND (document_no IS NULL OR confirmed_at IS NOT NULL))
   OR (status IN ('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
       AND document_no IS NOT NULL AND confirmed_at IS NOT NULL AND confirmed_by IS NOT NULL))
);
CREATE INDEX purchase_order_supplier_idx ON purchase_order(installation_id,branch_id,supplier_id,created_at DESC);
CREATE TABLE purchase_order_line (
 installation_id uuid NOT NULL, branch_id uuid NOT NULL,
 order_id uuid NOT NULL, line_no integer NOT NULL CHECK(line_no BETWEEN 1 AND 10000),
 product_id uuid NOT NULL,
 quantity_base numeric(24,6) NOT NULL CHECK(quantity_base>0 AND quantity_base <> 'NaN'::numeric),
 unit_cost numeric(18,4) NOT NULL CHECK(unit_cost>=0 AND unit_cost <> 'NaN'::numeric),
 PRIMARY KEY(installation_id,branch_id,order_id,line_no),
 FOREIGN KEY(installation_id,branch_id,order_id)
   REFERENCES purchase_order(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id)
   REFERENCES catalog_product(installation_id,branch_id,id)
);
CREATE TABLE purchase_receipt (
 installation_id uuid NOT NULL, branch_id uuid NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL, warehouse_id uuid NOT NULL,
 status text NOT NULL DEFAULT 'POSTED' CHECK(status='POSTED'),
 request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 posted_by uuid NOT NULL, posted_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,order_id)
   REFERENCES purchase_order(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
   REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,posted_by) REFERENCES app_user(installation_id,id)
);
CREATE INDEX purchase_receipt_order_idx ON purchase_receipt(installation_id,branch_id,order_id,posted_at);
CREATE TABLE purchase_receipt_line (
 installation_id uuid NOT NULL, branch_id uuid NOT NULL,
 receipt_id uuid NOT NULL, line_no integer NOT NULL CHECK(line_no BETWEEN 1 AND 10000),
 order_id uuid NOT NULL, order_line_no integer NOT NULL,
 product_id uuid NOT NULL,
 quantity_base numeric(24,6) NOT NULL CHECK(quantity_base>0 AND quantity_base <> 'NaN'::numeric),
 unit_cost numeric(18,4) NOT NULL CHECK(unit_cost>=0 AND unit_cost <> 'NaN'::numeric),
 inventory_ledger_id uuid NOT NULL, warehouse_id uuid NOT NULL,
 PRIMARY KEY(installation_id,branch_id,receipt_id,line_no),
 UNIQUE(installation_id,branch_id,warehouse_id,inventory_ledger_id),
 FOREIGN KEY(installation_id,branch_id,receipt_id)
   REFERENCES purchase_receipt(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,order_id,order_line_no)
   REFERENCES purchase_order_line(installation_id,branch_id,order_id,line_no),
 FOREIGN KEY(installation_id,branch_id,warehouse_id,inventory_ledger_id)
   REFERENCES inventory_ledger(installation_id,branch_id,warehouse_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id)
   REFERENCES catalog_product(installation_id,branch_id,id)
);
CREATE INDEX purchase_receipt_line_po_idx
 ON purchase_receipt_line(installation_id,branch_id,order_id,order_line_no);

-- Purchase lines and posted receipts are immutable. Corrections require new, referenced documents.
CREATE FUNCTION erp_purchase_fact_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION 'Posted purchase documents are immutable';
END; $$;
CREATE TRIGGER purchase_order_line_immutable BEFORE UPDATE OR DELETE ON purchase_order_line
 FOR EACH ROW EXECUTE FUNCTION erp_purchase_fact_immutable();
CREATE TRIGGER purchase_receipt_immutable BEFORE UPDATE OR DELETE ON purchase_receipt
 FOR EACH ROW EXECUTE FUNCTION erp_purchase_fact_immutable();
CREATE TRIGGER purchase_receipt_line_immutable BEFORE UPDATE OR DELETE ON purchase_receipt_line
 FOR EACH ROW EXECUTE FUNCTION erp_purchase_fact_immutable();

-- Guard even direct SQL inserts: one purchase line must not be over-received and
-- must have matching, immutable inventory credit from this receipt.
CREATE FUNCTION erp_purchase_receipt_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
 ordered numeric;
 unit_price numeric;
 accepted numeric;
 source_order uuid;
 source_warehouse uuid;
 order_status text;
 ledger_product uuid;
 ledger_delta numeric;
 ledger_source text;
 ledger_receipt uuid;
 ledger_line integer;
BEGIN
 SELECT o.status,o.warehouse_id,l.quantity_base,l.unit_cost
  INTO order_status,source_warehouse,ordered,unit_price
  FROM purchase_order o
  JOIN purchase_order_line l ON l.installation_id=o.installation_id
   AND l.branch_id=o.branch_id AND l.order_id=o.id
   AND l.line_no=NEW.order_line_no AND l.product_id=NEW.product_id
  WHERE o.installation_id=NEW.installation_id AND o.branch_id=NEW.branch_id
   AND o.id=NEW.order_id FOR UPDATE OF o;
 IF order_status NOT IN ('CONFIRMED','PARTIALLY_RECEIVED') OR
    source_warehouse IS DISTINCT FROM NEW.warehouse_id OR
    ordered IS NULL OR unit_price IS DISTINCT FROM NEW.unit_cost THEN
   RAISE EXCEPTION 'Purchase line, status or warehouse does not match confirmed order';
 END IF;
 SELECT r.order_id INTO source_order FROM purchase_receipt r
  WHERE r.installation_id=NEW.installation_id AND r.branch_id=NEW.branch_id
   AND r.id=NEW.receipt_id AND r.warehouse_id=NEW.warehouse_id;
 IF source_order IS DISTINCT FROM NEW.order_id THEN
   RAISE EXCEPTION 'Receipt and purchase order mismatch';
 END IF;
 SELECT product_id,delta_base,source_type,source_id,source_line
  INTO ledger_product,ledger_delta,ledger_source,ledger_receipt,ledger_line
  FROM inventory_ledger WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND warehouse_id=NEW.warehouse_id AND id=NEW.inventory_ledger_id FOR SHARE;
 IF ledger_product IS DISTINCT FROM NEW.product_id OR
   ledger_delta IS DISTINCT FROM NEW.quantity_base OR
   ledger_source IS DISTINCT FROM 'PURCHASE_RECEIPT' OR
   ledger_receipt IS DISTINCT FROM NEW.receipt_id OR
   ledger_line IS DISTINCT FROM NEW.line_no THEN
   RAISE EXCEPTION 'Receipt line is not matched by one posted inventory ledger movement';
 END IF;
 SELECT COALESCE(sum(quantity_base),0) INTO accepted FROM purchase_receipt_line
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND order_id=NEW.order_id AND order_line_no=NEW.order_line_no;
 IF accepted+NEW.quantity_base>ordered THEN
   RAISE EXCEPTION 'Purchase receipt exceeds ordered quantity';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER purchase_receipt_line_guard BEFORE INSERT ON purchase_receipt_line
 FOR EACH ROW EXECUTE FUNCTION erp_purchase_receipt_line_guard();

-- Only legal lifecycle transitions can alter a PO; identity and supplier are immutable.
CREATE FUNCTION erp_purchase_order_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Purchase order cannot be deleted'; END IF;
 IF (NEW.installation_id,NEW.branch_id,NEW.id,NEW.supplier_id,NEW.warehouse_id,
    NEW.note,NEW.created_by,NEW.request_id,NEW.created_at) IS DISTINCT FROM
    (OLD.installation_id,OLD.branch_id,OLD.id,OLD.supplier_id,OLD.warehouse_id,
    OLD.note,OLD.created_by,OLD.request_id,OLD.created_at)
    OR NEW.revision<>OLD.revision+1
    OR (OLD.status='DRAFT' AND NEW.status NOT IN ('CONFIRMED','CANCELLED'))
    OR (OLD.status='CONFIRMED' AND NEW.status NOT IN ('PARTIALLY_RECEIVED','RECEIVED','CANCELLED'))
    OR (OLD.status='PARTIALLY_RECEIVED' AND NEW.status NOT IN ('PARTIALLY_RECEIVED','RECEIVED'))
    OR OLD.status IN ('RECEIVED','CANCELLED')
    OR (OLD.status<>'DRAFT' AND (NEW.document_no IS DISTINCT FROM OLD.document_no
        OR NEW.confirmed_at IS DISTINCT FROM OLD.confirmed_at
        OR NEW.confirmed_by IS DISTINCT FROM OLD.confirmed_by))
 THEN RAISE EXCEPTION 'Purchase lifecycle mutation invalid'; END IF;
 IF NEW.status='CANCELLED' AND EXISTS(SELECT 1 FROM purchase_receipt
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND order_id=NEW.id) THEN
   RAISE EXCEPTION 'Cannot cancel received purchase order';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER purchase_order_guard BEFORE UPDATE OR DELETE ON purchase_order
 FOR EACH ROW EXECUTE FUNCTION erp_purchase_order_guard();

-- Existing owner role requires explicit, scoped permissions; bootstrap reads new allowlist.
INSERT INTO role_permission(installation_id,role_id,permission_code)
 SELECT installation_id,id,permission FROM app_role
 CROSS JOIN (VALUES ('purchase.read'),('purchase.create'),
   ('purchase.confirm'),('purchase.receive')) AS p(permission)
 WHERE code='PRIMARY_OWNER_MAIN' ON CONFLICT DO NOTHING;
