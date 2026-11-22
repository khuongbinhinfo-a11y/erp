-- R3.4 stocktake: snapshot physical stock, immutable count rounds and approved
-- adjustments posted through the same authoritative inventory_ledger.
-- Never write a projection/balance row to change stock.
ALTER TABLE inventory_ledger DROP CONSTRAINT inventory_ledger_kind_check;
ALTER TABLE inventory_ledger ADD CONSTRAINT inventory_ledger_kind_check
 CHECK(kind IN ('OPENING','RECEIPT','ISSUE','TRANSFER_IN','TRANSFER_OUT','REVERSAL','ADJUSTMENT'));
ALTER TABLE inventory_ledger DROP CONSTRAINT inventory_ledger_source_type_check;
ALTER TABLE inventory_ledger ADD CONSTRAINT inventory_ledger_source_type_check
 CHECK(source_type IN ('OPENING','PURCHASE_RECEIPT','FULFILLMENT','TRANSFER','REVERSAL','STOCKTAKE'));
ALTER TABLE inventory_ledger DROP CONSTRAINT inventory_ledger_check1;
ALTER TABLE inventory_ledger ADD CONSTRAINT inventory_ledger_check1
 CHECK ((kind IN ('OPENING','RECEIPT','TRANSFER_IN') AND delta_base>0)
    OR (kind IN ('ISSUE','TRANSFER_OUT') AND delta_base<0)
    OR kind IN ('REVERSAL','ADJUSTMENT'));

CREATE TABLE inventory_stocktake (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),warehouse_id uuid NOT NULL,
 status text NOT NULL DEFAULT 'CREATED'
   CHECK(status IN ('CREATED','COUNTING','SUBMITTED','APPROVED','POSTED','CANCELLED')),
 revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 note text NOT NULL DEFAULT '' CHECK(length(note)<=500),
 created_by uuid NOT NULL,submitted_by uuid,approved_by uuid,posted_by uuid,
 request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 created_at timestamptz NOT NULL DEFAULT now(),
 submitted_at timestamptz,approved_at timestamptz,posted_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,created_by) REFERENCES app_user(installation_id,id),
 FOREIGN KEY(installation_id,submitted_by) REFERENCES app_user(installation_id,id),
 FOREIGN KEY(installation_id,approved_by) REFERENCES app_user(installation_id,id),
 FOREIGN KEY(installation_id,posted_by) REFERENCES app_user(installation_id,id),
 CHECK ((status IN ('SUBMITTED','APPROVED','POSTED'))
   = (submitted_by IS NOT NULL AND submitted_at IS NOT NULL)),
 CHECK ((status IN ('APPROVED','POSTED'))
   = (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
 CHECK ((status='POSTED') = (posted_by IS NOT NULL AND posted_at IS NOT NULL)),
 CHECK(approved_by IS NULL OR approved_by<>submitted_by)
);
CREATE INDEX inventory_stocktake_wh_idx ON inventory_stocktake
 (installation_id,branch_id,warehouse_id,created_at DESC);
CREATE TABLE inventory_stocktake_line (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,stocktake_id uuid NOT NULL,
 line_no integer NOT NULL CHECK(line_no BETWEEN 1 AND 10000),
 product_id uuid NOT NULL,
 snapshot_on_hand numeric(24,6) NOT NULL CHECK(snapshot_on_hand<>'NaN'::numeric),
 snapshot_movement_count bigint NOT NULL CHECK(snapshot_movement_count>=0),
 PRIMARY KEY(installation_id,branch_id,stocktake_id,line_no),
 UNIQUE(installation_id,branch_id,stocktake_id,product_id),
 FOREIGN KEY(installation_id,branch_id,stocktake_id)
  REFERENCES inventory_stocktake(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,product_id)
  REFERENCES catalog_product(installation_id,branch_id,id)
);
CREATE TABLE inventory_stocktake_count (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,stocktake_id uuid NOT NULL,
 line_no integer NOT NULL,round_no integer NOT NULL CHECK(round_no BETWEEN 1 AND 3),
 counted_base numeric(24,6) NOT NULL CHECK(counted_base>=0 AND counted_base<>'NaN'::numeric),
 counted_by uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 counted_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,stocktake_id,line_no,round_no),
 FOREIGN KEY(installation_id,branch_id,stocktake_id,line_no)
  REFERENCES inventory_stocktake_line(installation_id,branch_id,stocktake_id,line_no),
 FOREIGN KEY(installation_id,counted_by) REFERENCES app_user(installation_id,id)
);
CREATE INDEX inventory_stocktake_count_latest_idx ON inventory_stocktake_count
 (installation_id,branch_id,stocktake_id,line_no,round_no DESC);

-- Freeze counted SKU scope after CREATED; count records are append-only.
CREATE FUNCTION erp_stocktake_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE st text;
BEGIN
 IF TG_OP IN ('UPDATE','DELETE') THEN RAISE EXCEPTION 'Stocktake snapshot is immutable'; END IF;
 SELECT status INTO st FROM inventory_stocktake
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND id=NEW.stocktake_id FOR UPDATE;
 IF st IS DISTINCT FROM 'CREATED' THEN
   RAISE EXCEPTION 'Stocktake snapshot can only be captured on creation';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER inventory_stocktake_line_guard BEFORE INSERT OR UPDATE OR DELETE
 ON inventory_stocktake_line FOR EACH ROW EXECUTE FUNCTION erp_stocktake_line_guard();

CREATE FUNCTION erp_stocktake_count_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE st text;
BEGIN
 IF TG_OP IN ('UPDATE','DELETE') THEN RAISE EXCEPTION 'Stocktake count is immutable'; END IF;
 SELECT status INTO st FROM inventory_stocktake
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
    AND id=NEW.stocktake_id FOR UPDATE;
 IF st IS DISTINCT FROM 'COUNTING' THEN
   RAISE EXCEPTION 'Stocktake count only permitted during counting';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER inventory_stocktake_count_guard BEFORE INSERT OR UPDATE OR DELETE
 ON inventory_stocktake_count FOR EACH ROW EXECUTE FUNCTION erp_stocktake_count_guard();

-- No mutation of snapshot identity and only server-defined lifecycle transitions.
CREATE FUNCTION erp_stocktake_header_guard() RETURNS trigger LANGUAGE plpgsql AS $
BEGIN
 IF TG_OP='INSERT' THEN
   IF NEW.status IS DISTINCT FROM 'CREATED' OR NEW.revision<>0
     OR NEW.submitted_by IS NOT NULL OR NEW.submitted_at IS NOT NULL
     OR NEW.approved_by IS NOT NULL OR NEW.approved_at IS NOT NULL
     OR NEW.posted_by IS NOT NULL OR NEW.posted_at IS NOT NULL THEN
      RAISE EXCEPTION 'Stocktake must begin in CREATED without posted facts';
   END IF;
   RETURN NEW;
 END IF;
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Stocktake document cannot be deleted'; END IF;
 IF (NEW.installation_id,NEW.branch_id,NEW.id,NEW.warehouse_id,
      NEW.created_by,NEW.request_id,NEW.created_at,NEW.note)
    IS DISTINCT FROM
    (OLD.installation_id,OLD.branch_id,OLD.id,OLD.warehouse_id,
      OLD.created_by,OLD.request_id,OLD.created_at,OLD.note)
    OR NEW.revision<>OLD.revision+1
    OR (OLD.status='CREATED' AND NEW.status NOT IN ('COUNTING','CANCELLED'))
    OR (OLD.status='COUNTING' AND NEW.status NOT IN ('SUBMITTED','CANCELLED'))
    OR (OLD.status='SUBMITTED' AND NEW.status<>'APPROVED')
    OR (OLD.status='APPROVED' AND NEW.status<>'POSTED')
    OR OLD.status IN ('POSTED','CANCELLED')
    OR (OLD.status<>'COUNTING' AND
      (NEW.submitted_by IS DISTINCT FROM OLD.submitted_by
       OR NEW.submitted_at IS DISTINCT FROM OLD.submitted_at))
    OR (OLD.status<>'SUBMITTED' AND
      (NEW.approved_by IS DISTINCT FROM OLD.approved_by
       OR NEW.approved_at IS DISTINCT FROM OLD.approved_at))
    OR (OLD.status<>'APPROVED' AND
      (NEW.posted_by IS DISTINCT FROM OLD.posted_by
       OR NEW.posted_at IS DISTINCT FROM OLD.posted_at))
 THEN RAISE EXCEPTION 'Stocktake lifecycle mutation invalid'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER inventory_stocktake_header_guard BEFORE INSERT OR UPDATE OR DELETE
 ON inventory_stocktake FOR EACH ROW EXECUTE FUNCTION erp_stocktake_header_guard();

-- A direct SQL movement cannot create arbitrary stocktake corrections.
-- This enforces one approved count, matching SKU/warehouse and exact signed delta;
-- no stock movement can silently cross the snapshot boundary.
CREATE FUNCTION erp_stocktake_ledger_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  snapshot_qty numeric;
  counted_qty numeric;
  movement_count bigint;
  current_count bigint;
  expected_wh uuid;
  status_now text;
BEGIN
 SELECT t.status,t.warehouse_id,l.snapshot_on_hand,l.snapshot_movement_count,
   (SELECT c.counted_base FROM inventory_stocktake_count c
     WHERE c.installation_id=l.installation_id AND c.branch_id=l.branch_id
       AND c.stocktake_id=l.stocktake_id AND c.line_no=l.line_no
     ORDER BY c.round_no DESC LIMIT 1)
 INTO status_now,expected_wh,snapshot_qty,movement_count,counted_qty
 FROM inventory_stocktake t JOIN inventory_stocktake_line l
   ON l.installation_id=t.installation_id AND l.branch_id=t.branch_id
   AND l.stocktake_id=t.id AND l.line_no=NEW.source_line
 WHERE t.installation_id=NEW.installation_id AND t.branch_id=NEW.branch_id
  AND t.id=NEW.source_id AND l.product_id=NEW.product_id FOR SHARE OF t;
 IF NEW.source_type IS DISTINCT FROM 'STOCKTAKE' OR
    status_now IS DISTINCT FROM 'APPROVED' OR
    expected_wh IS DISTINCT FROM NEW.warehouse_id OR
    counted_qty IS NULL OR snapshot_qty IS NULL OR
    NEW.delta_base IS DISTINCT FROM counted_qty-snapshot_qty THEN
   RAISE EXCEPTION 'Stocktake ledger movement must match one approved counted line';
 END IF;
 SELECT count(*) INTO current_count FROM inventory_ledger
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
    AND warehouse_id=NEW.warehouse_id AND product_id=NEW.product_id;
 IF current_count<>movement_count THEN
   RAISE EXCEPTION 'Stocktake inventory snapshot became stale';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER inventory_stocktake_ledger_guard BEFORE INSERT ON inventory_ledger
 FOR EACH ROW WHEN (NEW.kind='ADJUSTMENT')
 EXECUTE FUNCTION erp_stocktake_ledger_guard();

INSERT INTO role_permission(installation_id,role_id,permission_code)
 SELECT installation_id,id,p.permission FROM app_role
 CROSS JOIN (VALUES ('inventory.stocktake.read'),('inventory.stocktake.create'),
   ('inventory.stocktake.count'),('inventory.stocktake.submit'),
   ('inventory.stocktake.approve'),('inventory.stocktake.post')) AS p(permission)
 WHERE code='PRIMARY_OWNER_MAIN' ON CONFLICT DO NOTHING;
