import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import worker from "./erp_r2_oidc_worker.mjs";

const URL = "https://erp-android-r2-stage.gustavjung24.workers.dev/uat/0.1.0/readback";
const SHA = "385766285dfc21e4c9d8cca3ab9d332e94476df1ec5ddbe02628bc0dc46b1328";

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

async function withGithubJwt(callback, overrides = {}) {
  const keys = await crypto.webcrypto.subtle.generateKey(
    {name:"RSASSA-PKCS1-v1_5",modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:"SHA-256"},
    true,["sign","verify"]);
  const publicKey = await crypto.webcrypto.subtle.exportKey("jwk",keys.publicKey);
  Object.assign(publicKey,{kid:"unit-test-key",use:"sig"});
  const now = Math.floor(Date.now()/1000);
  const claims = {
    iss:"https://token.actions.githubusercontent.com",
    aud:"erp-android-r2-stage-0.1.0",
    exp:now+300,iat:now-1,
    repository:"khuongbinhinfo-a11y/erp",
    repository_id:"1466503632",
    environment:"android-r2-publish",
    sub:"repo:khuongbinhinfo-a11y/erp:environment:android-r2-publish",
    workflow_ref:"khuongbinhinfo-a11y/erp/.github/workflows/erp-android-r2-oidc-stage.yml@refs/heads/main",
    ref:"refs/heads/main",
    event_name:"workflow_run",
    ...overrides
  };
  const header = base64url(JSON.stringify({kid:"unit-test-key",alg:"RS256",typ:"JWT"}));
  const payload = base64url(JSON.stringify(claims));
  const data = header+"."+payload;
  const sig = await crypto.webcrypto.subtle.sign("RSASSA-PKCS1-v1_5",keys.privateKey,Buffer.from(data));
  const jwt = data+"."+Buffer.from(sig).toString("base64url");
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({keys:[publicKey]}),{
    status:200,headers:{"content-type":"application/json"}});
  try { await callback(jwt); } finally { globalThis.fetch=original; }
}

const env = {
  ERP_ANDROID_RELEASES: {
    get:async()=>({size:63425634,customMetadata:{sha256:SHA},
      body:new Response("mock verified readback").body})
  }
};

test("no auth, foreign paths and malformed JWT are rejected", async () => {
  assert.equal((await worker.fetch(new Request(URL),env)).status,401);
  assert.equal((await worker.fetch(new Request(URL,{headers:{authorization:"Bearer broken"}}),env)).status,403);
  assert.equal((await worker.fetch(new Request("https://host/"),env)).status,404);
});

test("short-lived GitHub OIDC signature + protected workflow gives private readback", async () => {
  await withGithubJwt(async jwt => {
    const res=await worker.fetch(new Request(URL,{headers:{authorization:"Bearer "+jwt}}),env);
    assert.equal(res.status,200);
    assert.equal(await res.text(),"mock verified readback");
  });
});

test("OIDC cannot come from another ref or event", async () => {
  for(const change of [{ref:"refs/heads/feature"},{event_name:"pull_request"},{repository_id:"999"},
     {environment:"production"},{aud:"other"},{exp:0}]) {
    await withGithubJwt(async jwt=>{
      const res=await worker.fetch(new Request(URL,{headers:{authorization:"Bearer "+jwt}}),env);
      assert.equal(res.status,403);
    },change);
  }
});

test("mismatched remote object metadata never serves data", async () => {
  await withGithubJwt(async jwt => {
    const bad={ERP_ANDROID_RELEASES:{get:async()=>({size:63425634,customMetadata:{sha256:"wrong"}})}};
    const res=await worker.fetch(new Request(URL,{headers:{authorization:"Bearer "+jwt}}),bad);
    assert.equal(res.status,409);
  });
});
