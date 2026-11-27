import type { IncomingMessage, ServerResponse } from "node:http";
import type { Pool } from "pg";
import type { IdentityOptions } from "./identity_http.ts";
import { resolveSession } from "./auth.ts";
import { hasPermission } from "./rbac.ts";
import { executeMutation, MutationFault, type MutationContext } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";
import { createLocation,createLot,setTrackingPolicy,assignStockScope,stockScopes,
  directIssueHistory,directIssueTotals,reconcileManualIssues,issueManualStock,requireT3b,type DirectIssueItem } from "./direct_stock_issue.ts";
import { InventoryFault, validBaseQty, balance, balances, movements, reservations,
  openStock, reserveStock, releaseStock, readInventoryGuardPolicy,
  setInventoryGuardPolicy, type ShortageMode, type WarehouseScope } from "./inventory.ts";

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
 const message=({
  T3B_MIGRATION_REQUIRED:"Cần nâng cấp dữ liệu kho T3-B trước khi xuất.",
  CONFIRMED_MANUAL_ORDER_REQUIRED:"Chỉ xuất trực tiếp cho đơn MANUAL đã xác nhận đúng kho.",
  ISSUE_EXCEEDS_ORDER_LINE:"Số xuất vượt lượng còn lại trên đơn.",
  INSUFFICIENT_AVAILABLE_STOCK:"Tồn khả dụng không đủ. Vui lòng điều chỉnh số xuất.",
  INSUFFICIENT_UNASSIGNED_STOCK:"Kho chưa có đủ hàng chưa phân lô/vị trí.",
  NEGATIVE_ISSUE_REQUIRES_POLICY_ALLOW:"Kho đang cảnh báo tồn âm. Quản trị viên phải cho phép trước khi xuất.",
  NEGATIVE_TRACKED_STOCK_DENIED:"Không được xuất âm khi hàng đã quản lý lô hoặc vị trí.",
  STOCK_SCOPE_REQUIRED_OR_UNAVAILABLE:"Lô hoặc vị trí bắt buộc chưa hợp lệ, hoặc lô đã hết hạn.",
  NEGATIVE_ISSUE_DENIED:"Nhân viên không có quyền xuất âm kho.",
  RELEASE_ORDER_HOLDS_FIRST:"Đơn còn giữ hàng. Cần giải phóng trước khi xuất trực tiếp.",
 } as Record<string,string>)[code]??(code==="ORDER_DIRECT_ISSUE_ONLY"
  ?"Đơn giao thủ công hoặc tại quầy không giữ hàng theo chuyến.":status===401?"Phiên đăng nhập không hợp lệ":
  status===403?"Bạn không có quyền trên kho này.":
  status===409?"Tồn kho hoặc chứng từ đã thay đổi. Vui lòng tải lại.":
  status===503?"Nghiệp vụ kho chưa sẵn sàng.":"Thông tin kho không hợp lệ.");
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
function optionalUuid(v:unknown):string|undefined{
 return v===undefined||v===null?undefined:uuid(v);
}
function shortText(v:unknown,max:number):string{
 if(typeof v!=="string"||v.trim().length<1||v.trim().length>max)
  throw new InventoryFault(400,"INVALID_TEXT");
 return v.trim();
}
function isoDate(v:unknown):string|null{
 if(v===undefined||v===null)return null;
 if(typeof v!=="string"||!/^\d{4}-\d{2}-\d{2}$/.test(v)||
  !Number.isFinite(new Date(v).getTime())||
  new Date(v).toISOString().slice(0,10)!==v)
  throw new InventoryFault(400,"INVALID_DATE");
 return v;
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
    const rawOffset=url.searchParams.get("offset")??"0";
    if(!/^(0|[1-9][0-9]{0,5})$/.test(rawOffset)||
       Number(rawOffset)%100!==0)
      throw new InventoryFault(400,"INVALID_INVENTORY_PAGE");
    const offset=Number(rawOffset);
    if(url.pathname.endsWith("/reservations")){
     const state=url.searchParams.get("state")??"ACTIVE";
     if(!["ACTIVE","RELEASED"].includes(state))
      throw new InventoryFault(400,"INVALID_RESERVATION_STATE");
     const page=await reservations(db,tenant,s,state as "ACTIVE"|"RELEASED",offset);
     send(res,200,{...page,requestId:id},id,cors);
    }else{
     const page=url.pathname.endsWith("/balances")
       ?await balances(db,tenant,s,offset):await movements(db,tenant,s,offset);
     send(res,200,{...page,requestId:id},id,cors);
    }
   }finally{db.release();}
   return;
  }
  if(req.method==="GET"&&url.pathname==="/v1/inventory/guard-policy"){
   const s=scope({branchId:url.searchParams.get("branchId"),
    warehouseId:url.searchParams.get("warehouseId")});
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:tenant,actorId,
       permission:"inventory.read",...s}))
      throw new InventoryFault(403,"INVENTORY_READ_DENIED");
    send(res,200,{policy:await readInventoryGuardPolicy(db,tenant,s),requestId:id},id,cors);
   }finally{db.release();}
   return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/inventory/guard-policy"){
   const raw=await parseBody(req);
   allowFields(raw,["branchId","warehouseId","reserveShortageMode","negativeIssueMode"]);
   const s=scope(raw),mode=raw.reserveShortageMode,negative=raw.negativeIssueMode;
   if(mode!=="ALLOW"&&mode!=="WARN"&&mode!=="BLOCK")
    throw new InventoryFault(400,"INVALID_RESERVE_POLICY");
   if(negative!==undefined&&negative!=="ALLOW"&&negative!=="WARN"&&negative!=="BLOCK")
    throw new InventoryFault(400,"INVALID_NEGATIVE_POLICY");
   const payload={...s,reserveShortageMode:mode,...(negative===undefined?{}:{negativeIssueMode:negative})};
   const c=ctx(req,id,tenant,actorId,"inventory.guard-policy.set",payload,false);
   const outcome=await executeMutation(pool,c,{
    authorize:(db,m)=>hasPermission(db,{installationId:m.installationId,
      actorId:m.actorId,permission:"inventory.policy.manage",...s}),
    execute:async(db,m)=>{
      if(negative!==undefined)await requireT3b(db);
      return setInventoryGuardPolicy(db,m,s,mode as ShortageMode,
       negative as ShortageMode|undefined);
    },
   });
   send(res,outcome.status,outcome.body,id,cors);return;
  }
  if(req.method==="GET"&&url.pathname==="/v1/inventory/stock-scopes"){
   const q=scope({branchId:url.searchParams.get("branchId"),
    warehouseId:url.searchParams.get("warehouseId")});
   const productId=uuid(url.searchParams.get("productId"));
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:tenant,actorId,
      permission:"inventory.read",...q}))throw new InventoryFault(403,"INVENTORY_READ_DENIED");
    send(res,200,{...await stockScopes(db,tenant,q,productId),requestId:id},id,cors);
   }finally{db.release();}
   return;
  }
  if(req.method==="GET"&&url.pathname==="/v1/inventory/direct-issues/totals"){
   const q=scope({branchId:url.searchParams.get("branchId"),
    warehouseId:url.searchParams.get("warehouseId")});
   const orderId=uuid(url.searchParams.get("orderId"));
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:tenant,actorId,
       permission:"inventory.read",...q})||
      !await hasPermission(db,{installationId:tenant,actorId,
       permission:"orders.read",branchId:q.branchId}))
      throw new InventoryFault(403,"INVENTORY_READ_DENIED");
    send(res,200,{items:await directIssueTotals(db,tenant,q,orderId),
      requestId:id},id,cors);
   }finally{db.release();}
   return;
  }
  if(req.method==="GET"&&url.pathname==="/v1/inventory/direct-issues/reconcile"){
   const q=scope({branchId:url.searchParams.get("branchId"),
    warehouseId:url.searchParams.get("warehouseId")});
   const orderId=uuid(url.searchParams.get("orderId"));
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:tenant,actorId,
      permission:"inventory.read",...q})||
      !await hasPermission(db,{installationId:tenant,actorId,
       permission:"orders.read",branchId:q.branchId}))
      throw new InventoryFault(403,"INVENTORY_READ_DENIED");
    const summary=await reconcileManualIssues(db,tenant,q,orderId);
    if(!summary.reconciled)throw new InventoryFault(409,"MANUAL_ISSUE_LEDGER_MISMATCH");
    send(res,200,{...summary,requestId:id},id,cors);
   }finally{db.release();}
   return;
  }
  if(req.method==="GET"&&url.pathname==="/v1/inventory/direct-issues"){
   const q=scope({branchId:url.searchParams.get("branchId"),
    warehouseId:url.searchParams.get("warehouseId")});
   const orderId=uuid(url.searchParams.get("orderId"));
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:tenant,actorId,
      permission:"inventory.read",...q})||
       !await hasPermission(db,{installationId:tenant,actorId,
        permission:"orders.read",branchId:q.branchId}))
      throw new InventoryFault(403,"INVENTORY_READ_DENIED");
    send(res,200,{items:await directIssueHistory(db,tenant,q,orderId),requestId:id},id,cors);
   }finally{db.release();}
   return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/inventory/locations"){
   const v=await parseBody(req);allowFields(v,["branchId","warehouseId","code","name"]);
   const q=scope(v),code=shortText(v.code,40),name=shortText(v.name,120);
   const payload={...q,code,name},c=ctx(req,id,tenant,actorId,"inventory.location.create",payload,true);
   const out=await executeMutation(pool,c,{
    authorize:(db,m)=>hasPermission(db,{installationId:m.installationId,actorId:m.actorId,
      permission:"inventory.policy.manage",...q}),
    execute:(db,m)=>createLocation(db,m,q,code,name),
   });
   send(res,out.status,out.body,id,cors);return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/inventory/lots"){
   const v=await parseBody(req);allowFields(v,["branchId","warehouseId","productId","lotCode","expiryDate"]);
   const q=scope(v),productId=uuid(v.productId),lotCode=shortText(v.lotCode,80),
    expiryDate=isoDate(v.expiryDate);
   const payload={...q,productId,lotCode,expiryDate};
   const c=ctx(req,id,tenant,actorId,"inventory.lot.create",payload,true);
   const out=await executeMutation(pool,c,{
    authorize:(db,m)=>hasPermission(db,{installationId:m.installationId,actorId:m.actorId,
     permission:"inventory.policy.manage",...q}),
    execute:(db,m)=>createLot(db,m,q,productId,lotCode,expiryDate),
   });
   send(res,out.status,out.body,id,cors);return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/inventory/tracking-policy"){
   const v=await parseBody(req);allowFields(v,
    ["branchId","warehouseId","productId","requireLocation","requireLot"]);
   const q=scope(v),productId=uuid(v.productId);
   if(typeof v.requireLocation!=="boolean"||typeof v.requireLot!=="boolean")
    throw new InventoryFault(400,"INVALID_TRACKING_POLICY");
   const requireLocation=v.requireLocation,requireLot=v.requireLot;
   const payload={...q,productId,requireLocation,requireLot};
   const c=ctx(req,id,tenant,actorId,"inventory.tracking.set",payload,false);
   const out=await executeMutation(pool,c,{
    authorize:(db,m)=>hasPermission(db,{installationId:m.installationId,actorId:m.actorId,
      permission:"inventory.policy.manage",...q}),
    execute:(db,m)=>setTrackingPolicy(db,m,q,productId,requireLocation,requireLot),
   });
   send(res,out.status,out.body,id,cors);return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/inventory/stock-scopes/assign"){
   const v=await parseBody(req);allowFields(v,
    ["branchId","warehouseId","productId","quantityBase","locationId","lotId"]);
   if(!validBaseQty(v.quantityBase))throw new InventoryFault(400,"INVALID_QUANTITY");
   const payload={...scope(v),productId:uuid(v.productId),
     quantityBase:v.quantityBase,
     ...(optionalUuid(v.locationId)?{locationId:uuid(v.locationId)}:{}),
     ...(optionalUuid(v.lotId)?{lotId:uuid(v.lotId)}:{})};
   const c=ctx(req,id,tenant,actorId,"inventory.stock-scope.assign",payload,true);
   const out=await executeMutation(pool,c,{
    authorize:(db,m)=>hasPermission(db,{installationId:m.installationId,actorId:m.actorId,
      permission:"inventory.post",branchId:payload.branchId,warehouseId:payload.warehouseId}),
    execute:(db,m)=>assignStockScope(db,m,payload),
   });
   send(res,out.status,out.body,id,cors);return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/inventory/direct-issues"){
   const v=await parseBody(req);allowFields(v,
    ["branchId","warehouseId","orderId","version","lines","allowNegative"]);
   if(!Array.isArray(v.lines)||v.lines.length<1||v.lines.length>100)
    throw new InventoryFault(400,"INVALID_ISSUE_LINES");
   const lines:DirectIssueItem[]=v.lines.map((x:unknown)=>{
    const row=record(x);
    allowFields(row,["lineNo","quantityBase","locationId","lotId"]);
    if(!validBaseQty(row.quantityBase))throw new InventoryFault(400,"INVALID_QUANTITY");
    return {lineNo:positiveInt(row.lineNo),quantityBase:row.quantityBase,
     ...(optionalUuid(row.locationId)?{locationId:uuid(row.locationId)}:{}),
     ...(optionalUuid(row.lotId)?{lotId:uuid(row.lotId)}:{})};
   });
   if(v.allowNegative!==undefined&&typeof v.allowNegative!=="boolean")
    throw new InventoryFault(400,"INVALID_NEGATIVE_FLAG");
   const input={...scope(v),orderId:uuid(v.orderId),version:positiveInt(v.version),
    lines,allowNegative:v.allowNegative===true};
   const c=ctx(req,id,tenant,actorId,"inventory.manual.issue",input,false);
   const out=await executeMutation(pool,c,{
    authorize:async(db,m)=>
      await hasPermission(db,{installationId:m.installationId,actorId:m.actorId,
       permission:"inventory.post",branchId:input.branchId,warehouseId:input.warehouseId})&&
      await hasPermission(db,{installationId:m.installationId,actorId:m.actorId,
       permission:"orders.update",branchId:input.branchId}),
    execute:(db,m)=>issueManualStock(db,m,input),
   });
   send(res,out.status,out.body,id,cors);return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/inventory/openings"){
   const raw=await parseBody(req);
   allowFields(raw,["branchId","warehouseId","productId","quantity"]);
   const quantity=raw.quantity;
   if(!validBaseQty(quantity))throw new InventoryFault(400,"INVALID_QUANTITY");
   const input={...scope(raw),productId:uuid(raw.productId),quantity};
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
