import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import worker from "./erp_r2_oidc_v4_worker.mjs";

const BASE="https://erp-android-r2-stage-v4.gustavjung24.workers.dev";
const READ=BASE+"/uat/0.4.0/readback";
const PUT=BASE+"/uat/0.4.0/upload";
const SIGNER="545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028";
const SOURCE="56384b325b55129f028906edf3d9b2b33e20b6bb";
const KEY="releases/4/erp-4.apk";
const bytes=Buffer.from("test-only-imaginary-apk");
const HASH=crypto.createHash("sha256").update(bytes).digest("hex");
const metadata={sha256:HASH,signersha256:SIGNER,sourcesha:SOURCE,
  versioncode:"4",versionname:"0.4.0"};
function b64(x){return Buffer.from(x).toString("base64url")}
async function withJwt(fn,patch={}){
  const pair=await crypto.webcrypto.subtle.generateKey(
    {name:"RSASSA-PKCS1-v1_5",modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:"SHA-256"},true,["sign","verify"]);
  const publicKey=await crypto.webcrypto.subtle.exportKey("jwk",pair.publicKey);
  Object.assign(publicKey,{kid:"test-only",use:"sig"});
  const now=Math.floor(Date.now()/1000);
  const claims={
    iss:"https://token.actions.githubusercontent.com",aud:"erp-android-r2-stage-v4",
    exp:now+300,iat:now-1,repository:"khuongbinhinfo-a11y/erp",
    repository_id:"1466503632",repository_owner_id:"269412638",
    environment:"android-r2-publish",
    sub:"repo:khuongbinhinfo-a11y@269412638/erp@1466503632:environment:android-r2-publish",
    workflow_ref:"khuongbinhinfo-a11y/erp/.github/workflows/erp-android-uxb-v4-stage.yml@refs/heads/main",
    ref:"refs/heads/main",event_name:"workflow_run",sha:SOURCE,...patch
  };
  const header=b64(JSON.stringify({alg:"RS256",kid:"test-only"}));
  const payload=b64(JSON.stringify(claims));
  const data=header+"."+payload;
  const signature=await crypto.webcrypto.subtle.sign("RSASSA-PKCS1-v1_5",pair.privateKey,Buffer.from(data));
  const token=data+"."+Buffer.from(signature).toString("base64url");
  const original=globalThis.fetch;
  globalThis.fetch=async()=>new Response(JSON.stringify({keys:[publicKey]}),{status:200});
  try{await fn(token)}finally{globalThis.fetch=original}
}
function store(){
  let value=null;
  return {ERP_ANDROID_RELEASES:{
    head:async key=>{assert.equal(key,KEY);return value&&{size:value.size,customMetadata:value.customMetadata}},
    get:async key=>{assert.equal(key,KEY);return value&&{...value,body:new Response(value.bytes).body}},
    put:async(key,body,opts)=>{
      assert.equal(key,KEY);
      assert.equal(opts.onlyIf.etagDoesNotMatch,"*");
      const input=Buffer.from(await new Response(body).arrayBuffer());
      const actual=crypto.createHash("sha256").update(input).digest("hex");
      if(actual!==opts.sha256)throw Error("BadDigest");
      value={bytes:input,size:input.length,customMetadata:opts.customMetadata};
      return {size:input.length,customMetadata:opts.customMetadata};
    }
  }};
}
function upload(jwt,extra={}){
  return new Request(PUT,{method:"PUT",body:bytes,headers:{
    authorization:"Bearer "+jwt,"content-type":"application/vnd.android.package-archive",
    "content-length":String(bytes.length),"x-erp-sha256":HASH,
    "x-erp-signer-sha256":SIGNER,"x-erp-source-sha":SOURCE,
    "x-erp-version-code":"4","x-erp-version-name":"0.4.0",...extra
  }});
}
test("only two exact OIDC-authenticated paths are accessible",async()=>{
  const env=store();
  assert.equal((await worker.fetch(new Request(READ),env)).status,401);
  assert.equal((await worker.fetch(new Request(READ+"?a=1"),env)).status,404);
  assert.equal((await worker.fetch(new Request(BASE+"/releases/latest.json"),env)).status,404);
  assert.equal((await worker.fetch(new Request(PUT,{method:"DELETE"}),env)).status,404);
  assert.equal((await worker.fetch(new Request(READ,{headers:{authorization:"Bearer broken"}}),env)).status,403);
});
test("signed protected GitHub OIDC can stage only immutable APK v4 and read full bytes",async()=>{
  await withJwt(async jwt=>{
    const env=store();
    assert.equal((await worker.fetch(upload(jwt),env)).status,201);
    const result=await worker.fetch(new Request(READ,{headers:{authorization:"Bearer "+jwt}}),env);
    assert.equal(result.status,200);
    assert.equal(result.headers.get("x-erp-sha256"),HASH);
    assert.deepEqual(Buffer.from(await result.arrayBuffer()),bytes);
    assert.equal((await worker.fetch(upload(jwt),env)).status,200);
    const changed=upload(jwt,{"x-erp-sha256":"b".repeat(64)});
    assert.equal((await worker.fetch(changed,env)).status,409);
  });
});
test("foreign ref, workflow, owner, expired token, or unprotected job is denied",async()=>{
  for(const patch of [
    {ref:"refs/heads/feature"},{repository_owner_id:"999"},
    {environment:"production"},{event_name:"pull_request"},{sha:"not-a-sha"},
    {aud:"other"},{exp:0},
    {workflow_ref:"khuongbinhinfo-a11y/erp/.github/workflows/ci.yml@refs/heads/main"}
  ]){
    await withJwt(async jwt=>{
      assert.equal((await worker.fetch(new Request(READ,{headers:{authorization:"Bearer "+jwt}}),store())).status,403);
    },patch);
  }
});
test("release signer, source commit, version and declared byte hash cannot change",async()=>{
  await withJwt(async jwt=>{
    for(const headers of [
      {"x-erp-signer-sha256":"c".repeat(64)},
      {"x-erp-source-sha":"d".repeat(40)},
      {"x-erp-version-code":"5"},
      {"x-erp-version-name":"0.5.0"},
      {"x-erp-sha256":"broken"}
    ]){
      assert.equal((await worker.fetch(upload(jwt,headers),store())).status,400);
    }
    await assert.rejects(()=>worker.fetch(upload(jwt,{"x-erp-sha256":"e".repeat(64)}),store()),/BadDigest/);
  });
});
test("tampered R2 signer metadata fails closed",async()=>{
  await withJwt(async jwt=>{
    const bad={ERP_ANDROID_RELEASES:{get:async()=>({
      size:bytes.length,customMetadata:{...metadata,signersha256:"bad"},
      body:new Response(bytes).body
    })}};
    assert.equal((await worker.fetch(new Request(READ,{headers:{authorization:"Bearer "+jwt}}),bad)).status,409);
  });
});
