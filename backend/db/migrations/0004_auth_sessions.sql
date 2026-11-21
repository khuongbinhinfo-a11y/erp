-- Issue #6: installation-local opaque sessions; store token SHA-256 only.
CREATE TABLE app_session (
  token_hash char(64) PRIMARY KEY CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  installation_id uuid NOT NULL,
  user_id uuid NOT NULL,
  issued_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  FOREIGN KEY (installation_id, user_id) REFERENCES app_user(installation_id,id),
  CHECK (expires_at > issued_at),
  CHECK (revoked_at IS NULL OR revoked_at >= issued_at)
);
CREATE INDEX app_session_actor_expiry_idx
  ON app_session(installation_id,user_id,expires_at DESC);

-- No login names, passwords, raw tokens or IPs in authentication audit.
CREATE TABLE auth_event (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  installation_id uuid NOT NULL REFERENCES installation(id),
  actor_id uuid,
  request_id text NOT NULL CHECK (request_id ~ '^[A-Za-z0-9._:-]{1,80}$'),
  event_code text NOT NULL CHECK (event_code IN ('login.success','login.denied','session.revoked')),
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (installation_id,actor_id) REFERENCES app_user(installation_id,id),
  CHECK (event_code = 'login.denied' OR actor_id IS NOT NULL)
);
CREATE INDEX auth_event_installation_idx ON auth_event(installation_id,created_at DESC);
CREATE TRIGGER auth_event_append_only BEFORE UPDATE OR DELETE ON auth_event
  FOR EACH ROW EXECUTE FUNCTION erp_guard_audit_event();
