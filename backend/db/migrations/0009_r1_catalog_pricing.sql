-- R1/P0: canonical sellable SKU and customer/channel-aware exact pricing.
-- Existing catalog prices and B1 confirmed commercial snapshots are not changed.
ALTER TABLE catalog_customer
  ADD COLUMN phone text CHECK (phone IS NULL OR phone ~ '^\+?[0-9]{9,15}$'),
  ADD COLUMN delivery_address text CHECK (delivery_address IS NULL OR length(delivery_address) BETWEEN 1 AND 500),
  ADD COLUMN payment_terms_days integer NOT NULL DEFAULT 0 CHECK (payment_terms_days BETWEEN 0 AND 365);
CREATE UNIQUE INDEX catalog_customer_phone_unique ON catalog_customer
  (installation_id,branch_id,phone) WHERE phone IS NOT NULL AND active;

CREATE TABLE catalog_sell_sku (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL,
  sku text NOT NULL CHECK (sku ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  unit_code text NOT NULL CHECK (length(trim(unit_code)) BETWEEN 1 AND 24),
  conversion_to_base numeric(20,6) NOT NULL CHECK (conversion_to_base > 0),
  is_base boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(installation_id,branch_id,id),
  UNIQUE(installation_id,branch_id,sku),
  UNIQUE(installation_id,branch_id,product_id,unit_code),
  FOREIGN KEY(installation_id,branch_id,product_id) REFERENCES
    catalog_product(installation_id,branch_id,id),
  FOREIGN KEY(installation_id,branch_id,product_id,unit_code) REFERENCES
    catalog_unit(installation_id,branch_id,product_id,unit_code),
  CHECK (NOT is_base OR conversion_to_base=1)
);
CREATE UNIQUE INDEX catalog_one_base_sell_sku ON catalog_sell_sku
  (installation_id,branch_id,product_id) WHERE is_base=true;
CREATE INDEX catalog_sell_sku_product_idx ON catalog_sell_sku
  (installation_id,branch_id,product_id,active);

-- Backfill existing product's explicitly defined inventory-base unit only.
-- Never invent carton SKU names from a suffix or conversion factor.
INSERT INTO catalog_sell_sku
  (installation_id,branch_id,product_id,sku,unit_code,conversion_to_base,is_base,active)
SELECT p.installation_id,p.branch_id,p.id,p.sku,p.base_unit,u.to_base,true,p.active
FROM catalog_product p
JOIN catalog_unit u ON u.installation_id=p.installation_id AND
 u.branch_id=p.branch_id AND u.product_id=p.id AND u.unit_code=p.base_unit
WHERE u.to_base=1;

CREATE FUNCTION erp_r1_sku_identity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE factor numeric;
DECLARE parent_sku text;
DECLARE parent_unit text;
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'Catalog SKU is lifecycle-only';
  END IF;
  IF TG_OP='UPDATE' THEN
    IF (NEW.installation_id,NEW.branch_id,NEW.id,NEW.product_id,NEW.sku,
        NEW.unit_code,NEW.conversion_to_base,NEW.is_base)
       IS DISTINCT FROM
       (OLD.installation_id,OLD.branch_id,OLD.id,OLD.product_id,OLD.sku,
        OLD.unit_code,OLD.conversion_to_base,OLD.is_base) THEN
      RAISE EXCEPTION 'SKU identity and conversion are immutable';
    END IF;
    RETURN NEW;
  END IF;
  SELECT to_base INTO factor FROM catalog_unit
   WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
     AND product_id=NEW.product_id AND unit_code=NEW.unit_code FOR SHARE;
  IF factor IS NULL OR NEW.conversion_to_base<>factor THEN
    RAISE EXCEPTION 'SKU conversion differs from canonical product unit';
  END IF;
  IF NEW.is_base THEN
    SELECT sku,base_unit INTO parent_sku,parent_unit FROM catalog_product
     WHERE installation_id=NEW.installation_id AND branch_id=NEW.branch_id
       AND id=NEW.product_id FOR SHARE;
    IF NEW.sku<>parent_sku OR NEW.unit_code<>parent_unit THEN
      RAISE EXCEPTION 'Base sell SKU must equal canonical product inventory base SKU';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER catalog_sell_sku_guard BEFORE INSERT OR UPDATE OR DELETE ON catalog_sell_sku
  FOR EACH ROW EXECUTE FUNCTION erp_r1_sku_identity_guard();

CREATE FUNCTION erp_r1_canonical_unit_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM catalog_sell_sku s WHERE
      s.installation_id=OLD.installation_id AND s.branch_id=OLD.branch_id AND
      s.product_id=OLD.product_id AND s.unit_code=OLD.unit_code
  ) THEN
    RAISE EXCEPTION 'A sellable SKU references this immutable conversion';
  END IF;
  RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER catalog_unit_sku_immutability BEFORE UPDATE OR DELETE ON catalog_unit
  FOR EACH ROW EXECUTE FUNCTION erp_r1_canonical_unit_guard();

CREATE TABLE catalog_sku_barcode (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  sell_sku_id uuid NOT NULL,
  barcode text NOT NULL CHECK (barcode ~ '^[A-Za-z0-9._-]{4,64}$'),
  is_primary boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(installation_id,branch_id,id),
  UNIQUE(installation_id,branch_id,barcode),
  FOREIGN KEY(installation_id,branch_id,sell_sku_id)
   REFERENCES catalog_sell_sku(installation_id,branch_id,id)
);
CREATE UNIQUE INDEX catalog_sku_one_primary_barcode ON catalog_sku_barcode
  (installation_id,branch_id,sell_sku_id) WHERE active AND is_primary;

CREATE TABLE catalog_sales_channel (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  active boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(installation_id,branch_id,id),
  UNIQUE(installation_id,branch_id,code),
  FOREIGN KEY(installation_id,branch_id)
   REFERENCES branch(installation_id,id)
);

-- A rule is an immutable fact. Supersede by a new effective rule, not rewriting history.
-- BASE is a fixed price for one exact sell SKU, independent of unit conversion.
CREATE TABLE catalog_sku_price_rule (
  installation_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  price_list_id uuid NOT NULL,
  sell_sku_id uuid NOT NULL,
  scope_kind text NOT NULL CHECK (scope_kind IN
    ('BASE','CHANNEL','CUSTOMER_GROUP','CUSTOMER','PROMOTION')),
  channel_id uuid,
  customer_id uuid,
  customer_group text CHECK (customer_group IS NULL OR
    length(trim(customer_group)) BETWEEN 1 AND 64),
  adjustment text NOT NULL CHECK (adjustment IN
    ('FIXED_PRICE','PERCENT_DISCOUNT','AMOUNT_DISCOUNT','PERCENT_MARKUP','AMOUNT_MARKUP')),
  amount numeric(18,4) NOT NULL CHECK (amount>=0),
  priority integer NOT NULL DEFAULT 0 CHECK (priority BETWEEN -100000 AND 100000),
  stacking text NOT NULL DEFAULT 'EXCLUSIVE' CHECK (stacking IN ('EXCLUSIVE','STACKABLE')),
  stop_processing boolean NOT NULL DEFAULT false,
  min_quantity numeric(18,3) NOT NULL DEFAULT 1 CHECK (min_quantity > 0),
  effective_from timestamptz NOT NULL,
  effective_to timestamptz CHECK (effective_to IS NULL OR effective_to>effective_from),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(installation_id,branch_id,id),
  FOREIGN KEY(installation_id,branch_id,price_list_id)
    REFERENCES catalog_price_list(installation_id,branch_id,id),
  FOREIGN KEY(installation_id,branch_id,sell_sku_id)
    REFERENCES catalog_sell_sku(installation_id,branch_id,id),
  FOREIGN KEY(installation_id,branch_id,channel_id)
    REFERENCES catalog_sales_channel(installation_id,branch_id,id),
  FOREIGN KEY(installation_id,branch_id,customer_id)
    REFERENCES catalog_customer(installation_id,branch_id,id),
  CHECK (
    (scope_kind='BASE' AND adjustment='FIXED_PRICE' AND
      channel_id IS NULL AND customer_id IS NULL AND customer_group IS NULL)
    OR (scope_kind='CHANNEL' AND channel_id IS NOT NULL AND
      customer_id IS NULL AND customer_group IS NULL)
    OR (scope_kind='CUSTOMER_GROUP' AND customer_group IS NOT NULL AND customer_id IS NULL)
    OR (scope_kind='CUSTOMER' AND customer_id IS NOT NULL)
    OR (scope_kind='PROMOTION')
  ),
  CHECK (adjustment NOT IN ('PERCENT_DISCOUNT','PERCENT_MARKUP') OR amount<=100)
);
CREATE INDEX catalog_sku_price_lookup_idx ON catalog_sku_price_rule
  (installation_id,branch_id,price_list_id,sell_sku_id,priority DESC,effective_from DESC);
CREATE FUNCTION erp_r1_price_rule_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'SKU pricing history is immutable; create a new effective rule';
END;
$$;
CREATE TRIGGER catalog_sku_price_immutable BEFORE UPDATE OR DELETE ON catalog_sku_price_rule
 FOR EACH ROW EXECUTE FUNCTION erp_r1_price_rule_guard();
