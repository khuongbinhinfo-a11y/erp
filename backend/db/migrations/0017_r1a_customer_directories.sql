-- R1-A: canonical customer group and commercial region directories.
-- Keep legacy customer_group as a compatibility/snapshot field for existing price
-- rules; never destroy old labels or rewrite historical posted documents.
CREATE TABLE catalog_customer_group (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id, branch_id, id),
  UNIQUE (installation_id, branch_id, code),
  FOREIGN KEY (installation_id, branch_id) REFERENCES branch(installation_id,id)
);
CREATE INDEX catalog_customer_group_search_idx
 ON catalog_customer_group(installation_id,branch_id,active,code);

CREATE TABLE catalog_customer_region (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (installation_id, branch_id, id),
  UNIQUE (installation_id, branch_id, code),
  FOREIGN KEY (installation_id, branch_id) REFERENCES branch(installation_id,id)
);
CREATE INDEX catalog_customer_region_search_idx
 ON catalog_customer_region(installation_id,branch_id,active,code);

ALTER TABLE catalog_customer
 ADD COLUMN customer_group_id uuid,
 ADD COLUMN customer_region_id uuid,
 ADD CONSTRAINT catalog_customer_group_fk
   FOREIGN KEY(installation_id,branch_id,customer_group_id)
   REFERENCES catalog_customer_group(installation_id,branch_id,id),
 ADD CONSTRAINT catalog_customer_region_fk
   FOREIGN KEY(installation_id,branch_id,customer_region_id)
   REFERENCES catalog_customer_region(installation_id,branch_id,id);
CREATE INDEX catalog_customer_group_ref_idx ON catalog_customer
 (installation_id,branch_id,customer_group_id) WHERE customer_group_id IS NOT NULL;
CREATE INDEX catalog_customer_region_ref_idx ON catalog_customer
 (installation_id,branch_id,customer_region_id) WHERE customer_region_id IS NOT NULL;

-- Existing free-text groups are normalized to a reusable directory using
-- original valid codes when possible. Unicode/space-containing labels receive
-- a deterministic hash-based key. The original label is retained unchanged.
-- No speculative region assignment; region remains NULL until categorized.
WITH legacy AS (
 SELECT DISTINCT installation_id,branch_id,trim(customer_group) AS label
 FROM catalog_customer
 WHERE customer_group IS NOT NULL AND length(trim(customer_group))>0
), normalized AS (
 SELECT installation_id,branch_id,label,
 CASE WHEN label ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'
      THEN label ELSE 'LEGACY-' || substr(md5(label),1,32) END AS code
 FROM legacy
)
INSERT INTO catalog_customer_group(installation_id,branch_id,code,name)
 SELECT installation_id,branch_id,code,label FROM normalized
 ON CONFLICT (installation_id,branch_id,code) DO NOTHING;

UPDATE catalog_customer c
 SET customer_group_id=g.id
 FROM catalog_customer_group g
 WHERE c.installation_id=g.installation_id AND c.branch_id=g.branch_id
   AND c.customer_group IS NOT NULL
   AND g.code=CASE
       WHEN trim(c.customer_group) ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'
       THEN trim(c.customer_group)
       ELSE 'LEGACY-' || substr(md5(trim(c.customer_group)),1,32) END;

-- Abort rather than silently losing an existing group during conversion.
DO $$
BEGIN
 IF EXISTS (
   SELECT 1 FROM catalog_customer
   WHERE customer_group IS NOT NULL AND length(trim(customer_group))>0
     AND customer_group_id IS NULL
 ) THEN
   RAISE EXCEPTION 'R1A_LEGACY_CUSTOMER_GROUP_BACKFILL_INCOMPLETE';
 END IF;
END; $$;
