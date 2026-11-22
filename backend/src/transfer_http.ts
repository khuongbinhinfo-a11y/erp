import type { IncomingMessage, ServerResponse } from "node:http";
import type { Pool } from "pg";
import type { IdentityOptions } from "./identity_http.ts";
import { resolveSession } from "./auth.ts";
import { hasPermission } from "./rbac.ts";
import { executeMutation, MutationFault,type MutationContext } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";
import { validBaseQty } from "./inventory.ts";
import { TransferFault,createTransfer,transitionTransfer,receiveTransfer,
  transferDetail,listTransfers,type TransferScope,type TransferLine,type TransferReceiptLine } from "./transfer.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BEARER=/^Bearer ([A-Za-z0-9_-]{43})$/;
function send(res:ServerResponse,status:number,data:unknown,id:string,origin?:string){
 const h:Record<string,string>={"content-type":"application/json; charset=utf-8",
  "cache-control":"no-store","x-request-id":id,"vary":"Origin","x-content-type-options":"nosniff"};
 if(origin){
  h["access-control-allow-origin"]=origin;
  h["access-control-allow-methods"]="GET, POST, OPTIONS";
  h["access-control-allow-headers"]="content-type,authorization,idempotency-key,if-match,x-request-id";
 }
 res.writeHead(status,h);res.end(status===204?"":JSON.stringify(data));
}
function fail(res:ServerResponse,status:number,code:string,id:string,cors?:string){
 send(res,status,{error:{code,requestId:id,message:status===403?
 "Không có quyền với kho này.":status===409?
 "Tồn kho hoặc số lượng đã thay đổi. Hãy tải lại.":status===503?
 "Nghiệp vụ chuyển kho chưa sẵn sàng.":"Thông tin chuyển kho không hợp lệ."}},id,cors);
}
function uuid(x:unknown):string{
 if(typeof x!=="string"||!UUID.test(x))throw new TransferFault(400,"INVALID_UUID");
 return x;
}
function obj(x:unknown):Record<string,unknown>{
 if(!x||typeof x!=="object"||Array.isArray(x))throw new TransferFault(400,"INVALID_OBJECT");
 return x as Record<string,unknown>;
}
function only(x:Record<string,unknown>,keys:string[]){
 if(Object.keys(x).some(k=>!keys.includes(k)))throw new TransferFault(400,"UNKNOWN_FIELD");
}
function scope(x:Record<string,unknown>):TransferScope{
 return {branchId:uuid(x.branchId),sourceWarehouseId:uuid(x.sourceWarehouseId),
  destinationWarehouseId:uuid(x.destinationWarehouseId)};
}
function lines(x:unknown,receipt=false):TransferLine[]|TransferReceiptLine[]{
 if(!Array.isArray(x)||x.length<1||x.length>40)throw new TransferFault(400,"INVALID_LINES");
 if(receipt)return x.map((raw:unknown):TransferReceiptLine=>{
  const v=obj(raw);only(v,["transferLineNo","quantity"]);
  const n=v.transferLineNo;
  if(typeof n!=="number"||!Number.isSafeInteger(n)||n<1||n>10000||
     !validBaseQty(v.quantity))throw new TransferFault(400,"INVALID_RECEIPT_LINE");
  return {transferLineNo:n,quantity:v.quantity};
 });
 return x.map((raw:unknown):TransferLine=>{
  const v=obj(raw);only(v,["productId","quantity"]);
  if(!validBaseQty(v.quantity))throw new TransferFault(400,"INVALID_QTY");
  return {productId:uuid(v.productId),quantity:v.quantity};
 });
}
async function body(req:IncomingMessage){
 if(req.headers["content-type"]?.split(";")[0]?.trim().toLowerCase()!=="application/json")
  throw new TransferFault(415,"JSON_REQUIRED");
 let size=0;const chunks:Buffer[]=[];
 for await(const chunk of req){
  const b=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk as Uint8Array);
  size+=b.length;if(size>8192)throw new TransferFault(413,"BODY_TOO_LARGE");
  chunks.push(b);
 }
 try{return obj(JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown);}
 catch(e){if(e instanceof TransferFault)throw e;throw new TransferFault(400,"INVALID_JSON");}
}
function ctx(req:IncomingMessage,id:string,t:string,actor:string,
  action:string,payload:Record<string,unknown>,create=false):MutationContext{
 const key=req.headers["idempotency-key"],rev=req.headers["if-match"];
 if(typeof key!=="string"||!validIdempotencyKey(key)||typeof rev!=="string"||
  !/^(0|[1-9][0-9]{0,14})$/.test(rev))throw new TransferFault(400,"MUTATION_HEADERS_REQUIRED");
 const n=Number(rev);
 if(!Number.isSafeInteger(n)||(create&&n!==0))throw new TransferFault(400,"INVALID_REVISION");
 return {installationId:t,actorId:actor,requestId:id,
   action,idempotencyKey:key,expectedRevision:n,payload};
}
async function schemaReady(db:Pool){
 try{
  const q=await db.query<{yes:boolean}>(
   "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0013_r3_transfer_in_transit.sql') AS yes");
  return q.rows[0]?.yes===true;
 }catch{return false;}
}
export async function handleTransferHttp(req:IncomingMessage,res:ServerResponse,
 id:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fail(res,403,"ORIGIN_DENIED",id);return;}
 if(req.method==="OPTIONS"){
  if(!cors){fail(res,403,"ORIGIN_DENIED",id);return;}
  send(res,204,null,id,cors);return;
 }
 const t=opts.installationId,db=opts.pool;
 if(!t||!UUID.test(t)||!db||!opts.allowedOrigin){
  fail(res,503,"TRANSFER_NOT_CONFIGURED",id,cors);return;
 }
 try{
  if(!await ready()||!await schemaReady(db)){
   fail(res,503,"TRANSFER_MIGRATION_REQUIRED",id,cors);return;
  }
  const token=typeof req.headers.authorization==="string"?
   BEARER.exec(req.headers.authorization)?.[1]:undefined;
  const c=await db.connect();let actor:string|undefined;
  try{actor=token?(await resolveSession(c,t,token))?.actorId:undefined;}
  finally{c.release();}
  if(!actor){fail(res,401,"AUTH_REQUIRED",id,cors);return;}
  const route=/^\/v1\/inventory\/transfers\/([0-9a-f-]{36})(?:\/(approve|dispatch|cancel|receipts))?$/.exec(url.pathname);
  if(req.method==="GET"){
   const b=uuid(url.searchParams.get("branchId"));
   const wh=uuid(url.searchParams.get("warehouseId"));
   const con=await db.connect();
   try{
    if(!await hasPermission(con,{installationId:t,actorId:actor,
      permission:"inventory.transfer.read",branchId:b,warehouseId:wh}))
      throw new TransferFault(403,"TRANSFER_READ_DENIED");
    if(route&&!route[2]){
     const s=scope({branchId:b,sourceWarehouseId:url.searchParams.get("sourceWarehouseId"),
       destinationWarehouseId:url.searchParams.get("destinationWarehouseId")});
     if(![s.sourceWarehouseId,s.destinationWarehouseId].includes(wh))
      throw new TransferFault(403,"TRANSFER_READ_SCOPE_DENIED");
     send(res,200,{transfer:await transferDetail(con,t,s,uuid(route[1])),
       requestId:id},id,cors);
    }else if(url.pathname==="/v1/inventory/transfers"){
     const offset=url.searchParams.get("offset")??"0";
     if(!/^(0|[1-9][0-9]{0,5})$/.test(offset)||Number(offset)%100!==0)
      throw new TransferFault(400,"INVALID_PAGE");
     send(res,200,{...(await listTransfers(con,t,b,wh,Number(offset))),
       requestId:id},id,cors);
    }else fail(res,404,"TRANSFER_ROUTE_NOT_FOUND",id,cors);
   }finally{con.release();}
   return;
  }
  if(req.method!=="POST"){fail(res,405,"METHOD_NOT_ALLOWED",id,cors);return;}
  if(url.pathname==="/v1/inventory/transfers"){
   const raw=await body(req);
   only(raw,["branchId","sourceWarehouseId","destinationWarehouseId","note","lines"]);
   const s=scope(raw),note=raw.note??"";
   if(typeof note!=="string"||note.length>500)throw new TransferFault(400,"NOTE_INVALID");
   const data={...s,note,lines:lines(raw.lines) as TransferLine[]};
   const m=ctx(req,id,t,actor,"inventory.transfer.create",data,true);
   const result=await executeMutation(db,m,{
    authorize:async(con,x)=>await hasPermission(con,{installationId:t,actorId:x.actorId,
      permission:"inventory.transfer.create",branchId:s.branchId,
      warehouseId:s.sourceWarehouseId})&&
      await hasPermission(con,{installationId:t,actorId:x.actorId,
       permission:"inventory.read",branchId:s.branchId,
       warehouseId:s.destinationWarehouseId}),
    execute:(con,x)=>createTransfer(con,x,data),
   });
   send(res,result.status,result.body,id,cors);return;
  }
  if(route&&route[2]){
   const transferId=uuid(route[1]),action=route[2],raw=await body(req);
   const s=scope(raw);
   if(action==="receipts"){
    only(raw,["branchId","sourceWarehouseId","destinationWarehouseId","lines"]);
    const data={...s,transferId,lines:lines(raw.lines,true) as TransferReceiptLine[]};
    const m=ctx(req,id,t,actor,"inventory.transfer.receive",data);
    const result=await executeMutation(db,m,{
     authorize:(con,x)=>hasPermission(con,{installationId:t,actorId:x.actorId,
       permission:"inventory.transfer.receive",branchId:s.branchId,
       warehouseId:s.destinationWarehouseId}),
     execute:(con,x)=>receiveTransfer(con,x,data),
    });
    send(res,result.status,result.body,id,cors);return;
   }
   only(raw,["branchId","sourceWarehouseId","destinationWarehouseId"]);
   const data={...s,transferId};
   const m=ctx(req,id,t,actor,"inventory.transfer."+action,data);
   const permission=action==="approve"?"inventory.transfer.approve":
     action==="dispatch"?"inventory.transfer.dispatch":"inventory.transfer.create";
   const result=await executeMutation(db,m,{
    authorize:(con,x)=>hasPermission(con,{installationId:t,actorId:x.actorId,
      permission,branchId:s.branchId,warehouseId:s.sourceWarehouseId}),
    execute:(con,x)=>transitionTransfer(con,x,s,transferId,
     action as "approve"|"dispatch"|"cancel"),
   });
   send(res,result.status,result.body,id,cors);return;
  }
  fail(res,404,"TRANSFER_ROUTE_NOT_FOUND",id,cors);
 }catch(e){
  if(e instanceof TransferFault){fail(res,e.status,e.code,id,cors);return;}
  if(e instanceof MutationFault){fail(res,e.httpStatus,e.code,id,cors);return;}
  if(e&&typeof e==="object"&&"code" in e){
   if(e.code==="23505"){fail(res,409,"TRANSFER_DUPLICATE",id,cors);return;}
   if(e.code==="23503"||e.code==="23514"){
    fail(res,409,"TRANSFER_CONSTRAINT",id,cors);return;
   }
  }
  fail(res,503,"TRANSFER_UNAVAILABLE",id,cors);
 }
}
