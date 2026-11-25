import test from "node:test";
import assert from "node:assert/strict";
import worker from "./erp_r2_download_worker.mjs";

const URL = "https://erp-android-download.gustavjung24.workers.dev/ERP-Android-0.1.0.apk";
const SHA = "385766285dfc21e4c9d8cca3ab9d332e94476df1ec5ddbe02628bc0dc46b1328";
const SIGNER = "545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028";
const meta={size:63425634,customMetadata:{sha256:SHA,signersha256:SIGNER}};
let keys=[];
const env={ERP_ANDROID_RELEASES:{
  head: async key=>{keys.push(key);return meta},
  get:async key=>{keys.push(key);return {...meta,body:new Response("apk-test-stream").body}}
}};

test("direct GET serves only the signed APK and never requires Cloudflare login",async()=>{
  keys=[];
  const r=await worker.fetch(new Request(URL),env);
  assert.equal(r.status,200);
  assert.equal(r.headers.get("content-type"),"application/vnd.android.package-archive");
  assert.equal(r.headers.get("content-disposition"),'attachment; filename="ERP-Android-0.1.0.apk"');
  assert.equal(r.headers.get("content-length"),"63425634");
  assert.equal(r.headers.get("x-erp-sha256"),SHA);
  assert.equal(await r.text(),"apk-test-stream");
  assert.deepEqual(keys,["releases/1/erp-1.apk","releases/1/erp-1.apk"]);
});

test("HEAD checks R2 metadata but does not download the APK",async()=>{
  keys=[];
  const r=await worker.fetch(new Request(URL,{method:"HEAD"}),env);
  assert.equal(r.status,200);
  assert.equal(r.body,null);
  assert.deepEqual(keys,["releases/1/erp-1.apk"]);
});

test("cannot fetch any other R2 object or write to storage",async()=>{
  const targets=[URL.replace("0.1.0","0.1.1"),URL.replace("ERP-Android-0.1.0.apk","releases/latest.json"),URL+"?download=true"];
  for(const u of targets) assert.equal((await worker.fetch(new Request(u),env)).status,404);
  for(const method of ["POST","PUT","DELETE"]) assert.equal((await worker.fetch(new Request(URL,{method}),env)).status,404);
});

test("metadata signer/hash mismatch fails closed",async()=>{
  for(const bad of [
    {...meta,size:1},
    {...meta,customMetadata:{sha256:"wrong",signersha256:SIGNER}},
    {...meta,customMetadata:{sha256:SHA,signersha256:"other"}}
  ]){
    const e={ERP_ANDROID_RELEASES:{head:async()=>bad,get:async()=>{throw Error("GET must not occur")}}};
    assert.equal((await worker.fetch(new Request(URL),e)).status,409);
  }
  assert.equal((await worker.fetch(new Request(URL),{ERP_ANDROID_RELEASES:{head:async()=>null}})).status,404);
});
