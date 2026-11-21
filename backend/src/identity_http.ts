import type { IncomingMessage, ServerResponse } from "node:http";
import { createHash } from "node:crypto";
import type { Pool, PoolClient } from "pg";
import { signIn,signOut,resolveSession,AuthDenied,AuthThrottled,validThrottleSecret } from "./auth.ts";
import { userAccess,listUsers,listScopes,listGrants,createUser,updateUser,addGrant,revokeGrant,IdentityError } from "./identity_admin.ts";
import { MutationFault } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export type IdentityOptions={pool:Pool|null;installationId?:string;allowedOrigin?:string;throttleSecret?:string};
const allowedMethods="GET, POST, PATCH, DELETE, OPTIONS";
function safeOrigin(origin:string|undefined):boolean {
  if(!origin)return false;
  try {const url=new URL(origin);return url.origin===origin&&
    (url.protocol==="https:" || url.hostname==="localhost"&&url.protocol==="http:");}
  catch{return false;}
}
function send(res:ServerResponse,status:number,body:unknown,id:string,origin?:string,withoutBody=false):void{
  const headers:Record<string,string>={
    "content-type":"application/json; charset=utf-8",
    "cache-control":"no-store",
    "x-content-type-options":"nosniff",
    "referrer-policy":"no-referrer",
    "x-request-id":id,
    "vary":"Origin",
  };
  if(origin){
    headers["access-control-allow-origin"]=origin;
    headers["access-control-allow-methods"]=allowedMethods;
    headers["access-control-allow-headers"]="content-type,authorization,idempotency-key,if-match,x-request-id";
    headers["access-control-max-age"]="300";
  }
  res.writeHead(status,headers);
  res.end(withoutBody?"":JSON.stringify(body));
}
function fail(res:ServerResponse,status:number,code:string,id:string,origin?:string){
  send(res,status,{error:{code,message:status===503?"Hệ thống danh tính chưa sẵn sàng":
    status===401?"Đăng nhập không hợp lệ":status===403?"Không có quyền":
    status===429?"Quá nhiều lần thử. Vui lòng thử lại sau":"Yêu cầu không hợp lệ",requestId:id}},id,origin);
}
async function readBody(req:IncomingMessage):Promise<Record<string,unknown>>{
  if(req.headers["content-type"]?.split(";")[0]?.trim().toLowerCase()!=="application/json")
    throw new IdentityError(415,"INVALID_CONTENT_TYPE");
  if(Number(req.headers["content-length"]||0)>8192)throw new IdentityError(413,"TOO_LARGE");
  let bytes=0;const parts:Buffer[]=[];
  for await(const part of req){
    const buf=Buffer.isBuffer(part)?part:Buffer.from(part as Uint8Array);
    bytes+=buf.length;
    if(bytes>8192)throw new IdentityError(413,"TOO_LARGE");
    parts.push(buf);
  }
  let value:unknown;
  try {value=JSON.parse(Buffer.concat(parts).toString("utf8")) as unknown;}
  catch {throw new IdentityError(400,"INVALID_JSON");}
  if(!value||Array.isArray(value)||typeof value!=="object")throw new IdentityError(400,"INVALID_INPUT");
  return value as Record<string,unknown>;
}
function bearer(req:IncomingMessage):string|null{
  const raw=req.headers.authorization;
  if(typeof raw!=="string")return null;
  const match=/^Bearer ([A-Za-z0-9_-]{43})$/.exec(raw);
  return match?.[1]??null;
}
function mutateHeaders(req:IncomingMessage,id:string,payload:unknown,action:string,actorId:string,tenant:string){
  const key=req.headers["idempotency-key"];
  const match=req.headers["if-match"];
  const revision=typeof match==="string"&&/^(0|[1-9][0-9]{0,14})$/.test(match)?Number(match):NaN;
  if(typeof key!=="string"||!validIdempotencyKey(key)||!Number.isSafeInteger(revision))
    throw new IdentityError(400,"INVALID_MUTATION_HEADERS");
  return {installationId:tenant,actorId,requestId:id,action,idempotencyKey:key,
    expectedRevision:revision,payload};
}
async function authenticated(client:PoolClient,tenant:string,token:string|null){
  return token?resolveSession(client,tenant,token):null;
}
/** Routes are enabled only for a provisioned single-tenant backend and verified schema. */
export async function handleIdentityHttp(
  req:IncomingMessage,res:ServerResponse,id:string,path:string,
  opts:IdentityOptions,ready:()=>Promise<boolean>,
):Promise<void>{
  const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
  const corsOrigin=origin&&origin===opts.allowedOrigin?origin:undefined;
  if(origin&&!corsOrigin){fail(res,403,"ORIGIN_DENIED",id);return;}
  if(req.method==="OPTIONS"){
    if(!corsOrigin){fail(res,403,"ORIGIN_DENIED",id);return;}
    send(res,204,null,id,corsOrigin,true);
    return;
  }
  const tenant=opts.installationId,pool=opts.pool;
  if(!pool||!tenant||!UUID.test(tenant)||!safeOrigin(opts.allowedOrigin)||
    !validThrottleSecret(opts.throttleSecret)){
    fail(res,503,"AUTH_NOT_CONFIGURED",id,corsOrigin);return;
  }
  try{
    if(!await ready()){fail(res,503,"SCHEMA_NOT_READY",id,corsOrigin);return;}
    if(path==="/v1/auth/config"&&req.method==="GET"){
      send(res,200,{enabled:true,method:"bearer-memory",requestId:id},id,corsOrigin);return;
    }
    if(path==="/v1/auth/login"&&req.method==="POST"){
      const data=await readBody(req);
      if(typeof data.loginName!=="string"||typeof data.password!=="string")
        throw new AuthDenied();
      const login=await signIn(pool,tenant,data.loginName,data.password,id,opts.throttleSecret);
      send(res,200,{token:login.token,actorId:login.actorId,expiresAt:login.expiresAt,
        requestId:id},id,corsOrigin);return;
    }
    const token=bearer(req);
    const client=await pool.connect();
    let actor:{actorId:string;installationId:string}|null=null;
    try {actor=await authenticated(client,tenant,token);}
    finally {client.release();}
    if(!actor){fail(res,401,"AUTH_DENIED",id,corsOrigin);return;}
    if(path==="/v1/auth/logout"&&req.method==="POST"){
      if(!await signOut(pool,tenant,token!,id)){fail(res,401,"AUTH_DENIED",id,corsOrigin);return;}
      send(res,200,{signedOut:true,requestId:id},id,corsOrigin);return;
    }
    if(path==="/v1/auth/session"&&req.method==="GET"){
      const db=await pool.connect();
      try{
        const permissions=await userAccess(db,tenant,actor.actorId);
        const identity=await db.query<{loginName:string;expiresAt:Date}>(
          `SELECT u.login_name AS "loginName",s.expires_at AS "expiresAt"
           FROM app_session s JOIN app_user u
             ON u.installation_id=s.installation_id AND u.id=s.user_id
           WHERE s.installation_id=$1 AND s.user_id=$2 AND s.token_hash=$3
             AND s.revoked_at IS NULL AND s.expires_at>now() AND u.disabled=false`,
          [tenant,actor.actorId,createHash('sha256').update(token!).digest('hex')]);
        if(!identity.rows[0]){fail(res,401,"AUTH_DENIED",id,corsOrigin);return;}
        send(res,200,{actorId:actor.actorId,loginName:identity.rows[0].loginName,
          expiresAt:identity.rows[0].expiresAt.toISOString(),grants:permissions,requestId:id},id,corsOrigin);
      }finally{db.release();}
      return;
    }
    if(path==="/v1/admin/users"&&req.method==="GET"){
      const db=await pool.connect();
      try{send(res,200,{users:await listUsers(db,tenant,actor.actorId),requestId:id},id,corsOrigin);}
      finally{db.release();}
      return;
    }
    if(path==="/v1/admin/scopes"&&req.method==="GET"){
      const db=await pool.connect();
      try{send(res,200,{...await listScopes(db,tenant,actor.actorId),requestId:id},id,corsOrigin);}
      finally{db.release();}
      return;
    }
    if(path==="/v1/admin/users"&&req.method==="POST"){
      const payload=await readBody(req);
      const ctx=mutateHeaders(req,id,payload,"identity.user.create",actor.actorId,tenant);
      const result=await createUser(pool,ctx);
      send(res,result.status,result.body,id,corsOrigin);return;
    }
    const userPath=/^\/v1\/admin\/users\/([0-9a-f-]{36})$/.exec(path);
    if(userPath&&req.method==="PATCH"){
      const payload=await readBody(req);
      const ctx=mutateHeaders(req,id,payload,"identity.user.update",actor.actorId,tenant);
      const r=await updateUser(pool,ctx,userPath[1]!);
      send(res,r.status,r.body,id,corsOrigin);return;
    }
    const grantsPath=/^\/v1\/admin\/users\/([0-9a-f-]{36})\/grants$/.exec(path);
    if(grantsPath&&req.method==="GET"){
      const db=await pool.connect();
      try{send(res,200,{grants:await listGrants(db,tenant,actor.actorId,grantsPath[1]!),requestId:id},id,corsOrigin);}
      finally{db.release();}
      return;
    }
    if(grantsPath&&req.method==="POST"){
      const payload=await readBody(req);
      const ctx=mutateHeaders(req,id,payload,"identity.grant.create",actor.actorId,tenant);
      const r=await addGrant(pool,ctx,grantsPath[1]!);
      send(res,r.status,r.body,id,corsOrigin);return;
    }
    const revokedPath=/^\/v1\/admin\/users\/([0-9a-f-]{36})\/grants\/([0-9a-f-]{36})$/.exec(path);
    if(revokedPath&&req.method==="DELETE"){
      const payload={userId:revokedPath[1],roleId:revokedPath[2]};
      const ctx=mutateHeaders(req,id,payload,"identity.grant.revoke",actor.actorId,tenant);
      const r=await revokeGrant(pool,ctx,revokedPath[1]!,revokedPath[2]!);
      send(res,r.status,r.body,id,corsOrigin);return;
    }
    fail(res,404,"NOT_FOUND",id,corsOrigin);
  }catch(error){
    if(error instanceof AuthThrottled){fail(res,429,"AUTH_THROTTLED",id,corsOrigin);return;}
    if(error instanceof AuthDenied){fail(res,401,"AUTH_DENIED",id,corsOrigin);return;}
    if(error instanceof IdentityError){fail(res,error.status,error.kind,id,corsOrigin);return;}
    if(error instanceof MutationFault){fail(res,error.httpStatus,error.code,id,corsOrigin);return;}
    if(typeof error==="object"&&error!==null&&"code" in error&&error.code==="23505"){
      fail(res,409,"CONFLICT",id,corsOrigin);return;
    }
    // Never log DB or credential-containing exceptions.
    fail(res,503,"IDENTITY_UNAVAILABLE",id,corsOrigin);
  }
}
