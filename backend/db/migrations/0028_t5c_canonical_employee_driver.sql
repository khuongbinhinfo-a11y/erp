-- T5-C foundation: canonical branch employees and driver linkage.
-- Additive only. Existing 0027 drivers keep their historical row unchanged
-- and remain ineligible for new trip plan/lock until linked explicitly.
CREATE TABLE org_employee (
 installation_id uuid NOT NULL,
 branch_id uuid NOT NULL,
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 code text NOT NULL,
 full_name text NOT NULL,
 job_title text,
 phone text,
 active boolean NOT NULL DEFAULT true,
 revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 account_user_id uuid,
 created_by uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(installation_id,branch_id,id),
 UNIQUE(installation_id,branch_id,code),
 CHECK(length(btrim(code)) BETWEEN 1 AND 48),
 CHECK(length(btrim(full_name)) BETWEEN 2 AND 120),
 CHECK(job_title IS NULL OR length(job_title)<=100),
 CHECK(phone IS NULL OR phone ~ '^\+?[0-9]{9,15}$'),
 FOREIGN KEY(installation_id,branch_id) REFERENCES branch(installation_id,id),
 FOREIGN KEY(installation_id,account_user_id) REFERENCES app_user(installation_id,id),
 FOREIGN KEY(installation_id,created_by) REFERENCES app_user(installation_id,id)
);
CREATE INDEX org_employee_active_branch_idx ON org_employee
 (installation_id,branch_id,active,code);
CREATE UNIQUE INDEX org_employee_account_unique ON org_employee(installation_id,account_user_id)
 WHERE account_user_id IS NOT NULL;
CREATE FUNCTION erp_employee_immutable_identity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Employee history cannot be deleted'; END IF;
 IF (NEW.installation_id,NEW.branch_id,NEW.id,NEW.code,NEW.created_by,NEW.created_at)
   IS DISTINCT FROM
    (OLD.installation_id,OLD.branch_id,OLD.id,OLD.code,OLD.created_by,OLD.created_at)
 THEN RAISE EXCEPTION 'Employee identity is immutable'; END IF;
 IF NEW.revision<>OLD.revision+1 THEN RAISE EXCEPTION 'Employee revision required'; END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER org_employee_identity_guard BEFORE UPDATE OR DELETE ON org_employee
 FOR EACH ROW EXECUTE FUNCTION erp_employee_immutable_identity();

ALTER TABLE delivery_driver ADD COLUMN employee_id uuid;
ALTER TABLE delivery_driver ADD CONSTRAINT driver_canonical_employee_fk
 FOREIGN KEY(installation_id,branch_id,employee_id)
 REFERENCES org_employee(installation_id,branch_id,id);
CREATE UNIQUE INDEX delivery_driver_one_active_employee ON delivery_driver
 (installation_id,employee_id) WHERE employee_id IS NOT NULL AND active;
CREATE FUNCTION erp_t5c_driver_employee_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='INSERT' AND NEW.employee_id IS NULL
 THEN RAISE EXCEPTION 'New drivers require a canonical employee'; END IF;
 IF TG_OP='UPDATE' THEN
   IF OLD.employee_id IS NOT NULL AND NEW.employee_id IS DISTINCT FROM OLD.employee_id
   THEN RAISE EXCEPTION 'Driver employee link is immutable'; END IF;
   IF OLD.employee_id IS NULL AND NEW.employee_id IS NULL AND NEW.active
   THEN RAISE EXCEPTION 'Unlinked legacy driver must be linked before reactivation'; END IF;
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER delivery_driver_employee_guard BEFORE INSERT OR UPDATE ON delivery_driver
 FOR EACH ROW EXECUTE FUNCTION erp_t5c_driver_employee_guard();
