-- IA-A: canonical staff is branch-owned, not part of delivery RBAC.
-- Additive after 0028; never rewrite staff, drivers, or historical documents.
ALTER TABLE org_employee ADD COLUMN department text;
ALTER TABLE org_employee ADD CONSTRAINT org_employee_department_length
 CHECK (department IS NULL OR length(department)<=100);
-- Give only existing owner branch roles the new rights; ordinary users stay deny-by-default.
INSERT INTO role_permission(installation_id,role_id,permission_code)
SELECT r.installation_id,r.id,p.permission
FROM app_role r CROSS JOIN
 (VALUES ('org.employees.read'),('org.employees.manage')) AS p(permission)
WHERE (r.code='PRIMARY_OWNER_MAIN' OR r.code LIKE 'OWNER_BRANCH_%')
 AND EXISTS(SELECT 1 FROM user_role u WHERE u.installation_id=r.installation_id
  AND u.role_id=r.id AND u.branch_id IS NOT NULL)
ON CONFLICT DO NOTHING;
