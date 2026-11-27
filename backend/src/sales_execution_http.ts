import type {IncomingMessage,ServerResponse} from "node:http";
import type {Pool,PoolClient} from "pg";
import type {IdentityOptions} from "./identity_http.ts";
import {resolveSession} from "./auth.ts";
import {hasPermission} from "./rbac.ts";
import {validIdempotencyKey} from "./contracts.ts";
import {executeMutation,readCommittedMutation,MutationFault,type MutationContext} from "./mutation.ts";
import {ExecutionFault,requireT5a,executionRead,returnManual,completeManual,payManual,
 type ExecutionScope,type ManualReturnInput,type ManualPaymentInput} from "./sales_execution_core.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MONEY=/^(?:0|[1-9][0-9]{0,15})$/;
const POS=/^(?:0|[1-9][0-9]{0,8})(?:\.[0-9]{1,6})?$/;
class InputFault extends Error {
 readonly httpStatus:number;
 readonly code:string;
 constructor(httpStatus:number,code:string){super(code);this.httpStatus=httpStatus;this.code=code;}
}
const id=(x:unknown):string=>{
 if(typeof x!=="string"||!UUID.test(x))throw new InputFault(400,"INVALID_ID");return x;
};
const integer=(x:unknown):number=>{
 if(typeof x!=="number"||!Number.isSafeInteger(x)||x<1||x>10000)
  throw new InputFault(400,"INVALID_INTEGER");
 return x;
};
const qty=(x:unknown):string=>{
 if(typeof x!=="string"||!POS.test(x)||!/[1-9]/.test(x))
  throw new InputFault(400,"INVALID_QUANTITY");
 return x;
};
const record=(v:unknown):Record<string,unknown>=>{
 if(!v||Array.isArray(v)||typeof v!=="object")throw new InputFault(400,"INVALID_BODY");
 return v as Record<string,unknown>;
};
const only=(v:Record<string,unknown>,fields:string[])=>{
 if(Object.keys(v).some(x=>!fields.includes(x)))throw new InputFault(400,"UNKNOWN_FIELD");
};
async function body(req:IncomingMessage){
 if(req.headers["content-type"]?.split(";")[0]?.trim()!=="application/json")
  throw new InputFault(415,"JSON_REQUIRED");
 const chunks:Buffer[]=[];let bytes=0;
 for await(const part of req){
  const buf=Buffer.isBuffer(part)?part:Buffer.from(part as Uint8Array);
  bytes+=buf.length;if(bytes>32768)throw new InputFault(413,"BODY_TOO_LARGE");
  chunks.push(buf);
 }
 try{return record(JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown);}
 catch(e){if(e instanceof InputFault)throw e;throw new InputFault(400,"INVALID_JSON");}
}
function base(raw:Record<string,unknown>,withVersion:boolean):ExecutionScope{
 const branchId=id(raw.branchId),warehouseId=id(raw.warehouseId),orderId=id(raw.orderId);
 return {branchId,warehouseId,orderId,version:withVersion?integer(raw.version):0};
}
function parseAction(action:string,raw:Record<string,unknown>){
 if(action==="complete"){
  only(raw,["branchId","warehouseId","orderId","version"]);
  return base(raw,true);
 }
 if(action==="return"){
  only(raw,["branchId","warehouseId","orderId","version","reason","lines"]);
  const scope=base(raw,true);
  const reason=raw.reason;
  if(typeof reason!=="string"||reason.trim().length<3||reason.length>500)
   throw new InputFault(400,"INVALID_REASON");
  if(!Array.isArray(raw.lines)||raw.lines.length<1||raw.lines.length>100)
   throw new InputFault(400,"INVALID_RETURN_LINES");
  const used=new Set<string>();
  const lines=raw.lines.map(x=>{
   const l=record(x);only(l,["issueId","sourceLine","quantityBase"]);
   const issueId=id(l.issueId),sourceLine=integer(l.sourceLine),quantityBase=qty(l.quantityBase);
   const key=issueId+":"+sourceLine;
   if(used.has(key))throw new InputFault(400,"DUPLICATE_RETURN_SOURCE");
   used.add(key);return {issueId,sourceLine,quantityBase};
  });
  return {...scope,reason:reason.trim(),lines};
 }
 if(action==="payment"){
  only(raw,["branchId","warehouseId","orderId","amount","method"]);
  const scope=base(raw,false);
  const amount=raw.amount,method=raw.method;
  if(typeof amount!=="string"||!MONEY.test(amount))
   throw new InputFault(400,"INVALID_PAYMENT_AMOUNT");
  if(method!=="CASH"&&method!=="BANK_TRANSFER")
   throw new InputFault(400,"INVALID_PAYMENT_METHOD");
  return {branchId:scope.branchId,warehouseId:scope.warehouseId,
   orderId:scope.orderId,amount,method} satisfies ManualPaymentInput;
 }
 throw new InputFault(400,"INVALID_ACTION");
}
function ctx(req:IncomingMessage,rid:string,t:string,actor:string,action:string,payload:unknown){
 const key=req.headers["idempotency-key"],rev=req.headers["if-match"];
 if(typeof key!=="string"||!validIdempotencyKey(key)||
  typeof rev!=="string"||!/^(0|[1-9][0-9]{0,14})$/.test(rev))
  throw new InputFault(400,"MUTATION_HEADERS_REQUIRED");
 const expectedRevision=Number(rev);
 if(!Number.isSafeInteger(expectedRevision))throw new InputFault(400,"INVALID_REVISION");
 return {installationId:t,actorId:actor,requestId:rid,idempotencyKey:key,
  expectedRevision,action:"sales.execution."+action,payload} satisfies MutationContext;
}
async function permitted(db:PoolClient,c:MutationContext,s:Pick<ExecutionScope,'branchId'|'warehouseId'|'orderId'>,action:string){
 const branch=s.branchId,warehouse=s.warehouseId,tenant=c.installationId,actor=c.actorId;
 const branchPerm=action==="read"?["orders.read"]:
  action==="payment"?["orders.read","finance.payments.record"]:
  action==="return"?["orders.update","delivery.update"]:["orders.read","delivery.update"];
 const warehousePerm=action==="return"?["inventory.post"]:["inventory.read"];
 for(const permission of branchPerm){
  if(!await hasPermission(db,{installationId:tenant,actorId:actor,
   branchId:branch,permission}))return false;
 }
 for(const permission of warehousePerm){
  if(!await hasPermission(db,{installationId:tenant,actorId:actor,
   branchId:branch,warehouseId:warehouse,permission}))return false;
 }
 return true;
}
function send(res:ServerResponse,status:number,payload:unknown,rid:string,cors?:string){
 res.writeHead(status,{"content-type":"application/json; charset=utf-8",
  "cache-control":"no-store","x-request-id":rid,"x-content-type-options":"nosniff",
  "vary":"Origin",...(cors?{"access-control-allow-origin":cors,
   "access-control-allow-headers":"authorization,content-type,idempotency-key,if-match,x-request-id",
   "access-control-allow-methods":"GET,POST,OPTIONS"}:{})});
 res.end(status===204?"":JSON.stringify(payload));
}
function fail(res:ServerResponse,httpStatus:number,code:string,rid:string,cors?:string){
 const messages:Record<string,string>={
  T5A_MIGRATION_REQUIRED:"Chức năng hoàn thành và thu tiền chưa được nâng cấp trên máy chủ.",
  CONFIRMED_MANUAL_ORDER_REQUIRED:"Đơn phải xác nhận ở chế độ giao thủ công, đúng kho và phiên bản.",
  DELIVERY_ALREADY_COMPLETED:"Đơn đã hoàn thành giao. Chỉ có thể tạo chứng từ điều chỉnh.",
  NO_ISSUED_GOODS_TO_DELIVER:"Chưa có hàng thực xuất để hoàn thành đơn.",
  PAYMENT_EXCEEDS_REMAINING:"Số tiền nhập lớn hơn số còn phải thu.",
  MANUAL_DELIVERY_NOT_COMPLETED:"Phải hoàn thành giao hàng trước khi ghi nhận thu tiền.",
  ISSUE_LINE_NOT_FOUND:"Không tìm thấy dòng xuất kho còn hiệu lực.",
  RECEIVABLE_RECONCILIATION_REQUIRED:"Công nợ chưa đối soát được. Không thể ghi tiền.",
  FORBIDDEN:"Không có quyền phù hợp tại chi nhánh/kho.",
 };
 send(res,httpStatus,{error:{code,message:messages[code]??(
  httpStatus===409?"Dữ liệu đơn đã thay đổi, hãy tải lại và đối soát.":
  httpStatus===503?"Chức năng chứng từ đang tạm gián đoạn.":"Thông tin không hợp lệ."),requestId:rid}},rid,cors);
}
export async function handleExecutionHttp(req:IncomingMessage,res:ServerResponse,rid:string,
 url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin&&origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fail(res,403,"ORIGIN_DENIED",rid);return;}
 if(req.method==="OPTIONS"){send(res,204,null,rid,cors);return;}
 const t=opts.installationId,pool=opts.pool;
 if(!t||!UUID.test(t)||!pool||!opts.allowedOrigin){
  fail(res,503,"EXECUTION_NOT_CONFIGURED",rid,cors);return;
 }
 try{
  if(!await ready()){fail(res,503,"BACKEND_NOT_READY",rid,cors);return;}
  const schema=await pool.query<{ok:boolean}>(`SELECT EXISTS(
   SELECT 1 FROM schema_migrations WHERE version='0026_t5a_sales_execution.sql') AS ok`);
  if(!schema.rows[0]?.ok){fail(res,503,"T5A_MIGRATION_REQUIRED",rid,cors);return;}
  const token=typeof req.headers.authorization==="string"
   ?/^Bearer ([A-Za-z0-9_-]{43})$/.exec(req.headers.authorization)?.[1]:undefined;
  const sessionDb=await pool.connect();
  let actor:string|undefined;
  try{actor=token?(await resolveSession(sessionDb,t,token))?.actorId:undefined;}
  finally{sessionDb.release();}
  if(!actor){fail(res,401,"AUTH_REQUIRED",rid,cors);return;}
  if(req.method==="GET"&&url.pathname==="/v1/sales/execution/read"){
   const raw={branchId:url.searchParams.get("branchId"),
    warehouseId:url.searchParams.get("warehouseId"),
    orderId:url.searchParams.get("orderId")};
   const s=base(raw,false);
   const c={installationId:t,actorId:actor,requestId:rid,
    action:"sales.execution.read",idempotencyKey:"read",
    expectedRevision:0,payload:{}} satisfies MutationContext;
   const db=await pool.connect();
   try{
    if(!await permitted(db,c,s,"read"))throw new ExecutionFault(403,"FORBIDDEN");
    send(res,200,{execution:await executionRead(db,c,s),requestId:rid},rid,cors);
   }finally{db.release();}
   return;
  }
  if(req.method==="POST"&&url.pathname==="/v1/sales/execution/recovery"){
   const raw=await body(req);only(raw,["action","body"]);
   const action=raw.action;
   if(typeof action!=="string")throw new InputFault(400,"INVALID_ACTION");
   const payload=parseAction(action,record(raw.body));
   const c=ctx(req,rid,t,actor,action,payload);
   const receipt=await readCommittedMutation(pool,c,(db,x)=>
    permitted(db,x,payload,action));
   send(res,200,{receipt:receipt?.body??null,requestId:rid},rid,cors);return;
  }
  const action=url.pathname==="/v1/sales/execution/complete"?"complete":
   url.pathname==="/v1/sales/execution/returns"?"return":
   url.pathname==="/v1/sales/execution/payments"?"payment":null;
  if(req.method==="POST"&&action){
   const payload=parseAction(action,await body(req));
   const c=ctx(req,rid,t,actor,action,payload);
   const result=await executeMutation(pool,c,{
    authorize:(db,x)=>permitted(db,x,payload,action),
    execute:(db,x)=>action==="return"?returnManual(db,x,payload as ManualReturnInput):
     action==="complete"?completeManual(db,x,payload as ExecutionScope):
     payManual(db,x,payload as ManualPaymentInput),
   });
   send(res,result.status,result.body,rid,cors);return;
  }
  fail(res,404,"NOT_FOUND",rid,cors);
 }catch(err){
  if(err instanceof InputFault||err instanceof ExecutionFault||
   err instanceof MutationFault){fail(res,err.httpStatus,err.code,rid,cors);return;}
  if(err&&typeof err==="object"&&"code" in err){
   const code=String(err.code);
   if(code==="23505"){fail(res,409,"DUPLICATE_EXECUTION",rid,cors);return;}
   if(code==="23503"||code==="23514"||code==="P0001"){
    fail(res,409,"EXECUTION_CONSTRAINT_REJECTED",rid,cors);return;}
  }
  fail(res,503,"EXECUTION_UNAVAILABLE",rid,cors);
 }
}
