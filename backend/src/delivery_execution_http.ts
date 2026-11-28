import type {IncomingMessage,ServerResponse} from "node:http";
import type {PoolClient} from "pg";
import type {IdentityOptions} from "./identity_http.ts";
import {resolveSession} from "./auth.ts";
import {hasPermission} from "./rbac.ts";
import {executeMutation,readCommittedMutation,MutationFault,type MutationContext} from "./mutation.ts";
import {DeliveryTripFault} from "./delivery_trip.ts";
import {executeStart,executionRead,executeAttempt,executeReturn,executeCollect,executeHandover} from "./delivery_execution.ts";
import type {AttemptInput} from "./delivery_attempt_contract.ts";
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
type Scope={branchId:string;warehouseId:string;tripId:string};
type Action="start"|"attempt"|"return"|"collect"|"handover";
type Body=Scope&{orderId?:string;result?:AttemptInput["result"];reasonCode?:string;rescheduledFor?:string;
 lines?:{dispatchId:string;sourceLine:number;deliveredBase?:string;quantityBase?:string}[];
 reason?:string;amount?:string;method?:string;collectionLines?:{collectionId:string;amount:string}[]};
const err=(code:string,status=400):never=>{throw new DeliveryTripFault(status,code);};
function id(v:unknown):string{if(typeof v!=="string"||!UUID.test(v))err("INVALID_ID");return v as string;}
function obj(v:unknown):Record<string,unknown>{
 if(!v||typeof v!=="object"||Array.isArray(v))err("INVALID_BODY");
 return v as Record<string,unknown>;
}
function fields(x:Record<string,unknown>,allowed:string[]){
 if(Object.keys(x).some(k=>!allowed.includes(k)))err("UNKNOWN_FIELD");
}
function scope(raw:Record<string,unknown>):Scope{
 return {branchId:id(raw.branchId),warehouseId:id(raw.warehouseId),tripId:id(raw.tripId)};
}
function parsed(action:Action,raw:Record<string,unknown>):Body{
 const s=scope(raw);
 if(action==="start"){fields(raw,["branchId","warehouseId","tripId"]);return s;}
 if(action==="handover"){
  fields(raw,["branchId","warehouseId","tripId","collectionLines"]);
  if(!Array.isArray(raw.collectionLines)||raw.collectionLines.length<1||raw.collectionLines.length>200)err("COD_HANDOVER_INVALID");
  const collectionLines=raw.collectionLines.map(item=>{
   const x=obj(item);fields(x,["collectionId","amount"]);
   if(typeof x.amount!=="string"||!/^[1-9][0-9]{0,15}$/.test(x.amount))err("COD_HANDOVER_INVALID");
   return {collectionId:id(x.collectionId),amount:x.amount as string};
  });
  return {...s,collectionLines};
 }
 const orderId=id(raw.orderId);
 if(action==="collect"){
  fields(raw,["branchId","warehouseId","tripId","orderId","amount","method"]);
  if(typeof raw.amount!=="string"||!/^(0|[1-9][0-9]{0,15})$/.test(raw.amount))err("INVALID_PAYMENT_AMOUNT");
  if(raw.method!=="CASH"&&raw.method!=="BANK_TRANSFER")err("INVALID_PAYMENT_METHOD");
  return {...s,orderId,amount:raw.amount,method:raw.method};
 }
 if(action==="return"){
  fields(raw,["branchId","warehouseId","tripId","orderId","reason","lines"]);
  if(typeof raw.reason!=="string"||raw.reason.trim().length<3||raw.reason.length>500)err("RETURN_REASON_REQUIRED");
  if(!Array.isArray(raw.lines)||raw.lines.length<1||raw.lines.length>1000)err("RETURN_LINES_REQUIRED");
  const lines=raw.lines.map(item=>{
   const x=obj(item);fields(x,["dispatchId","sourceLine","quantityBase"]);
   if(!Number.isInteger(x.sourceLine)||typeof x.quantityBase!=="string"||
    !/^(0|[1-9][0-9]{0,17})(?:\\.[0-9]{1,6})?$/.test(x.quantityBase))err("RETURN_QUANTITY_INVALID");
   return {dispatchId:id(x.dispatchId),sourceLine:x.sourceLine as number,quantityBase:x.quantityBase as string};
  });
  return {...s,orderId,reason:raw.reason.trim(),lines};
 }
 fields(raw,["branchId","warehouseId","tripId","orderId","result","reasonCode","rescheduledFor","lines"]);
 if(!["DELIVERED_FULL","DELIVERED_PARTIAL","FAILED","RESCHEDULED"].includes(String(raw.result)))err("DELIVERY_ATTEMPT_RESULT_INVALID");
 if(raw.reasonCode!==undefined&&typeof raw.reasonCode!=="string")err("DELIVERY_ATTEMPT_REASON_INVALID");
 if(raw.rescheduledFor!==undefined&&typeof raw.rescheduledFor!=="string")err("DELIVERY_ATTEMPT_TIME_INVALID");
 if(raw.lines!==undefined&&!Array.isArray(raw.lines))err("DELIVERY_ATTEMPT_LINES_INVALID");
 const lines=(raw.lines as unknown[]|undefined)?.map(item=>{
  const x=obj(item);fields(x,["dispatchId","sourceLine","deliveredBase"]);
  if(!Number.isInteger(x.sourceLine)||typeof x.deliveredBase!=="string")err("DELIVERY_ATTEMPT_LINES_INVALID");
  return {dispatchId:id(x.dispatchId),sourceLine:x.sourceLine as number,deliveredBase:x.deliveredBase as string};
 });
 return {...s,orderId,result:raw.result as AttemptInput["result"],
  ...(raw.reasonCode!==undefined?{reasonCode:raw.reasonCode as string}:{}),
  ...(raw.rescheduledFor!==undefined?{rescheduledFor:raw.rescheduledFor as string}:{}),
  ...(lines!==undefined?{lines}:{})};
}
async function readBody(req:IncomingMessage){
 let text="",size=0;
 for await(const chunk of req){size+=Buffer.byteLength(chunk);if(size>65536)err("BODY_TOO_LARGE",413);text+=String(chunk);}
 try{return obj(JSON.parse(text));}catch(e){if(e instanceof DeliveryTripFault)throw e;return err("INVALID_JSON");}
}
function context(req:IncomingMessage,t:string,actor:string,rid:string,action:string,payload:Body):MutationContext{
 const rev=String(req.headers["if-match"]??"");
 if(!/^(0|[1-9][0-9]*)$/.test(rev)||!Number.isSafeInteger(Number(rev))||
  typeof req.headers["idempotency-key"]!=="string")err("MUTATION_HEADERS_REQUIRED");
 return {installationId:t,actorId:actor,requestId:rid,action,
  expectedRevision:Number(rev),idempotencyKey:req.headers["idempotency-key"] as string,payload};
}
function send(res:ServerResponse,status:number,data:unknown,rid:string,cors?:string){
 res.writeHead(status,{"content-type":"application/json; charset=utf-8","cache-control":"no-store",
 "x-request-id":rid,"x-content-type-options":"nosniff",
 ...(cors?{"access-control-allow-origin":cors,"vary":"Origin",
 "access-control-allow-headers":"Authorization,Content-Type,If-Match,Idempotency-Key",
 "access-control-allow-methods":"GET,POST,OPTIONS"}:{})});res.end(JSON.stringify(data));
}
function fault(res:ServerResponse,status:number,code:string,rid:string,cors?:string){
 send(res,status,{error:{code},requestId:rid},rid,cors);
}
async function permitted(db:PoolClient,t:string,actor:string,s:Scope,action:Action|"read"){
 const required=action==="start"?["delivery.update","orders.read"]:
  action==="return"?["delivery.update","orders.read"]:
  action==="handover"?["delivery.cod.handover","finance.payments.record"]:
  action==="read"?["orders.read"]:["delivery.execute"];
 for(const permission of required)if(!await hasPermission(db,{installationId:t,actorId:actor,
  permission,branchId:s.branchId}))return false;
 if(!await hasPermission(db,{installationId:t,actorId:actor,
  permission:action==="return"?"inventory.post":"inventory.read",
  branchId:s.branchId,warehouseId:s.warehouseId}))return false;
 if(action==="read"){
  if(await hasPermission(db,{installationId:t,actorId:actor,
   permission:"delivery.read",branchId:s.branchId}))return true;
  if(!await hasPermission(db,{installationId:t,actorId:actor,
   permission:"delivery.execute",branchId:s.branchId}))return false;
  const r=await db.query<{yes:boolean}>(`SELECT EXISTS(SELECT 1 FROM delivery_trip t
  JOIN delivery_driver d ON d.installation_id=t.installation_id AND d.branch_id=t.branch_id AND d.id=t.driver_id
  JOIN org_employee e ON e.installation_id=d.installation_id AND e.branch_id=d.branch_id AND e.id=d.employee_id
  WHERE t.installation_id=$1 AND t.branch_id=$2 AND t.warehouse_id=$3 AND t.id=$4
  AND e.account_user_id=$5 AND d.active AND e.active) AS yes`,
  [t,s.branchId,s.warehouseId,s.tripId,actor]);
  return r.rows[0]?.yes===true;
 }
 return true;
}
export async function handleDeliveryExecutionHttp(req:IncomingMessage,res:ServerResponse,rid:string,
 url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fault(res,403,"ORIGIN_DENIED",rid);return;}
 if(req.method==="OPTIONS"){send(res,204,null,rid,cors);return;}
 const t=opts.installationId,pool=opts.pool;
 if(!t||!UUID.test(t)||!pool||!opts.allowedOrigin){fault(res,503,"DELIVERY_NOT_CONFIGURED",rid,cors);return;}
 try{
  if(!await ready())err("BACKEND_NOT_READY",503);
  const exists=await pool.query<{ok:boolean}>(`SELECT EXISTS(SELECT 1 FROM schema_migrations
   WHERE version='0030_t5d_trip_execution.sql') AS ok`);
  if(!exists.rows[0]?.ok)err("T5D_MIGRATION_REQUIRED",503);
  const bearer=typeof req.headers.authorization==="string"
   ?/^Bearer ([A-Za-z0-9_-]{43})$/.exec(req.headers.authorization)?.[1]:undefined;
  const db=await pool.connect();let actor:string|undefined;
  try{actor=bearer?(await resolveSession(db,t,bearer))?.actorId:undefined;}
  finally{db.release();}
  if(!actor)err("AUTH_REQUIRED",401);
  if(req.method==="GET"&&url.pathname==="/v1/delivery/execution/read"){
   const s=scope({branchId:url.searchParams.get("branchId"),warehouseId:url.searchParams.get("warehouseId"),
    tripId:url.searchParams.get("tripId")});
   const x=await pool.connect();
   try{
    if(!await permitted(x,t,actor!,s,"read"))err("FORBIDDEN",403);
    const m={installationId:t,actorId:actor!,requestId:rid,expectedRevision:0,
     idempotencyKey:"read",action:"delivery.execution.read",payload:s};
    send(res,200,{execution:await executionRead(x,m,s),requestId:rid},rid,cors);
   }finally{x.release();}
   return;
  }
  if(req.method!=="POST")err("NOT_FOUND",404);
  if(url.pathname==="/v1/delivery/execution/recovery"){
   const raw=await readBody(req);fields(raw,["action","body"]);
   if(!["start","attempt","return","collect","handover"].includes(String(raw.action)))err("INVALID_ACTION");
   const action=raw.action as Action,payload=parsed(action,obj(raw.body));
   const m=context(req,t,actor!,rid,"delivery.execution."+action,payload);
   const receipt=await readCommittedMutation(pool,m,db=>permitted(db,t,actor!,payload,action));
   send(res,200,{receipt:receipt?.body??null,requestId:rid},rid,cors);return;
  }
  const parts=/^\/v1\/delivery\/execution\/(start|attempt|return|collect|handover)$/.exec(url.pathname);
  if(!parts)err("NOT_FOUND",404);
  const action=parts![1] as Action,payload=parsed(action,await readBody(req));
  const m=context(req,t,actor!,rid,"delivery.execution."+action,payload);
  const out=await executeMutation(pool,m,{
   authorize:db=>permitted(db,t,actor!,payload,action),
   execute:(db,ctx)=>action==="start"?executeStart(db,ctx,payload):
    action==="attempt"?executeAttempt(db,ctx,payload,payload.orderId!,{
     result:payload.result!,reasonCode:payload.reasonCode,rescheduledFor:payload.rescheduledFor,
     lines:payload.lines as AttemptInput["lines"]|undefined
    }):action==="return"?executeReturn(db,ctx,payload,payload.orderId!,payload.reason!,
      payload.lines as {dispatchId:string;sourceLine:number;quantityBase:string}[]):
     action==="collect"?executeCollect(db,ctx,payload,payload.orderId!,payload.amount!,
      payload.method as "CASH"|"BANK_TRANSFER"):
     executeHandover(db,ctx,payload,payload.collectionLines!),
  });
  send(res,out.status,out.body,rid,cors);
 }catch(e){
  if(e instanceof DeliveryTripFault){fault(res,e.httpStatus,e.code,rid,cors);return;}
  if(e instanceof MutationFault){fault(res,e.httpStatus,e.code,rid,cors);return;}
  if(e&&typeof e==="object"&&"status" in e&&"code" in e){
   const status=Number(e.status);
   if(status>=400&&status<=599){fault(res,status,String(e.code),rid,cors);return;}
  }
  if(e&&typeof e==="object"&&"code" in e&&
   ["23505","23503","23514","P0001","40P01"].includes(String(e.code))){
   fault(res,409,"DELIVERY_CONSTRAINT_REJECTED",rid,cors);return;
  }
  fault(res,503,"DELIVERY_UNAVAILABLE",rid,cors);
 }
}
