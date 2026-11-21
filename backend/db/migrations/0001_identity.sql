-- ERP installation-local schema, PostgreSQL 16+
-- Apply via reviewed versioned migration pipeline; never execute ad hoc on production.
CREATE TABLE installation (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE CHECK (length(code) BETWEEN 2 AND 80),
  display_name text NOT NULL CHECK (length(trim(display_name)) > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE branch (
  installation_id uuid NOT NULL REFERENCES installation(id),
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (length(code) BETWEEN 1 AND 64),
  name text NOT NULL CHECK (length(trim(name)) > 0),
  PRIMARY KEY (installation_id, id),
  UNIQUE (installation_id, code)
);

CREATE TABLE warehouse (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (length(code) BETWEEN 1 AND 64),
  name text NOT NULL CHECK (length(trim(name)) > 0),
  PRIMARY KEY (installation_id, id),
  UNIQUE (installation_id, code),
  FOREIGN KEY (installation_id, branch_id) REFERENCES branch(installation_id, id)
);

CREATE TABLE app_user (
  installation_id uuid NOT NULL REFERENCES installation(id),
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  login_name text NOT NULL CHECK (length(login_name) BETWEEN 3 AND 120),
  password_hash text NOT NULL CHECK (length(password_hash) >= 32),
  disabled boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id, id),
  UNIQUE (installation_id, login_name)
);

CREATE TABLE app_role (
  installation_id uuid NOT NULL REFERENCES installation(id),
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (length(code) BETWEEN 2 AND 80),
  PRIMARY KEY (installation_id, id),
  UNIQUE (installation_id, code)
);

CREATE TABLE role_permission (
  installation_id uuid NOT NULL,
  role_id uuid NOT NULL,
  permission_code text NOT NULL CHECK (length(permission_code) BETWEEN 3 AND 100),
  PRIMARY KEY (installation_id, role_id, permission_code),
  FOREIGN KEY (installation_id, role_id) REFERENCES app_role(installation_id, id)
);

CREATE TABLE user_role (
  installation_id uuid NOT NULL,
  user_id uuid NOT NULL,
  role_id uuid NOT NULL,
  branch_id uuid,
  PRIMARY KEY (installation_id, user_id, role_id),
  FOREIGN KEY (installation_id, user_id) REFERENCES app_user(installation_id, id),
  FOREIGN KEY (installation_id, role_id) REFERENCES app_role(installation_id, id),
  FOREIGN KEY (installation_id, branch_id) REFERENCES branch(installation_id, id)
);

-- Deny-by-default: there are no implicit users, grants or global roles.
