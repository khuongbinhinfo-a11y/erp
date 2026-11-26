-- T6 POS: canonical PICKUP checkout with atomic stock, receivables and payment facts.
-- Forward-only. No existing sales order or immutable ledger fact is rewritten.
-- A retail checkout is never a separate price engine, sale ledger or inventory balance.

ALTER TABLE sales_order DROP CONSTRAINT sales_order_fulfillment_status_check;
ALTER TABLE sales_order ADD CONSTRAINT sales_order_fulfillment_status_check
  CHECK (fulfillment_status IN ('NOT_ALLOCATED','PARTIAL','ALLOCATED','COMPLETED'));

CREATE TABLE retail_shift (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 warehouse_id uuid NOT NULL,actor_id uuid NOT NULL,
 counter_name text NOT NULL CHECK(length(trim(counter_name)) BETWEEN 1 AND 80),
 opening_cash numeric(20,0) NOT NULL DEFAULT 0 CHECK(opening_cash>=0),
 closing_cash numeric(20,0) CHECK(closing_cash>=0),
 status text NOT NULL DEFAULT 'OPEN' CHECK(status IN ('OPEN','CLOSED')),
 opened_at timestamptz NOT NULL DEFAULT now(),
 closed_at timestamptz,
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id),
 CHECK ((status='OPEN' AND closed_at IS NULL AND closing_cash IS NULL)
     OR (status='CLOSED' AND closed_at IS NOT NULL AND closing_cash IS NOT NULL))
);
CREATE UNIQUE INDEX retail_one_open_shift_per_cashier
 ON retail_shift(installation_id,branch_id,warehouse_id,actor_id) WHERE status='OPEN';
CREATE FUNCTION erp_retail_shift_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Retail shifts cannot be deleted'; END IF;
 IF OLD.status<>'OPEN' OR NEW.status<>'CLOSED'
    OR (NEW.installation_id,NEW.branch_id,NEW.id,NEW.warehouse_id,NEW.actor_id,
        NEW.counter_name,NEW.opening_cash,NEW.opened_at)
       IS DISTINCT FROM
       (OLD.installation_id,OLD.branch_id,OLD.id,OLD.warehouse_id,OLD.actor_id,
        OLD.counter_name,OLD.opening_cash,OLD.opened_at)
    OR NEW.closed_at IS NULL OR NEW.closing_cash IS NULL THEN
   RAISE EXCEPTION 'Invalid cashier shift transition';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER retail_shift_guard BEFORE UPDATE OR DELETE ON retail_shift
 FOR EACH ROW EXECUTE FUNCTION erp_retail_shift_guard();

-- This is the shared direct fulfillment fact for PICKUP; inventory ISSUE rows
-- carry this fulfillment ID and remain in the pre-existing inventory_ledger.
CREATE TABLE sales_fulfillment (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL,version_no integer NOT NULL,
 warehouse_id uuid NOT NULL,mode text NOT NULL CHECK(mode='PICKUP'),
 completed_at timestamptz NOT NULL DEFAULT now(),
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,order_id),
 FOREIGN KEY(installation_id,branch_id,order_id,version_no)
  REFERENCES sales_order_version(installation_id,branch_id,order_id,version_no),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);

CREATE TABLE retail_checkout (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL,fulfillment_id uuid NOT NULL,shift_id uuid NOT NULL,
 warehouse_id uuid NOT NULL,customer_id uuid NOT NULL,
 grand_total numeric(20,0) NOT NULL CHECK(grand_total>=0),
 cash_received numeric(20,0) NOT NULL CHECK(cash_received>=0),
 bank_amount numeric(20,0) NOT NULL CHECK(bank_amount>=0 AND bank_amount<=grand_total),
 change_due numeric(20,0) NOT NULL CHECK(change_due>=0),
 cashier_id uuid NOT NULL,
 request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,order_id),
 UNIQUE(installation_id,branch_id,fulfillment_id),
 FOREIGN KEY(installation_id,branch_id,order_id)
  REFERENCES sales_order(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,fulfillment_id)
  REFERENCES sales_fulfillment(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,shift_id)
  REFERENCES retail_shift(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,customer_id)
  REFERENCES catalog_customer(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,cashier_id) REFERENCES app_user(installation_id,id),
 CHECK (cash_received+bank_amount=grand_total+change_due)
);

-- Shared AR ledger, not a retail-specific second stock/receivable engine.
-- Debit SALE and REFUND; credit PAYMENT and RETURN. Immutable posted facts.
CREATE TABLE customer_receivable_ledger (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 customer_id uuid NOT NULL,order_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN ('SALE','PAYMENT','RETURN','REFUND')),
 source_id uuid NOT NULL,
 amount numeric(20,0) NOT NULL CHECK(amount<>0),
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 posted_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,kind,source_id),
 FOREIGN KEY(installation_id,branch_id,customer_id)
  REFERENCES catalog_customer(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,order_id)
  REFERENCES sales_order(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id),
 CHECK ((kind IN ('SALE','REFUND') AND amount>0)
     OR (kind IN ('PAYMENT','RETURN') AND amount<0))
);
CREATE INDEX customer_receivable_ledger_customer_idx
 ON customer_receivable_ledger(installation_id,branch_id,customer_id,posted_at);

CREATE TABLE payment_receipt (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 checkout_id uuid NOT NULL,order_id uuid NOT NULL,
 method text NOT NULL CHECK(method IN ('CASH','BANK_TRANSFER')),
 amount numeric(20,0) NOT NULL CHECK(amount>0),
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 posted_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,checkout_id,method),
 FOREIGN KEY(installation_id,branch_id,checkout_id)
  REFERENCES retail_checkout(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,order_id)
  REFERENCES sales_order(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);

CREATE TABLE payment_allocation (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 receipt_id uuid NOT NULL,sale_ledger_id uuid NOT NULL,
 allocated numeric(20,0) NOT NULL CHECK(allocated>0),
 PRIMARY KEY(installation_id,branch_id,receipt_id,sale_ledger_id),
 FOREIGN KEY(installation_id,branch_id,receipt_id)
  REFERENCES payment_receipt(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,sale_ledger_id)
  REFERENCES customer_receivable_ledger(installation_id,branch_id,id)
);

CREATE TABLE retail_return (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 checkout_id uuid NOT NULL,order_id uuid NOT NULL,
 amount numeric(20,0) NOT NULL CHECK(amount>=0),
 refund_method text NOT NULL CHECK(refund_method IN ('CASH','BANK_TRANSFER')),
 actor_id uuid NOT NULL,request_id text NOT NULL CHECK(length(request_id) BETWEEN 1 AND 80),
 completed_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,checkout_id),
 FOREIGN KEY(installation_id,branch_id,checkout_id)
  REFERENCES retail_checkout(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,order_id)
  REFERENCES sales_order(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);

CREATE FUNCTION erp_pos_facts_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION 'Posted POS, fulfillment and monetary facts are immutable';
END; $$;
CREATE TRIGGER sales_fulfillment_immutable BEFORE UPDATE OR DELETE ON sales_fulfillment
 FOR EACH ROW EXECUTE FUNCTION erp_pos_facts_immutable();
CREATE TRIGGER retail_checkout_immutable BEFORE UPDATE OR DELETE ON retail_checkout
 FOR EACH ROW EXECUTE FUNCTION erp_pos_facts_immutable();
CREATE TRIGGER receivable_ledger_immutable BEFORE UPDATE OR DELETE ON customer_receivable_ledger
 FOR EACH ROW EXECUTE FUNCTION erp_pos_facts_immutable();
CREATE TRIGGER payment_receipt_immutable BEFORE UPDATE OR DELETE ON payment_receipt
 FOR EACH ROW EXECUTE FUNCTION erp_pos_facts_immutable();
CREATE TRIGGER payment_allocation_immutable BEFORE UPDATE OR DELETE ON payment_allocation
 FOR EACH ROW EXECUTE FUNCTION erp_pos_facts_immutable();
CREATE TRIGGER retail_return_immutable BEFORE UPDATE OR DELETE ON retail_return
 FOR EACH ROW EXECUTE FUNCTION erp_pos_facts_immutable();

INSERT INTO role_permission(installation_id,role_id,permission_code)
 SELECT r.installation_id,r.id,p.code FROM app_role r
 CROSS JOIN (VALUES('pos.shift'),('pos.checkout'),('pos.return')) p(code)
 WHERE r.code='PRIMARY_OWNER_MAIN'
 ON CONFLICT DO NOTHING;
