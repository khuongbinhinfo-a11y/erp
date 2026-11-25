// ERP Android 0.2.0 immutable staging only. No latest.json mutation, no static credentials.
const ISSUER="https://token.actions.githubusercontent.com";
const JWKS=ISSUER+"/.well-known/jwks";
const AUD="erp-android-r2-stage-v2";
const REPO="khuongbinhinfo-a11y/erp";
const REF=REPO+"/.github/workflows/erp-android-r2-oidc-v2-stage.yml@refs/heads/main";
const SUBJECT="repo:khuongbinhinfo-a11y@269412638/erp@1466503632:environment:android-r2-publish";
const SOURCE="9963be10fd6d648474b826bcb5e917adbde03b5c";
const SIGNER="545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028";
const KEY="releases/2/erp-2.apk";
const MAX=300*1024*1024;
const HEX=/^[a-f0-9]{64}$/;
const UPLOAD="/uat/0.2.0/upload",READBACK="/uat/0.2.0/readback";
function fail(status,reason){return new Response(reason,{status,headers:{
  "cache-control":"no-store","content-type":"text/plain; charset=utf-8",
  "x-content-type-options":"nosniff"
}})}
function decode(s){
  if(!/^[A-Za-z0-9_-]+$/.test(s))throw Error("Invalid token");
  const b=atob(s.replace(/-/g,"+").replace(/_/g,"/")+"=".repeat((4-s.length%4)%4));
  return Uint8Array.from(b,x=>x.charCodeAt(0));
}
async function verifyOidc(jwt){
  if(typeof jwt!=="string"||jwt.length<100||jwt.length>16000)throw Error("Invalid token length");
  const parts=jwt.split(".");if(parts.length!==3)throw Error("Invalid JWT");
  const header=JSON.parse(new TextDecoder().decode(decode(parts[0])));
  const payload=JSON.parse(new TextDecoder().decode(decode(parts[1])));
  const now=Math.floor(Date.now()/1000);
  if(header.alg!=="RS256"||typeof header.kid!=="string"||
     payload.iss!==ISSUER||payload.aud!==AUD||
     !Number.isFinite(payload.exp)||payload.exp<=now||payload.exp>now+600||
     !Number.isFinite(payload.iat)||payload.iat>now+30||payload.iat<now-600||
     (payload.nbf!==undefined&&payload.nbf>now+30)||
     payload.repository!==REPO||String(payload.repository_id)!=="1466503632"||
     String(payload.repository_owner_id)!=="269412638"||
     payload.environment!=="android-r2-publish"||payload.sub!==SUBJECT||
     payload.workflow_ref!==REF||payload.ref!=="refs/heads/main"||
     payload.event_name!=="workflow_run")throw Error("Unapproved workflow claims");
  const response=await fetch(JWKS,{headers:{accept:"application/json"}});
  if(!response.ok)throw Error("JWKS unavailable");
  const keys=await response.json();
  const jwk=keys.keys?.find(k=>k.kid===header.kid&&k.kty==="RSA"&&k.use==="sig");
  if(!jwk?.n||!jwk?.e)throw Error("Signing key unavailable");
  const key=await crypto.subtle.importKey("jwk",
    {kty:"RSA",n:jwk.n,e:jwk.e,ext:true},
    {name:"RSASSA-PKCS1-v1_5",hash:"SHA-256"},false,["verify"]);
  if(!await crypto.subtle.verify("RSASSA-PKCS1-v1_5",key,decode(parts[2]),
    new TextEncoder().encode(parts[0]+"."+parts[1])))throw Error("Invalid signature");
}
function sameObject(obj,sha,size){
  return !!obj&&obj.size===size&&obj.customMetadata?.sha256===sha&&
    obj.customMetadata?.signersha256===SIGNER&&
    obj.customMetadata?.sourcesha===SOURCE&&
    obj.customMetadata?.versioncode==="2"&&obj.customMetadata?.versionname==="0.2.0";
}
export default {
  async fetch(request,env){
    const url=new URL(request.url);
    const upload=request.method==="PUT"&&url.pathname===UPLOAD;
    const readback=request.method==="GET"&&url.pathname===READBACK;
    if(url.search||(!upload&&!readback))return fail(404,"Not found");
    if(!env.ERP_ANDROID_RELEASES)return fail(503,"R2 unavailable");
    const token=/^Bearer ([A-Za-z0-9._-]+)$/.exec(request.headers.get("authorization")||"")?.[1];
    if(!token)return fail(401,"OIDC required");
    try{await verifyOidc(token)}catch{return fail(403,"GitHub OIDC denied")}
    const bucket=env.ERP_ANDROID_RELEASES;
    if(readback){
      const obj=await bucket.get(KEY);
      if(!obj)return fail(404,"Signed APK not staged");
      const sha=obj.customMetadata?.sha256;
      if(!HEX.test(sha||"")||!sameObject(obj,sha,obj.size))return fail(409,"Release identity mismatch");
      return new Response(obj.body,{status:200,headers:{
        "content-type":"application/vnd.android.package-archive",
        "content-length":String(obj.size),"cache-control":"no-store",
        "x-content-type-options":"nosniff","x-erp-sha256":sha
      }});
    }
    const sha=request.headers.get("x-erp-sha256")||"";
    const size=Number(request.headers.get("content-length"));
    if(!HEX.test(sha)||!Number.isSafeInteger(size)||size<1||size>MAX||
       request.headers.get("x-erp-signer-sha256")!==SIGNER||
       request.headers.get("x-erp-source-sha")!==SOURCE||
       request.headers.get("x-erp-version-code")!=="2"||
       request.headers.get("x-erp-version-name")!=="0.2.0"||
       request.headers.get("content-type")!=="application/vnd.android.package-archive"||
       !request.body)return fail(400,"APK identity declaration mismatch");
    const old=await bucket.head(KEY);
    if(old){
      return sameObject(old,sha,size)?fail(200,"Already staged; verify GET bytes"):fail(409,"Immutable release conflict");
    }
    // R2 validates sha256 against actual stream bytes BEFORE writing the object.
    // onlyIf prevents accidental overwrite of any existing APK.
    const put=await bucket.put(KEY,request.body,{
      onlyIf:{etagDoesNotMatch:"*"},sha256:sha,
      httpMetadata:{contentType:"application/vnd.android.package-archive"},
      customMetadata:{sha256:sha,signersha256:SIGNER,sourcesha:SOURCE,
        versioncode:"2",versionname:"0.2.0"}
    });
    const remote=put||await bucket.head(KEY);
    if(!sameObject(remote,sha,size))return fail(409,"Immutable R2 readback mismatch");
    return fail(201,"ERP_ANDROID_V2_STAGED");
  }
};
