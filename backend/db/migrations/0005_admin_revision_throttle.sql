-- P0.1–P0.3: durable login throttling and optimistic revisions; CI first.
ALTER TABLE app_user ADD COLUMN revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0);

-- Stores only keyed login hashes, never login text, IP address or passwords.
CREATE TABLE auth_login_throttle (
  installation_id uuid NOT NULL REFERENCES installation(id),
  login_digest char(64) NOT NULL CHECK (login_digest ~ '^[a-f0-9]{64}$'),
  failed_count integer NOT NULL DEFAULT 0 CHECK (failed_count BETWEEN 0 AND 1000),
  window_started_at timestamptz NOT NULL DEFAULT now(),
  blocked_until timestamptz,
  PRIMARY KEY (installation_id, login_digest)
);
