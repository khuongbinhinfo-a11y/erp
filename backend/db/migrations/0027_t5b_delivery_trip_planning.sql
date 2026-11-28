-- T5-B: planning only. Never post Inventory OUT, actual delivery, COD or AR.
CREATE TABLE delivery_vehicle (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,warehouse_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),code text NOT NULL,
 license_plate text NOT NULL,name text NOT NULL DEFAULT '',active boolean NOT NULL DEFAULT true,
 created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,warehouse_id,id),
 UNIQUE(installation_id,branch_id,code),
 CHECK(length(btrim(code)) BETWEEN 1 AND 48),
 CHECK(length(btrim(license_plate)) BETWEEN 3 AND 32),
 CHECK(length(name)<=120),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,created_by) REFERENCES app_user(installation_id,id)
);
CREATE TABLE delivery_driver (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,warehouse_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),code text NOT NULL,
 name text NOT NULL,phone text,active boolean NOT NULL DEFAULT true,
 created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,warehouse_id,id),
 UNIQUE(installation_id,branch_id,code),
 CHECK(length(btrim(code)) BETWEEN 1 AND 48),
 CHECK(length(btrim(name)) BETWEEN 2 AND 120),
 CHECK(phone IS NULL OR phone ~ '^\+?[0-9]{9,15}$'),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,created_by) REFERENCES app_user(installation_id,id)
);
CREATE TABLE delivery_trip_counter (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 business_day date NOT NULL,next_value integer NOT NULL CHECK(next_value BETWEEN 1 AND 999999),
 PRIMARY KEY(installation_id,branch_id,business_day),
 FOREIGN KEY(installation_id,branch_id) REFERENCES branch(installation_id,id)
);
CREATE TABLE delivery_trip (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,warehouse_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),trip_no text NOT NULL,
 status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN ('DRAFT','PLANNED','LOCKED')),
 revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 vehicle_id uuid,driver_id uuid,planned_date date NOT NULL,
 note text NOT NULL DEFAULT '' CHECK(length(note)<=500),
 created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,trip_no),
 CHECK(trip_no ~ '^TG-[0-9]{8}-[0-9]{6}$'),
 FOREIGN KEY(installation_id,branch_id,warehouse_id)
  REFERENCES warehouse(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,warehouse_id,vehicle_id)
  REFERENCES delivery_vehicle(installation_id,branch_id,warehouse_id,id),
 FOREIGN KEY(installation_id,branch_id,warehouse_id,driver_id)
  REFERENCES delivery_driver(installation_id,branch_id,warehouse_id,id),
 FOREIGN KEY(installation_id,created_by) REFERENCES app_user(installation_id,id)
);
CREATE INDEX delivery_trip_scope_idx ON delivery_trip
 (installation_id,branch_id,warehouse_id,created_at DESC,id DESC);
CREATE TABLE delivery_trip_stop (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,trip_id uuid NOT NULL,
 order_id uuid NOT NULL,order_version integer NOT NULL CHECK(order_version>0),
 sequence_no integer NOT NULL CHECK(sequence_no>0),
 customer_id uuid NOT NULL,customer_name text NOT NULL,
 delivery_address text NOT NULL CHECK(length(btrim(delivery_address)) BETWEEN 1 AND 500),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,trip_id,order_id),
 UNIQUE(installation_id,branch_id,order_id),
 CONSTRAINT delivery_trip_stop_sequence_unique
 UNIQUE(installation_id,branch_id,trip_id,sequence_no) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(installation_id,branch_id,trip_id)
  REFERENCES delivery_trip(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,order_id)
  REFERENCES sales_order(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,customer_id)
  REFERENCES catalog_customer(installation_id,branch_id,id)
);
CREATE TABLE delivery_trip_event (
 installation_id uuid NOT NULL,branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),trip_id uuid NOT NULL,
 event_type text NOT NULL CHECK(event_type IN
  ('CREATED','ASSIGNED','UNASSIGNED','REORDERED','PLANNED','REOPENED','LOCKED')),
 revision bigint NOT NULL,detail jsonb NOT NULL DEFAULT '{}'::jsonb,
 actor_id uuid NOT NULL,request_id text NOT NULL,occurred_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,branch_id,trip_id)
  REFERENCES delivery_trip(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,actor_id) REFERENCES app_user(installation_id,id)
);
CREATE INDEX delivery_trip_event_scope ON delivery_trip_event
 (installation_id,branch_id,trip_id,occurred_at,id);

CREATE FUNCTION erp_t5b_trip_header_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Trip cannot be deleted'; END IF;
 IF (NEW.installation_id,NEW.branch_id,NEW.id,NEW.warehouse_id,NEW.trip_no,
    NEW.created_by,NEW.created_at)
  IS DISTINCT FROM
    (OLD.installation_id,OLD.branch_id,OLD.id,OLD.warehouse_id,OLD.trip_no,
    OLD.created_by,OLD.created_at)
 THEN RAISE EXCEPTION 'Trip identity is immutable'; END IF;
 IF OLD.status='LOCKED' THEN RAISE EXCEPTION 'Locked trip is immutable'; END IF;
 IF NOT ((OLD.status='DRAFT' AND NEW.status IN ('DRAFT','PLANNED')) OR
         (OLD.status='PLANNED' AND NEW.status IN ('PLANNED','DRAFT','LOCKED'))) THEN
   RAISE EXCEPTION 'Invalid trip state transition';
 END IF;
 IF NEW.revision<>OLD.revision+1 THEN RAISE EXCEPTION 'Trip revision required'; END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER delivery_trip_header_guard BEFORE UPDATE OR DELETE ON delivery_trip
 FOR EACH ROW EXECUTE FUNCTION erp_t5b_trip_header_guard();

CREATE FUNCTION erp_t5b_trip_stop_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE trip_state text;chosen_wh uuid;current_version integer;
 order_status text;version_state text;delivery_mode text;order_wh uuid;
 fulfillment text;delivery text;payment text;
BEGIN
 IF TG_OP='UPDATE' AND
  (NEW.installation_id,NEW.branch_id,NEW.trip_id,NEW.order_id,NEW.order_version,
   NEW.customer_id,NEW.customer_name,NEW.delivery_address)
  IS DISTINCT FROM
  (OLD.installation_id,OLD.branch_id,OLD.trip_id,OLD.order_id,OLD.order_version,
   OLD.customer_id,OLD.customer_name,OLD.delivery_address)
 THEN RAISE EXCEPTION 'Trip stop identity and customer address immutable'; END IF;
 SELECT status,warehouse_id INTO trip_state,chosen_wh FROM delivery_trip
 WHERE installation_id=CASE WHEN TG_OP='DELETE' THEN OLD.installation_id ELSE NEW.installation_id END
  AND branch_id=CASE WHEN TG_OP='DELETE' THEN OLD.branch_id ELSE NEW.branch_id END
  AND id=CASE WHEN TG_OP='DELETE' THEN OLD.trip_id ELSE NEW.trip_id END FOR UPDATE;
 IF trip_state IS DISTINCT FROM 'DRAFT' THEN RAISE EXCEPTION 'Only draft trip can change stops'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 -- On UPDATE every immutable stop field was compared above, so only
 -- sequence_no can change. A stale remaining order must not block cleanup
 -- or re-numbering while its trip is still DRAFT.
 IF TG_OP='UPDATE' THEN RETURN NEW; END IF;
 SELECT o.current_version,o.status,v.state,c.delivery_choice,c.warehouse_id,
  o.fulfillment_status,o.delivery_status,o.payment_status
 INTO current_version,order_status,version_state,delivery_mode,order_wh,fulfillment,delivery,payment
 FROM sales_order o JOIN sales_order_version v
  ON v.installation_id=o.installation_id AND v.branch_id=o.branch_id
  AND v.order_id=o.id AND v.version_no=o.current_version
 JOIN sales_order_version_context c ON c.installation_id=v.installation_id
  AND c.branch_id=v.branch_id AND c.order_id=v.order_id AND c.version_no=v.version_no
 WHERE o.installation_id=NEW.installation_id AND o.branch_id=NEW.branch_id
  AND o.id=NEW.order_id FOR SHARE OF o;
 IF current_version IS DISTINCT FROM NEW.order_version
 OR order_status IS DISTINCT FROM 'CONFIRMED' OR version_state IS DISTINCT FROM 'CONFIRMED'
 OR delivery_mode IS DISTINCT FROM 'TRIP' OR order_wh IS DISTINCT FROM chosen_wh
 OR delivery IS DISTINCT FROM 'NOT_DISPATCHED' OR payment IS DISTINCT FROM 'NOT_DUE'
 OR fulfillment='COMPLETED' THEN
  RAISE EXCEPTION 'Order is not eligible for this trip';
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER delivery_trip_stop_guard BEFORE INSERT OR UPDATE OR DELETE ON delivery_trip_stop
 FOR EACH ROW EXECUTE FUNCTION erp_t5b_trip_stop_guard();

CREATE FUNCTION erp_t5b_locked_order_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 -- Lock freezes the COMMERCIAL order/version only. Future T5-C dispatch,
 -- actual delivery and COD must still be posted through their own ledgers.
 IF TG_OP='UPDATE' AND (NEW.current_version,NEW.status)
  IS NOT DISTINCT FROM (OLD.current_version,OLD.status) THEN RETURN NEW; END IF;
 IF EXISTS(
  SELECT 1 FROM delivery_trip_stop s JOIN delivery_trip t
   ON t.installation_id=s.installation_id AND t.branch_id=s.branch_id AND t.id=s.trip_id
  WHERE s.installation_id=OLD.installation_id AND s.branch_id=OLD.branch_id
   AND s.order_id=OLD.id AND t.status='LOCKED'
 ) THEN RAISE EXCEPTION 'Locked trip requires explicit reconciliation before order change'; END IF;
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER delivery_trip_locked_order_guard BEFORE UPDATE OR DELETE ON sales_order
 FOR EACH ROW EXECUTE FUNCTION erp_t5b_locked_order_guard();

CREATE FUNCTION erp_t5b_event_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Trip history is append only'; END;
$$;
CREATE TRIGGER delivery_trip_event_immutable BEFORE UPDATE OR DELETE ON delivery_trip_event
 FOR EACH ROW EXECUTE FUNCTION erp_t5b_event_immutable();
