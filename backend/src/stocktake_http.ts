import type { IncomingMessage,ServerResponse } from "node:http";
import type { Pool } from "pg";
import type { IdentityOptions } from "./identity_http.ts";
import { resolveSession } from "./auth.ts";
import { hasPermission } from "./rbac.ts";
import { executeMutation,MutationFault,type MutationContext } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";
import { StocktakeFault,listStocktakes,stocktakeDetail,createStocktake,
 recordCounts,transitionStocktake,validNonnegativeQty,
 type StocktakeScope,type StocktakeCountLine } from "./stocktake.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BEARER=/^Bearer ([A-Za-z0-9_-]{43})$/;
function send(res:ServerResponse,status:number,data:unknown,id:string,cors?:string){
 const h:Record<string,string>={"content-type":"application/json; charset=utf-8",
 "cache-control":"no-store","x-request-id":id,"x-content-type-options":"nosniff","vary":"Origin"};
 if(cors){
  h["access-control-allow-origin"]=cors;
  h["access-control-allow-methods"]="GET, POST, OPTIONS";
  h["access-control-allow-headers"]="content-type,authorization,idempotency-key,if-match,x-request-id";
 }
 res.writeHead(status,h);res.end(status===204?"":JSON.stringify(data));
}
function fail(res:ServerResponse,status:number,code:string,id:string,cors?:string){
 send(res,status,{error:{code,requestId:id,message:status===403?
   "Không được cấp quyền kiểm kê tại kho này.":status===409?
   "Tồn hoặc số đếm đã thay đổi, hãy kiểm lại.":status===503?
   "Kiểm kê chưa sẵn sàng.":"Dữ liệu kiểm kê không hợp lệ."}},id,cors);
}
function uuid(x:unknown):string{
 if(typeof x!=="string"||!UUID.test(x))throw new StocktakeFault(400,"INVALID_UUID");
 return x;
}
function obj(x:unknown):Record<string,unknown>{
 if(!x||typeof x!=="object"||Array.isArray(x))throw new StocktakeFault(400,"INVALID_OBJECT");
 return x as Record<string,unknown>;
}
function only(x:Record<string,unknown>,fields:string[]){
 if(Object.keys(x).some(k=>!fields.includes(k)))throw new StocktakeFault(400,"UNKNOWN_FIELD");
}
function scope(x:Record<string,unknown>):StocktakeScope{
 return {branchId:uuid(x.branchId),warehouseId:uuid(x.warehouseId)};
}
function counts(x:unknown):StocktakeCountLine[]{
 if(!Array.isArray(x)||x.length<1||x.length>100)
  throw new StocktakeFault(400,"INVALID_COUNT_LINES");
 return x.map((raw:unknown)=>{
  const v=obj(raw);only(v,["lineNo","round","quantity"]);
  if(typeof v.lineNo!=="number"||!Number.isInteger(v.lineNo)||v.lineNo<1||
    v.lineNo>10000||typeof v.round!=="number"||!Number.isInteger(v.round)||
    v.round<1||v.round>3||!validNonnegativeQty(v.quantity))
    throw new StocktakeFault(400,"INVALID_COUNT_LINE");
  return {lineNo:v.lineNo,round:v.round,quantity:v.quantity};
 });
}
async function body(req:IncomingMessage){
 if(req.headers["content-type"]?.split(";")[0]?.trim().toLowerCase()!=="application/json")
  throw new StocktakeFault(415,"JSON_REQUIRED");
 let size=0;const chunks:Buffer[]=[];
 for await(const chunk of req){
  const bytes=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk as Uint8Array);
  size+=bytes.length;
  if(size>20000)throw new StocktakeFault(413,"BODY_TOO_LARGE");
  chunks.push(bytes);
 }
 try{return obj(JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown);}
 catch(e){if(e instanceof StocktakeFault)throw e;throw new StocktakeFault(400,"INVALID_JSON");}
}
function ctx(req:IncomingMessage,id:string,t:string,actor:string,
 action:string,payload:Record<string,unknown>,create=false):MutationContext{
 const key=req.headers["idempotency-key"],rev=req.headers["if-match"];
 if(typeof key!=="string"||!validIdempotencyKey(key)||typeof rev!=="string"||
  !/^(0|[1-9][0-9]{0,14})$/.test(rev))throw new StocktakeFault(400,"MUTATION_HEADERS_REQUIRED");
 const value=Number(rev);
 if(!Number.isSafeInteger(value)||(create&&value!==0))
  throw new StocktakeFault(400,"INVALID_REVISION");
 return {installationId:t,actorId:actor,requestId:id,action,
  idempotencyKey:key,expectedRevision:value,payload};
}
async function schemaReady(pool:Pool){
 try{
  const q=await pool.query<{yes:boolean}>(
    "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0014_r3_stocktake.sql') AS yes");
  return q.rows[0]?.yes===true;
 }catch{return false;}
}
export async function handleStocktakeHttp(req:IncomingMessage,res:ServerResponse,
 id:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fail(res,403,"ORIGIN_DENIED",id);return;}
 if(req.method==="OPTIONS"){
  if(!cors){fail(res,403,"ORIGIN_DENIED",id);return;}
  send(res,204,null,id,cors);return;
 }
 const t=opts.installationId,pool=opts.pool;
 if(!t||!UUID.test(t)||!pool||!opts.allowedOrigin){
  fail(res,503,"STOCKTAKE_NOT_CONFIGURED",id,cors);return;
 }
 try{
  if(!await ready()||!await schemaReady(pool)){
   fail(res,503,"STOCKTAKE_MIGRATION_REQUIRED",id,cors);return;
  }
  const token=typeof req.headers.authorization==="string"?
   BEARER.exec(req.headers.authorization)?.[1]:undefined;
  const c=await pool.connect();let actor:string|undefined;
  try{actor=token?(await resolveSession(c,t,token))?.actorId:undefined;}
  finally{c.release();}
  if(!actor){fail(res,401,"AUTH_REQUIRED",id,cors);return;}
  // Dedicated stocktake selectors avoid requiring unrestricted catalog inventory access.
  if(req.method==="GET"&&url.pathname==="/v1/inventory/stocktakes/scopes"){
    const branch=url.searchParams.get("branchId"),q=(url.searchParams.get("q")??"").trim();
    if((branch!==null&&!UUID.test(branch))||q.length>80)
      throw new StocktakeFault(400,"INVALID_SCOPE_QUERY");
    const conn=await pool.connect();
    try{
      const branches=await conn.query(
        `SELECT DISTINCT b.id,b.name FROM user_role ur
          JOIN role_permission rp ON rp.installation_id=ur.installation_id
            AND rp.role_id=ur.role_id AND rp.permission_code='inventory.stocktake.read'
          JOIN user_role_warehouse uw ON uw.installation_id=ur.installation_id
            AND uw.user_id=ur.user_id AND uw.role_id=ur.role_id
            AND uw.branch_id=ur.branch_id
          JOIN branch b ON b.installation_id=ur.installation_id AND b.id=ur.branch_id
          WHERE ur.installation_id=$1 AND ur.user_id=$2 ORDER BY b.name,b.id`,[t,actor]);
      const warehouses=branch===null?{rows:[]}:await conn.query(
        `SELECT DISTINCT w.id,w.code,w.name,w.branch_id AS "branchId"
          FROM user_role ur
          JOIN role_permission rp ON rp.installation_id=ur.installation_id
            AND rp.role_id=ur.role_id AND rp.permission_code='inventory.stocktake.read'
          JOIN user_role_warehouse uw ON uw.installation_id=ur.installation_id
            AND uw.user_id=ur.user_id AND uw.role_id=ur.role_id
            AND uw.branch_id=ur.branch_id
          JOIN warehouse w ON w.installation_id=uw.installation_id
            AND w.branch_id=uw.branch_id AND w.id=uw.warehouse_id
          WHERE ur.installation_id=$1 AND ur.user_id=$2 AND w.branch_id=$3
            AND ($4='' OR w.code ILIKE '%'||$4||'%' OR w.name ILIKE '%'||$4||'%')
          ORDER BY w.name,w.id LIMIT 100`,[t,actor,branch,q]);
      send(res,200,{branches:branches.rows,warehouses:warehouses.rows,
        requestId:id},id,cors);
    }finally{conn.release();}
    return;
  }
  const route=/^\/v1\/inventory\/stocktakes\/([0-9a-f-]{36})(?:\/(counts|submit|approve|post|cancel))?$/.exec(url.pathname);
  if(req.method==="GET"){
   const s=scope({branchId:url.searchParams.get("branchId"),
     warehouseId:url.searchParams.get("warehouseId")});
   const c=await pool.connect();
   try{
    if(!await hasPermission(c,{installationId:t,actorId:actor,
      permission:"inventory.stocktake.read",...s}))
      throw new StocktakeFault(403,"STOCKTAKE_READ_DENIED");
    if(route&&!route[2]){
      send(res,200,{stocktake:await stocktakeDetail(c,t,s,uuid(route[1])),
        requestId:id},id,cors);
    }else if(url.pathname==="/v1/inventory/stocktakes"){
      const offset=url.searchParams.get("offset")??"0";
      if(!/^(0|[1-9][0-9]{0,5})$/.test(offset)||Number(offset)%100!==0)
        throw new StocktakeFault(400,"INVALID_PAGE");
      send(res,200,{...(await listStocktakes(c,t,s,Number(offset))),
        requestId:id},id,cors);
    }else fail(res,404,"STOCKTAKE_ROUTE_NOT_FOUND",id,cors);
   }finally{c.release();}
   return;
  }
  if(req.method!=="POST"){fail(res,405,"METHOD_NOT_ALLOWED",id,cors);return;}
  if(url.pathname==="/v1/inventory/stocktakes"){
   const raw=await body(req);only(raw,["branchId","warehouseId","note"]);
   const s=scope(raw),note=raw.note??"";
   if(typeof note!=="string"||note.length>500)
    throw new StocktakeFault(400,"INVALID_NOTE");
   const data={...s,note};
   const m=ctx(req,id,t,actor,"inventory.stocktake.create",data,true);
   const result=await executeMutation(pool,m,{
    authorize:(c,x)=>hasPermission(c,{installationId:t,actorId:x.actorId,
      permission:"inventory.stocktake.create",...s}),
    execute:(c,x)=>createStocktake(c,x,data),
   });
   send(res,result.status,result.body,id,cors);return;
  }
  if(route&&route[2]){
   const stocktakeId=uuid(route[1]),action=route[2],raw=await body(req);
   if(action==="counts"){
    only(raw,["branchId","warehouseId","lines"]);
    const s=scope(raw),data={...s,stocktakeId,lines:counts(raw.lines)};
    const m=ctx(req,id,t,actor,"inventory.stocktake.count",data);
    const result=await executeMutation(pool,m,{
      authorize:(c,x)=>hasPermission(c,{installationId:t,actorId:x.actorId,
        permission:"inventory.stocktake.count",...s}),
      execute:(c,x)=>recordCounts(c,x,s,stocktakeId,data.lines),
    });
    send(res,result.status,result.body,id,cors);return;
   }
   only(raw,["branchId","warehouseId"]);
   const s=scope(raw),data={...s,stocktakeId};
   const permission=action==="submit"?"inventory.stocktake.submit":
    action==="approve"?"inventory.stocktake.approve":
    action==="post"?"inventory.stocktake.post":"inventory.stocktake.create";
   const m=ctx(req,id,t,actor,"inventory.stocktake."+action,data);
   const result=await executeMutation(pool,m,{
    authorize:(c,x)=>hasPermission(c,{installationId:t,actorId:x.actorId,
      permission,...s}),
    execute:(c,x)=>transitionStocktake(c,x,s,stocktakeId,
      action as "submit"|"approve"|"post"|"cancel"),
   });
   send(res,result.status,result.body,id,cors);return;
  }
  fail(res,404,"STOCKTAKE_ROUTE_NOT_FOUND",id,cors);
 }catch(e){
  if(e instanceof StocktakeFault){fail(res,e.status,e.code,id,cors);return;}
  if(e instanceof MutationFault){fail(res,e.httpStatus,e.code,id,cors);return;}
  if(e&&typeof e==="object"&&"code" in e){
   const error=e as {code?:unknown;message?:unknown};
   if(error.code==="P0001"&&typeof error.message==="string"&&
       /Stocktake|Inventory insufficient available stock/.test(error.message)){
    fail(res,409,"STOCKTAKE_POST_REJECTED",id,cors);return;
   }
   if(error.code==="23505"){fail(res,409,"STOCKTAKE_DUPLICATE",id,cors);return;}
   if(error.code==="23503"||error.code==="23514"){
    fail(res,409,"STOCKTAKE_CONSTRAINT",id,cors);return;
   }
  }
  fail(res,503,"STOCKTAKE_UNAVAILABLE",id,cors);
 }
}
