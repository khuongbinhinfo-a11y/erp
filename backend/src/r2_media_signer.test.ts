import test from "node:test";
import assert from "node:assert/strict";
import {presignR2,resolveR2Config} from "./r2_media_signer.ts";
const fake={
  accountId:"a".repeat(32),bucket:"erp-r1-media",
  accessKeyId:"b".repeat(32),secretAccessKey:"not-a-real-key-".repeat(4),
};
const key="installations/"+"c".repeat(36)+"/products/"+"e".repeat(36)+"/foo.png";
test("R2 credentials are required and private links never expose the secret",()=>{
  assert.equal(resolveR2Config({}),null);
  assert.equal(resolveR2Config({ERP_R2_ACCOUNT_ID:fake.accountId,
    ERP_R2_BUCKET:fake.bucket,ERP_R2_ACCESS_KEY_ID:fake.accessKeyId,
    ERP_R2_SECRET_ACCESS_KEY:fake.secretAccessKey})?.bucket,"erp-r1-media");
  const at=new Date("2026-11-22T13:00:00.000Z");
  const signed=presignR2(fake,"PUT",key,"image/png",at,300,1024);
  const uri=new URL(signed);
  assert.equal(uri.protocol,"https:");
  assert.equal(uri.host,fake.accountId+".r2.cloudflarestorage.com");
  assert.equal(uri.pathname,"/"+fake.bucket+"/"+key);
  assert.equal(uri.searchParams.get("X-Amz-Date"),"20261122T130000Z");
  assert.equal(uri.searchParams.get("X-Amz-Expires"),"300");
  assert.equal(uri.searchParams.get("X-Amz-SignedHeaders"),
    "content-length;content-type;host;if-none-match");
  assert.ok(signed.includes("if-none-match"),
    "write-once condition must be bound by S3 signature");
  assert.ok(signed.includes("content-length"),
    "validated byte length must be part of signed S3 headers");
  assert.notEqual(signed,presignR2(fake,"PUT",key,"image/png",at,300,1025),
    "a different byte length must invalidate the original signature");
  assert.match(uri.searchParams.get("X-Amz-Signature")??"",/^[a-f0-9]{64}$/);
  assert.ok(!signed.includes(fake.secretAccessKey),"Never leak R2 secret in signed URL");
  assert.equal(signed,presignR2(fake,"PUT",key,"image/png",at,300,1024),
    "retry generates same authorization within same instant");
  assert.notEqual(signed,presignR2(fake,"GET",key,undefined,at),
    "read and write links are distinct");
  assert.throws(()=>presignR2(fake,"PUT","../../escape.png","image/png"));
  assert.throws(()=>presignR2(fake,"PUT",key,"text/html"));
  assert.throws(()=>presignR2(fake,"GET",key,undefined,at,601));
  assert.throws(()=>presignR2(fake,"PUT",key,"image/png",at,300,0));
  assert.throws(()=>presignR2(fake,"PUT",key,"image/png",at,300,5242881));
  assert.throws(()=>presignR2(fake,"PUT",key,"image/png",at),
    "missing claimed size must fail closed");
});
