import type { PoolClient } from "pg";

/** Server-side allowlist only. Any unknown permission is denied. */
export const PERMISSIONS = {
  "identity.users.read": "installation",
  "identity.users.manage": "installation",
  "identity.roles.manage": "installation",
  "org.employees.read": "branch",
  "org.employees.manage": "branch",
  "catalog.read": "branch",
  "catalog.write": "branch",
  "orders.read": "branch",
  "orders.create": "branch",
  "orders.update": "branch",
  "orders.price.override": "branch",
  "orders.discount.override": "branch",
  "orders.tax.override": "branch",
  "orders.confirm": "branch",
  "orders.amend": "branch",
  "orders.cancel": "branch",
  "inventory.read": "warehouse",
  "inventory.post": "warehouse",
  "inventory.negative.issue": "warehouse",
  "inventory.reserve": "warehouse",
  "inventory.policy.manage": "warehouse",
  "inventory.transfer.read": "warehouse",
  "inventory.transfer.create": "warehouse",
  "inventory.transfer.approve": "warehouse",
  "inventory.transfer.dispatch": "warehouse",
  "inventory.transfer.receive": "warehouse",
  "inventory.stocktake.read": "warehouse",
  "inventory.stocktake.create": "warehouse",
  "inventory.stocktake.count": "warehouse",
  "inventory.stocktake.submit": "warehouse",
  "inventory.stocktake.approve": "warehouse",
  "inventory.stocktake.post": "warehouse",
  "purchase.read": "branch",
  "purchase.create": "branch",
  "purchase.confirm": "branch",
  "purchase.receive": "warehouse",
  "finance.receivables.read": "branch",
  "finance.payments.record": "branch",
  "pos.shift": "branch",
  "pos.checkout": "branch",
  "pos.return": "branch",
  "delivery.read": "branch",
  "delivery.update": "branch",
  "delivery.execute": "branch",
  "delivery.cod.handover": "branch",
} as const;

export type Permission = keyof typeof PERMISSIONS;
export type AuthorizationRequest = {
  installationId: string;
  actorId: string;
  permission: string;
  branchId?: string;
  warehouseId?: string;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function validRequest(request: AuthorizationRequest): boolean {
  if (!UUID.test(request.installationId) || !UUID.test(request.actorId)) return false;
  if (!Object.prototype.hasOwnProperty.call(PERMISSIONS, request.permission)) return false;
  const scope = PERMISSIONS[request.permission as Permission];
  if (scope === "installation") return request.branchId === undefined && request.warehouseId === undefined;
  if (!request.branchId || !UUID.test(request.branchId)) return false;
  if (scope === "branch") return request.warehouseId === undefined;
  return typeof request.warehouseId === "string" && UUID.test(request.warehouseId);
}

/** Caller supplies the transaction client; auth is checked in the same transaction as writes. */
export async function hasPermission(client: PoolClient, request: AuthorizationRequest): Promise<boolean> {
  if (!validRequest(request)) return false;
  const record = await client.query<{ allowed: boolean }>(
    `SELECT EXISTS (
       SELECT 1 FROM app_user u
       JOIN user_role ur ON ur.installation_id = u.installation_id AND ur.user_id = u.id
       JOIN role_permission rp ON rp.installation_id = ur.installation_id AND rp.role_id = ur.role_id
       WHERE u.installation_id = $1::uuid AND u.id = $2::uuid
         AND u.disabled = FALSE AND rp.permission_code = $3
         AND (
           ($4::uuid IS NULL AND $5::uuid IS NULL AND ur.branch_id IS NULL)
           OR ($4::uuid IS NOT NULL AND $5::uuid IS NULL AND ur.branch_id = $4::uuid)
           OR ($4::uuid IS NOT NULL AND $5::uuid IS NOT NULL AND ur.branch_id = $4::uuid
             AND EXISTS (
               SELECT 1 FROM user_role_warehouse uw
               WHERE uw.installation_id = ur.installation_id AND uw.user_id = ur.user_id
                 AND uw.role_id = ur.role_id AND uw.branch_id = ur.branch_id
                 AND uw.warehouse_id = $5::uuid
             )
           )
         )
     ) AS allowed`,
    [request.installationId,request.actorId,request.permission,request.branchId ?? null,request.warehouseId ?? null],
  );
  return record.rows[0]?.allowed === true;
}

/** Delegation must not grant a right or scope the actor does not currently hold. */
export async function canDelegatePermission(client: PoolClient, request: AuthorizationRequest): Promise<boolean> {
  return (await hasPermission(client,{
    installationId: request.installationId,
    actorId: request.actorId,
    permission: "identity.roles.manage",
  })) && (await hasPermission(client,request));
}
