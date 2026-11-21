import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { Pool, type PoolClient } from "pg";
import { canDelegatePermission, hasPermission, type AuthorizationRequest } from "./rbac.ts";

test("RBAC fails closed for unsupported permission, UUID and missing/invalid scope", async () => {
  const db = { query: () => { throw new Error("invalid request must not reach DB"); } } as unknown as PoolClient;
  const request: AuthorizationRequest = {
    installationId: randomUUID(), actorId: randomUUID(),
    permission: "inventory.read",
  };
  assert.equal(await hasPermission(db, request), false);
  assert.equal(await hasPermission(db, { ...request, permission: "invented.superuser" }), false);
  assert.equal(await hasPermission(db, { ...request, permission: "identity.roles.manage", branchId: randomUUID() }), false);
  assert.equal(await hasPermission(db, { ...request, permission: "catalog.read", warehouseId: randomUUID() }), false);
  assert.equal(await hasPermission(db, { ...request, actorId: "invalid" }), false);
});

test("PostgreSQL enforces tenant/branch/warehouse isolation, revoke, disabled user and delegation", {
  skip: !process.env.DATABASE_URL,
}, async () => {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 4 });
  try {
    const installation = async () => (await pool.query<{ id: string }>(
      "INSERT INTO installation(code,display_name) VALUES($1,'Synthetic RBAC CI') RETURNING id",
      ["ci_" + randomUUID().slice(0, 12)],
    )).rows[0]!.id;
    const installationId = await installation();
    const otherInstallationId = await installation();
    const actorId = (await pool.query<{ id: string }>(
      "INSERT INTO app_user(installation_id,login_name,password_hash) VALUES($1,$2,$3) RETURNING id",
      [installationId,"ci_" + randomUUID().slice(0, 12),"h".repeat(64)],
    )).rows[0]!.id;
    const branch = async () => (await pool.query<{ id: string }>(
      "INSERT INTO branch(installation_id,code,name) VALUES($1,$2,'Synthetic') RETURNING id",
      [installationId,"b_" + randomUUID().slice(0, 10)],
    )).rows[0]!.id;
    const branchId = await branch();
    const otherBranchId = await branch();
    const warehouse = async (bid: string) => (await pool.query<{ id: string }>(
      "INSERT INTO warehouse(installation_id,branch_id,code,name) VALUES($1,$2,$3,'Synthetic') RETURNING id",
      [installationId,bid,"w_" + randomUUID().slice(0, 10)],
    )).rows[0]!.id;
    const warehouseId = await warehouse(branchId);
    const otherWarehouseId = await warehouse(otherBranchId);
    const role = async (code: string) => (await pool.query<{ id: string }>(
      "INSERT INTO app_role(installation_id,code) VALUES($1,$2) RETURNING id",
      [installationId,code],
    )).rows[0]!.id;
    const globalRole = await role("manager");
    const branchRole = await role("stock");
    const client = await pool.connect();
    try {
      const scope: AuthorizationRequest = {
        installationId,actorId,permission:"inventory.read",branchId,warehouseId,
      };
      assert.equal(await hasPermission(client,scope),false,"deny without explicit role");
      await client.query("INSERT INTO user_role(installation_id,user_id,role_id,branch_id) VALUES($1,$2,$3,NULL)",
        [installationId,actorId,globalRole]);
      await client.query("INSERT INTO user_role(installation_id,user_id,role_id,branch_id) VALUES($1,$2,$3,$4)",
        [installationId,actorId,branchRole,branchId]);
      await client.query("INSERT INTO role_permission(installation_id,role_id,permission_code) VALUES($1,$2,$3)",
        [installationId,globalRole,"identity.roles.manage"]);
      await client.query("INSERT INTO role_permission(installation_id,role_id,permission_code) VALUES($1,$2,$3)",
        [installationId,branchRole,"inventory.read"]);
      assert.equal(await hasPermission(client,scope),false,"branch grant cannot imply warehouse access");
      await assert.rejects(
        client.query("INSERT INTO user_role_warehouse(installation_id,user_id,role_id,branch_id,warehouse_id) VALUES($1,$2,$3,$4,$5)",
          [installationId,actorId,branchRole,branchId,otherWarehouseId]),
        (error: unknown) => (error as { code?: string }).code === "23503",
        "foreign key prevents cross-branch grants",
      );
      await client.query("INSERT INTO user_role_warehouse(installation_id,user_id,role_id,branch_id,warehouse_id) VALUES($1,$2,$3,$4,$5)",
        [installationId,actorId,branchRole,branchId,warehouseId]);
      assert.equal(await hasPermission(client,scope),true);
      assert.equal(await hasPermission(client,{...scope,installationId:otherInstallationId}),false);
      assert.equal(await hasPermission(client,{...scope,branchId:otherBranchId}),false);
      assert.equal(await hasPermission(client,{...scope,warehouseId:otherWarehouseId}),false);
      assert.equal(await hasPermission(client,{...scope,permission:"inventory.post"}),false);
      assert.equal(await canDelegatePermission(client,scope),true);
      assert.equal(await canDelegatePermission(client,{...scope,permission:"inventory.post"}),false);
      assert.equal(await canDelegatePermission(client,{...scope,warehouseId:otherWarehouseId}),false);
      await client.query("DELETE FROM user_role_warehouse WHERE installation_id=$1 AND user_id=$2",
        [installationId,actorId]);
      assert.equal(await hasPermission(client,scope),false,"revocation applies immediately");
      await client.query("INSERT INTO user_role_warehouse(installation_id,user_id,role_id,branch_id,warehouse_id) VALUES($1,$2,$3,$4,$5)",
        [installationId,actorId,branchRole,branchId,warehouseId]);
      await client.query("UPDATE app_user SET disabled=true WHERE installation_id=$1 AND id=$2",
        [installationId,actorId]);
      assert.equal(await hasPermission(client,scope),false,"disabled actor always denied");
      assert.equal(await canDelegatePermission(client,scope),false);
    } finally {
      client.release();
    }
  } finally {
    await pool.end();
  }
});
