// Immutable signed ERP Android artifact Worker. Public APK bytes are non-secret;
// the app's backend still enforces session, grants and short-lived download ticket.
const SIGNER="545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028";
const RELEASES={
  "/ERP-Android-0.1.0.apk":{key:"releases/1/erp-1.apk",name:"ERP-Android-0.1.0.apk",
    sha:"385766285dfc21e4c9d8cca3ab9d332e94476df1ec5ddbe02628bc0dc46b1328",size:63425634},
  "/ERP-Android-0.2.0.apk":{key:"releases/2/erp-2.apk",name:"ERP-Android-0.2.0.apk",
    sha:"c1c047754b69e466467c7997c6dd2cb752b806a5a8e4f2d1609524b59102b7c0",size:63769586},
  "/releases/2/erp-2.apk":{key:"releases/2/erp-2.apk",name:"ERP-Android-0.2.0.apk",
    sha:"c1c047754b69e466467c7997c6dd2cb752b806a5a8e4f2d1609524b59102b7c0",size:63769586},
  "/ERP-Android-0.3.0.apk":{key:"releases/3/erp-3.apk",name:"ERP-Android-0.3.0.apk",
    sha:"5bce59f3dea1143f148632f5bfc17552b2f4dd3d6a10d56cf5f4e4ef7c23f9f0",size:64343306},
  "/releases/3/erp-3.apk":{key:"releases/3/erp-3.apk",name:"ERP-Android-0.3.0.apk",
    sha:"5bce59f3dea1143f148632f5bfc17552b2f4dd3d6a10d56cf5f4e4ef7c23f9f0",size:64343306},
};
const PKG="vn.erpdistribution.erp_distribution";
const SOURCE_2="9963be10fd6d648474b826bcb5e917adbde03b5c";
const SOURCE_3="56384b325b55129f028906edf3d9b2b33e20b6bb";
function fail(status,message){return new Response(message,{status,headers:{
  "content-type":"text/plain; charset=utf-8","cache-control":"no-store",
  "x-content-type-options":"nosniff"
}})}
function same(meta,release){
  return !!meta&&meta.size===release.size&&
    meta.customMetadata?.sha256===release.sha&&meta.customMetadata?.signersha256===SIGNER;
}
function releaseValid(x){
  if(!x||typeof x!=="object")return false;
  const r=RELEASES["/releases/"+x.versionCode+"/erp-"+x.versionCode+".apk"];
  const versionName=x.versionCode===2?"0.2.0":x.versionCode===3?"0.3.0":null;
  const sourceSha=x.versionCode===2?SOURCE_2:x.versionCode===3?SOURCE_3:null;
  return !!r&&!!versionName&&x.schema===1&&x.versionName===versionName&&
    x.packageName===PKG&&x.sha256===r.sha&&x.signerSha256===SIGNER&&
    x.size===r.size&&x.objectKey===r.key&&x.sourceSha===sourceSha&&
    typeof x.notes==="string"&&x.notes.length<=4000&&
    typeof x.releasedAt==="string"&&Number.isFinite(Date.parse(x.releasedAt));
}
export default {
  async fetch(request,env){
    const url=new URL(request.url);
    if((request.method!=="GET"&&request.method!=="HEAD")||url.search)return fail(404,"Not found");
    if(!env.ERP_ANDROID_RELEASES)return fail(503,"R2 unavailable");
    const bucket=env.ERP_ANDROID_RELEASES;
    if(url.pathname==="/releases/latest.json"){
      const meta=await bucket.head("releases/latest.json");
      if(!meta)return fail(404,"No active release");
      if(meta.size>16384)return fail(409,"Invalid manifest");
      const obj=await bucket.get("releases/latest.json");
      if(!obj)return fail(404,"No active release");
      const raw=await obj.text();
      let active;
      try{active=JSON.parse(raw)}catch{return fail(409,"Invalid manifest")}
      if(!releaseValid(active))return fail(409,"Release identity mismatch");
      const current=RELEASES["/releases/"+active.versionCode+"/erp-"+active.versionCode+".apk"];
      if(!current||!same(await bucket.head(current.key),current))return fail(409,"Signed APK mismatch");
      const headers={"content-type":"application/json; charset=utf-8",
        "content-length":String(new TextEncoder().encode(raw).length),
        "cache-control":"no-store","x-content-type-options":"nosniff"};
      return new Response(request.method==="HEAD"?null:raw,{status:200,headers});
    }
    const rel=RELEASES[url.pathname];
    if(!rel)return fail(404,"Not found");
    const meta=await bucket.head(rel.key);
    if(!meta)return fail(404,"APK unavailable");
    if(!same(meta,rel))return fail(409,"APK identity mismatch");
    const range=request.headers.get("range");
    const match=range===null?null:/^bytes=([0-9]+)-$/.exec(range);
    if(range!==null&&!match)return fail(416,"Invalid range");
    const offset=match?Number(match[1]):0;
    if(!Number.isSafeInteger(offset)||offset>=rel.size)return new Response(null,{status:416,
      headers:{"content-range":"bytes */"+rel.size,"cache-control":"no-store"}});
    const headers=new Headers({"content-type":"application/vnd.android.package-archive",
      "content-disposition":'attachment; filename="'+rel.name+'"',
      "content-length":String(rel.size-offset),"accept-ranges":"bytes",
      "x-content-type-options":"nosniff","cache-control":"no-store",
      "x-erp-sha256":rel.sha,"x-erp-signer-sha256":SIGNER});
    if(range!==null)headers.set("content-range","bytes "+offset+"-"+(rel.size-1)+"/"+rel.size);
    if(request.method==="HEAD")return new Response(null,{status:200,headers});
    const obj=await bucket.get(rel.key,range===null?undefined:{range:{offset}});
    if(!same(obj,rel))return fail(409,"APK content mismatch");
    return new Response(obj.body,{status:range===null?200:206,headers});
  }
};
