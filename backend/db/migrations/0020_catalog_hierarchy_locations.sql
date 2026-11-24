-- 0020: configurable brand > product group > nested category taxonomy, and
-- multiple customer delivery locations. Additive; no historical document rewrite.
CREATE TABLE catalog_brand (
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
ALTER TABLE catalog_product_group ADD COLUMN brand_id uuid;
ALTER TABLE catalog_product_group ADD CONSTRAINT catalog_group_brand_fk
  FOREIGN KEY (installation_id,branch_id,brand_id)
  REFERENCES catalog_brand(installation_id,branch_id,id);

CREATE TABLE catalog_product_category (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL,
  parent_id uuid,
  code text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id,branch_id,id),
  UNIQUE (installation_id,branch_id,code),
  UNIQUE (installation_id,branch_id,group_id,id),
  CHECK (parent_id IS NULL OR parent_id<>id),
  FOREIGN KEY (installation_id,branch_id,group_id)
    REFERENCES catalog_product_group(installation_id,branch_id,id),
  FOREIGN KEY (installation_id,branch_id,group_id,parent_id)
    REFERENCES catalog_product_category(installation_id,branch_id,group_id,id)
);
CREATE INDEX catalog_category_parent_idx ON catalog_product_category
  (installation_id,branch_id,group_id,parent_id,code);

-- Serialize tree edits under one group; reject cycles, including concurrent re-parenting.
CREATE FUNCTION erp_validate_catalog_category_tree() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(
    NEW.installation_id::text||':'||NEW.branch_id::text||':'||NEW.group_id::text,0));
  IF NEW.parent_id IS NOT NULL AND EXISTS (
    WITH RECURSIVE ancestors(id,parent_id) AS (
      SELECT id,parent_id FROM catalog_product_category
       WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
         AND group_id=NEW.group_id AND id=NEW.parent_id
      UNION ALL
      SELECT c.id,c.parent_id FROM catalog_product_category c
       JOIN ancestors a ON c.id=a.parent_id
      WHERE c.installation_id=NEW.installation_id AND c.branch_id=NEW.branch_id
        AND c.group_id=NEW.group_id
    )
    SELECT 1 FROM ancestors WHERE id=NEW.id
  ) THEN
    RAISE EXCEPTION 'catalog category cycle' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER catalog_category_tree_guard
  BEFORE INSERT OR UPDATE OF parent_id,group_id
  ON catalog_product_category FOR EACH ROW
  EXECUTE FUNCTION erp_validate_catalog_category_tree();

ALTER TABLE catalog_product ADD COLUMN category_id uuid;
ALTER TABLE catalog_product ADD CONSTRAINT catalog_product_category_needs_group
  CHECK (category_id IS NULL OR group_id IS NOT NULL);
ALTER TABLE catalog_product ADD CONSTRAINT catalog_product_category_fk
  FOREIGN KEY (installation_id,branch_id,group_id,category_id)
  REFERENCES catalog_product_category(installation_id,branch_id,group_id,id);
CREATE INDEX catalog_product_category_idx ON catalog_product
  (installation_id,branch_id,group_id,category_id);

CREATE TABLE catalog_customer_location (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL,
  code text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  address text NOT NULL CHECK (length(trim(address)) BETWEEN 1 AND 500),
  phone text CHECK (phone IS NULL OR phone ~ '^\\+?[0-9]{9,15}$'),
  is_default boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id,branch_id,id),
  UNIQUE (installation_id,branch_id,customer_id,code),
  FOREIGN KEY (installation_id,branch_id,customer_id)
    REFERENCES catalog_customer(installation_id,branch_id,id)
);
CREATE UNIQUE INDEX catalog_customer_location_one_default
  ON catalog_customer_location(installation_id,branch_id,customer_id)
  WHERE active AND is_default;
CREATE INDEX catalog_customer_location_customer_idx
  ON catalog_customer_location(installation_id,branch_id,customer_id,active,code);
