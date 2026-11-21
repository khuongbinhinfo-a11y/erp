-- Issue #5: atomic server-only mutation receipts and redacted append-only audit.
-- Apply exclusively via the reviewed versioned migration runner.
CREATE TABLE mutation_receipt (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  installation_id uuid NOT NULL REFERENCES installation(id),
  actor_id uuid NOT NULL,
  action_code text NOT NULL CHECK (length(action_code) BETWEEN 3 AND 96),
  idempotency_key text NOT NULL CHECK (idempotency_key ~ '^[A-Za-z0-9._:-]{8,128}$'),
  request_id text NOT NULL CHECK (length(request_id) BETWEEN 1 AND 80),
  expected_revision bigint NOT NULL CHECK (expected_revision >= 0),
  fingerprint char(64) NOT NULL CHECK (fingerprint ~ '^[a-f0-9]{64}$'),
  response_status integer,
  response_body jsonb,
  committed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (installation_id, actor_id) REFERENCES app_user (installation_id, id),
  UNIQUE (installation_id, actor_id, action_code, idempotency_key),
  CHECK (
    (response_status IS NULL AND response_body IS NULL AND committed_at IS NULL)
    OR (response_status BETWEEN 200 AND 299 AND response_body IS NOT NULL AND committed_at IS NOT NULL)
  )
);

CREATE TABLE audit_event (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  installation_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  receipt_id uuid NOT NULL UNIQUE REFERENCES mutation_receipt(id),
  request_id text NOT NULL CHECK (length(request_id) BETWEEN 1 AND 80),
  action_code text NOT NULL CHECK (length(action_code) BETWEEN 3 AND 96),
  expected_revision bigint NOT NULL CHECK (expected_revision >= 0),
  fingerprint char(64) NOT NULL,
  event_code text NOT NULL CHECK (event_code = 'mutation.committed'),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (installation_id, actor_id) REFERENCES app_user (installation_id, id)
);
CREATE INDEX audit_event_actor_time_idx ON audit_event(installation_id, actor_id, occurred_at DESC);

CREATE FUNCTION erp_guard_mutation_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'mutation_receipt cannot be deleted';
  END IF;
  IF OLD.committed_at IS NOT NULL OR NEW.committed_at IS NULL OR
     NEW.installation_id IS DISTINCT FROM OLD.installation_id OR
     NEW.actor_id IS DISTINCT FROM OLD.actor_id OR
     NEW.action_code IS DISTINCT FROM OLD.action_code OR
     NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key OR
     NEW.request_id IS DISTINCT FROM OLD.request_id OR
     NEW.expected_revision IS DISTINCT FROM OLD.expected_revision OR
     NEW.fingerprint IS DISTINCT FROM OLD.fingerprint THEN
    RAISE EXCEPTION 'mutation_receipt cannot be rewritten';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER mutation_receipt_write_once
  BEFORE UPDATE OR DELETE ON mutation_receipt
  FOR EACH ROW EXECUTE FUNCTION erp_guard_mutation_receipt();

CREATE FUNCTION erp_guard_audit_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_event is append-only';
END;
$$;
CREATE TRIGGER audit_event_append_only
  BEFORE UPDATE OR DELETE ON audit_event
  FOR EACH ROW EXECUTE FUNCTION erp_guard_audit_event();
