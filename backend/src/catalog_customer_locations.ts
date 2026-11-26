import type { PoolClient } from "pg";
import { hasPermission } from "./rbac.ts";
import { MutationFault, requireRevision, type MutationContext } from "./mutation.ts";

export class CustomerLocationFault extends Error {
  readonly status:number;
  readonly code:string;
  constructor(status:number,code:string){super(code);this.status=status;this.code=code;}
}
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CODE=/^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$/;
const PHONE=/^\+?[0-9]{9,15}$/;
function isObject(value:unknown):value is Record<string,unknown>{
  return !!value&&typeof value==="object"&&!Array.isArray(value);
}
function fieldName(raw:unknown,max:number):string{
  if(typeof raw!=="string"||!raw.trim()||raw.trim().length>max)
    throw new CustomerLocationFault(400,"INVALID_LOCATION_FIELD");
  return raw.trim();
}
function optionalPhone(raw:unknown):string|null{
  if(raw===null||raw==="")return null;
  if(typeof raw!=="string"||!PHONE.test(raw))
    throw new CustomerLocationFault(400,"INVALID_LOCATION_PHONE");
  return raw;
}
export function parseCustomerLocation(raw:unknown,edit=false){
  if(!isObject(raw))throw new CustomerLocationFault(400,"INVALID_LOCATION");
  const allowed=edit?["branchId","name","address","phone","isDefault","active"]:
    ["branchId","code","name","address","phone","isDefault"];
  if(Object.keys(raw).some(k=>!allowed.includes(k)))
    throw new CustomerLocationFault(400,"UNKNOWN_LOCATION_FIELD");
  if(typeof raw.branchId!=="string"||!UUID.test(raw.branchId))
    throw new CustomerLocationFault(400,"INVALID_BRANCH");
  const columns:Record<string,unknown>={};
  // A location belongs to the same customer. Code is an internal identity,
  // not an input required from a cashier or customer.
  if(!edit&&raw.code!==undefined&&raw.code!==null&&raw.code!==""){
    if(typeof raw.code!=="string"||!CODE.test(raw.code))
      throw new CustomerLocationFault(400,"INVALID_LOCATION_CODE");
    columns.code=raw.code;
  }
  if(!edit||Object.prototype.hasOwnProperty.call(raw,"name")){
    columns.name=raw.name==null||
      (typeof raw.name==="string"&&!raw.name.trim())
        ?"Địa chỉ giao hàng":fieldName(raw.name,160);
  }
  if(!edit||Object.prototype.hasOwnProperty.call(raw,"address"))
    columns.address=fieldName(raw.address,500);
  if(Object.prototype.hasOwnProperty.call(raw,"phone"))
    columns.phone=optionalPhone(raw.phone);
  if(Object.prototype.hasOwnProperty.call(raw,"isDefault")){
    if(typeof raw.isDefault!=="boolean")
      throw new CustomerLocationFault(400,"INVALID_LOCATION_DEFAULT");
    columns.is_default=raw.isDefault;
  }
  if(edit&&Object.prototype.hasOwnProperty.call(raw,"active")){
    if(typeof raw.active!=="boolean")
      throw new CustomerLocationFault(400,"INVALID_LOCATION_ACTIVE");
    columns.active=raw.active;
    if(raw.active===false)columns.is_default=false;
  }
  if(edit&&Object.keys(columns).length===0)
    throw new CustomerLocationFault(400,"EMPTY_LOCATION_UPDATE");
  return {branchId:raw.branchId,columns};
}
/** Allocate an internal destination code under the per-customer write lock. */
export function nextCustomerLocationCode(existing:Iterable<string>):string{
  const used=new Set(existing);
  let index=1;
  while(used.has("DC"+String(index).padStart(4,"0")))index++;
  return "DC"+String(index).padStart(4,"0");
}
async function permit(db:PoolClient,installationId:string,actorId:string,
  branchId:string,write:boolean){
  const ok=await hasPermission(db,{installationId,actorId,
    permission:write?"catalog.write":"catalog.read",branchId});
  if(!ok)throw new MutationFault("FORBIDDEN",403);
}
async function validCustomer(db:PoolClient,installationId:string,branchId:string,
  customerId:string){
  const r=await db.query(`SELECT id FROM catalog_customer
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [installationId,branchId,customerId]);
  if(r.rowCount!==1)throw new CustomerLocationFault(404,"CUSTOMER_NOT_FOUND");
}
export async function listCustomerLocations(db:PoolClient,tenant:string,
  actorId:string,branchId:string,customerId:string){
  await permit(db,tenant,actorId,branchId,false);
  await validCustomer(db,tenant,branchId,customerId);
  const r=await db.query(`SELECT id,code,name,address,phone,
    is_default AS "isDefault",active,revision::integer
    FROM catalog_customer_location WHERE installation_id=$1 AND branch_id=$2
    AND customer_id=$3 ORDER BY is_default DESC,code,id LIMIT 200`,
    [tenant,branchId,customerId]);
  return r.rows;
}
export async function createCustomerLocation(db:PoolClient,ctx:MutationContext,
  customerId:string,input:ReturnType<typeof parseCustomerLocation>){
  await permit(db,ctx.installationId,ctx.actorId,input.branchId,true);
  await validCustomer(db,ctx.installationId,input.branchId,customerId);
  const cols=input.columns;
  // Serialize every location write for one customer so a single default is stable.
  await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))",
    [[ctx.installationId,input.branchId,customerId].join("|")]);
  if(cols.code===undefined){
    const existing=await db.query<{code:string}>(`SELECT code FROM catalog_customer_location
      WHERE installation_id=$1 AND branch_id=$2 AND customer_id=$3`,
      [ctx.installationId,input.branchId,customerId]);
    cols.code=nextCustomerLocationCode(existing.rows.map(row=>row.code));
  }
  if(cols.is_default===true)await db.query(`UPDATE catalog_customer_location
    SET is_default=false,revision=revision+1 WHERE installation_id=$1
    AND branch_id=$2 AND customer_id=$3 AND is_default`,
    [ctx.installationId,input.branchId,customerId]);
  const r=await db.query<{id:string}>(`INSERT INTO catalog_customer_location
    (installation_id,branch_id,customer_id,code,name,address,phone,is_default)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`,
    [ctx.installationId,input.branchId,customerId,
    cols.code,cols.name,cols.address,cols.phone??null,cols.is_default??false]);
  return {status:201,body:{id:r.rows[0]!.id,revision:0}};
}
export async function updateCustomerLocation(db:PoolClient,ctx:MutationContext,
  customerId:string,locationId:string,input:ReturnType<typeof parseCustomerLocation>){
  await permit(db,ctx.installationId,ctx.actorId,input.branchId,true);
  await validCustomer(db,ctx.installationId,input.branchId,customerId);
  await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))",
    [[ctx.installationId,input.branchId,customerId].join("|")]);
  const old=await db.query<{revision:string}>(`SELECT revision::text
    FROM catalog_customer_location WHERE installation_id=$1 AND branch_id=$2
    AND customer_id=$3 AND id=$4 FOR UPDATE`,
    [ctx.installationId,input.branchId,customerId,locationId]);
  if(!old.rows.length)throw new CustomerLocationFault(404,"LOCATION_NOT_FOUND");
  requireRevision(ctx.expectedRevision,Number(old.rows[0]!.revision));
  if(input.columns.is_default===true){
    await db.query(`UPDATE catalog_customer_location SET is_default=false,revision=revision+1
      WHERE installation_id=$1 AND branch_id=$2 AND customer_id=$3
        AND id<>$4 AND is_default`,
      [ctx.installationId,input.branchId,customerId,locationId]);
  }
  const col=Object.entries(input.columns);
  const sets=col.map(([key],idx)=>key+"=$"+(idx+5));
  const r=await db.query<{revision:string}>(`UPDATE catalog_customer_location
    SET ${sets.join(",")},revision=revision+1 WHERE installation_id=$1
    AND branch_id=$2 AND customer_id=$3 AND id=$4 RETURNING revision::text`,
    [ctx.installationId,input.branchId,customerId,locationId,...col.map(x=>x[1])]);
  return {status:200,body:{id:locationId,revision:Number(r.rows[0]!.revision)}};
}
