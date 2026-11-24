-- T1 commercial context. Adapted from legacy sales-order repository's
-- immutable warehouse/address/collection snapshots and walk-in settings.
-- Existing confirmed orders are NOT backfilled with guessed facts.
CREATE TABLE sales_walk_in_customer (
 installation_id uuid NOT NULL,
 branch_id uuid NOT NULL,
 customer_id uuid NOT NULL,
 created_by uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (installation_id,branch_id),
 UNIQUE (installation_id,branch_id,customer_id),
 FOREIGN KEY (installation_id,branch_id,customer_id)
  REFERENCES catalog_customer(installation_id,branch_id,id),
 FOREIGN KEY (installation_id,created_by) REFERENCES app_user(installation_id,id)
);
CREATE FUNCTION erp_sales_walk_in_customer_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM sales_walk_in_customer c
   WHERE c.installation_id=OLD.installation_id AND c.branch_id=OLD.branch_id
     AND c.customer_id=OLD.id) THEN
   RAISE EXCEPTION 'System walk-in customer cannot be edited or deleted'
    USING ERRCODE='23514';
 END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER sales_walk_in_customer_guard BEFORE UPDATE OR DELETE ON catalog_customer
 FOR EACH ROW EXECUTE FUNCTION erp_sales_walk_in_customer_guard();

CREATE TABLE sales_order_version_context (
 installation_id uuid NOT NULL,
 branch_id uuid NOT NULL,
 order_id uuid NOT NULL,
 version_no integer NOT NULL,
 customer_id uuid NOT NULL,
 customer_mode text NOT NULL CHECK(customer_mode IN ('EXISTING','WALK_IN')),
 walk_in_name text CHECK(walk_in_name IS NULL OR length(trim(walk_in_name)) BETWEEN 1 AND 160),
 walk_in_phone text CHECK(walk_in_phone IS NULL OR walk_in_phone ~ '^\+?[0-9]{9,15}$'),
 warehouse_id uuid NOT NULL,
 warehouse_code text NOT NULL,
 warehouse_name text NOT NULL,
 delivery_choice text NOT NULL CHECK(delivery_choice IN ('MANUAL','TRIP','PICKUP')),
 customer_location_id uuid,
 delivery_address text CHECK(delivery_address IS NULL OR length(trim(delivery_address)) BETWEEN 1 AND 500),
 requested_delivery_date date,
 collection_policy text NOT NULL CHECK(collection_policy IN
   ('COLLECT_ON_DELIVERY','PREPAID','COLLECT_AFTER_DELIVERY','CREDIT_TERMS')),
 payment_terms_days integer NOT NULL CHECK(payment_terms_days BETWEEN 0 AND 365),
 PRIMARY KEY (installation_id,branch_id,order_id,version_no),
 FOREIGN KEY (installation_id,branch_id,order_id,version_no)
  REFERENCES sales_order_version(installation_id,branch_id,order_id,version_no),
 FOREIGN KEY (installation_id,branch_id,customer_id)
  REFERENCES catalog_customer(installation_id,branch_id,id),
 FOREIGN KEY (installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY (installation_id,branch_id,customer_location_id)
  REFERENCES catalog_customer_location(installation_id,branch_id,id),
 CHECK (delivery_choice<>'PICKUP' OR (customer_location_id IS NULL AND delivery_address IS NULL)),
 CHECK (customer_mode='WALK_IN' OR (walk_in_name IS NULL AND walk_in_phone IS NULL)),
 CHECK (customer_mode<>'WALK_IN' OR
   (delivery_choice='PICKUP' AND collection_policy IN ('PREPAID','COLLECT_ON_DELIVERY')
     AND payment_terms_days=0))
);
CREATE INDEX sales_order_version_context_warehouse_idx
 ON sales_order_version_context(installation_id,branch_id,warehouse_id,order_id,version_no);
CREATE FUNCTION erp_sales_order_context_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
 parent_state text;
 location_customer uuid;
 is_walk_in boolean;
BEGIN
 IF TG_OP='DELETE' THEN
   RAISE EXCEPTION 'Sales order context cannot be deleted' USING ERRCODE='23514';
 END IF;
 IF TG_OP='UPDATE' AND
   (OLD.installation_id,OLD.branch_id,OLD.order_id,OLD.version_no) IS DISTINCT FROM
   (NEW.installation_id,NEW.branch_id,NEW.order_id,NEW.version_no) THEN
   RAISE EXCEPTION 'Sales order context identity is immutable' USING ERRCODE='23514';
 END IF;
 SELECT state INTO parent_state FROM sales_order_version
  WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND order_id=NEW.order_id AND version_no=NEW.version_no FOR SHARE;
 IF parent_state IS DISTINCT FROM 'DRAFT' THEN
   RAISE EXCEPTION 'Confirmed sales order context is immutable' USING ERRCODE='23514';
 END IF;
 IF NEW.customer_location_id IS NOT NULL THEN
  SELECT customer_id INTO location_customer FROM catalog_customer_location
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
     AND id=NEW.customer_location_id;
  IF location_customer IS DISTINCT FROM NEW.customer_id THEN
   RAISE EXCEPTION 'Sales location does not belong to customer' USING ERRCODE='23514';
  END IF;
 END IF;
 SELECT EXISTS(SELECT 1 FROM sales_walk_in_customer
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
     AND customer_id=NEW.customer_id) INTO is_walk_in;
 IF is_walk_in IS DISTINCT FROM (NEW.customer_mode='WALK_IN') THEN
  RAISE EXCEPTION 'Invalid walk-in customer mode' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER sales_order_context_guard BEFORE INSERT OR UPDATE OR DELETE
 ON sales_order_version_context FOR EACH ROW EXECUTE FUNCTION erp_sales_order_context_guard();

-- Scoped default follows the actor across sessions/devices, never another user.
CREATE TABLE sales_order_entry_preference (
 installation_id uuid NOT NULL,
 actor_id uuid NOT NULL,
 delivery_choice text NOT NULL CHECK(delivery_choice IN ('MANUAL','TRIP','PICKUP')),
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (installation_id,actor_id),
 FOREIGN KEY (installation_id,actor_id) REFERENCES app_user(installation_id,id)
);

-- Preserve the warehouse on scoped orders when downstream reservation is used.
-- Old orders without a context remain eligible under their historical contract.
CREATE FUNCTION erp_sales_reservation_warehouse_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE chosen uuid;
BEGIN
 SELECT warehouse_id INTO chosen FROM sales_order_version_context
 WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
   AND order_id=NEW.order_id AND version_no=NEW.order_version;
 IF chosen IS NOT NULL AND chosen<>NEW.warehouse_id THEN
   RAISE EXCEPTION 'Reservation warehouse differs from sales version' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER sales_reservation_warehouse_guard BEFORE INSERT ON inventory_reservation
 FOR EACH ROW EXECUTE FUNCTION erp_sales_reservation_warehouse_guard();
