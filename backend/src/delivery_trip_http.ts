import type {IncomingMessage,ServerResponse} from "node:http";
import type {Pool,PoolClient} from "pg";
import type {IdentityOptions} from "./identity_http.ts";
import {resolveSession} from "./auth.ts";
import {hasPermission} from "./rbac.ts";
import {executeMutation,MutationFault,type MutationContext} from "./mutation.ts";
import {DeliveryTripFault,tripResources,createResource,tripList,tripEligible,
 tripDetail,createTrip,assignOrders,removeOrders,reorder,transition,
 type TripScope} from "./delivery_trip.ts";
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TOKEN=/^Bearer ([A-Za-z0-9_-]{43})$/;
function reject(code:string,status=400):never{throw new DeliveryTripFault(status,code);}
function id(v:unknown):string{
 if(typeof v!=="string"||!UUID.test(v))reject("INVALID_ID");return v as string;
}
function str(v:unknown,max:number,required=true):string{
 if(typeof v!=="string"||v.trim().length>(max)||required&&v.trim().length===0)
  reject("INVALID_TEXT");
 return (v as string).trim();
}
function date(v:unknown):string{
 const x=str(v,10),parsed=new Date(x+"T00:00:00Z");
 if(!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(x)||
  !Number.isFinite(parsed.getTime())||parsed.toISOString().slice(0,10)!==x)
   reject("INVALID_DATE");
 return x;
}
function scope(r:Record<string,unknown>):TripScope{
 return {branchId:id(r.branchId),warehouseId:id(r.warehouseId)};
}
function rec(v:unknown):Record<string,unknown>{
 if(!v||typeof v!=="object"||Array.isArray(v))reject("INVALID_BODY");
 return v as Record<string,unknown>;
}
function only(v:Record<string,unknown>,keys:string[]):void{
 if(Object.keys(v).some(k=>!keys.includes(k)))reject("UNEXPECTED_FIELD");
}
function ids(v:unknown):string[]{
 if(!Array.isArray(v)||!v.length||v.length>100)reject("INVALID_ORDER_SELECTION");
 const a=v.map(id);
 if(new Set(a).size!==a.length)reject("DUPLICATE_SELECTED_ORDER");
 return a;
}
async function readBody(req:IncomingMessage):Promise<Record<string,unknown>>{
 if(!String(req.headers["content-type"]??"").startsWith("application/json"))
  reject("CONTENT_TYPE_REQUIRED",415);
 if(Number(req.headers["content-length"]??0)>32768)reject("BODY_TOO_LARGE",413);
 let s="";
 for await(const chunk of req){
  s+=String(chunk);if(s.length>32768)reject("BODY_TOO_LARGE",413);
 }
 try{return rec(JSON.parse(s));}catch{return reject("INVALID_JSON");}
}
function context(req:IncomingMessage,t:string,actor:string,rid:string,
 action:string,payload:unknown):MutationContext{
 const match=String(req.headers["if-match"]??"");
 const key=req.headers["idempotency-key"];
 if(!/^(0|[1-9][0-9]*)$/.test(match)||!Number.isSafeInteger(Number(match))||
 typeof key!=="string")reject("MUTATION_HEADERS_REQUIRED");
 return {installationId:t,actorId:actor,requestId:rid,action,
 expectedRevision:Number(match),idempotencyKey:key,payload};
}
function send(res:ServerResponse,status:number,data:unknown,rid:string,cors?:string){
 res.writeHead(status,{"content-type":"application/json; charset=utf-8",
 "cache-control":"no-store","x-request-id":rid,
 "x-content-type-options":"nosniff",
 ...(cors?{"access-control-allow-origin":cors,"vary":"Origin",
 "access-control-allow-headers":"Authorization,Content-Type,If-Match,Idempotency-Key",
 "access-control-allow-methods":"GET,POST,OPTIONS"}:{})});
 res.end(status===204?undefined:JSON.stringify(data));
}
function fault(res:ServerResponse,status:number,code:string,rid:string,cors?:string){
 send(res,status,{error:{code},requestId:rid},rid,cors);
}
async function permitted(db:PoolClient,t:string,actor:string,s:TripScope,write:boolean){
 const rights=write?["delivery.update","orders.read"]:["delivery.read","orders.read"];
 for(const permission of rights){
  if(!await hasPermission(db,{installationId:t,actorId:actor,permission,
  branchId:s.branchId}))return false;
 }
 return await hasPermission(db,{installationId:t,actorId:actor,
  permission:"inventory.read",...s});
}
export async function handleDeliveryTripHttp(req:IncomingMessage,res:ServerResponse,
 rid:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fault(res,403,"ORIGIN_DENIED",rid);return;}
 if(req.method==="OPTIONS"){send(res,204,null,rid,cors);return;}
 const t=opts.installationId,pool=opts.pool;
 if(!t||!UUID.test(t)||!pool||!opts.allowedOrigin){
  fault(res,503,"TRIP_NOT_CONFIGURED",rid,cors);return;
 }
 try{
  if(!await ready()){fault(res,503,"BACKEND_NOT_READY",rid,cors);return;}
  const version=await pool.query<{ok:boolean}>(`SELECT EXISTS(SELECT 1 FROM schema_migrations
   WHERE version='0027_t5b_delivery_trip_planning.sql') AS ok`);
  if(!version.rows[0]?.ok){
   fault(res,503,"TRIP_MIGRATION_REQUIRED",rid,cors);return;
  }
  const token=typeof req.headers.authorization==="string"?
    TOKEN.exec(req.headers.authorization)?.[1]:undefined;
  const cdb=await pool.connect();let actor:string|undefined;
  try{actor=token?(await resolveSession(cdb,t,token))?.actorId:undefined;}
  finally{cdb.release();}
  if(!actor){fault(res,401,"AUTH_REQUIRED",rid,cors);return;}
  if(req.method==="GET"){
   const s=scope({branchId:url.searchParams.get("branchId"),
     warehouseId:url.searchParams.get("warehouseId")});
   const db=await pool.connect();
   try{
    if(!await permitted(db,t,actor,s,false))reject("FORBIDDEN",403);
    let result:unknown;
    if(url.pathname==="/v1/delivery/vehicles")result={items:await tripResources(db,t,s,"vehicles")};
    else if(url.pathname==="/v1/delivery/drivers")result={items:await tripResources(db,t,s,"drivers")};
    else if(url.pathname==="/v1/delivery/trips/eligible")result={items:await tripEligible(db,t,s)};
    else if(url.pathname==="/v1/delivery/trips")result={items:await tripList(db,t,s)};
    else{
     const p=/^\/v1\/delivery\/trips\/([0-9a-f-]{36})$/i.exec(url.pathname);
     if(!p)reject("NOT_FOUND",404);
     result={trip:await tripDetail(db,t,s,id(p![1]))};
    }
    send(res,200,{...result as object,requestId:rid},rid,cors);return;
   }finally{db.release();}
  }
  if(req.method!=="POST")reject("NOT_FOUND",404);
  const raw=await readBody(req),s=scope(raw);
  const master=/^\/v1\/delivery\/(drivers|vehicles)$/.exec(url.pathname);
  const sub=/^\/v1\/delivery\/trips\/([0-9a-f-]{36})\/(assign|unassign|reorder|plan|reopen|lock)$/.exec(url.pathname);
  let action:string,payload:Record<string,unknown>;
  if(master){
   const kind=master[1] as "drivers"|"vehicles";
   only(raw,["branchId","warehouseId","code","name","phone","licensePlate"]);
   // Exclude absent optional fields: canonicalMutationPayload rejects undefined.
   const v={code:str(raw.code,48),name:str(raw.name,120),
     ...(kind==="drivers"?
       (raw.phone==null?{}:{phone:str(raw.phone,15,false)}):
       {licensePlate:str(raw.licensePlate,32)})};
   action="delivery."+kind+".create";
   payload={...s,...v};
   const c=context(req,t,actor,rid,action,payload);
   const out=await executeMutation(pool,c,{
    authorize:(db)=>permitted(db,t,actor!,s,true),
    execute:(db,m)=>createResource(db,m,s,kind,v)
   });
   send(res,out.status,out.body,rid,cors);return;
  }
  if(url.pathname==="/v1/delivery/trips"){
   only(raw,["branchId","warehouseId","plannedDate","note"]);
   const plannedDate=date(raw.plannedDate),note=raw.note==null?"":str(raw.note,500,false);
   payload={...s,plannedDate,note};
   action="delivery.trip.create";
   const c=context(req,t,actor,rid,action,payload);
   const out=await executeMutation(pool,c,{
    authorize:(db)=>permitted(db,t,actor!,s,true),
    execute:(db,m)=>createTrip(db,m,s,plannedDate,note)
   });
   send(res,out.status,out.body,rid,cors);return;
  }
  if(!sub)reject("NOT_FOUND",404);
  const tripId=id(sub![1]),kind=sub![2] as
    "assign"|"unassign"|"reorder"|"plan"|"reopen"|"lock";
  let orderIds:string[]=[];
  let vehicleId:string|undefined,driverId:string|undefined;
  let plannedDate:string|undefined,note:string|undefined;
  if(["assign","unassign","reorder"].includes(kind)){
   only(raw,["branchId","warehouseId","orderIds"]);
   orderIds=ids(raw.orderIds);
   if(kind==="reorder"&&orderIds.length>200)reject("TOO_MANY_STOPS");
  }else if(kind==="plan"){
   only(raw,["branchId","warehouseId","vehicleId","driverId","plannedDate","note"]);
   vehicleId=id(raw.vehicleId);driverId=id(raw.driverId);
   plannedDate=date(raw.plannedDate);
   note=raw.note==null?"":str(raw.note,500,false);
  }else only(raw,["branchId","warehouseId"]);
  payload={...s,tripId,kind,...(orderIds.length?{orderIds}:{}),
    ...(vehicleId?{vehicleId,driverId,plannedDate,note}:{})};
  action="delivery.trip."+kind;
  const c=context(req,t,actor,rid,action,payload);
  const out=await executeMutation(pool,c,{
   authorize:(db)=>permitted(db,t,actor!,s,true),
   execute:(db,m)=>kind==="assign"?assignOrders(db,m,s,tripId,orderIds):
     kind==="unassign"?removeOrders(db,m,s,tripId,orderIds):
     kind==="reorder"?reorder(db,m,s,tripId,orderIds):
      transition(db,m,s,tripId,kind as "plan"|"reopen"|"lock",
       vehicleId,driverId,plannedDate,note),
  });
  send(res,out.status,out.body,rid,cors);return;
 }catch(e){
  if(e instanceof DeliveryTripFault){fault(res,e.httpStatus,e.code,rid,cors);return;}
  if(e instanceof MutationFault){fault(res,e.httpStatus,e.code,rid,cors);return;}
  if(e&&typeof e==="object"&&"code" in e){
   const code=String(e.code);
   if(["23505","23503","23514","P0001","40P01"].includes(code)){
    fault(res,409,"TRIP_CONSTRAINT_OR_CONCURRENCY",rid,cors);return;
   }
  }
  fault(res,503,"TRIP_UNAVAILABLE",rid,cors);
 }
}
