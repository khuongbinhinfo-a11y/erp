-- Issue #6: explicit warehouse authorization, scoped by installation and branch.
-- Branch roles never implicitly receive warehouse access.
ALTER TABLE user_role ADD CONSTRAINT user_role_scope_key
  UNIQUE (installation_id, user_id, role_id, branch_id);
ALTER TABLE warehouse ADD CONSTRAINT warehouse_branch_scope_key
  UNIQUE (installation_id, branch_id, id);

CREATE TABLE user_role_warehouse (
  installation_id uuid NOT NULL,
  user_id uuid NOT NULL,
  role_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id, user_id, role_id, branch_id, warehouse_id),
  FOREIGN KEY (installation_id, user_id, role_id, branch_id)
    REFERENCES user_role (installation_id, user_id, role_id, branch_id)
    ON DELETE CASCADE,
  FOREIGN KEY (installation_id, branch_id, warehouse_id)
    REFERENCES warehouse (installation_id, branch_id, id)
);
CREATE INDEX user_role_warehouse_actor_idx
  ON user_role_warehouse (installation_id, user_id, branch_id, warehouse_id);
