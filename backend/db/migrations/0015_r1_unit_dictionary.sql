-- R1 Lô A follow-up: reusable, branch-scoped unit-of-measure dictionary.
-- Historical product UOM strings are preserved exactly. No invented conversion.
CREATE TABLE catalog_unit_definition (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK(length(trim(code)) BETWEEN 1 AND 24),
  name text NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 80),
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(installation_id,branch_id,id),
  UNIQUE(installation_id,branch_id,code),
  FOREIGN KEY(installation_id,branch_id) REFERENCES branch(installation_id,id)
);
CREATE INDEX catalog_uom_definition_search_idx ON catalog_unit_definition
  (installation_id,branch_id,active,code);

-- Import only labels that existed in the former schema; legacy names can be
-- corrected in the catalog without ever changing a posted product UOM code.
INSERT INTO catalog_unit_definition(installation_id,branch_id,code,name)
SELECT DISTINCT old.installation_id,old.branch_id,old.code,old.code
FROM (
  SELECT installation_id,branch_id,base_unit AS code FROM catalog_product
  UNION
  SELECT installation_id,branch_id,unit_code AS code FROM catalog_unit
) AS old
ON CONFLICT (installation_id,branch_id,code) DO NOTHING;
