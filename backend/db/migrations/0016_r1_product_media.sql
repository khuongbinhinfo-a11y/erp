-- R1 media: immutable object identity; uploads are private R2, metadata here.
CREATE TABLE catalog_product_media(
 installation_id uuid NOT NULL,
 branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 product_id uuid NOT NULL,
 object_key text NOT NULL CHECK(length(object_key) BETWEEN 1 AND 255),
 mime_type text NOT NULL CHECK(mime_type IN ('image/jpeg','image/png','image/webp')),
 byte_length integer NOT NULL CHECK(byte_length BETWEEN 1 AND 5242880),
 etag text NOT NULL CHECK(length(etag) BETWEEN 1 AND 160),
 is_primary boolean NOT NULL DEFAULT false,
 active boolean NOT NULL DEFAULT true,
 revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 created_by uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,object_key),
 FOREIGN KEY(installation_id,branch_id,product_id) REFERENCES
   catalog_product(installation_id,branch_id,id),
 FOREIGN KEY(installation_id,created_by) REFERENCES app_user(installation_id,id)
);
CREATE UNIQUE INDEX catalog_product_media_one_primary ON catalog_product_media
 (installation_id,branch_id,product_id) WHERE active AND is_primary;
CREATE INDEX catalog_product_media_product_idx ON catalog_product_media
 (installation_id,branch_id,product_id,active,created_at DESC);
-- Posted product links and image content cannot be retargeted or deleted.
CREATE FUNCTION erp_product_media_identity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Product media is lifecycle-only'; END IF;
 IF ROW(NEW.installation_id,NEW.branch_id,NEW.id,NEW.product_id,
        NEW.object_key,NEW.mime_type,NEW.byte_length,NEW.etag,NEW.created_by)
    IS DISTINCT FROM
    ROW(OLD.installation_id,OLD.branch_id,OLD.id,OLD.product_id,
        OLD.object_key,OLD.mime_type,OLD.byte_length,OLD.etag,OLD.created_by)
 THEN RAISE EXCEPTION 'Product media identity is immutable'; END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER erp_product_media_identity_guard_trg
 BEFORE UPDATE OR DELETE ON catalog_product_media
 FOR EACH ROW EXECUTE FUNCTION erp_product_media_identity_guard();
