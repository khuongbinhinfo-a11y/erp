import test from "node:test";
import assert from "node:assert/strict";
import worker from "./erp_r2_download_worker.mjs";
const BASE="https://erp-android-download.gustavjung24.workers.dev";
const SIGNER="545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028";
const SHA1="385766285dfc21e4c9d8cca3ab9d332e94476df1ec5ddbe02628bc0dc46b1328";
const SHA2="c1c047754b69e466467c7997c6dd2cb752b806a5a8e4f2d1609524b59102b7c0";
const manifest={schema:1,versionCode:2,versionName:"0.2.0",
  packageName:"vn.erpdistribution.erp_distribution",sha256:SHA2,signerSha256:SIGNER,
  size:63769586,objectKey:"releases/2/erp-2.apk",sourceSha:"9963be10fd6d648474b826bcb5e917adbde03b5c",
  releasedAt:"2026-11-26T00:00:00Z",notes:"Android mobile 0.2.0"};
const meta=(size,sha)=>({size,customMetadata:{sha256:sha,signersha256:SIGNER}});
const store={
  "releases/1/erp-1.apk":meta(63425634,SHA1),
  "releases/2/erp-2.apk":meta(63769586,SHA2),
  "releases/latest.json":{size:JSON.stringify(manifest).length}
};
let calls=[];
const bucket={
  head:async key=>{calls.push(["head",key]);return store[key]||null},
  get:async (key,opts)=>{calls.push(["get",key,opts||null]);
    if(key==="releases/latest.json")return {text:async()=>JSON.stringify(manifest)};
    const info=store[key];return info?{...info,body:new Response("apk-stream").body}:null}
};
const env={ERP_ANDROID_RELEASES:bucket};
test("old APK path remains downloadable",async()=>{
  calls=[];
  const res=await worker.fetch(new Request(BASE+"/ERP-Android-0.1.0.apk"),env);
  assert.equal(res.status,200);assert.equal(res.headers.get("x-erp-sha256"),SHA1);
  assert.equal(await res.text(),"apk-stream");
});
test("signed v2 exact key supports range and HEAD",async()=>{
  calls=[];
  const path="/releases/2/erp-2.apk";
  const res=await worker.fetch(new Request(BASE+path),env);
  assert.equal(res.status,200);assert.equal(res.headers.get("content-length"),"63769586");
  assert.equal(res.headers.get("x-erp-sha256"),SHA2);
  const partial=await worker.fetch(new Request(BASE+path,{headers:{range:"bytes=10-"}}),env);
  assert.equal(partial.status,206);
  assert.equal(partial.headers.get("content-range"),"bytes 10-63769585/63769586");
  assert.deepEqual(calls[calls.length-1],["get","releases/2/erp-2.apk",{range:{offset:10}}]);
  const head=await worker.fetch(new Request(BASE+path,{method:"HEAD"}),env);
  assert.equal(head.status,200);assert.equal(head.body,null);
  assert.equal((await worker.fetch(new Request(BASE+path,{headers:{range:"bytes=999999999-"}}),env)).status,416);
});
test("R2 latest relay enforces immutable APK identity",async()=>{
  calls=[];
  const res=await worker.fetch(new Request(BASE+"/releases/latest.json"),env);
  assert.equal(res.status,200);assert.deepEqual(JSON.parse(await res.text()),manifest);
  assert.deepEqual(calls.map(x=>x[1]),["releases/latest.json","releases/latest.json","releases/2/erp-2.apk"]);
  const bad={ERP_ANDROID_RELEASES:{head:bucket.head,
    get:async key=>key==="releases/latest.json"?{text:async()=>JSON.stringify({...manifest,sha256:SHA1})}:null}};
  assert.equal((await worker.fetch(new Request(BASE+"/releases/latest.json"),bad)).status,409);
});
test("arbitrary R2 files, writes and queries are denied",async()=>{
  for(const path of ["/releases/3/erp-3.apk","/releases/2/manifest.json","/private","/releases/latest.json?a=1"]){
    assert.equal((await worker.fetch(new Request(BASE+path),env)).status,404);
  }
  for(const method of ["POST","PUT","DELETE"])assert.equal(
    (await worker.fetch(new Request(BASE+"/releases/latest.json",{method}),env)).status,404);
});
test("incorrect R2 signer/hash is denied",async()=>{
  const bad={ERP_ANDROID_RELEASES:{head:async()=>meta(63769586,SHA1),
    get:async()=>{throw Error("GET must not happen")}}};
  assert.equal((await worker.fetch(new Request(BASE+"/releases/2/erp-2.apk"),bad)).status,409);
});
