import type { Pool } from "pg";
import { hashPassword } from "./auth.ts";
import { PERMISSIONS } from "./rbac.ts";

type BootstrapInput = { code: string; displayName: string; adminLogin: string; adminPassword: string };
type BootstrapResult = { installationId: string; actorId: string; branchId: string; warehouseId: string };

const LOGIN = /^[a-z][a-z0-9._-]{2,79}$/;
const CODE = /^[a-z][a-z0-9._-]{1,63}$/;

/**
 * Run ONLY on an empty, independently provisioned installation DB, after its
 * approved migration. Not a public HTTP endpoint and never called at server startup.
 * One advisory lock prevents concurrent first-admin creation.
 */
export async function bootstrapInstallation(pool: Pool, input: BootstrapInput): Promise<BootstrapResult> {
  if (!CODE.test(input.code) || !LOGIN.test(input.adminLogin) ||
      input.displayName.trim().length < 2 || input.displayName.length > 120) {
    throw new Error("INVALID_BOOTSTRAP_INPUT");
  }
  const passwordHash = await hashPassword(input.adminPassword);
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await client.query("SELECT pg_advisory_xact_lock(2026,601)");
    const used = await client.query<{count: string}>("SELECT count(*) FROM installation");
    if (used.rows[0]?.count !== "0") throw new Error("INSTALLATION_ALREADY_INITIALIZED");
    const tenant = await client.query<{id: string}>(
      "INSERT INTO installation(code,display_name) VALUES($1,$2) RETURNING id",
      [input.code,input.displayName.trim()],
    );
    const installationId = tenant.rows[0]!.id;
    const branch = await client.query<{id: string}>(
      "INSERT INTO branch(installation_id,code,name) VALUES($1,'MAIN','Chi nhánh chính') RETURNING id",
      [installationId],
    );
    const branchId = branch.rows[0]!.id;
    const warehouse = await client.query<{id: string}>(
      "INSERT INTO warehouse(installation_id,branch_id,code,name) VALUES($1,$2,'MAIN','Kho chính') RETURNING id",
      [installationId,branchId],
    );
    const warehouseId = warehouse.rows[0]!.id;
    const user = await client.query<{id: string}>(
      "INSERT INTO app_user(installation_id,login_name,password_hash) VALUES($1,$2,$3) RETURNING id",
      [installationId,input.adminLogin,passwordHash],
    );
    const actorId = user.rows[0]!.id;
    for (const scope of ["installation","branch"] as const) {
      const role = await client.query<{id: string}>(
        "INSERT INTO app_role(installation_id,code) VALUES($1,$2) RETURNING id",
        [installationId,scope === "installation" ? "PRIMARY_OWNER" : "PRIMARY_OWNER_MAIN"],
      );
      const roleId = role.rows[0]!.id;
      await client.query(
        "INSERT INTO user_role(installation_id,user_id,role_id,branch_id) VALUES($1,$2,$3,$4)",
        [installationId,actorId,roleId,scope === "installation" ? null : branchId],
      );
      for (const [permission,grantScope] of Object.entries(PERMISSIONS)) {
        if (grantScope === "installation" && scope !== "installation") continue;
        if (grantScope !== "installation" && scope !== "branch") continue;
        await client.query(
          "INSERT INTO role_permission(installation_id,role_id,permission_code) VALUES($1,$2,$3)",
          [installationId,roleId,permission],
        );
      }
      if (scope === "branch") {
        await client.query(
          "INSERT INTO user_role_warehouse(installation_id,user_id,role_id,branch_id,warehouse_id) VALUES($1,$2,$3,$4,$5)",
          [installationId,actorId,roleId,branchId,warehouseId],
        );
      }
    }
    await client.query("COMMIT");
    return {installationId,actorId,branchId,warehouseId};
  } catch (error) {
    await client.query("ROLLBACK").catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}
