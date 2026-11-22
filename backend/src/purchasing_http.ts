import type { IncomingMessage, ServerResponse } from "node:http";
import type { Pool } from "pg";
import type { IdentityOptions } from "./identity_http.ts";
import { resolveSession } from "./auth.ts";
import { hasPermission } from "./rbac.ts";
import { executeMutation, MutationFault, type MutationContext } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";
import { PurchaseFault, validCost,listOrders,orderDetail,createPurchase,
 confirmPurchase,cancelPurchase,postReceipt,
 type PurchaseScope,type PurchaseLine,type PurchaseReceiptLine } from "./purchasing.ts";
import { validBaseQty } from "./inventory.ts";
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BEARER=/^Bearer ([A-Za-z0-9_-]{43})$/;
function output(res:ServerResponse,status:number,body:unknown,id:string,origin?:string){
 const headers:Record<string,string>={
  "content-type":"application/json; charset=utf-8","cache-control":"no-store",
  "x-request-id":id,"x-content-type-options":"nosniff","vary":"Origin",
 };
 if(origin){
  headers["access-control-allow-origin"]=origin;
  headers["access-control-allow-methods"]="GET, POST, OPTIONS";
  headers["access-control-allow-headers"]="content-type,authorization,idempotency-key,if-match,x-request-id";
 }
 res.writeHead(status,headers);res.end(status===204?"":JSON.stringify(body));
}
function fail(res:ServerResponse,status:number,code:string,id:string,origin?:string){
 const message=status===401?"Phiên đăng nhập không hợp lệ":
  status===403?"Không có quyền với đơn mua hoặc kho này.":
  status===409?"Đơn mua, số lượng hoặc chứng từ đã thay đổi. Hãy tải lại.":
  status===503?"Nghiệp vụ mua hàng chưa sẵn sàng.":
  status===404?"Không tìm thấy đơn mua.":"Dữ liệu mua hàng không hợp lệ.";
 output(res,status,{error:{code,message,requestId:id}},id,origin);
}
function uuid(x:unknown){
 if(typeof x!=="string"||!UUID.test(x))throw new PurchaseFault(400,"INVALID_UUID");
 return x;
}
function rec(x:unknown):Record<string,unknown>{
 if(x===null||typeof x!=="object"||Array.isArray(x))
  throw new PurchaseFault(400,"INVALID_JSON_OBJECT");
 return x as Record<string,unknown>;
}
function whitelist(x:Record<string,unknown>,keys:string[]){
 if(Object.keys(x).some(k=>!keys.includes(k)))
  throw new PurchaseFault(400,"UNKNOWN_FIELD");
}
function scope(x:Record<string,unknown>):PurchaseScope{
 return {branchId:uuid(x.branchId),warehouseId:uuid(x.warehouseId)};
}
function int(x:unknown){
 if(typeof x!=="number"||!Number.isSafeInteger(x)||x<1||x>10000)
  throw new PurchaseFault(400,"INVALID_LINE_NO");
 return x;
}
function lines(value:unknown,receipt=false){
 if(!Array.isArray(value)||value.length<1||value.length>40)
  throw new PurchaseFault(400,"INVALID_LINES");
 if(receipt){
  return value.map((v:unknown)=>{
   const x=rec(v);whitelist(x,["orderLineNo","quantity"]);
   if(!validBaseQty(x.quantity))throw new PurchaseFault(400,"INVALID_QTY");
   return {orderLineNo:int(x.orderLineNo),quantity:x.quantity} satisfies PurchaseReceiptLine;
  });
 }
 return value.map((v:unknown)=>{
  const x=rec(v);whitelist(x,["productId","quantity","unitCost"]);
  if(!validBaseQty(x.quantity)||!validCost(x.unitCost))
   throw new PurchaseFault(400,"INVALID_DECIMAL");
  return {productId:uuid(x.productId),quantity:x.quantity,
   unitCost:x.unitCost} satisfies PurchaseLine;
 });
}
async function body(req:IncomingMessage){
 if(req.headers["content-type"]?.split(";")[0]?.trim().toLowerCase()!=="application/json")
  throw new PurchaseFault(415,"JSON_REQUIRED");
 let count=0;const parts:Buffer[]=[];
 for await(const chunk of req){
  const bytes=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk as Uint8Array);
  count+=bytes.length;
  if(count>8192)throw new PurchaseFault(413,"BODY_TOO_LARGE");
  parts.push(bytes);
 }
 try{return rec(JSON.parse(Buffer.concat(parts).toString("utf8")) as unknown);}
 catch(e){if(e instanceof PurchaseFault)throw e;throw new PurchaseFault(400,"INVALID_JSON");}
}
function context(req:IncomingMessage,id:string,t:string,actor:string,
 action:string,payload:Record<string,unknown>,create=false):MutationContext{
 const key=req.headers["idempotency-key"],r=req.headers["if-match"];
 if(typeof key!=="string"||!validIdempotencyKey(key)||
    typeof r!=="string"||!/^(0|[1-9][0-9]{0,14})$/.test(r))
  throw new PurchaseFault(400,"MUTATION_HEADERS_REQUIRED");
 const revision=Number(r);
 if(!Number.isSafeInteger(revision)||(create&&revision!==0))
  throw new PurchaseFault(400,"INVALID_REVISION");
 return {installationId:t,actorId:actor,requestId:id,action,
  idempotencyKey:key,expectedRevision:revision,payload};
}
async function schemaReady(pool:Pool){
 try{
  const r=await pool.query<{ok:boolean}>(
   "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0012_r3_purchase_receipt.sql') AS ok");
  return r.rows[0]?.ok===true;
 }catch{return false;}
}
export async function handlePurchasingHttp(req:IncomingMessage,res:ServerResponse,
 id:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fail(res,403,"ORIGIN_DENIED",id);return;}
 if(req.method==="OPTIONS"){
  if(!cors){fail(res,403,"ORIGIN_DENIED",id);return;}
  output(res,204,null,id,cors);return;
 }
 const t=opts.installationId,pool=opts.pool;
 if(!t||!UUID.test(t)||!pool||!opts.allowedOrigin){
  fail(res,503,"PURCHASE_NOT_CONFIGURED",id,cors);return;
 }
 try{
  if(!await ready()||!await schemaReady(pool)){
   fail(res,503,"PURCHASE_MIGRATION_REQUIRED",id,cors);return;
  }
  const token=typeof req.headers.authorization==="string"
    ?BEARER.exec(req.headers.authorization)?.[1]:undefined;
  const auth=await pool.connect();let actor:string|undefined;
  try{actor=token?(await resolveSession(auth,t,token))?.actorId:undefined;}
  finally{auth.release();}
  if(!actor){fail(res,401,"AUTH_REQUIRED",id,cors);return;}
  if(req.method==="GET"&&url.pathname==="/v1/purchasing/orders"){
   const s=scope({branchId:url.searchParams.get("branchId"),
    warehouseId:url.searchParams.get("warehouseId")});
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:t,actorId:actor,
      permission:"purchase.read",branchId:s.branchId})||
       !await hasPermission(db,{installationId:t,actorId:actor,
      permission:"inventory.read",...s}))throw new PurchaseFault(403,"PURCHASE_READ_DENIED");
    const rawOffset=url.searchParams.get("offset")??"0";
    if(!/^(0|[1-9][0-9]{0,5})$/.test(rawOffset)||
        Number(rawOffset)%100!==0)
      throw new PurchaseFault(400,"INVALID_PURCHASE_PAGE");
    const page=await listOrders(db,t,s.branchId,[s.warehouseId],Number(rawOffset));
    output(res,200,{...page,requestId:id},id,cors);
   }finally{db.release();}
   return;
  }
  const route=/^\/v1\/purchasing\/orders\/([0-9a-f-]{36})(?:\/(confirm|cancel|receipts))?$/.exec(url.pathname);
  if(req.method==="GET"&&route&&!route[2]){
   const orderId=uuid(route[1]),s=scope({
    branchId:url.searchParams.get("branchId"),warehouseId:url.searchParams.get("warehouseId")});
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:t,actorId:actor,
      permission:"purchase.read",branchId:s.branchId})||
       !await hasPermission(db,{installationId:t,actorId:actor,
        permission:"inventory.read",...s}))throw new PurchaseFault(403,"PURCHASE_READ_DENIED");
    output(res,200,{order:await orderDetail(db,t,s,orderId),requestId:id},id,cors);
   }finally{db.release();}
   return;
  }
  if(req.method!=="POST"){fail(res,405,"METHOD_NOT_ALLOWED",id,cors);return;}
  if(url.pathname==="/v1/purchasing/orders"){
   const raw=await body(req);whitelist(raw,["branchId","warehouseId","supplierId","note","lines"]);
   const s=scope(raw),supplierId=uuid(raw.supplierId);
   const note=raw.note===undefined?"":raw.note;
   if(typeof note!=="string"||note.length>500)throw new PurchaseFault(400,"INVALID_NOTE");
   const parsed=lines(raw.lines,false) as PurchaseLine[];
   const input={...s,supplierId,note,lines:parsed};
   const m=context(req,id,t,actor,"purchase.order.create",input,true);
   const response=await executeMutation(pool,m,{
    authorize:async(db,ctx)=>
      await hasPermission(db,{installationId:t,actorId:ctx.actorId,
        permission:"purchase.create",branchId:s.branchId})&&
      await hasPermission(db,{installationId:t,actorId:ctx.actorId,
        permission:"inventory.read",...s}),
    execute:(db,ctx)=>createPurchase(db,ctx,input),
   });
   output(res,response.status,response.body,id,cors);return;
  }
  if(route&&route[2]){
   const orderId=uuid(route[1]),action=route[2],raw=await body(req);
   if(action==="receipts"){
    whitelist(raw,["branchId","warehouseId","lines"]);
    const s=scope(raw),parsed=lines(raw.lines,true) as PurchaseReceiptLine[];
    const input={...s,orderId,lines:parsed};
    const m=context(req,id,t,actor,"purchase.receipt.post",input);
    const response=await executeMutation(pool,m,{
     authorize:async(db,ctx)=>
       await hasPermission(db,{installationId:t,actorId:ctx.actorId,
         permission:"purchase.receive",...s}),
     execute:(db,ctx)=>postReceipt(db,ctx,input),
    });
    output(res,response.status,response.body,id,cors);return;
   }
   whitelist(raw,["branchId","warehouseId"]);
   const s=scope(raw),payload={...s,orderId};
   const m=context(req,id,t,actor,"purchase.order."+action,payload);
   const permission=action==="confirm"?"purchase.confirm":"purchase.create";
   const response=await executeMutation(pool,m,{
    authorize:async(db,ctx)=>
      await hasPermission(db,{installationId:t,actorId:ctx.actorId,
         permission,branchId:s.branchId})&&
      await hasPermission(db,{installationId:t,actorId:ctx.actorId,
         permission:"inventory.read",...s}),
    execute:(db,ctx)=>action==="confirm"
      ?confirmPurchase(db,ctx,s,orderId):cancelPurchase(db,ctx,s,orderId),
   });
   output(res,response.status,response.body,id,cors);return;
  }
  fail(res,404,"PURCHASE_ROUTE_NOT_FOUND",id,cors);
 }catch(err){
  if(err instanceof PurchaseFault){fail(res,err.status,err.code,id,cors);return;}
  if(err instanceof MutationFault){fail(res,err.httpStatus,err.code,id,cors);return;}
  if(err&&typeof err==="object"&&"code" in err){
   if(err.code==="23505"){fail(res,409,"PURCHASE_DUPLICATE",id,cors);return;}
   if(err.code==="23503"||err.code==="23514"){
    fail(res,409,"PURCHASE_CONSTRAINT",id,cors);return;}
  }
  fail(res,503,"PURCHASE_UNAVAILABLE",id,cors);
 }
}
