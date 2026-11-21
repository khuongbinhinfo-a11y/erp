-- ERP Issue #7: installation + branch scoped catalog and versioned price records.
-- PostgreSQL NUMERIC stores money and UOM coefficients; never JS binary floating point.
CREATE TABLE catalog_customer (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  customer_group text CHECK (customer_group IS NULL OR length(trim(customer_group)) BETWEEN 1 AND 64),
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id,branch_id,id),
  UNIQUE (installation_id,branch_id,code),
  FOREIGN KEY (installation_id,branch_id) REFERENCES branch(installation_id,id)
);

CREATE TABLE catalog_supplier (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id,branch_id,id),
  UNIQUE (installation_id,branch_id,code),
  FOREIGN KEY (installation_id,branch_id) REFERENCES branch(installation_id,id)
);

CREATE TABLE catalog_product_group (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  PRIMARY KEY (installation_id,branch_id,id),
  UNIQUE (installation_id,branch_id,code),
  FOREIGN KEY (installation_id,branch_id) REFERENCES branch(installation_id,id)
);

CREATE TABLE catalog_product (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  sku text NOT NULL CHECK (sku ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  group_id uuid,
  base_unit text NOT NULL CHECK (length(trim(base_unit)) BETWEEN 1 AND 24),
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id,branch_id,id),
  UNIQUE (installation_id,branch_id,sku),
  FOREIGN KEY (installation_id,branch_id) REFERENCES branch(installation_id,id),
  FOREIGN KEY (installation_id,branch_id,group_id)
    REFERENCES catalog_product_group(installation_id,branch_id,id)
);

CREATE TABLE catalog_unit (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  product_id uuid NOT NULL,
  unit_code text NOT NULL CHECK (length(trim(unit_code)) BETWEEN 1 AND 24),
  to_base numeric(18,6) NOT NULL CHECK (to_base > 0),
  PRIMARY KEY (installation_id,branch_id,product_id,unit_code),
  FOREIGN KEY (installation_id,branch_id,product_id)
    REFERENCES catalog_product(installation_id,branch_id,id)
);

CREATE TABLE catalog_price_list (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  currency text NOT NULL DEFAULT 'VND' CHECK (currency='VND'),
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id,branch_id,id),
  UNIQUE (installation_id,branch_id,code),
  FOREIGN KEY (installation_id,branch_id) REFERENCES branch(installation_id,id)
);

-- Append-only price history: corrections are new effective entries, never overwrite old rates.
CREATE TABLE catalog_price_entry (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  price_list_id uuid NOT NULL,
  product_id uuid NOT NULL,
  amount numeric(18,4) NOT NULL CHECK (amount >= 0),
  discount_rate numeric(5,2) NOT NULL DEFAULT 0 CHECK (discount_rate BETWEEN 0 AND 100),
  effective_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id,branch_id,id),
  UNIQUE (installation_id,branch_id,price_list_id,product_id,effective_at),
  FOREIGN KEY (installation_id,branch_id,price_list_id)
    REFERENCES catalog_price_list(installation_id,branch_id,id),
  FOREIGN KEY (installation_id,branch_id,product_id)
    REFERENCES catalog_product(installation_id,branch_id,id)
);
CREATE INDEX catalog_price_effective_idx ON catalog_price_entry
  (installation_id,branch_id,price_list_id,product_id,effective_at DESC);
CREATE FUNCTION erp_guard_catalog_price_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'catalog_price_entry is append-only';
END;
$$;
CREATE TRIGGER catalog_price_history_append_only BEFORE UPDATE OR DELETE ON catalog_price_entry
  FOR EACH ROW EXECUTE FUNCTION erp_guard_catalog_price_history();
