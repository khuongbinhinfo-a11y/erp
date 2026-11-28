import { randomUUID } from "node:crypto";
import type { Pool,PoolClient } from "pg";
import { executeMutation,type MutationContext } from "./mutation.ts";
import { hasPermission } from "./rbac.ts";

const CODE=/^[A-Z0-9][A-Z0-9_-]{0,63}$/;
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export class DirectoryFault extends Error {
 readonly status:number;
 readonly code:string;
 constructor(status:number,code:string){super(code);this.status=status;this.code=code;}
}
function text(value:unknown,label:"CODE"|"NAME"){
 if(typeof value!=="string")throw new DirectoryFault(400,"INVALID_"+label);
 const result=value.trim();
 if(label==="CODE"){
  const normalized=result.toUpperCase();
  if(!CODE.test(normalized))throw new DirectoryFault(400,"INVALID_CODE");
  return normalized;
 }
 if(!result||result.length>160)throw new DirectoryFault(400,"INVALID_NAME");
 return result;
}
function fields(payload:unknown,allowed:string[]){
 if(!payload||typeof payload!=="object"||Array.isArray(payload))throw new DirectoryFault(400,"INVALID_INPUT");
 const obj=payload as Record<string,unknown>;
 if(Object.keys(obj).some(k=>!allowed.includes(k)))throw new DirectoryFault(400,"UNKNOWN_FIELD");
 return obj;
}
/** Installation principal only: creating a scope must never grant a tenant admin
 * rights to an unrelated installation or silently make arbitrary users owners. */
export async function isDirectoryOwner(db:PoolClient,tenant:string,actor:string){
 if(!await hasPermission(db,{installationId:tenant,actorId:actor,permission:"identity.roles.manage"}))return false;
 const r=await db.query(`SELECT 1 FROM user_role ur JOIN app_role ar
  ON ar.installation_id=ur.installation_id AND ar.id=ur.role_id
  WHERE ur.installation_id=$1 AND ur.user_id=$2 AND ur.branch_id IS NULL
  AND ar.code='PRIMARY_OWNER' LIMIT 1`,[tenant,actor]);
 return r.rowCount===1;
}
export async function createDirectoryBranch(pool:Pool,ctx:MutationContext){
 const data=fields(ctx.payload,["code","name"]);
 const code=text(data.code,"CODE"),name=text(data.name,"NAME");
 if(ctx.expectedRevision!==0)throw new DirectoryFault(409,"REVISION_CONFLICT");
 return executeMutation(pool,ctx,{
  authorize:db=>isDirectoryOwner(db,ctx.installationId,ctx.actorId),
  execute:async db=>{
   const created=await db.query<{id:string}>(`
    INSERT INTO branch(installation_id,code,name) VALUES($1,$2,$3)
    RETURNING id`,[ctx.installationId,code,name]);
   const branchId=created.rows[0]!.id;
   const source=await db.query<{id:string}>(`
    SELECT ar.id FROM app_role ar JOIN user_role ur
      ON ur.installation_id=ar.installation_id AND ur.role_id=ar.id
    WHERE ar.installation_id=$1 AND ar.code='PRIMARY_OWNER_MAIN'
      AND ur.user_id=$2 LIMIT 1`,[ctx.installationId,ctx.actorId]);
   if(!source.rows[0])throw new DirectoryFault(409,"OWNER_BRANCH_TEMPLATE_MISSING");
   const roleId=randomUUID();
   await db.query("INSERT INTO app_role(installation_id,id,code) VALUES($1,$2,$3)",
     [ctx.installationId,roleId,"OWNER_BRANCH_"+roleId.replaceAll("-","")]);
   await db.query(`INSERT INTO role_permission(installation_id,role_id,permission_code)
     SELECT installation_id,$2,permission_code FROM role_permission
     WHERE installation_id=$1 AND role_id=$3`,
     [ctx.installationId,roleId,source.rows[0].id]);
   await db.query(`INSERT INTO user_role(installation_id,user_id,role_id,branch_id)
     VALUES($1,$2,$3,$4)`,[ctx.installationId,ctx.actorId,roleId,branchId]);
   return {status:201,body:{id:branchId,code,name}};
  },
 });
}
export async function createDirectoryWarehouse(pool:Pool,ctx:MutationContext){
 const data=fields(ctx.payload,["branchId","code","name"]);
 const branchId=data.branchId;
 if(typeof branchId!=="string"||!UUID.test(branchId))throw new DirectoryFault(400,"INVALID_BRANCH_ID");
 const code=text(data.code,"CODE"),name=text(data.name,"NAME");
 if(ctx.expectedRevision!==0)throw new DirectoryFault(409,"REVISION_CONFLICT");
 return executeMutation(pool,ctx,{
  authorize:async db=>(await isDirectoryOwner(db,ctx.installationId,ctx.actorId))&&
    (await hasPermission(db,{installationId:ctx.installationId,actorId:ctx.actorId,
      permission:"catalog.read",branchId})),
  execute:async db=>{
   const branch=await db.query(`SELECT 1 FROM branch WHERE installation_id=$1 AND id=$2
     FOR SHARE`,[ctx.installationId,branchId]);
   if(!branch.rowCount)throw new DirectoryFault(404,"BRANCH_NOT_FOUND");
   const created=await db.query<{id:string}>(`
     INSERT INTO warehouse(installation_id,branch_id,code,name)
     VALUES($1,$2,$3,$4) RETURNING id`,
     [ctx.installationId,branchId,code,name]);
   const warehouseId=created.rows[0]!.id;
   const assign=await db.query(`
     INSERT INTO user_role_warehouse(installation_id,user_id,role_id,branch_id,warehouse_id)
     SELECT DISTINCT ur.installation_id,ur.user_id,ur.role_id,ur.branch_id,$4
     FROM user_role ur JOIN role_permission rp
       ON rp.installation_id=ur.installation_id AND rp.role_id=ur.role_id
     WHERE ur.installation_id=$1 AND ur.branch_id=$2 AND ur.user_id=$3
       AND rp.permission_code='inventory.read'
     ON CONFLICT DO NOTHING`,[ctx.installationId,branchId,ctx.actorId,warehouseId]);
   if(!assign.rowCount)throw new DirectoryFault(409,"WAREHOUSE_GRANT_REQUIRED");
   return {status:201,body:{id:warehouseId,branchId,code,name,
     negativeIssueMode:"BLOCK",reserveShortageMode:"WARN"}};
  },
 });
}
