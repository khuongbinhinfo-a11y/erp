import {createHash,createHmac} from "node:crypto";

export type R2Config={
  accountId:string;bucket:string;accessKeyId:string;secretAccessKey:string;
};
const HEX=/^[a-f0-9]{32}$/i;
const BUCKET=/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/;
const KEY=/^[A-Za-z0-9/_-]{1,240}\.(?:png|jpg|webp)$/;
const hash=(text:string)=>createHash("sha256").update(text).digest("hex");
const hmac=(key:Buffer|string,value:string)=>
  createHmac("sha256",key).update(value).digest();
function queryEncode(value:string):string{
  return encodeURIComponent(value).replace(/[!'()*]/g,
    char=>"%"+char.charCodeAt(0).toString(16).toUpperCase());
}
export function resolveR2Config(values:Record<string,string|undefined>=process.env):
  R2Config|null{
  const accountId=values.ERP_R2_ACCOUNT_ID??"";
  const bucket=values.ERP_R2_BUCKET??"";
  const accessKeyId=values.ERP_R2_ACCESS_KEY_ID??"";
  const secretAccessKey=values.ERP_R2_SECRET_ACCESS_KEY??"";
  if(!HEX.test(accountId)||!BUCKET.test(bucket)||
    !/^[a-f0-9]{32}$/i.test(accessKeyId)||secretAccessKey.length<32)return null;
  return {accountId,bucket,accessKeyId,secretAccessKey};
}
/** R2 S3 SigV4, region=auto; only signed, short-lived, private object URLs. */
export function presignR2(config:R2Config,
  method:"PUT"|"GET"|"HEAD",objectKey:string,
  contentType?:string,now=new Date(),ttlSeconds=300,contentLength?:number):string{
  if(!KEY.test(objectKey)||ttlSeconds<1||ttlSeconds>600)
    throw new Error("R2_SIGN_INPUT_INVALID");
  if(method==="PUT"&&!["image/png","image/jpeg","image/webp"].includes(contentType??""))
    throw new Error("R2_SIGN_TYPE_INVALID");
  if(method==="PUT"&&(!Number.isSafeInteger(contentLength)||
    contentLength===undefined||contentLength<1||contentLength>5*1024*1024))
    throw new Error("R2_SIGN_LENGTH_INVALID");
  const host=config.accountId+".r2.cloudflarestorage.com";
  const canonicalUri="/"+[config.bucket,...objectKey.split("/")]
    .map(queryEncode).join("/");
  const date=now.toISOString().replace(/[:-]|\.\d{3}/g,"");
  const day=date.slice(0,8),scope=day+"/auto/s3/aws4_request";
  // R2 evaluates If-None-Match atomically during PutObject. Bind the
  // create-only precondition to the signature so a client cannot remove it.
  // The declared byte limit is enforced by SigV4 on the actual PUT.
  // Browsers set Content-Length automatically for a fixed Uint8List body.
  const headers=method==="PUT"
    ? "content-length:"+contentLength+"\ncontent-type:"+contentType+
      "\nhost:"+host+"\nif-none-match:*\n"
    : "host:"+host+"\n";
  const signedHeaders=method==="PUT"
    ?"content-length;content-type;host;if-none-match":"host";
  const fields:Record<string,string>={
    "X-Amz-Algorithm":"AWS4-HMAC-SHA256",
    "X-Amz-Credential":config.accessKeyId+"/"+scope,
    "X-Amz-Date":date,
    "X-Amz-Expires":String(ttlSeconds),
    "X-Amz-SignedHeaders":signedHeaders,
  };
  const canonicalQuery=Object.entries(fields).sort(([a],[b])=>a.localeCompare(b))
    .map(([k,v])=>queryEncode(k)+"="+queryEncode(v)).join("&");
  const request=[method,canonicalUri,canonicalQuery,headers,signedHeaders,
    "UNSIGNED-PAYLOAD"].join("\n");
  const key=hmac(hmac(hmac(hmac("AWS4"+config.secretAccessKey,day),"auto"),"s3"),"aws4_request");
  const sign=createHmac("sha256",key)
    .update("AWS4-HMAC-SHA256\n"+date+"\n"+scope+"\n"+hash(request)).digest("hex");
  return "https://"+host+canonicalUri+"?"+canonicalQuery+"&X-Amz-Signature="+sign;
}
