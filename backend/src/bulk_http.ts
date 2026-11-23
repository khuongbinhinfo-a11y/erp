import { createHash } from "node:crypto";
import type { IncomingMessage,ServerResponse } from "node:http";
import type { PoolClient } from "pg";
import { resolveSession } from "./auth.ts";
import { hasPermission } from "./rbac.ts";
import { executeMutation,MutationFault } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";
import type { IdentityOptions } from "./identity_http.ts";
import { parseBulkFile,bulkCsv,BulkFileFault } from "./bulk_file.ts";
import { BulkFault,bulkColumns,suggestBulkMapping,checkBulkInput,
  buildBulkPlan,publicBulkPlan,applyBulkPlan,type BulkResource } from "./bulk_plan.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
function send(res:ServerResponse,status:number,body:unknown,requestId:string,origin?:string){
 const headers:Record<string,string>={
  "content-type":"application/json; charset=utf-8","cache-control":"no-store",
  "x-content-type-options":"nosniff","x-request-id":requestId,"vary":"Origin",
 };
 if(origin){
  headers["access-control-allow-origin"]=origin;
  headers["access-control-allow-methods"]="GET,POST,OPTIONS";
  headers["access-control-allow-headers"]="content-type,authorization,idempotency-key,if-match,x-request-id";
  headers["access-control-max-age"]="300";
 }
 res.writeHead(status,headers);
 res.end(status===204?"":JSON.stringify(body));
}
function fail(res:ServerResponse,status:number,code:string,id:string,origin?:string){
 send(res,status,{error:{code,message:status===401?"Phiên đăng nhập không hợp lệ":
  status===403?"Không có quyền":status===409?
  "Dữ liệu đã thay đổi. Vui lòng xem trước lại.":"Không thể xử lý bảng tính.",requestId:id}},id,origin);
}
async function body(req:IncomingMessage):Promise<Record<string,unknown>>{
 if(req.headers["content-type"]?.split(";")[0]?.trim().toLowerCase()!=="application/json")
  throw new BulkFault("INVALID_CONTENT_TYPE",415);
 if(Number(req.headers["content-length"]||0)>9*1024*1024)
  throw new BulkFault("BULK_BODY_TOO_LARGE",413);
 let bytes=0;const chunks:Buffer[]=[];
 for await(const part of req){
  const buf=Buffer.isBuffer(part)?part:Buffer.from(part as Uint8Array);
  bytes+=buf.length;
  if(bytes>9*1024*1024)throw new BulkFault("BULK_BODY_TOO_LARGE",413);
  chunks.push(buf);
 }
 let parsed:unknown;
 try{parsed=JSON.parse(Buffer.concat(chunks).toString("utf8"));}
 catch{throw new BulkFault("INVALID_JSON");}
 if(!parsed||typeof parsed!=="object"||Array.isArray(parsed))
  throw new BulkFault("INVALID_BULK_BODY");
 return parsed as Record<string,unknown>;
}
function bearer(req:IncomingMessage):string|null{
 const h=req.headers.authorization;
 return typeof h==="string"?/^Bearer ([A-Za-z0-9_-]{43})$/.exec(h)?.[1]??null:null;
}
function resource(v:unknown):BulkResource{
 if(typeof v!=="string"||!["customers","products","skus","prices"].includes(v))
  throw new BulkFault("INVALID_BULK_RESOURCE");
 return v as BulkResource;
}
async function exportRows(db:PoolClient,tenant:string,branch:string,kind:BulkResource){
 const fields=bulkColumns(kind);
 let sql:string;
 switch(kind){
 case "customers":
  sql='SELECT c.code,c.name,g.code AS "customerGroupCode",r.code AS "customerRegionCode",'+
   'c.phone,c.delivery_address AS "deliveryAddress",'+
   'c.payment_terms_days::text AS "paymentTermsDays",c.active '+
   'FROM catalog_customer c LEFT JOIN catalog_customer_group g ON '+
   'g.installation_id=c.installation_id AND g.branch_id=c.branch_id AND g.id=c.customer_group_id '+
   'LEFT JOIN catalog_customer_region r ON r.installation_id=c.installation_id '+
   'AND r.branch_id=c.branch_id AND r.id=c.customer_region_id '+
   'WHERE c.installation_id=$1 AND c.branch_id=$2 ORDER BY c.code LIMIT 5001';
  break;
 case "products":
  sql='SELECT p.sku AS code,p.name,p.base_unit AS "baseUnit",g.code AS "groupCode",'+
   '(SELECT b.barcode FROM catalog_sku_barcode b JOIN catalog_sell_sku s '+
   'ON s.installation_id=b.installation_id AND s.branch_id=b.branch_id AND s.id=b.sell_sku_id '+
   'WHERE s.installation_id=p.installation_id AND s.branch_id=p.branch_id '+
   'AND s.product_id=p.id AND s.is_base AND b.active ORDER BY b.is_primary DESC LIMIT 1) '+
   'AS barcode,p.active FROM catalog_product p LEFT JOIN catalog_product_group g ON '+
   'g.installation_id=p.installation_id AND g.branch_id=p.branch_id AND g.id=p.group_id '+
   'WHERE p.installation_id=$1 AND p.branch_id=$2 ORDER BY p.sku LIMIT 5001';
  break;
 case "skus":
  sql='SELECT s.sku AS code,p.sku AS "productCode",s.unit_code AS "unitCode",'+
   's.conversion_to_base::text AS "toBase",s.active,NULL::text AS reason '+
   'FROM catalog_sell_sku s JOIN catalog_product p ON p.installation_id=s.installation_id '+
   'AND p.branch_id=s.branch_id AND p.id=s.product_id '+
   'WHERE s.installation_id=$1 AND s.branch_id=$2 ORDER BY s.sku LIMIT 5001';
  break;
 case "prices":
  sql='SELECT DISTINCT ON (l.code,p.sku) l.code AS "priceListCode",'+
   'p.sku AS "productCode",e.amount::text,e.discount_rate::text AS "discountRate",'+
   ` to_char(e.effective_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "effectiveAt" FROM catalog_price_entry e `++
   'JOIN catalog_price_list l ON l.installation_id=e.installation_id '+
   'AND l.branch_id=e.branch_id AND l.id=e.price_list_id '+
   'JOIN catalog_product p ON p.installation_id=e.installation_id '+
   'AND p.branch_id=e.branch_id AND p.id=e.product_id '+
   'WHERE e.installation_id=$1 AND e.branch_id=$2 '+
   'ORDER BY l.code,p.sku,e.effective_at DESC,e.id DESC LIMIT 5001';
 }
 const r=await db.query<Record<string,unknown>>(sql,[tenant,branch]);
 if(r.rows.length>5000)throw new BulkFault("EXPORT_ROW_LIMIT",413);
 const result=r.rows.map(x=>fields.map(k=>{
  const v=x[k];
  return v==null?"":v instanceof Date?v.toISOString():
   typeof v==="boolean"?v?"1":"0":String(v);
 }));
 return {content:bulkCsv(fields,result),total:result.length};
}
export async function handleBulkHttp(req:IncomingMessage,res:ServerResponse,
 requestId:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin&&origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fail(res,403,"ORIGIN_DENIED",requestId);return;}
 if(req.method==="OPTIONS"){
  if(!cors){fail(res,403,"ORIGIN_DENIED",requestId);return;}
  send(res,204,null,requestId,cors);return;
 }
 const pool=opts.pool,tenant=opts.installationId;
 if(!pool||!tenant||!UUID.test(tenant)||!opts.allowedOrigin){
  fail(res,503,"BULK_NOT_CONFIGURED",requestId,cors);return;
 }
 try{
  if(!await ready()){fail(res,503,"SCHEMA_NOT_READY",requestId,cors);return;}
  const auth=bearer(req);let actor:string|undefined;
  const conn=await pool.connect();
  try{actor=auth?(await resolveSession(conn,tenant,auth))?.actorId:undefined;}
  finally{conn.release();}
  if(!actor)throw new BulkFault("AUTH_REQUIRED",401);
  const action=url.pathname.replace("/v1/catalog/bulk/","");
  if(req.method==="GET"&&(action==="template"||action==="export")){
   const branch=url.searchParams.get("branchId"),kind=resource(url.searchParams.get("resource"));
   if(!branch||!UUID.test(branch))throw new BulkFault("INVALID_BRANCH");
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:tenant,actorId:actor,branchId:branch,
      permission:"catalog.read"}))throw new BulkFault("DENIED",403);
    if(action==="template"){
     const columns=bulkColumns(kind);
     send(res,200,{fileName:"mau-"+kind+".csv",content:bulkCsv(columns,[]),
       columns,requestId},requestId,cors);
    }else{
     const result=await exportRows(db,tenant,branch,kind);
     send(res,200,{fileName:"xuat-"+kind+".csv",...result,requestId},requestId,cors);
    }
   }finally{db.release();}
   return;
  }
  if(req.method!=="POST"||!["inspect","preview","apply"].includes(action))
   throw new BulkFault("BULK_METHOD_NOT_ALLOWED",405);
  const raw=await body(req);
  const branch=raw.branchId,kind=resource(raw.resource);
  if(typeof branch!=="string"||!UUID.test(branch))
   throw new BulkFault("INVALID_BRANCH");
  if(action==="inspect"){
   if(typeof raw.fileName!=="string"||typeof raw.contentBase64!=="string"||
      typeof raw.hasHeader!=="boolean")throw new BulkFault("INVALID_FILE");
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:tenant,actorId:actor,branchId:branch,
      permission:"catalog.read"}))throw new BulkFault("DENIED",403);
    const result=parseBulkFile(raw.fileName,raw.contentBase64,raw.hasHeader);
    send(res,200,{headers:result.headers,rowCount:result.rowCount,
      sample:result.rows.slice(0,5),suggestedMapping:suggestBulkMapping(kind,result.headers),
      allowedColumns:bulkColumns(kind),requestId},requestId,cors);
   }finally{db.release();}
   return;
  }
  const input=checkBulkInput(raw);
  if(action==="preview"){
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:tenant,actorId:actor,
      branchId:input.branchId,permission:"catalog.read"}))
     throw new BulkFault("DENIED",403);
    const plan=await buildBulkPlan(db,tenant,actor,input);
    send(res,200,{...publicBulkPlan(plan),requestId},requestId,cors);
   }finally{db.release();}
   return;
  }
  const match=req.headers["if-match"],key=req.headers["idempotency-key"];
  if(match!=="0"||typeof key!=="string"||!validIdempotencyKey(key))
   throw new BulkFault("INVALID_MUTATION_HEADERS");
  const previewHash=raw.previewHash;
  if(typeof previewHash!=="string"||!/^[0-9a-f]{64}$/.test(previewHash))
   throw new BulkFault("PREVIEW_REQUIRED");
  const fileHash=createHash("sha256").update(input.contentBase64).digest("hex");
  const outcome=await executeMutation(pool,{
   installationId:tenant,actorId:actor,requestId,
   action:"catalog.bulk."+kind+".apply",idempotencyKey:key,expectedRevision:0,
   payload:{branchId:input.branchId,resource:kind,mode:input.mode,
    fileHash,mapping:input.mapping,hasHeader:input.hasHeader,previewHash},
  },{
   authorize:(db,c)=>hasPermission(db,{installationId:c.installationId,
     actorId:c.actorId,branchId:input.branchId,permission:"catalog.write"}),
   execute:(db,c)=>applyBulkPlan(db,c,input,previewHash),
  });
  send(res,outcome.status,{...(outcome.body as Record<string,unknown>),
   replayed:outcome.replayed,requestId},requestId,cors);
 }catch(err){
  if(err instanceof BulkFault||err instanceof BulkFileFault){
   fail(res,err.status,err.code,requestId,cors);return;
  }
  if(err instanceof MutationFault){
   fail(res,err.httpStatus,err.code,requestId,cors);return;
  }
  if(typeof err==="object"&&err!==null&&"code" in err){
   if(err.code==="23505"){fail(res,409,"DUPLICATE_OR_CONCURRENT_UPDATE",requestId,cors);return;}
   if(err.code==="23503"||err.code==="23514"){
    fail(res,400,"INVALID_REFERENCE",requestId,cors);return;
   }
   if(err.code==="P0001"){fail(res,409,"IMMUTABLE_OR_CONVERSION_MISMATCH",requestId,cors);return;}
  }
  fail(res,503,"BULK_UNAVAILABLE",requestId,cors);
 }
}
