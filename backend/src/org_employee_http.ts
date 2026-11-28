import type {IncomingMessage,ServerResponse} from "node:http";
import type {PoolClient} from "pg";
import type {IdentityOptions} from "./identity_http.ts";
import {resolveSession} from "./auth.ts";
import {hasPermission} from "./rbac.ts";
import {executeMutation,MutationFault,requireRevision,type MutationContext} from "./mutation.ts";
import {createEmployee,updateEmployee} from "./delivery_employee.ts";
import {validIdempotencyKey} from "./contracts.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TOKEN=/^Bearer ([A-Za-z0-9_-]{43})$/;
class StaffFault extends Error{
 constructor(readonly status:number,readonly code:string){super(code);}
}
function fail(status:number,code:string):never{throw new StaffFault(status,code);}
function uuid(v:unknown):string{
 if(typeof v!=="string"||!UUID.test(v))fail(400,"INVALID_ID");
 return v as string;
}
function field(v:unknown,max:number,min=0):string{
 if(typeof v!=="string"||v.trim().length>max||v.trim().length<min)
  fail(400,"INVALID_FIELD");
 return (v as string).trim();
}
function optional(v:unknown,max:number):string|undefined{
 if(v===undefined||v===null)return undefined;
 return field(v,max);
}
function only(v:Record<string,unknown>,keys:string[]){
 if(Object.keys(v).some(k=>!keys.includes(k)))fail(400,"UNKNOWN_FIELD");
}
async function readBody(req:IncomingMessage):Promise<Record<string,unknown>>{
 if(!String(req.headers["content-type"]??"").startsWith("application/json"))
  fail(415,"CONTENT_TYPE_REQUIRED");
 if(Number(req.headers["content-length"]??0)>16384)fail(413,"BODY_TOO_LARGE");
 let source="";
 for await(const part of req){source+=String(part);if(source.length>16384)fail(413,"BODY_TOO_LARGE");}
 let v:unknown;
 try{v=JSON.parse(source);}catch{return fail(400,"INVALID_JSON");}
 if(!v||typeof v!=="object"||Array.isArray(v))fail(400,"INVALID_BODY");
 return v as Record<string,unknown>;
}
function mutation(req:IncomingMessage,t:string,a:string,rid:string,
 action:string,payload:unknown):MutationContext{
 const revision=req.headers["if-match"],key=req.headers["idempotency-key"];
 if(typeof revision!=="string"||!/^(0|[1-9][0-9]{0,14})$/.test(revision)||
  !Number.isSafeInteger(Number(revision))||typeof key!=="string"||
  !validIdempotencyKey(key))fail(400,"MUTATION_HEADERS_REQUIRED");
 return {installationId:t,actorId:a,requestId:rid,action,
  expectedRevision:Number(revision),idempotencyKey:key as string,payload};
}
function send(res:ServerResponse,status:number,body:unknown,rid:string,cors?:string){
 res.writeHead(status,{"content-type":"application/json; charset=utf-8",
  "cache-control":"no-store","x-content-type-options":"nosniff","x-request-id":rid,
  ...(cors?{"access-control-allow-origin":cors,"vary":"Origin",
  "access-control-allow-headers":"Authorization,Content-Type,If-Match,Idempotency-Key",
  "access-control-allow-methods":"GET,PATCH,POST,OPTIONS"}:{})});
 res.end(status===204?undefined:JSON.stringify(body));
}
function fault(res:ServerResponse,status:number,code:string,rid:string,cors?:string){
 send(res,status,{error:{code},requestId:rid},rid,cors);
}
async function can(db:PoolClient,t:string,actor:string,branchId:string,write:boolean){
 const p=write?"org.employees.manage":"org.employees.read";
 return await hasPermission(db,{installationId:t,actorId:actor,permission:p,branchId})||
  (!write&&await hasPermission(db,{installationId:t,actorId:actor,
   permission:"org.employees.manage",branchId}));
}
function fields(raw:Record<string,unknown>){
 const fullName=field(raw.fullName,120,2);
 const phone=optional(raw.phone,15),jobTitle=optional(raw.jobTitle,100);
 const department=optional(raw.department,100);
 if(phone!==undefined&&phone!==""&&!/^\+?[0-9]{9,15}$/.test(phone))
  fail(400,"INVALID_PHONE");
 return {fullName,...(phone!==undefined?{phone}:{}),
  ...(jobTitle!==undefined?{jobTitle}:{}),
  ...(department!==undefined?{department}:{})};
}
/** One canonical staff source for all modules; no warehouse binding. */
export async function handleOrgEmployeeHttp(req:IncomingMessage,res:ServerResponse,
 rid:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fault(res,403,"ORIGIN_DENIED",rid);return;}
 if(req.method==="OPTIONS"){send(res,204,null,rid,cors);return;}
 const t=opts.installationId,pool=opts.pool;
 if(!t||!UUID.test(t)||!pool||!opts.allowedOrigin){
  fault(res,503,"STAFF_NOT_CONFIGURED",rid,cors);return;
 }
 try{
  if(!await ready())fail(503,"BACKEND_NOT_READY");
  const migrated=await pool.query<{exists:boolean}>(`SELECT EXISTS
   (SELECT 1 FROM schema_migrations WHERE version='0029_iaa_employee_access.sql') AS exists`);
  if(!migrated.rows[0]?.exists)fail(503,"STAFF_MIGRATION_REQUIRED");
  const token=typeof req.headers.authorization==="string"?
   TOKEN.exec(req.headers.authorization)?.[1]:undefined;
  const db=await pool.connect();let actor:string|undefined;
  try{actor=token?(await resolveSession(db,t,token))?.actorId:undefined;}
  finally{db.release();}
  if(!actor)fail(401,"AUTH_REQUIRED");
  if(url.pathname==="/v1/org/employees/branches"&&req.method==="GET"){
   const db=await pool.connect();
   try{
    const x=await db.query(`SELECT DISTINCT b.id,b.code,b.name FROM branch b
     JOIN user_role ur ON ur.installation_id=b.installation_id
      AND ur.branch_id=b.id AND ur.user_id=$2
     JOIN role_permission rp ON rp.installation_id=ur.installation_id
      AND rp.role_id=ur.role_id
     JOIN app_user u ON u.installation_id=b.installation_id AND u.id=ur.user_id
     WHERE b.installation_id=$1 AND NOT u.disabled AND
      rp.permission_code IN ('org.employees.read','org.employees.manage')
     ORDER BY b.code,b.id LIMIT 1000`,[t,actor]);
    send(res,200,{items:x.rows,requestId:rid},rid,cors);return;
   }finally{db.release();}
  }
  if(url.pathname==="/v1/org/employees"&&req.method==="GET"){
   const branchId=uuid(url.searchParams.get("branchId"));
   const q=(url.searchParams.get("q")??"").trim(),offsetRaw=url.searchParams.get("offset")??"0";
   const active=url.searchParams.get("active");
   if(q.length>80||!/^(0|[1-9][0-9]*)$/.test(offsetRaw)||
    Number(offsetRaw)>100000||Number(offsetRaw)%200!==0||
    active!==null&&active!=="true"&&active!=="false")fail(400,"INVALID_FILTER");
   const db=await pool.connect();
   try{
    if(!await can(db,t,actor,branchId,false))fail(403,"FORBIDDEN");
    const x=await db.query(`SELECT e.id,e.code,e.full_name AS "fullName",
      e.job_title AS "jobTitle",e.department,e.phone,e.active,
      e.account_user_id AS "accountUserId",e.revision::integer,
      EXISTS(SELECT 1 FROM delivery_driver d WHERE d.installation_id=e.installation_id
       AND d.branch_id=e.branch_id AND d.employee_id=e.id AND d.active) AS "linkedDriver"
      FROM org_employee e WHERE e.installation_id=$1 AND e.branch_id=$2
       AND ($3::text='' OR e.code ILIKE '%'||$3||'%' OR
        e.full_name ILIKE '%'||$3||'%' OR COALESCE(e.department,'') ILIKE '%'||$3||'%')
       AND ($4::boolean IS NULL OR e.active=$4::boolean)
      ORDER BY e.active DESC,e.code,e.id LIMIT 200 OFFSET $5`,
      [t,branchId,q,active===null?null:active==="true",Number(offsetRaw)]);
    send(res,200,{items:x.rows,requestId:rid},rid,cors);return;
   }finally{db.release();}
  }
  if(url.pathname==="/v1/org/employees"&&req.method==="POST"){
   const raw=await readBody(req),branchId=uuid(raw.branchId);
   only(raw,["branchId","code","fullName","jobTitle","phone","department"]);
   const input={code:field(raw.code,48,1).toUpperCase(),...fields(raw)};
   if(!/^[A-Z0-9_-]+$/.test(input.code))fail(400,"INVALID_CODE");
   const ctx=mutation(req,t,actor,rid,"org.employees.create",{branchId,...input});
   const result=await executeMutation(pool,ctx,{
    authorize:(db)=>can(db,t,actor!,branchId,true),
    execute:(db,m)=>createEmployee(db,m,{branchId},input),
   });
   send(res,result.status,result.body,rid,cors);return;
  }
  const path=/^\/v1\/org\/employees\/([0-9a-f-]{36})$/i.exec(url.pathname);
  if(path&&req.method==="PATCH"){
   const raw=await readBody(req),branchId=uuid(raw.branchId),employeeId=uuid(path[1]);
   only(raw,["branchId","fullName","jobTitle","phone","department","active"]);
   if(typeof raw.active!=="boolean")fail(400,"INVALID_STATUS");
   const input={...fields(raw),active:raw.active as boolean};
   const ctx=mutation(req,t,actor,rid,"org.employees.update",{branchId,employeeId,...input});
   const result=await executeMutation(pool,ctx,{
    authorize:(db)=>can(db,t,actor!,branchId,true),
    execute:(db,m)=>updateEmployee(db,m,{branchId},employeeId,input),
   });
   send(res,result.status,result.body,rid,cors);return;
  }
  const link=/^\/v1\/admin\/users\/([0-9a-f-]{36})\/employee$/i.exec(url.pathname);
  if(link&&req.method==="PATCH"){
   const raw=await readBody(req),branchId=uuid(raw.branchId),userId=uuid(link[1]);
   only(raw,["branchId","employeeId"]);
   const employeeId=raw.employeeId===null?null:uuid(raw.employeeId);
   const ctx=mutation(req,t,actor,rid,"org.employee.account.link",
    {branchId,userId,employeeId});
   const result=await executeMutation(pool,ctx,{
    authorize:async db=>await hasPermission(db,{installationId:t,actorId:actor!,
     permission:"identity.users.manage"})&&await can(db,t,actor!,branchId,true),
    execute:async(db,m)=>{
     const user=await db.query<{revision:string;disabled:boolean}>(`SELECT
      revision::text,disabled FROM app_user WHERE installation_id=$1 AND id=$2 FOR UPDATE`,
      [t,userId]);
     if(!user.rows[0])fail(404,"USER_NOT_FOUND");
     requireRevision(m.expectedRevision,Number(user.rows[0].revision));
     if(user.rows[0].disabled&&employeeId!==null)fail(409,"USER_DISABLED");
     const prior=await db.query<{id:string;branch_id:string}>(`SELECT id,branch_id
      FROM org_employee WHERE installation_id=$1 AND account_user_id=$2 FOR UPDATE`,
      [t,userId]);
     if(prior.rows[0]&&prior.rows[0].branch_id!==branchId)
      fail(409,"EMPLOYEE_LINKED_OTHER_BRANCH");
     let target:null|{id:string;active:boolean;account_user_id:string|null}=null;
     if(employeeId){
      const emp=await db.query<{id:string;active:boolean;account_user_id:string|null}>(
       `SELECT id,active,account_user_id FROM org_employee WHERE installation_id=$1
        AND branch_id=$2 AND id=$3 FOR UPDATE`,[t,branchId,employeeId]);
      target=emp.rows[0]??null;
      if(!target)fail(404,"EMPLOYEE_NOT_FOUND");
      if(!target.active)fail(409,"EMPLOYEE_INACTIVE");
      if(target.account_user_id&&target.account_user_id!==userId)
       fail(409,"EMPLOYEE_LINKED_OTHER_USER");
     }
     if(prior.rows[0]?.id!==employeeId){
      if(prior.rows[0]){
       const pending=await db.query(`SELECT 1 FROM delivery_driver d
        JOIN delivery_trip tr ON tr.installation_id=d.installation_id
         AND tr.branch_id=d.branch_id AND tr.warehouse_id=d.warehouse_id
         AND tr.driver_id=d.id WHERE d.installation_id=$1
         AND d.branch_id=$2 AND d.employee_id=$3
         AND tr.status IN ('PLANNED','LOCKED') LIMIT 1`,
        [t,branchId,prior.rows[0].id]);
       if(pending.rowCount)fail(409,"EMPLOYEE_HAS_PENDING_TRIPS");
       await db.query(`UPDATE org_employee SET account_user_id=NULL,
        revision=revision+1,updated_at=now()
        WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
        [t,branchId,prior.rows[0].id]);
      }
      if(employeeId)await db.query(`UPDATE org_employee SET account_user_id=$4,
       revision=revision+1,updated_at=now()
       WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
       [t,branchId,employeeId,userId]);
     }
     const changed=await db.query<{revision:string}>(`UPDATE app_user
      SET revision=revision+1 WHERE installation_id=$1 AND id=$2 RETURNING revision::text`,
      [t,userId]);
     return {status:200,body:{userId,branchId,employeeId,
      revision:Number(changed.rows[0]!.revision)}};
    },
   });
   send(res,result.status,result.body,rid,cors);return;
  }
  fail(404,"NOT_FOUND");
 }catch(e){
  if(e instanceof StaffFault){fault(res,e.status,e.code,rid,cors);return;}
  if(e instanceof MutationFault){fault(res,e.httpStatus,e.code,rid,cors);return;}
  if(e&&typeof e==="object"&&"code" in e){
   const code=String(e.code);
   if(["23503","23505","23514","40P01"].includes(code)){
    fault(res,409,"EMPLOYEE_CONFLICT",rid,cors);return;
   }
  }
  fault(res,503,"STAFF_UNAVAILABLE",rid,cors);
 }
}
