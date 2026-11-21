-- Issue #8 / B1. Order agreement only. Does NOT reserve, issue inventory, deliver or post AR/AP.
-- Every installation, branch, customer, product and price reference is tenant scoped.
CREATE TABLE sales_order (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  document_no text,
  status text NOT NULL DEFAULT 'DRAFT'
    CHECK(status IN ('DRAFT','CONFIRMED','CANCELLED')),
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  current_version integer NOT NULL DEFAULT 1 CHECK (current_version >= 1),
  customer_id uuid NOT NULL,
  price_list_id uuid NOT NULL,
  source_type text NOT NULL DEFAULT 'COMPANY'
    CHECK (source_type IN ('COMPANY','MCP','RETAIL','PORTAL','IMPORT')),
  source_ref text,
  fulfillment_status text NOT NULL DEFAULT 'NOT_ALLOCATED'
    CHECK(fulfillment_status IN ('NOT_ALLOCATED','PARTIAL','ALLOCATED')),
  delivery_status text NOT NULL DEFAULT 'NOT_DISPATCHED'
    CHECK(delivery_status IN ('NOT_DISPATCHED','PARTIAL','DELIVERED')),
  payment_status text NOT NULL DEFAULT 'NOT_DUE'
    CHECK(payment_status IN ('NOT_DUE','PARTIAL','PAID')),
  created_by uuid NOT NULL,
  confirmed_by uuid,
  confirmed_at timestamptz,
  cancelled_by uuid,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id, branch_id, id),
  UNIQUE (installation_id, branch_id, document_no),
  FOREIGN KEY (installation_id,branch_id) REFERENCES branch(installation_id,id),
  FOREIGN KEY (installation_id,branch_id,customer_id)
    REFERENCES catalog_customer(installation_id,branch_id,id),
  FOREIGN KEY (installation_id,branch_id,price_list_id)
    REFERENCES catalog_price_list(installation_id,branch_id,id),
  FOREIGN KEY (installation_id,created_by) REFERENCES app_user(installation_id,id),
  FOREIGN KEY (installation_id,confirmed_by) REFERENCES app_user(installation_id,id),
  FOREIGN KEY (installation_id,cancelled_by) REFERENCES app_user(installation_id,id),
  CHECK ((source_type='COMPANY' AND source_ref IS NULL) OR
    (source_type<>'COMPANY' AND source_ref IS NOT NULL AND length(trim(source_ref)) BETWEEN 1 AND 128)),
  CHECK ((status='CONFIRMED' AND document_no IS NOT NULL AND confirmed_at IS NOT NULL AND confirmed_by IS NOT NULL)
    OR status<>'CONFIRMED'),
  CHECK ((status='CANCELLED' AND cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL
    AND cancellation_reason IS NOT NULL AND length(trim(cancellation_reason)) BETWEEN 3 AND 500) OR status<>'CANCELLED'),
  CHECK (document_no IS NULL OR document_no ~ '^SO-[0-9]{8}-[0-9]{6}$')
);
CREATE UNIQUE INDEX sales_order_source_unique ON sales_order
  (installation_id,source_type,source_ref) WHERE source_ref IS NOT NULL;
CREATE INDEX sales_order_list_idx ON sales_order
  (installation_id,branch_id,created_at DESC,id DESC);
CREATE INDEX sales_order_customer_idx ON sales_order
  (installation_id,branch_id,customer_id,created_at DESC);

CREATE TABLE sales_order_version (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  order_id uuid NOT NULL,
  version_no integer NOT NULL CHECK (version_no >= 1),
  state text NOT NULL DEFAULT 'DRAFT' CHECK(state IN ('DRAFT','CONFIRMED','CANCELLED')),
  customer_code text NOT NULL,
  customer_name text NOT NULL,
  price_list_code text NOT NULL,
  currency text NOT NULL DEFAULT 'VND' CHECK(currency='VND'),
  subtotal numeric(20,0) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount_total numeric(20,0) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
  tax_total numeric(20,0) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
  grand_total numeric(20,0) NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
  note text NOT NULL DEFAULT '' CHECK (length(note) <= 1000),
  amendment_reason text,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  confirmed_by uuid,
  confirmed_at timestamptz,
  PRIMARY KEY (installation_id,branch_id,order_id,version_no),
  FOREIGN KEY (installation_id,branch_id,order_id)
    REFERENCES sales_order(installation_id,branch_id,id),
  FOREIGN KEY (installation_id,created_by) REFERENCES app_user(installation_id,id),
  FOREIGN KEY (installation_id,confirmed_by) REFERENCES app_user(installation_id,id),
  CHECK ((state='CONFIRMED' AND confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL)
    OR state<>'CONFIRMED'),
  CHECK (grand_total = subtotal - discount_total + tax_total)
);

CREATE TABLE sales_order_line (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  order_id uuid NOT NULL,
  version_no integer NOT NULL,
  line_no integer NOT NULL CHECK (line_no BETWEEN 1 AND 100),
  product_id uuid NOT NULL,
  price_entry_id uuid NOT NULL,
  sku text NOT NULL,
  product_name text NOT NULL,
  unit_code text NOT NULL,
  quantity numeric(18,3) NOT NULL CHECK (quantity > 0),
  unit_price numeric(18,4) NOT NULL CHECK (unit_price >= 0),
  discount_rate numeric(5,2) NOT NULL DEFAULT 0 CHECK (discount_rate BETWEEN 0 AND 100),
  tax_rate numeric(5,2) NOT NULL DEFAULT 0 CHECK (tax_rate BETWEEN 0 AND 100),
  subtotal numeric(20,0) NOT NULL CHECK (subtotal >= 0),
  discount_amount numeric(20,0) NOT NULL CHECK (discount_amount >= 0),
  tax_amount numeric(20,0) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  line_total numeric(20,0) NOT NULL CHECK (line_total >= 0),
  PRIMARY KEY (installation_id,branch_id,order_id,version_no,line_no),
  UNIQUE (installation_id,branch_id,order_id,version_no,product_id),
  FOREIGN KEY (installation_id,branch_id,order_id,version_no)
    REFERENCES sales_order_version(installation_id,branch_id,order_id,version_no),
  FOREIGN KEY (installation_id,branch_id,product_id)
    REFERENCES catalog_product(installation_id,branch_id,id),
  FOREIGN KEY (installation_id,branch_id,price_entry_id)
    REFERENCES catalog_price_entry(installation_id,branch_id,id),
  CHECK (line_total = subtotal - discount_amount + tax_amount),
  CHECK (tax_rate = 0)
);

-- Branch-local sequence allocated only during confirmation under a row-level lock.
CREATE TABLE sales_order_sequence (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  next_value bigint NOT NULL CHECK(next_value BETWEEN 1 AND 999999),
  PRIMARY KEY (installation_id,branch_id),
  FOREIGN KEY (installation_id,branch_id) REFERENCES branch(installation_id,id)
);

CREATE FUNCTION erp_sales_order_version_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Sales versions cannot be deleted'; END IF;
  IF OLD.state <> 'DRAFT' THEN RAISE EXCEPTION 'Confirmed sales versions are immutable'; END IF;
  IF NEW.state NOT IN ('DRAFT','CONFIRMED','CANCELLED') THEN
    RAISE EXCEPTION 'Invalid sales version transition';
  END IF;
  IF (NEW.state <> 'DRAFT' AND
      (NEW.customer_code,NEW.customer_name,NEW.price_list_code,NEW.subtotal,
       NEW.discount_total,NEW.tax_total,NEW.grand_total,NEW.note)
       IS DISTINCT FROM
      (OLD.customer_code,OLD.customer_name,OLD.price_list_code,OLD.subtotal,
       OLD.discount_total,OLD.tax_total,OLD.grand_total,OLD.note)) THEN
    RAISE EXCEPTION 'Cannot modify commercial values during confirmation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER sales_order_version_guard BEFORE UPDATE OR DELETE ON sales_order_version
  FOR EACH ROW EXECUTE FUNCTION erp_sales_order_version_guard();

CREATE FUNCTION erp_sales_order_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  version_state text;
  target_installation uuid;
  target_branch uuid;
  target_order uuid;
  target_version integer;
BEGIN
  -- Never allow a row to be moved between aggregates/versions via UPDATE.
  -- Revisions are represented by new commercial version lines instead.
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.installation_id,NEW.branch_id,NEW.order_id,NEW.version_no,NEW.line_no)
       IS DISTINCT FROM
       (OLD.installation_id,OLD.branch_id,OLD.order_id,OLD.version_no,OLD.line_no)
    THEN
      RAISE EXCEPTION 'Sales order line identity is immutable';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN
    target_installation := OLD.installation_id;
    target_branch := OLD.branch_id;
    target_order := OLD.order_id;
    target_version := OLD.version_no;
  ELSE
    target_installation := NEW.installation_id;
    target_branch := NEW.branch_id;
    target_order := NEW.order_id;
    target_version := NEW.version_no;
  END IF;
  -- FOR SHARE serializes INSERT/UPDATE/DELETE with confirmation's
  -- FOR UPDATE parent-version lock. A late writer sees CONFIRMED and fails.
  SELECT v.state INTO version_state FROM sales_order_version v
   WHERE v.installation_id=target_installation AND v.branch_id=target_branch
     AND v.order_id=target_order AND v.version_no=target_version FOR SHARE;
  IF version_state IS DISTINCT FROM 'DRAFT' THEN
    RAISE EXCEPTION 'Confirmed sales order lines are immutable';
  END IF;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER sales_order_line_guard BEFORE INSERT OR UPDATE OR DELETE ON sales_order_line
  FOR EACH ROW EXECUTE FUNCTION erp_sales_order_line_guard();

CREATE FUNCTION erp_sales_order_identity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Sales order cannot be deleted'; END IF;
  IF OLD.status='CANCELLED'
    OR NEW.installation_id IS DISTINCT FROM OLD.installation_id
    OR NEW.branch_id IS DISTINCT FROM OLD.branch_id
    OR NEW.id IS DISTINCT FROM OLD.id
    OR NEW.source_type IS DISTINCT FROM OLD.source_type
    OR NEW.source_ref IS DISTINCT FROM OLD.source_ref
    OR (OLD.document_no IS NOT NULL AND NEW.document_no IS DISTINCT FROM OLD.document_no)
    OR (OLD.status='CONFIRMED' AND
      (NEW.customer_id IS DISTINCT FROM OLD.customer_id OR
       NEW.price_list_id IS DISTINCT FROM OLD.price_list_id))
  THEN RAISE EXCEPTION 'Sales order identity cannot be changed'; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER sales_order_identity_guard BEFORE UPDATE OR DELETE ON sales_order
  FOR EACH ROW EXECUTE FUNCTION erp_sales_order_identity_guard();


-- Existing installation owners receive the new sales action permissions.
-- Other users/roles remain deny-by-default; only installation administrators can delegate later.
INSERT INTO role_permission(installation_id,role_id,permission_code)
SELECT r.installation_id,r.id,p.code
FROM app_role r
CROSS JOIN (VALUES ('orders.update'),('orders.confirm'),('orders.amend'),('orders.cancel')) AS p(code)
WHERE r.code='PRIMARY_OWNER_MAIN'
ON CONFLICT DO NOTHING;
