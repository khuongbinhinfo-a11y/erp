import { randomUUID } from "node:crypto";
import type { Pool, PoolClient } from "pg";
import { hashPassword } from "./auth.ts";
import { executeMutation, MutationFault, requireRevision, type MutationContext } from "./mutation.ts";
import { PERMISSIONS, canDelegatePermission, hasPermission, type Permission } from "./rbac.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const LOGIN=/^[a-z][a-z0-9._-]{2,79}$/;
export class IdentityError extends Error {
  readonly status:number;
  readonly kind:string;
  constructor(status:number, kind:string){super(kind);this.status=status;this.kind=kind;}
}
export type Scope={permission:Permission;branchId?:string;warehouseId?:string};
function data(ctx:MutationContext):Record<string,unknown>{
  if(!ctx.payload||typeof ctx.payload!=="object"||Array.isArray(ctx.payload))throw new IdentityError(400,"INVALID_INPUT");
  return ctx.payload as Record<string,unknown>;
}
export function parseScope(input:Record<string,unknown>):Scope{
  if(typeof input.permission!=="string"||!(input.permission in PERMISSIONS))throw new IdentityError(400,"INVALID_SCOPE");
  const permission=input.permission as Permission;
  const branchId=typeof input.branchId==="string"?input.branchId:undefined;
  const warehouseId=typeof input.warehouseId==="string"?input.warehouseId:undefined;
  const scope=PERMISSIONS[permission];
  if(scope==="installation"&&(input.branchId!=null||input.warehouseId!=null)||
     scope!=="installation"&&(!branchId||!UUID.test(branchId))||
     scope==="branch"&&input.warehouseId!=null||
     scope==="warehouse"&&(!warehouseId||!UUID.test(warehouseId)))throw new IdentityError(400,"INVALID_SCOPE");
  return {permission,...(branchId?{branchId}:{}),...(warehouseId?{warehouseId}:{})};
}
export type Grant={roleId:string;permission:string;branchId:string|null;warehouseId:string|null};
export async function userAccess(db:PoolClient,installationId:string,userId:string):Promise<Grant[]>{
  const r=await db.query<{role_id:string;permission_code:string;branch_id:string|null;warehouse_id:string|null}>(
    `SELECT ur.role_id,rp.permission_code,ur.branch_id,uw.warehouse_id
     FROM app_user u JOIN user_role ur ON ur.installation_id=u.installation_id AND ur.user_id=u.id
     JOIN role_permission rp ON rp.installation_id=ur.installation_id AND rp.role_id=ur.role_id
     LEFT JOIN user_role_warehouse uw ON uw.installation_id=ur.installation_id AND uw.user_id=ur.user_id
       AND uw.role_id=ur.role_id AND uw.branch_id=ur.branch_id
     WHERE u.installation_id=$1 AND u.id=$2 AND NOT u.disabled
     ORDER BY rp.permission_code,ur.branch_id,uw.warehouse_id`,[installationId,userId]);
  const seen=new Set<string>(), grants:Grant[]=[];
  for(const x of r.rows){
    if(!(x.permission_code in PERMISSIONS))continue;
    const s=PERMISSIONS[x.permission_code as Permission];
    if(s==="installation"&&x.branch_id!==null||s!=="installation"&&!x.branch_id||
       s==="warehouse"&&!x.warehouse_id)continue;
    const item:Grant={roleId:x.role_id,permission:x.permission_code,
      branchId:s==="installation"?null:x.branch_id,warehouseId:s==="warehouse"?x.warehouse_id:null};
    const key=[item.permission,item.branchId,item.warehouseId].join(":");
    if(!seen.has(key)){grants.push(item);seen.add(key);}
  }
  return grants;
}
export async function listUsers(db:PoolClient,installationId:string,actorId:string){
  if(!await hasPermission(db,{installationId,actorId,permission:"identity.users.read"}))throw new MutationFault("FORBIDDEN",403);
  const r=await db.query<{id:string;login_name:string;disabled:boolean;revision:string;employeeId:string|null;employeeName:string|null;employeeBranchId:string|null}>(
    `SELECT u.id,u.login_name,u.disabled,u.revision::text,
     e.id AS "employeeId",e.full_name AS "employeeName",e.branch_id AS "employeeBranchId"
     FROM app_user u LEFT JOIN org_employee e
     ON e.installation_id=u.installation_id AND e.account_user_id=u.id
     WHERE u.installation_id=$1 ORDER BY u.created_at,u.id LIMIT 100`,
    [installationId]);
  return r.rows.map(x=>({id:x.id,loginName:x.login_name,disabled:x.disabled,
    employeeId:x.employeeId,employeeName:x.employeeName,employeeBranchId:x.employeeBranchId,
    revision:Number(x.revision)}));
}
export async function listScopes(db:PoolClient,installationId:string,actorId:string,offset=0){
  if(!Number.isSafeInteger(offset)||offset<0||offset>100000)
    throw new IdentityError(400,"INVALID_PAGINATION");
  if(!await hasPermission(db,{installationId,actorId,permission:"identity.roles.manage"}))throw new MutationFault("FORBIDDEN",403);
  // Return a bounded page with a separate more flag for each collection.
  // Ordering by code + immutable ID prevents dropping equal-code rows.
  const a=await db.query(
    "SELECT id,code,name FROM branch WHERE installation_id=$1 ORDER BY code,id LIMIT 101 OFFSET $2",
    [installationId,offset]);
  const b=await db.query(
    "SELECT id,branch_id AS \"branchId\",code,name FROM warehouse WHERE installation_id=$1 ORDER BY code,id LIMIT 101 OFFSET $2",
    [installationId,offset]);
  return {
    branches:a.rows.slice(0,100),warehouses:b.rows.slice(0,100),
    hasMoreBranches:a.rows.length>100,hasMoreWarehouses:b.rows.length>100,
  };
}
/** Scope listing for a warehouse policy editor. Never expose unrelated warehouses. */
export async function listPolicyScopes(db:PoolClient,installationId:string,actorId:string,offset=0){
  if(!Number.isSafeInteger(offset)||offset<0||offset>100000)
    throw new IdentityError(400,"INVALID_PAGINATION");
  const grants=(await userAccess(db,installationId,actorId)).filter(
    g=>g.permission==="inventory.policy.manage"&&g.branchId&&g.warehouseId);
  if(grants.length===0)throw new MutationFault("FORBIDDEN",403);
  const branchIds=[...new Set(grants.map(g=>g.branchId!))];
  const warehouseIds=[...new Set(grants.map(g=>g.warehouseId!))];
  const branches=await db.query(
    "SELECT id,code,name FROM branch WHERE installation_id=$1 AND id=ANY($2::uuid[]) ORDER BY code,id LIMIT 101 OFFSET $3",
    [installationId,branchIds,offset]);
  const warehouses=await db.query(
    'SELECT id,branch_id AS "branchId",code,name FROM warehouse WHERE installation_id=$1 AND id=ANY($2::uuid[]) AND branch_id=ANY($3::uuid[]) ORDER BY code,id LIMIT 101 OFFSET $4',
    [installationId,warehouseIds,branchIds,offset]);
  return {branches:branches.rows.slice(0,100),warehouses:warehouses.rows.slice(0,100),
    hasMoreBranches:branches.rows.length>100,hasMoreWarehouses:warehouses.rows.length>100};
}
/** The permission catalog is sourced from the backend allowlist, not UI constants. */
export async function listPermissionCatalog(db:PoolClient,installationId:string,actorId:string){
  if(!await hasPermission(db,{installationId,actorId,permission:"identity.users.read"}) &&
     !await hasPermission(db,{installationId,actorId,permission:"identity.roles.manage"}))
    throw new MutationFault("FORBIDDEN",403);
  return Object.entries(PERMISSIONS).map(([code,scope])=>({code,scope}));
}
/** Redacted, read-only and installation-scoped audit timeline. */
export async function listAuditEvents(db:PoolClient,installationId:string,actorId:string){
  if(!await hasPermission(db,{installationId,actorId,permission:"identity.roles.manage"}))
    throw new MutationFault("FORBIDDEN",403);
  const result=await db.query(
    `SELECT e.id,e.action_code AS "actionCode",e.event_code AS "eventCode",
      e.request_id AS "requestId",e.occurred_at AS "occurredAt",
      u.login_name AS "actorLogin"
      FROM audit_event e JOIN app_user u
      ON u.installation_id=e.installation_id AND u.id=e.actor_id
      WHERE e.installation_id=$1 ORDER BY e.occurred_at DESC,e.id DESC LIMIT 50`,
    [installationId]);
  return result.rows;
}
export async function listGrants(db:PoolClient,installationId:string,actorId:string,target:string){
  if(!UUID.test(target))throw new IdentityError(400,"INVALID_INPUT");
  if(!await hasPermission(db,{installationId,actorId,permission:"identity.users.read"}))throw new MutationFault("FORBIDDEN",403);
  const r=await db.query("SELECT 1 FROM app_user WHERE installation_id=$1 AND id=$2",[installationId,target]);
  if(!r.rowCount)throw new IdentityError(404,"NOT_FOUND");
  return userAccess(db,installationId,target);
}
async function lockTarget(db:PoolClient,tenant:string,target:string,revision:number){
  if(!UUID.test(target))throw new IdentityError(400,"INVALID_INPUT");
  const r=await db.query<{revision:string}>(
    "SELECT revision::text FROM app_user WHERE installation_id=$1 AND id=$2 FOR UPDATE",[tenant,target]);
  if(!r.rows[0])throw new IdentityError(404,"NOT_FOUND");
  requireRevision(revision,Number(r.rows[0].revision));
  const owner=await db.query(
    `SELECT 1 FROM user_role ur JOIN app_role ar ON ar.installation_id=ur.installation_id AND ar.id=ur.role_id
      WHERE ur.installation_id=$1 AND ur.user_id=$2 AND ar.code='PRIMARY_OWNER' LIMIT 1`,[tenant,target]);
  if(owner.rowCount)throw new IdentityError(403,"PROTECTED_OWNER");
}
export async function createUser(pool:Pool,ctx:MutationContext){
  const x=data(ctx);
  if(typeof x.loginName!=="string"||!LOGIN.test(x.loginName)||typeof x.password!=="string")throw new IdentityError(400,"INVALID_INPUT");
  const login=x.loginName,password=x.password;
  return executeMutation(pool,ctx,{
    authorize:db=>hasPermission(db,{installationId:ctx.installationId,actorId:ctx.actorId,permission:"identity.users.manage"}),
    execute:async db=>{
      const hashed=await hashPassword(password);
      const q=await db.query<{id:string}>(
        "INSERT INTO app_user(installation_id,login_name,password_hash) VALUES($1,$2,$3) RETURNING id",
        [ctx.installationId,login,hashed]);
      return {status:201,body:{id:q.rows[0]!.id,loginName:login,disabled:false,revision:0}};
    },
  });
}
export async function updateUser(pool:Pool,ctx:MutationContext,target:string){
  const x=data(ctx);
  if(typeof x.disabled!=="boolean"||target===ctx.actorId)throw new IdentityError(400,"INVALID_INPUT");
  return executeMutation(pool,ctx,{
    authorize:db=>hasPermission(db,{installationId:ctx.installationId,actorId:ctx.actorId,permission:"identity.users.manage"}),
    execute:async db=>{
      await lockTarget(db,ctx.installationId,target,ctx.expectedRevision);
      const r=await db.query<{revision:string}>(
        "UPDATE app_user SET disabled=$3,revision=revision+1 WHERE installation_id=$1 AND id=$2 RETURNING revision::text",
        [ctx.installationId,target,x.disabled]);
      return {status:200,body:{id:target,disabled:x.disabled,revision:Number(r.rows[0]!.revision)}};
    },
  });
}
export async function addGrant(pool:Pool,ctx:MutationContext,target:string){
  const scope=parseScope(data(ctx));
  return executeMutation(pool,ctx,{
    authorize:db=>canDelegatePermission(db,{installationId:ctx.installationId,actorId:ctx.actorId,...scope}),
    execute:async db=>{
      await lockTarget(db,ctx.installationId,target,ctx.expectedRevision);
      if(scope.branchId){
        const b=await db.query("SELECT 1 FROM branch WHERE installation_id=$1 AND id=$2",[ctx.installationId,scope.branchId]);
        if(!b.rowCount)throw new IdentityError(400,"INVALID_SCOPE");
      }
      if(scope.warehouseId){
        const w=await db.query("SELECT 1 FROM warehouse WHERE installation_id=$1 AND branch_id=$2 AND id=$3",
          [ctx.installationId,scope.branchId,scope.warehouseId]);
        if(!w.rowCount)throw new IdentityError(400,"INVALID_SCOPE");
      }
      const roleId=randomUUID();
      await db.query("INSERT INTO app_role(installation_id,id,code) VALUES($1,$2,$3)",
        [ctx.installationId,roleId,"GRANT_"+roleId.replaceAll("-","")]);
      await db.query("INSERT INTO role_permission(installation_id,role_id,permission_code) VALUES($1,$2,$3)",
        [ctx.installationId,roleId,scope.permission]);
      await db.query("INSERT INTO user_role(installation_id,user_id,role_id,branch_id) VALUES($1,$2,$3,$4)",
        [ctx.installationId,target,roleId,scope.branchId??null]);
      if(scope.warehouseId)await db.query(
        "INSERT INTO user_role_warehouse(installation_id,user_id,role_id,branch_id,warehouse_id) VALUES($1,$2,$3,$4,$5)",
        [ctx.installationId,target,roleId,scope.branchId,scope.warehouseId]);
      const r=await db.query<{revision:string}>(
        "UPDATE app_user SET revision=revision+1 WHERE installation_id=$1 AND id=$2 RETURNING revision::text",
        [ctx.installationId,target]);
      return {status:201,body:{id:target,roleId,...scope,revision:Number(r.rows[0]!.revision)}};
    },
  });
}
export async function revokeGrant(pool:Pool,ctx:MutationContext,target:string,roleId:string){
  if(!UUID.test(target)||!UUID.test(roleId))throw new IdentityError(400,"INVALID_INPUT");
  return executeMutation(pool,ctx,{
    authorize:async db=>{
      if(!await hasPermission(db,{installationId:ctx.installationId,actorId:ctx.actorId,permission:"identity.roles.manage"}))return false;
      const q=await db.query<{permission_code:string;branch_id:string|null;warehouse_id:string|null}>(
        `SELECT rp.permission_code,ur.branch_id,uw.warehouse_id FROM user_role ur
          JOIN app_role ar ON ar.installation_id=ur.installation_id AND ar.id=ur.role_id
          JOIN role_permission rp ON rp.installation_id=ur.installation_id AND rp.role_id=ur.role_id
          LEFT JOIN user_role_warehouse uw ON uw.installation_id=ur.installation_id
            AND uw.user_id=ur.user_id AND uw.role_id=ur.role_id AND uw.branch_id=ur.branch_id
          WHERE ur.installation_id=$1 AND ur.user_id=$2 AND ur.role_id=$3 AND ar.code LIKE 'GRANT\\_%' ESCAPE '\\'`,
        [ctx.installationId,target,roleId]);
      if(q.rows.length!==1)return false;
      const x=q.rows[0]!;
      return canDelegatePermission(db,{installationId:ctx.installationId,actorId:ctx.actorId,
        permission:x.permission_code,branchId:x.branch_id??undefined,warehouseId:x.warehouse_id??undefined});
    },
    execute:async db=>{
      await lockTarget(db,ctx.installationId,target,ctx.expectedRevision);
      const d=await db.query("DELETE FROM user_role WHERE installation_id=$1 AND user_id=$2 AND role_id=$3",
        [ctx.installationId,target,roleId]);
      if(d.rowCount!==1)throw new IdentityError(404,"NOT_FOUND");
      const r=await db.query<{revision:string}>(
        "UPDATE app_user SET revision=revision+1 WHERE installation_id=$1 AND id=$2 RETURNING revision::text",
        [ctx.installationId,target]);
      return {status:200,body:{id:target,revokedRoleId:roleId,revision:Number(r.rows[0]!.revision)}};
    },
  });
}
