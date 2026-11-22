-- R3.3 transfer with separate dispatch and partial receiving.
-- Source stock is posted OUT only after approval/dispatch. Destination stock posts
-- IN only on a specific accepted receipt. Remaining quantity is in transit.
CREATE TABLE inventory_transfer (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 source_warehouse_id uuid NOT NULL,destination_warehouse_id uuid NOT NULL,
 status text NOT NULL DEFAULT 'CREATED'
  CHECK(status IN ('CREATED','APPROVED','IN_TRANSIT','PARTIALLY_RECEIVED','RECEIVED','CANCELLED')),
 revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 note text NOT NULL DEFAULT '' CHECK(length(note)<=500),
 created_by uuid NOT NULL,approved_by uuid,dispatched_by uuid,
 request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 created_at timestamptz NOT NULL DEFAULT now(),approved_at timestamptz,
 dispatched_at timestamptz,updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,source_warehouse_id)
   REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,destination_warehouse_id)
   REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,created_by) REFERENCES app_user(installation_id,id),
 FOREIGN KEY(installation_id,approved_by) REFERENCES app_user(installation_id,id),
 FOREIGN KEY(installation_id,dispatched_by) REFERENCES app_user(installation_id,id),
 CHECK(source_warehouse_id<>destination_warehouse_id),
 CHECK ((status='CREATED' AND approved_by IS NULL AND dispatched_by IS NULL)
     OR (status='CANCELLED' AND dispatched_by IS NULL)
     OR (status IN ('APPROVED','IN_TRANSIT','PARTIALLY_RECEIVED','RECEIVED')
         AND approved_by IS NOT NULL AND approved_at IS NOT NULL)),
 CHECK (status NOT IN ('IN_TRANSIT','PARTIALLY_RECEIVED','RECEIVED')
     OR (dispatched_by IS NOT NULL AND dispatched_at IS NOT NULL)),
 CHECK (status NOT IN ('CREATED','APPROVED','CANCELLED')
     OR (dispatched_by IS NULL AND dispatched_at IS NULL))
);
CREATE INDEX inventory_transfer_source_idx ON inventory_transfer
 (installation_id,branch_id,source_warehouse_id,created_at DESC);
CREATE INDEX inventory_transfer_dest_idx ON inventory_transfer
 (installation_id,branch_id,destination_warehouse_id,created_at DESC);
CREATE TABLE inventory_transfer_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,transfer_id uuid NOT NULL,
 line_no integer NOT NULL CHECK(line_no BETWEEN 1 AND 10000),
 product_id uuid NOT NULL,
 quantity_base numeric(24,6) NOT NULL CHECK(quantity_base>0 AND quantity_base<>'NaN'::numeric),
 PRIMARY KEY(installation_id,branch_id,transfer_id,line_no),
 UNIQUE(installation_id,branch_id,transfer_id,product_id),
 FOREIGN KEY(installation_id,branch_id,transfer_id)
   REFERENCES inventory_transfer(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id)
   REFERENCES catalog_product(installation_id,branch_id,id)
);
CREATE TABLE inventory_transfer_receipt (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),transfer_id uuid NOT NULL,
 destination_warehouse_id uuid NOT NULL,posted_by uuid NOT NULL,
 request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 posted_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,transfer_id)
   REFERENCES inventory_transfer(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,destination_warehouse_id)
   REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,posted_by)
   REFERENCES app_user(installation_id,id)
);
CREATE INDEX inventory_transfer_receipt_transfer_idx ON inventory_transfer_receipt
 (installation_id,branch_id,transfer_id,posted_at);
CREATE TABLE inventory_transfer_receipt_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 receipt_id uuid NOT NULL,line_no integer NOT NULL CHECK(line_no BETWEEN 1 AND 10000),
 transfer_id uuid NOT NULL,transfer_line_no integer NOT NULL,
 product_id uuid NOT NULL,destination_warehouse_id uuid NOT NULL,
 quantity_base numeric(24,6) NOT NULL CHECK(quantity_base>0 AND quantity_base<>'NaN'::numeric),
 ledger_id uuid NOT NULL,
 PRIMARY KEY(installation_id,branch_id,receipt_id,line_no),
 UNIQUE(installation_id,branch_id,destination_warehouse_id,ledger_id),
 FOREIGN KEY(installation_id,branch_id,receipt_id)
   REFERENCES inventory_transfer_receipt(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,transfer_id,transfer_line_no)
   REFERENCES inventory_transfer_line(installation_id,branch_id,transfer_id,line_no),
 FOREIGN KEY(installation_id,branch_id,destination_warehouse_id,ledger_id)
   REFERENCES inventory_ledger(installation_id,branch_id,warehouse_id,id)
);

CREATE FUNCTION erp_transfer_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE state_now text;
BEGIN
 IF TG_OP IN ('UPDATE','DELETE') THEN
   RAISE EXCEPTION 'Transfer line is immutable';
 END IF;
 SELECT status INTO state_now FROM inventory_transfer
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
     AND id=NEW.transfer_id FOR UPDATE;
 IF state_now IS DISTINCT FROM 'CREATED' THEN
   RAISE EXCEPTION 'Transfer lines require an unapproved document';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER inventory_transfer_line_guard BEFORE INSERT OR UPDATE OR DELETE
 ON inventory_transfer_line FOR EACH ROW EXECUTE FUNCTION erp_transfer_line_guard();

CREATE FUNCTION erp_transfer_header_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='INSERT' THEN
   IF NEW.status IS DISTINCT FROM 'CREATED' OR NEW.revision<>0
      OR NEW.approved_by IS NOT NULL OR NEW.approved_at IS NOT NULL
      OR NEW.dispatched_by IS NOT NULL OR NEW.dispatched_at IS NOT NULL THEN
     RAISE EXCEPTION 'Transfer must begin in CREATED without posting facts';
   END IF;
   RETURN NEW;
 END IF;
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Transfer document cannot be deleted'; END IF;
 IF (NEW.installation_id,NEW.branch_id,NEW.id,NEW.source_warehouse_id,
     NEW.destination_warehouse_id,NEW.note,NEW.created_by,NEW.request_id,NEW.created_at)
    IS DISTINCT FROM
    (OLD.installation_id,OLD.branch_id,OLD.id,OLD.source_warehouse_id,
     OLD.destination_warehouse_id,OLD.note,OLD.created_by,OLD.request_id,OLD.created_at)
   OR NEW.revision<>OLD.revision+1
   OR (OLD.status='CREATED' AND NEW.status NOT IN ('APPROVED','CANCELLED'))
   OR (OLD.status='CREATED' AND NEW.status='CANCELLED'
       AND (NEW.approved_by IS NOT NULL OR NEW.approved_at IS NOT NULL))
   OR (OLD.status='APPROVED' AND NEW.status NOT IN ('IN_TRANSIT','CANCELLED'))
   OR (OLD.status='IN_TRANSIT' AND NEW.status NOT IN ('PARTIALLY_RECEIVED','RECEIVED'))
   OR (OLD.status='PARTIALLY_RECEIVED'
       AND NEW.status NOT IN ('PARTIALLY_RECEIVED','RECEIVED'))
   OR OLD.status IN ('RECEIVED','CANCELLED')
   OR (OLD.status='CREATED' AND
       (NEW.dispatched_by IS NOT NULL OR NEW.dispatched_at IS NOT NULL))
   OR (OLD.status<>'CREATED'
       AND (NEW.approved_by IS DISTINCT FROM OLD.approved_by
        OR NEW.approved_at IS DISTINCT FROM OLD.approved_at))
   OR (OLD.status NOT IN ('CREATED','APPROVED')
       AND (NEW.dispatched_by IS DISTINCT FROM OLD.dispatched_by
        OR NEW.dispatched_at IS DISTINCT FROM OLD.dispatched_at))
 THEN RAISE EXCEPTION 'Transfer lifecycle mutation invalid'; END IF;
 -- PostgreSQL must never accept an IN_TRANSIT header without a positive line set.
 IF OLD.status='APPROVED' AND NEW.status='IN_TRANSIT' AND NOT EXISTS(
   SELECT 1 FROM inventory_transfer_line l
    WHERE l.installation_id=OLD.installation_id AND l.branch_id=OLD.branch_id
      AND l.transfer_id=OLD.id
 ) THEN RAISE EXCEPTION 'Transfer dispatch requires at least one line'; END IF;
 -- And every line must have an exact posted source issue.
 IF OLD.status='APPROVED' AND NEW.status='IN_TRANSIT' AND EXISTS(
   SELECT 1 FROM inventory_transfer_line l WHERE
     l.installation_id=OLD.installation_id AND l.branch_id=OLD.branch_id
      AND l.transfer_id=OLD.id AND NOT EXISTS(
       SELECT 1 FROM inventory_ledger x WHERE x.installation_id=l.installation_id
        AND x.branch_id=l.branch_id AND x.warehouse_id=OLD.source_warehouse_id
        AND x.source_type='TRANSFER' AND x.source_id=OLD.id AND x.source_line=l.line_no
        AND x.kind='TRANSFER_OUT'
      )
 ) THEN
   RAISE EXCEPTION 'Transfer dispatch requires one source issue per line';
 END IF;
 IF NEW.status IN ('PARTIALLY_RECEIVED','RECEIVED') THEN
   IF NOT EXISTS(SELECT 1 FROM inventory_transfer_receipt_line r
     WHERE r.installation_id=OLD.installation_id AND r.branch_id=OLD.branch_id
       AND r.transfer_id=OLD.id) THEN
     RAISE EXCEPTION 'Transfer cannot receive without posted receipt lines';
   END IF;
   IF NEW.status='RECEIVED' AND EXISTS(
     SELECT 1 FROM inventory_transfer_line l WHERE l.installation_id=OLD.installation_id
       AND l.branch_id=OLD.branch_id AND l.transfer_id=OLD.id AND
       COALESCE((SELECT sum(r.quantity_base) FROM inventory_transfer_receipt_line r
         WHERE r.installation_id=l.installation_id AND r.branch_id=l.branch_id
          AND r.transfer_id=l.transfer_id AND r.transfer_line_no=l.line_no),0)<l.quantity_base
   ) THEN
      RAISE EXCEPTION 'Transfer complete status requires all received quantities';
   END IF;
   IF NEW.status='PARTIALLY_RECEIVED' AND NOT EXISTS(
     SELECT 1 FROM inventory_transfer_line l WHERE l.installation_id=OLD.installation_id
       AND l.branch_id=OLD.branch_id AND l.transfer_id=OLD.id AND
       COALESCE((SELECT sum(r.quantity_base) FROM inventory_transfer_receipt_line r
         WHERE r.installation_id=l.installation_id AND r.branch_id=l.branch_id
          AND r.transfer_id=l.transfer_id AND r.transfer_line_no=l.line_no),0)<l.quantity_base
   ) THEN
      RAISE EXCEPTION 'Transfer partial status requires outstanding quantity';
   END IF;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER inventory_transfer_header_guard BEFORE INSERT OR UPDATE OR DELETE
 ON inventory_transfer FOR EACH ROW EXECUTE FUNCTION erp_transfer_header_guard();

CREATE FUNCTION erp_transfer_receipt_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Posted transfer receipt is immutable'; END; $$;
CREATE TRIGGER inventory_transfer_receipt_immutable BEFORE UPDATE OR DELETE
 ON inventory_transfer_receipt FOR EACH ROW EXECUTE FUNCTION erp_transfer_receipt_immutable();
CREATE TRIGGER inventory_transfer_receipt_line_immutable BEFORE UPDATE OR DELETE
 ON inventory_transfer_receipt_line FOR EACH ROW EXECUTE FUNCTION erp_transfer_receipt_immutable();

-- Guard both inventory fact origins and in-transit line consumption at DB boundary.
CREATE FUNCTION erp_transfer_ledger_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
 source_wh uuid;
 dest_wh uuid;
 transfer_state text;
 transfer_sku uuid;
 transfer_qty numeric;
 receipt_transfer uuid;
BEGIN
 IF NEW.kind='TRANSFER_OUT' THEN
   SELECT t.source_warehouse_id,t.status,l.product_id,l.quantity_base
     INTO source_wh,transfer_state,transfer_sku,transfer_qty
   FROM inventory_transfer t JOIN inventory_transfer_line l
     ON l.installation_id=t.installation_id AND l.branch_id=t.branch_id
     AND l.transfer_id=t.id AND l.line_no=NEW.source_line
   WHERE t.installation_id=NEW.installation_id AND t.branch_id=NEW.branch_id
     AND t.id=NEW.source_id;
   IF source_wh IS DISTINCT FROM NEW.warehouse_id OR transfer_state<>'APPROVED'
      OR transfer_sku IS DISTINCT FROM NEW.product_id
      OR NEW.delta_base IS DISTINCT FROM -transfer_qty THEN
     RAISE EXCEPTION 'Transfer dispatch must match approved source order line';
   END IF;
 ELSIF NEW.kind='TRANSFER_IN' THEN
   SELECT r.transfer_id,t.destination_warehouse_id,t.status
     INTO receipt_transfer,dest_wh,transfer_state
   FROM inventory_transfer_receipt r JOIN inventory_transfer t
     ON t.installation_id=r.installation_id AND t.branch_id=r.branch_id
     AND t.id=r.transfer_id
   WHERE r.installation_id=NEW.installation_id AND r.branch_id=NEW.branch_id
     AND r.id=NEW.source_id;
   IF receipt_transfer IS NULL OR dest_wh IS DISTINCT FROM NEW.warehouse_id
      OR transfer_state NOT IN ('IN_TRANSIT','PARTIALLY_RECEIVED') THEN
     RAISE EXCEPTION 'Transfer receipt movement must match in-transit destination';
   END IF;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER inventory_transfer_ledger_guard BEFORE INSERT ON inventory_ledger
 FOR EACH ROW WHEN (NEW.kind IN ('TRANSFER_IN','TRANSFER_OUT'))
 EXECUTE FUNCTION erp_transfer_ledger_guard();

CREATE FUNCTION erp_transfer_receipt_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
 ordered numeric;
 accepted numeric;
 ordered_product uuid;
 correct_transfer uuid;
 correct_wh uuid;
 transfer_status text;
 actual_product uuid;
 actual_delta numeric;
 actual_type text;
 actual_kind text;
 actual_source uuid;
 actual_line integer;
BEGIN
 SELECT r.transfer_id,r.destination_warehouse_id,t.status
   INTO correct_transfer,correct_wh,transfer_status
 FROM inventory_transfer_receipt r JOIN inventory_transfer t
   ON t.installation_id=r.installation_id AND t.branch_id=r.branch_id
    AND t.id=r.transfer_id
 WHERE r.installation_id=NEW.installation_id AND r.branch_id=NEW.branch_id
   AND r.id=NEW.receipt_id FOR UPDATE OF t;
 IF correct_transfer IS DISTINCT FROM NEW.transfer_id
   OR correct_wh IS DISTINCT FROM NEW.destination_warehouse_id
   OR transfer_status NOT IN ('IN_TRANSIT','PARTIALLY_RECEIVED') THEN
   RAISE EXCEPTION 'Transfer receipt header does not match in-transit transfer';
 END IF;
 SELECT quantity_base,product_id INTO ordered,ordered_product
 FROM inventory_transfer_line WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND transfer_id=NEW.transfer_id
  AND line_no=NEW.transfer_line_no FOR SHARE;
 IF ordered IS NULL OR ordered_product IS DISTINCT FROM NEW.product_id THEN
   RAISE EXCEPTION 'Transfer receipt product must match dispatched order line';
 END IF;
 SELECT kind,source_type,source_id,source_line,product_id,delta_base
 INTO actual_kind,actual_type,actual_source,actual_line,actual_product,actual_delta
 FROM inventory_ledger WHERE installation_id=NEW.installation_id
  AND branch_id=NEW.branch_id AND warehouse_id=NEW.destination_warehouse_id
  AND id=NEW.ledger_id FOR SHARE;
 IF actual_kind IS DISTINCT FROM 'TRANSFER_IN' OR actual_type IS DISTINCT FROM 'TRANSFER'
   OR actual_source IS DISTINCT FROM NEW.receipt_id
   OR actual_line IS DISTINCT FROM NEW.line_no
   OR actual_product IS DISTINCT FROM NEW.product_id
   OR actual_delta IS DISTINCT FROM NEW.quantity_base THEN
   RAISE EXCEPTION 'Transfer received quantity has no matching inventory movement';
 END IF;
 SELECT COALESCE(sum(quantity_base),0) INTO accepted
 FROM inventory_transfer_receipt_line
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
  AND transfer_id=NEW.transfer_id AND transfer_line_no=NEW.transfer_line_no;
 IF accepted+NEW.quantity_base>ordered THEN
   RAISE EXCEPTION 'Transfer accepted quantity exceeds dispatched quantity';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER inventory_transfer_receipt_line_guard BEFORE INSERT
 ON inventory_transfer_receipt_line FOR EACH ROW
 EXECUTE FUNCTION erp_transfer_receipt_line_guard();

-- Every destination stock credit must have a matching accepted receipt line
-- at COMMIT, not merely a matching header. Prevent forged orphan TRANSFER_IN facts.
-- Dispatch and stock deduction are one atomic business transition.
CREATE FUNCTION erp_transfer_out_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $transfer_out_guard$
DECLARE committed_state text;
BEGIN
 SELECT status INTO committed_state FROM inventory_transfer
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND id=NEW.source_id;
 IF committed_state IS DISTINCT FROM 'IN_TRANSIT'
   AND committed_state IS DISTINCT FROM 'PARTIALLY_RECEIVED'
   AND committed_state IS DISTINCT FROM 'RECEIVED' THEN
   RAISE EXCEPTION 'Transfer source movement requires dispatch transition at commit';
 END IF;
 RETURN NULL;
END; $transfer_out_guard$;
CREATE CONSTRAINT TRIGGER inventory_transfer_out_commit_guard
 AFTER INSERT ON inventory_ledger
 DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW WHEN (NEW.kind='TRANSFER_OUT')
 EXECUTE FUNCTION erp_transfer_out_commit_guard();

CREATE FUNCTION erp_transfer_in_commit_guard() RETURNS trigger LANGUAGE plpgsql AS $
DECLARE transfer_id_now uuid;
 committed_state text;
 still_outstanding boolean;
BEGIN
 IF NOT EXISTS(
   SELECT 1 FROM inventory_transfer_receipt_line r
    WHERE r.installation_id=NEW.installation_id AND r.branch_id=NEW.branch_id
      AND r.destination_warehouse_id=NEW.warehouse_id AND r.ledger_id=NEW.id
      AND r.receipt_id=NEW.source_id AND r.line_no=NEW.source_line
      AND r.product_id=NEW.product_id AND r.quantity_base=NEW.delta_base
 ) THEN
   RAISE EXCEPTION 'Transfer destination movement has no accepted receipt line';
 END IF;
 -- A receipt ledger credit is not valid until the transfer header reflects
 -- the full accepted quantity or a genuine partial receipt in this transaction.
 SELECT r.transfer_id,t.status INTO transfer_id_now,committed_state
 FROM inventory_transfer_receipt r JOIN inventory_transfer t
   ON t.installation_id=r.installation_id AND t.branch_id=r.branch_id
     AND t.id=r.transfer_id
 WHERE r.installation_id=NEW.installation_id AND r.branch_id=NEW.branch_id
   AND r.id=NEW.source_id;
 IF transfer_id_now IS NULL OR committed_state NOT IN ('PARTIALLY_RECEIVED','RECEIVED') THEN
   RAISE EXCEPTION 'Transfer destination movement requires receipt status transition at commit';
 END IF;
 SELECT EXISTS(
    SELECT 1 FROM inventory_transfer_line l
    WHERE l.installation_id=NEW.installation_id AND l.branch_id=NEW.branch_id
      AND l.transfer_id=transfer_id_now
      AND l.quantity_base>COALESCE((SELECT sum(r.quantity_base)
        FROM inventory_transfer_receipt_line r
        WHERE r.installation_id=l.installation_id AND r.branch_id=l.branch_id
          AND r.transfer_id=l.transfer_id AND r.transfer_line_no=l.line_no),0)
 ) INTO still_outstanding;
 IF (committed_state='RECEIVED' AND still_outstanding)
   OR (committed_state='PARTIALLY_RECEIVED' AND NOT still_outstanding) THEN
   RAISE EXCEPTION 'Transfer destination movement requires matching received status at commit';
 END IF;
 RETURN NULL;
END; $;
CREATE CONSTRAINT TRIGGER inventory_transfer_in_commit_guard
 AFTER INSERT ON inventory_ledger
 DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW WHEN (NEW.kind='TRANSFER_IN')
 EXECUTE FUNCTION erp_transfer_in_commit_guard();

CREATE VIEW inventory_transfer_in_transit AS
 SELECT t.installation_id,t.branch_id,t.id AS transfer_id,t.status,
  t.source_warehouse_id,t.destination_warehouse_id,
  l.line_no,l.product_id,l.quantity_base AS dispatched_base,
  COALESCE((SELECT sum(r.quantity_base) FROM inventory_transfer_receipt_line r
    WHERE r.installation_id=l.installation_id AND r.branch_id=l.branch_id
      AND r.transfer_id=l.transfer_id AND r.transfer_line_no=l.line_no),0)::numeric(24,6)
    AS received_base,
  (CASE WHEN t.status IN ('IN_TRANSIT','PARTIALLY_RECEIVED','RECEIVED')
     THEN l.quantity_base-COALESCE((SELECT sum(r.quantity_base)
       FROM inventory_transfer_receipt_line r WHERE r.installation_id=l.installation_id
         AND r.branch_id=l.branch_id AND r.transfer_id=l.transfer_id
         AND r.transfer_line_no=l.line_no),0)
     ELSE 0 END)::numeric(24,6) AS in_transit_base
 FROM inventory_transfer t JOIN inventory_transfer_line l
  ON l.installation_id=t.installation_id AND l.branch_id=t.branch_id AND l.transfer_id=t.id;

INSERT INTO role_permission(installation_id,role_id,permission_code)
 SELECT installation_id,id,p.permission FROM app_role
 CROSS JOIN (VALUES ('inventory.transfer.read'),('inventory.transfer.create'),
   ('inventory.transfer.approve'),('inventory.transfer.dispatch'),
   ('inventory.transfer.receive')) AS p(permission)
 WHERE code='PRIMARY_OWNER_MAIN' ON CONFLICT DO NOTHING;
