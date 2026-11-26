import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {validateRelease,releaseTicket,validTicket,releaseConfig,ERP_ANDROID_PACKAGE} from "./app_release_http.ts";
import {presignR2,presignReleaseRead} from "./r2_media_signer.ts";
const signer="a".repeat(64);
const release={schema:1,versionCode:1,versionName:"1.0.0",packageName:ERP_ANDROID_PACKAGE,
  sha256:"b".repeat(64),signerSha256:signer,size:200,objectKey:"releases/1/erp-1.apk",
  notes:"Bản đầu tiên",releasedAt:"2026-11-24T00:00:00Z",sourceSha:"c".repeat(40)};
test("T2 strict release manifest and independent R2 read namespace",()=>{
  assert.ok(validateRelease(release,signer));
  for(const patch of [{packageName:"other.app"},{signerSha256:"d".repeat(64)},{size:-1},
    {versionCode:0},{objectKey:"releases/2/erp-2.apk"},{objectKey:"../secret.apk"},
    {sha256:"xyz"},{sourceSha:"main"}])assert.equal(validateRelease({...release,...patch},signer),null);
  assert.equal(releaseConfig({}),null);
  const env={ERP_RELEASE_R2_ACCOUNT_ID:"a".repeat(32),ERP_RELEASE_R2_BUCKET:"erp-release",
    ERP_RELEASE_R2_ACCESS_KEY_ID:"b".repeat(32),ERP_RELEASE_R2_SECRET_ACCESS_KEY:"test-only".repeat(5),
    ERP_ANDROID_CERT_SHA256:signer,ERP_RELEASE_TICKET_SECRET:"test-only".repeat(5)};
  const config=releaseConfig(env)!;
  assert.ok(config);
  assert.equal(releaseConfig({...env,ERP_R2_BUCKET:"erp-release"}),null);
  const workerEnv={ERP_RELEASE_READ_ORIGIN:"https://erp-android-download.gustavjung24.workers.dev",
    ERP_ANDROID_CERT_SHA256:"545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028",
    ERP_RELEASE_TICKET_SECRET:"derived-ticket-test-only".repeat(3)};
  assert.equal(releaseConfig(workerEnv)?.readOrigin,workerEnv.ERP_RELEASE_READ_ORIGIN);
  assert.equal(releaseConfig({...workerEnv,ERP_RELEASE_READ_ORIGIN:"https://evil.example"}),null);
  assert.equal(releaseConfig({...workerEnv,ERP_ANDROID_CERT_SHA256:"a".repeat(64)}),null);
  assert.equal(releaseConfig({...workerEnv,ERP_RELEASE_TICKET_SECRET:"weak"}),null);
  assert.throws(()=>presignR2(config.r2!,"GET",release.objectKey));
  assert.throws(()=>presignReleaseRead(config.r2!,"GET","releases/2/erp-1.apk"));
  assert.throws(()=>presignReleaseRead(config.r2!,"GET","media/a.png"));
  assert.match(new URL(presignReleaseRead(config.r2!,"GET",release.objectKey)).pathname,/erp-release\/releases\/1\/erp-1\.apk$/);
});
test("tickets bind actor/session/grants, release bytes, version and short expiration",()=>{
  const checked=validateRelease(release,signer)!;
  const key="test-ticket-key",now=100,expires=400,ticket=releaseTicket(key,"scopeA",checked,expires);
  assert.ok(validTicket(key,"scopeA",checked,expires,ticket,now));
  assert.equal(validTicket(key,"scopeB",checked,expires,ticket,now),false);
  assert.equal(validTicket(key,"scopeA",{...checked,sha256:"e".repeat(64)},expires,ticket,now),false);
  assert.equal(validTicket(key,"scopeA",checked,expires,ticket,expires),false);
  assert.equal(validTicket(key,"scopeA",checked,expires+1,ticket,now),false);
  assert.equal(validTicket(key,"scopeA",checked,expires,"x",now),false);
});

// T2 deploy smoke regression: unsigned APK publishing is NOT a prerequisite for
// deploying the business API; the native release endpoints remain disabled.
test("Compute deployment has no mandatory Android release secret bindings before signed APK setup",()=>{
  const moduleCode=readFileSync(new URL("../deploy/module.ts",import.meta.url),"utf8");
  const serviceCode=readFileSync(new URL("../deploy/service.ts",import.meta.url),"utf8");
  const entryCode=readFileSync(new URL("../deploy/entry.ts",import.meta.url),"utf8");
  for(const variable of ["ERP_RELEASE_R2_ACCOUNT_ID","ERP_RELEASE_R2_BUCKET","ERP_RELEASE_R2_ACCESS_KEY_ID","ERP_RELEASE_R2_SECRET_ACCESS_KEY","ERP_ANDROID_CERT_SHA256","ERP_RELEASE_TICKET_SECRET"]){
    assert.equal(moduleCode.includes('envSecret("'+variable+'")'),false,variable);
    assert.equal(entryCode.includes(variable+': serviceInput.'),false,variable);
  }
  for(const name of ["releaseR2AccountId","releaseR2Bucket","releaseR2AccessKeyId","releaseR2SecretAccessKey","androidCertSha256","releaseTicketSecret"])
    assert.equal(serviceCode.includes('"'+name+'?"'),false,name);
  // All existing DB/identity/media bindings are left intact.
  assert.match(moduleCode,/envSecret\("ERP_POSTGRES_URL"\)/);
  assert.match(moduleCode,/envSecret\("ERP_R2_SECRET_ACCESS_KEY"\)/);
  assert.equal(releaseConfig({}),null);
});
