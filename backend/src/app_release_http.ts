import type {IncomingMessage,ServerResponse} from "node:http";
import {createHash,createHmac,timingSafeEqual} from "node:crypto";
import {Readable} from "node:stream";
import {pipeline} from "node:stream/promises";
import {resolveSession} from "./auth.ts";
import {userAccess} from "./identity_admin.ts";
import type {IdentityOptions} from "./identity_http.ts";
import {presignReleaseRead,type R2Config} from "./r2_media_signer.ts";

export const ERP_ANDROID_PACKAGE="vn.erpdistribution.erp_distribution";
const HEX=/^[a-f0-9]{64}$/;
const MAX_APK=300*1024*1024;
type Release={
  schema:1;versionCode:number;versionName:string;packageName:string;sha256:string;
  signerSha256:string;size:number;objectKey:string;notes:string;releasedAt:string;sourceSha:string;
};
type Config={r2:R2Config;signer:string;ticketKey:string};

export function releaseConfig(env:Record<string,string|undefined>=process.env):Config|null{
  const accountId=env.ERP_RELEASE_R2_ACCOUNT_ID??"",bucket=env.ERP_RELEASE_R2_BUCKET??"";
  const accessKeyId=env.ERP_RELEASE_R2_ACCESS_KEY_ID??"",secretAccessKey=env.ERP_RELEASE_R2_SECRET_ACCESS_KEY??"";
  const signer=env.ERP_ANDROID_CERT_SHA256??"",ticketKey=env.ERP_RELEASE_TICKET_SECRET??"";
  if(!/^[a-f0-9]{32}$/i.test(accountId)||!/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/.test(bucket)||
    bucket===env.ERP_R2_BUCKET||! /^[a-f0-9]{32}$/i.test(accessKeyId)||
    secretAccessKey.length<32||!HEX.test(signer)||ticketKey.length<32)return null;
  return {r2:{accountId,bucket,accessKeyId,secretAccessKey},signer,ticketKey};
}
export function validateRelease(raw:unknown,signer:string):Release|null{
  if(!raw||typeof raw!=="object"||Array.isArray(raw))return null;
  const d=raw as Record<string,unknown>;
  if(d.schema!==1||typeof d.versionCode!=="number"||!Number.isSafeInteger(d.versionCode)||
    d.versionCode<1||d.versionCode>999999999||d.packageName!==ERP_ANDROID_PACKAGE||
    typeof d.versionName!=="string"||!/^[0-9][0-9A-Za-z.+-]{0,63}$/.test(d.versionName)||
    typeof d.sha256!=="string"||!HEX.test(d.sha256)||!HEX.test(signer)||d.signerSha256!==signer||
    typeof d.size!=="number"||!Number.isSafeInteger(d.size)||d.size<1||d.size>MAX_APK||
    d.objectKey!=="releases/"+d.versionCode+"/erp-"+d.versionCode+".apk"||
    typeof d.notes!=="string"||d.notes.length>4000||typeof d.releasedAt!=="string"||
    !Number.isFinite(Date.parse(d.releasedAt))||typeof d.sourceSha!=="string"||! /^[a-f0-9]{40}$/.test(d.sourceSha))return null;
  return d as Release;
}
export function releaseTicket(secret:string,scope:string,release:Release,expires:number):string{
  return createHmac("sha256",secret).update(JSON.stringify([scope,release.versionCode,
    release.sha256,release.signerSha256,release.size,expires])).digest("hex");
}
export function validTicket(secret:string,scope:string,release:Release,expires:number,ticket:string,now:number):boolean{
  return Number.isSafeInteger(expires)&&expires>now&&expires<=now+300&&HEX.test(ticket)&&
    timingSafeEqual(Buffer.from(ticket,"hex"),Buffer.from(releaseTicket(secret,scope,release,expires),"hex"));
}
class Fault extends Error{readonly status:number;readonly code:string;constructor(status:number,code:string){super(code);this.status=status;this.code=code;}}
async function active(config:Config):Promise<Release|null>{
  const response=await fetch(presignReleaseRead(config.r2,"GET","releases/latest.json"),{
    redirect:"error",signal:AbortSignal.timeout(8000)});
  if(response.status===404){await response.body?.cancel();return null;}
  if(!response.ok||!response.body){await response.body?.cancel();throw new Fault(503,"RELEASE_UNAVAILABLE");}
  const reader=response.body.getReader();let total=0;const chunks:Uint8Array[]=[];
  try{for(;;){const part=await reader.read();if(part.done)break;
    total+=part.value.length;if(total>16384)throw new Fault(503,"RELEASE_INVALID");chunks.push(part.value);}}
  finally{await reader.cancel().catch(()=>undefined);}
  let release:Release|null;
  try{release=validateRelease(JSON.parse(Buffer.concat(chunks).toString("utf8")),config.signer);}
  catch{throw new Fault(503,"RELEASE_INVALID");}
  if(!release)throw new Fault(503,"RELEASE_INVALID");
  const head=await fetch(presignReleaseRead(config.r2,"HEAD",release.objectKey),{
    method:"HEAD",redirect:"error",signal:AbortSignal.timeout(8000)});
  if(!head.ok||head.headers.get("content-length")!==String(release.size)||
    head.headers.get("x-amz-meta-sha256")!==release.sha256||
    head.headers.get("x-amz-meta-signersha256")!==release.signerSha256)throw new Fault(503,"RELEASE_INVALID");
  return release;
}
function json(res:ServerResponse,status:number,data:unknown,id:string){
  res.writeHead(status,{"content-type":"application/json; charset=utf-8","cache-control":"no-store",
    "referrer-policy":"no-referrer","x-content-type-options":"nosniff","x-request-id":id});
  res.end(JSON.stringify(data));
}
async function versionBody(req:IncomingMessage):Promise<number>{
  if(req.headers["content-type"]?.split(";")[0]!=="application/json")throw new Fault(415,"INVALID_BODY");
  let n=0;const chunks:Buffer[]=[];
  for await(const chunk of req){const b=Buffer.from(chunk);n+=b.length;if(n>1024)throw new Fault(413,"INVALID_BODY");chunks.push(b);}
  try{const d=JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if(!d||Object.keys(d).length!==1||!Number.isSafeInteger(d.versionCode))throw new Error();
    return d.versionCode;
  }catch{throw new Fault(400,"INVALID_BODY");}
}
export async function handleAppReleaseHttp(req:IncomingMessage,res:ServerResponse,id:string,url:URL,
  opts:IdentityOptions,ready:()=>Promise<boolean>){
  try{
    // Native Android only; never expose release tickets to browser origins.
    if(req.headers.origin)throw new Fault(403,"ORIGIN_DENIED");
    const token=/^Bearer ([A-Za-z0-9_-]{43})$/.exec(req.headers.authorization??"")?.[1];
    if(!token)throw new Fault(401,"AUTH_DENIED");
    if(!opts.pool||!opts.installationId||!await ready())throw new Fault(503,"RELEASE_UNAVAILABLE");
    const db=await opts.pool.connect();
    let scope:string;
    try{
      const actor=await resolveSession(db,opts.installationId,token);
      if(!actor)throw new Fault(401,"AUTH_DENIED");
      const grants=await userAccess(db,opts.installationId,actor.actorId);
      if(!grants.length)throw new Fault(403,"FORBIDDEN");
      // Revalidate all grants and the same live session on every range request.
      const scopeGrants=grants.map(g=>JSON.stringify([g.permission,g.branchId,g.warehouseId])).sort();
      scope=createHash("sha256").update(JSON.stringify([opts.installationId,actor.actorId,token,scopeGrants])).digest("hex");
    }finally{db.release();}
    const config=releaseConfig();if(!config)throw new Fault(503,"RELEASE_UNAVAILABLE");
    const path=url.pathname;
    const latest=path==="/v1/app/releases/latest"&&req.method==="GET";
    const issue=path==="/v1/app/releases/ticket"&&req.method==="POST";
    const download=path==="/v1/app/releases/download"&&req.method==="GET";
    if(!latest&&!issue&&!download)throw new Fault(404,"NOT_FOUND");
    const release=await active(config);
    if(latest){
      const publicRelease=release?{versionCode:release.versionCode,versionName:release.versionName,
        packageName:release.packageName,sha256:release.sha256,signerSha256:release.signerSha256,
        size:release.size,notes:release.notes,releasedAt:release.releasedAt}:null;
      json(res,200,{release:publicRelease,requestId:id},id);return;
    }
    if(!release)throw new Fault(404,"RELEASE_NOT_FOUND");
    const now=Math.floor(Date.now()/1000);
    if(issue){
      if(await versionBody(req)!==release.versionCode)throw new Fault(409,"RELEASE_CHANGED");
      const expires=now+300,ticket=releaseTicket(config.ticketKey,scope,release,expires);
      const query=new URLSearchParams({versionCode:String(release.versionCode),expires:String(expires),ticket});
      json(res,200,{path:"/v1/app/releases/download?"+query,expiresAt:new Date(expires*1000).toISOString(),requestId:id},id);return;
    }
    if(url.searchParams.get("versionCode")!==String(release.versionCode)||
      !validTicket(config.ticketKey,scope,release,Number(url.searchParams.get("expires")),
        url.searchParams.get("ticket")??"",now))throw new Fault(403,"TICKET_DENIED");
    const range=req.headers.range;const offset=range===undefined?0:Number(/^bytes=([0-9]+)-$/.exec(range)?.[1]??NaN);
    if(!Number.isSafeInteger(offset)||offset<0||offset>=release.size){
      res.writeHead(416,{"content-range":"bytes */"+release.size,"cache-control":"no-store"});res.end();return;
    }
    const controller=new AbortController();res.once("close",()=>controller.abort());
    const partial=range!==undefined;
    const expectedRange="bytes "+offset+"-"+(release.size-1)+"/"+release.size;
    const upstream=await fetch(presignReleaseRead(config.r2,"GET",release.objectKey),{
      headers:partial?{range:"bytes="+offset+"-"}:{},redirect:"error",
      signal:AbortSignal.any([controller.signal,AbortSignal.timeout(180000)])});
    if(upstream.status!==(partial?206:200)||!upstream.body||
      upstream.headers.get("content-length")!==String(release.size-offset)||
      upstream.headers.get("x-amz-meta-sha256")!==release.sha256||
      (partial&&upstream.headers.get("content-range")!==expectedRange)){
      await upstream.body?.cancel();throw new Fault(503,"RELEASE_INVALID");
    }
    res.writeHead(partial?206:200,{"content-type":"application/vnd.android.package-archive",
      "content-length":String(release.size-offset),"accept-ranges":"bytes",
      ...(partial?{"content-range":expectedRange}:{}),"cache-control":"no-store",
      "referrer-policy":"no-referrer","x-content-type-options":"nosniff","x-request-id":id});
    await pipeline(Readable.fromWeb(upstream.body as unknown as import("node:stream/web").ReadableStream),res);
  }catch(e){
    if(res.headersSent){res.destroy();return;}
    if(!res.destroyed)json(res,e instanceof Fault?e.status:503,{error:{code:e instanceof Fault?e.code:"RELEASE_UNAVAILABLE",
      message:"Không thể kiểm tra hoặc tải bản cập nhật."},requestId:id},id);
  }
}
