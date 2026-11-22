import type {IncomingMessage,ServerResponse} from "node:http";
import {createHash} from "node:crypto";
import type {Pool,PoolClient} from "pg";
import {resolveSession} from "./auth.ts";
import {hasPermission} from "./rbac.ts";
import {executeMutation,MutationFault,type MutationContext} from "./mutation.ts";
import type {IdentityOptions} from "./identity_http.ts";
import {validIdempotencyKey} from "./contracts.ts";
import {resolveR2Config,presignR2,type R2Config} from "./r2_media_signer.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_BYTES=5*1024*1024;
type MediaType="image/png"|"image/jpeg"|"image/webp";
class MediaError extends Error{
  readonly status:number;
  readonly code:string;
  constructor(status:number,code:string){
    super(code);
    this.status=status;
    this.code=code;
  }
}
function mime(value:unknown):MediaType{
  if(value!=="image/png"&&value!=="image/jpeg"&&value!=="image/webp")
    throw new MediaError(400,"INVALID_IMAGE_TYPE");
  return value;
}
function metadata(value:Record<string,unknown>){
  const branchId=value.branchId,uploadNonce=value.uploadNonce;
  const byteLength=value.byteLength,contentType=mime(value.contentType);
  if(!UUID.test(String(branchId))||!UUID.test(String(uploadNonce))||
    typeof byteLength!=="number"||!Number.isSafeInteger(byteLength)||
    byteLength<1||byteLength>MAX_BYTES||
    Object.keys(value).some(k=>
      !["branchId","uploadNonce","byteLength","contentType"].includes(k)))
    throw new MediaError(400,"INVALID_MEDIA_METADATA");
  return {branchId:branchId as string,uploadNonce:uploadNonce as string,
    byteLength,contentType};
}
function objectKey(tenant:string,actorId:string,productId:string,
  value:ReturnType<typeof metadata>):string{
  const digest=createHash("sha256").update([
    tenant,value.branchId,actorId,productId,value.uploadNonce,
    value.contentType,String(value.byteLength)].join("|")).digest("hex");
  const ext=value.contentType==="image/jpeg"?"jpg":
    value.contentType==="image/png"?"png":"webp";
  return "installations/"+tenant+"/branches/"+value.branchId+
    "/products/"+productId+"/"+digest+"."+ext;
}
function response(res:ServerResponse,status:number,body:unknown,id:string,
  origin?:string,withoutBody=false){
  const headers:Record<string,string>={
    "content-type":"application/json; charset=utf-8",
    "cache-control":"no-store","x-content-type-options":"nosniff",
    "referrer-policy":"no-referrer","vary":"Origin","x-request-id":id,
  };
  if(origin){
    headers["access-control-allow-origin"]=origin;
    headers["access-control-allow-methods"]="GET,POST,PATCH,OPTIONS";
    headers["access-control-allow-headers"]=
      "authorization,content-type,idempotency-key,if-match,x-request-id";
    headers["access-control-max-age"]="300";
  }
  res.writeHead(status,headers);
  res.end(withoutBody?"":JSON.stringify(body));
}
function fail(res:ServerResponse,status:number,code:string,id:string,origin?:string){
  response(res,status,{error:{code,message:status===503
    ?"Kho ảnh tạm thời chưa sẵn sàng.":"Không thực hiện được thao tác hình ảnh.",
    requestId:id}},id,origin);
}
async function readBody(req:IncomingMessage):Promise<Record<string,unknown>>{
  if(req.headers["content-type"]?.split(";")[0]?.trim()!=="application/json")
    throw new MediaError(415,"INVALID_CONTENT_TYPE");
  const parts:Buffer[]=[];let total=0;
  for await(const chunk of req){
    const b=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk as Uint8Array);
    total+=b.length;
    if(total>1024)throw new MediaError(413,"MEDIA_METADATA_TOO_LARGE");
    parts.push(b);
  }
  let raw:unknown;
  try{raw=JSON.parse(Buffer.concat(parts).toString("utf8"));}
  catch{throw new MediaError(400,"INVALID_JSON");}
  if(!raw||typeof raw!=="object"||Array.isArray(raw))
    throw new MediaError(400,"INVALID_MEDIA_METADATA");
  return raw as Record<string,unknown>;
}
async function schemaReady(pool:Pool):Promise<boolean>{
  try{
    const r=await pool.query<{ok:boolean}>(
      "SELECT EXISTS(SELECT 1 FROM public.schema_migrations WHERE version='0016_r1_product_media.sql') AS ok");
    return r.rows[0]?.ok===true;
  }catch{return false;}
}
async function authorize(db:PoolClient,tenant:string,actorId:string,
  branchId:string,productId:string,permission:"catalog.read"|"catalog.write"){
  if(!await hasPermission(db,{installationId:tenant,actorId,
    branchId,permission}))throw new MediaError(403,"MEDIA_PERMISSION_DENIED");
  const product=await db.query<{id:string}>(`SELECT id FROM catalog_product
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active`,
    [tenant,branchId,productId]);
  if(product.rowCount!==1)throw new MediaError(404,"PRODUCT_NOT_FOUND");
}
async function verifyUploaded(config:R2Config,key:string,expected:ReturnType<typeof metadata>){
  // HEAD is server-side proof of durable R2 data. Never accept browser
  // assertion of a successful upload without verifying the remote object.
  const head=await fetch(presignR2(config,"HEAD",key),{
    method:"HEAD",signal:AbortSignal.timeout(6500),
  });
  if(!head.ok)throw new MediaError(409,"IMAGE_UPLOAD_NOT_FOUND");
  const actualSize=Number(head.headers.get("content-length"));
  const actualType=head.headers.get("content-type")?.split(";")[0]?.trim();
  const etag=head.headers.get("etag")?.replace(/^"|"$/g,"");
  if(!Number.isInteger(actualSize)||actualSize!==expected.byteLength||
    actualType!==expected.contentType||!etag||etag.length>160)
    throw new MediaError(409,"IMAGE_UPLOAD_MISMATCH");
  // MIME cannot be trusted from a header. Verify bytes before the metadata
  // record is acknowledged; SVG and HTML are never admitted.
  const read=await fetch(presignR2(config,"GET",key),{
    headers:{Range:"bytes=0-15"},signal:AbortSignal.timeout(6500),
  });
  if(!read.ok)throw new MediaError(409,"IMAGE_UPLOAD_NOT_FOUND");
  const bytes=new Uint8Array(await read.arrayBuffer());
  const isPng=bytes.length>=8&&
    [137,80,78,71,13,10,26,10].every((x,i)=>bytes[i]===x);
  const isJpeg=bytes.length>=3&&bytes[0]===255&&bytes[1]===216&&bytes[2]===255;
  const isWebp=bytes.length>=12&&
    String.fromCharCode(...bytes.slice(0,4))==="RIFF"&&
    String.fromCharCode(...bytes.slice(8,12))==="WEBP";
  if(!(expected.contentType==="image/png"&&isPng||
       expected.contentType==="image/jpeg"&&isJpeg||
       expected.contentType==="image/webp"&&isWebp))
    throw new MediaError(400,"INVALID_IMAGE_CONTENT");
  return etag;
}
function ctxFrom(req:IncomingMessage,id:string,actorId:string,tenant:string,
  payload:unknown):MutationContext{
  const key=req.headers["idempotency-key"],revision=req.headers["if-match"];
  if(typeof key!=="string"||!validIdempotencyKey(key)||revision!=="0")
    throw new MediaError(400,"INVALID_MUTATION_HEADERS");
  return {installationId:tenant,actorId,requestId:id,
    action:"catalog.product.media.complete",idempotencyKey:key,
    expectedRevision:0,payload};
}
export async function handleCatalogMediaHttp(req:IncomingMessage,
  res:ServerResponse,id:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>){
  const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
  const corsOrigin=origin&&origin===opts.allowedOrigin?origin:undefined;
  if(origin&&!corsOrigin){fail(res,403,"ORIGIN_DENIED",id);return;}
  if(req.method==="OPTIONS"){
    if(!corsOrigin){fail(res,403,"ORIGIN_DENIED",id);return;}
    response(res,204,null,id,corsOrigin,true);return;
  }
  const tenant=opts.installationId,pool=opts.pool;
  if(!pool||!tenant||!UUID.test(tenant)){
    fail(res,503,"MEDIA_NOT_CONFIGURED",id,corsOrigin);return;
  }
  const config=resolveR2Config();
  if(!config){fail(res,503,"MEDIA_NOT_CONFIGURED",id,corsOrigin);return;}
  try{
    if(!await ready()||!await schemaReady(pool))
      throw new MediaError(503,"MEDIA_MIGRATION_REQUIRED");
    const match=/^\/v1\/catalog\/products\/([0-9a-f-]{36})\/media(?:\/(prepare|complete))?$/i.exec(url.pathname);
    if(!match||!UUID.test(match[1]!))throw new MediaError(404,"NOT_FOUND");
    const productId=match[1]!;
    const rawAuth=req.headers.authorization;
    const token=typeof rawAuth==="string"
      ?/^Bearer ([A-Za-z0-9_-]{43})$/.exec(rawAuth)?.[1]:null;
    const db=await pool.connect();
    let actorId:string|undefined;
    try{
      actorId=token?(await resolveSession(db,tenant,token))?.actorId:undefined;
    }finally{db.release();}
    if(!actorId)throw new MediaError(401,"AUTH_DENIED");
    if(req.method==="GET"&&!match[2]){
      const branchId=url.searchParams.get("branchId");
      if(!UUID.test(branchId??""))throw new MediaError(400,"INVALID_BRANCH");
      const client=await pool.connect();
      try{
        await authorize(client,tenant,actorId,branchId!,productId,"catalog.read");
        const items=await client.query<{
          id:string;contentType:MediaType;byteLength:number;isPrimary:boolean;revision:number;
          objectKey:string;
        }>(`SELECT id,object_key AS "objectKey",mime_type AS "contentType",
          byte_length AS "byteLength",is_primary AS "isPrimary",
          revision::integer FROM catalog_product_media
          WHERE installation_id=$1 AND branch_id=$2 AND product_id=$3 AND active
          ORDER BY is_primary DESC,created_at DESC LIMIT 20`,[tenant,branchId,productId]);
        response(res,200,{items:items.rows.map(x=>({
          id:x.id,contentType:x.contentType,byteLength:x.byteLength,
          isPrimary:x.isPrimary,revision:x.revision,
          downloadUrl:presignR2(config,"GET",x.objectKey),
        })),requestId:id},id,corsOrigin);
      }finally{client.release();}
      return;
    }
    if(req.method==="POST"&&(match[2]==="prepare"||match[2]==="complete")){
      const value=metadata(await readBody(req));
      const key=objectKey(tenant,actorId,productId,value);
      if(match[2]==="prepare"){
        const client=await pool.connect();
        try{
          await authorize(client,tenant,actorId,value.branchId,productId,"catalog.write");
        }finally{client.release();}
        response(res,200,{putUrl:presignR2(config,"PUT",key,value.contentType),
          contentType:value.contentType,expiresInSeconds:300,requestId:id},id,corsOrigin);
        return;
      }
      const context=ctxFrom(req,id,actorId,tenant,value);
      const outcome=await executeMutation(pool,context,{
        authorize:(db,c)=>hasPermission(db,{installationId:c.installationId,
          actorId:c.actorId,branchId:value.branchId,permission:"catalog.write"}),
        execute:async(db)=>{
          const product=await db.query(`SELECT id FROM catalog_product
            WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active FOR UPDATE`,
            [tenant,value.branchId,productId]);
          if(product.rowCount!==1)throw new MediaError(404,"PRODUCT_NOT_FOUND");
          const count=await db.query<{total:number;primaryCount:number}>(`SELECT
            count(*)::integer AS total,
            count(*) FILTER(WHERE is_primary)::integer AS "primaryCount"
            FROM catalog_product_media WHERE installation_id=$1 AND
              branch_id=$2 AND product_id=$3 AND active`,
            [tenant,value.branchId,productId]);
          if((count.rows[0]?.total??0)>=10)
            throw new MediaError(409,"MAX_PRODUCT_IMAGES");
          const etag=await verifyUploaded(config,key,value);
          const created=await db.query<{id:string}>(`INSERT INTO catalog_product_media
            (installation_id,branch_id,product_id,object_key,mime_type,
             byte_length,etag,is_primary,created_by)
            VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING id`,
            [tenant,value.branchId,productId,key,value.contentType,
              value.byteLength,etag,(count.rows[0]?.primaryCount??0)===0,actorId]);
          return {status:201,body:{id:created.rows[0]!.id,
            productId,contentType:value.contentType,byteLength:value.byteLength,
            requestId:id}};
        },
      });
      response(res,outcome.status,outcome.body,id,corsOrigin);
      return;
    }
    throw new MediaError(405,"METHOD_NOT_ALLOWED");
  }catch(e){
    if(e instanceof MediaError){fail(res,e.status,e.code,id,corsOrigin);return;}
    if(e instanceof MutationFault){fail(res,e.httpStatus,e.code,id,corsOrigin);return;}
    if(typeof e==="object"&&e!==null&&"code" in e&&e.code==="23505"){
      fail(res,409,"DUPLICATE",id,corsOrigin);return;
    }
    fail(res,503,"MEDIA_UNAVAILABLE",id,corsOrigin);
  }
}
