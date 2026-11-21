import type { IncomingMessage, ServerResponse } from "node:http";
import type { Pool } from "pg";
import type { IdentityOptions } from "./identity_http.ts";
import { resolveSession } from "./auth.ts";
import { hasPermission } from "./rbac.ts";
import { executeMutation, MutationFault, type MutationContext } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";
import { InventoryFault, validBaseQty, balance, balances, movements, reservations,
  openStock, reserveStock, releaseStock, type WarehouseScope } from "./inventory.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BEARER=/^Bearer ([A-Za-z0-9_-]{43})$/;
function send(res:ServerResponse,status:number,payload:unknown,id:string,origin?:string):void {
 const headers:Record<string,string>={
  "content-type":"application/json; charset=utf-8","cache-control":"no-store",
  "x-content-type-options":"nosniff","x-request-id":id,"vary":"Origin",
 };
 if(origin){
  headers["access-control-allow-origin"]=origin;
  headers["access-control-allow-methods"]="GET, POST, OPTIONS";
  headers["access-control-allow-headers"]="content-type,authorization,idempotency-key,if-match,x-request-id";
 }
 res.writeHead(status,headers);res.end(status===204?"":JSON.stringify(payload));
}
function fail(res:ServerResponse,status:number,code:string,id:string,origin?:string):void {
 const message=status===401?"Phiên đăng nhập không hợp lệ":
  status===403?"Bạn không có quyền trên kho này.":
  status===409?"Tồn kho hoặc chứng từ đã thay đổi. Vui lòng tải lại.":
  status===503?"Nghiệp vụ kho chưa sẵn sàng.":"Thông tin kho không hợp lệ.";
 send(res,status,{error:{code,message,requestId:id}},id,origin);
}
function uuid(v:unknown):string{
 if(typeof v!=="string"||!UUID.test(v))throw new InventoryFault(400,"INVALID_ID");
 return v;
}
function positiveInt(v:unknown):number {
 if(typeof v!=="number"||!Number.isSafeInteger(v)||v<1||v>10000)
  throw new InventoryFault(400,"INVALID_INTEGER");
 return v;
}
function record(value:unknown):Record<string,unknown>{
 if(!value||typeof value!=="object"||Array.isArray(value))
  throw new InventoryFault(400,"INVALID_BODY");
 return value as Record<string,unknown>;
}
function allowFields(x:Record<string,unknown>,fields:string[]):void{
 if(Object.keys(x).some(k=>!fields.includes(k)))throw new InventoryFault(400,"UNKNOWN_FIELD");
}
function scope(x:Record<string,unknown>):WarehouseScope{
 return {branchId:uuid(x.branchId),warehouseId:uuid(x.warehouseId)};
}
async function parseBody(req:IncomingMessage):Promise<Record<string,unknown>>{
 if(req.headers["content-type"]?.split(";")[0]?.toLowerCase()!=="application/json")
  throw new InventoryFault(415,"JSON_REQUIRED");
 let count=0;const buffers:Buffer[]=[];
 for await(const chunk of req) {
  const buf=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk as Uint8Array);
  count+=buf.length;
  if(count>8192)throw new InventoryFault(413,"BODY_TOO_LARGE");
  buffers.push(buf);
 }
 try{return record(JSON.parse(Buffer.concat(buffers).toString("utf8")) as unknown);}
 catch(e){if(e instanceof InventoryFault)throw e;throw new InventoryFault(400,"INVALID_JSON");}
}
function ctx(req:IncomingMessage,requestId:string,t:string,actor:string,
 action:string,payload:Record<string,unknown>,create:boolean):MutationContext{
 const key=req.headers["idempotency-key"],rev=req.headers["if-match"];
 if(typeof key!=="string"||!validIdempotencyKey(key)||
    typeof rev!=="string"||!/^(0|[1-9][0-9]{0,14})$/.test(rev))
  throw new InventoryFault(400,"MUTATION_HEADERS_REQUIRED");
 const expectedRevision=Number(rev);
 if(!Number.isSafeInteger(expectedRevision)||(create&&expectedRevision!==0))
  throw new InventoryFault(400,"INVALID_REVISION");
 return {installationId:t,actorId:actor,requestId,action,idempotencyKey:key,
  expectedRevision,payload};
}
async function schemaReady(pool:Pool):Promise<boolean>{
 try{
  const r=await pool.query<{ok:boolean}>(
   "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version='0011_r3_inventory_ledger.sql') AS ok");
  return r.rows[0]?.ok===true;
 }catch{return false;}
}
export async function handleInventoryHttp(req:IncomingMessage,res:ServerResponse,
 id:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fail(res,403,"ORIGIN_DENIED",id);return;}
 if(req.method==="OPTIONS"){if(!cors){fail(res,403,"ORIGIN_DENIED",id);return;}
  send(res,204,null,id,cors);return;}
 const tenant=opts.installationId,pool=opts.pool;
 if(!tenant||!UUID.test(tenant)||!pool||!opts.allowedOrigin){
  fail(res,503,"INVENTORY_NOT_CONFIGURED",id,cors);return;
 }
 try{
  if(!await ready()||!await schemaReady(pool)){
   fail(res,503,"INVENTORY_MIGRATION_REQUIRED",id,cors);return;
  }
  const token=typeof req.headers.authorization==="string"
   ?BEARER.exec(req.headers.authorization)?.[1]:undefined;
  const client=await pool.connect();
  let actorId:string|undefined;
  try{actorId=token?(await resolveSession(client,tenant,token))?.actorId:undefined;}
  finally{client.release();}
  if(!actorId){fail(res,401,"AUTH_REQUIRED",id,cors);return;}
  if(req.method==="GET"&&["/v1/inventory/balances",
       "/v1/inventory/movements","/v1/inventory/reservations"].includes(url.pathname)){
   const s=scope({branchId:url.searchParams.get("branchId"),
    warehouseId:url.searchParams.get("warehouseId")});
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:tenant,actorId,
      permission:"inventory.read",...s}))throw new InventoryFault(403,"INVENTORY_READ_DENIED");
    const items=url.pathname.endsWith("/balances")?await balances(db,tenant,s):
     url.pathname.endsWith("/movements")?await movements(db,tenant,s):
     await reservations(db,tenant,s);
    send(res,200,{items,requestId:id},id,cors);
   }finally{db.release();}
   return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/inventory/openings"){
   const raw=await parseBody(req);
   allowFields(raw,["branchId","warehouseId","productId","quantity"]);
   const input={...scope(raw),productId:uuid(raw.productId),quantity:raw.quantity};
   if(!validBaseQty(input.quantity))throw new InventoryFault(400,"INVALID_QUANTITY");
   const c=ctx(req,id,tenant,actorId,"inventory.opening.post",
     input as Record<string,unknown>,true);
   const outcome=await executeMutation(pool,c,{
    authorize:(db,m)=>hasPermission(db,{installationId:m.installationId,
     actorId:m.actorId,permission:"inventory.post",...input}),
    execute:(db,m)=>openStock(db,m,input),
   });
   send(res,outcome.status,outcome.body,id,cors);return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/inventory/reservations"){
   const raw=await parseBody(req);
   allowFields(raw,["branchId","warehouseId","orderId","version","lineNo"]);
   const input={...scope(raw),orderId:uuid(raw.orderId),
    version:positiveInt(raw.version),lineNo:positiveInt(raw.lineNo)};
   const c=ctx(req,id,tenant,actorId,"inventory.reservation.create",input,true);
   const outcome=await executeMutation(pool,c,{
    authorize:(db,m)=>hasPermission(db,{installationId:m.installationId,
     actorId:m.actorId,permission:"inventory.reserve",...input}),
    execute:(db,m)=>reserveStock(db,m,input),
   });
   send(res,outcome.status,outcome.body,id,cors);return;
  }
  const release=/^\/v1\/inventory\/reservations\/([0-9a-f-]{36})\/release$/.exec(url.pathname);
  if(req.method==="POST"&&release){
   const reservationId=uuid(release[1]);
   const raw=await parseBody(req);allowFields(raw,["branchId","warehouseId"]);
   const s=scope(raw),payload={...s,reservationId};
   const c=ctx(req,id,tenant,actorId,"inventory.reservation.release",payload,false);
   const outcome=await executeMutation(pool,c,{
    authorize:(db,m)=>hasPermission(db,{installationId:m.installationId,
     actorId:m.actorId,permission:"inventory.reserve",...s}),
    execute:(db,m)=>releaseStock(db,m,s,reservationId),
   });
   send(res,outcome.status,outcome.body,id,cors);return;
  }
  fail(res,405,"METHOD_NOT_ALLOWED",id,cors);
 }catch(err){
  if(err instanceof InventoryFault){fail(res,err.status,err.code,id,cors);return;}
  if(err instanceof MutationFault){fail(res,err.httpStatus,err.code,id,cors);return;}
  if(err&&typeof err==="object"&&"code" in err){
   if(err.code==="23505"){fail(res,409,"DUPLICATE_STOCK_DOCUMENT",id,cors);return;}
   if(err.code==="23503"||err.code==="23514"){
    fail(res,409,"INVALID_STOCK_REFERENCE",id,cors);return;}
  }
  fail(res,503,"INVENTORY_UNAVAILABLE",id,cors);
 }
}
