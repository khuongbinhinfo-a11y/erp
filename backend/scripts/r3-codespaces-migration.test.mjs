import test from "node:test";
import assert from "node:assert/strict";
import { BASE, R3, checkOperator, checkVersions, canonicalRemote, checkCodespaceRecord, parsePrismaCredential } from "./r3-codespaces-migration.mjs";
const sha="a".repeat(40);
const remote="https://github.com/gustavjung24-ops/ERP.git";
const base={CODESPACES:"true",CODESPACE_NAME:"synthetic-erp-codespace",
 GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:"app.github.dev",
 GITHUB_REPOSITORY:"gustavjung24-ops/ERP",GITHUB_USER:"gustavjung24-ops",
 GITHUB_TOKEN:"ghu_synthetic_session_token_12345",ERP_APPROVED_SHA:sha,
 ERP_R3_MIGRATION_APPROVAL:"OWNER_APPROVED_R3_0011_0014_ERP_DB",
 ERP_TARGET_PROJECT_ID:"proj_ud3b1s5yn03vh0zp9cbs2upa",
 ERP_TARGET_DATABASE_ID:"db_jg2bl98hzi1jm06lwo0i4rqx"};
test("R3 operator accepts reviewed primary main exact SHA only",()=>{
 assert.doesNotThrow(()=>checkOperator(base,"main",sha,remote,[],true));
 assert.doesNotThrow(()=>checkOperator(base,"main",sha,"git@github.com:gustavjung24-ops/ERP.git",
  ["backend/package-lock.json","backend/deploy/package-lock.json"],true));
 for(const bad of [
  [{...base,CODESPACES:"false"},"main",sha,remote,[]],
  [base,"agent/r3",sha,remote,[]],
  [base,"main",sha,"https://github.com/binhnxwjfjxm/NPP-Platform.git",[]],
  [{...base,ERP_APPROVED_SHA:"b".repeat(40)},"main",sha,remote,[]],
  [base,"main",sha,remote,["backend/src/db.ts"]],
 ])assert.throws(()=>checkOperator(...bad,true));
});
test("R3 operator denies unapproved production target or missing owner approval",()=>{
 for(const k of ["ERP_R3_MIGRATION_APPROVAL","ERP_TARGET_PROJECT_ID","ERP_TARGET_DATABASE_ID"]){
  assert.throws(()=>checkOperator({...base,[k]:"invalid"},"main",sha,remote,[],true),
   /OWNER_R3_TARGET_APPROVAL_MISSING/);
 }
 assert.doesNotThrow(()=>checkOperator({...base,ERP_R3_MIGRATION_APPROVAL:""},
   "main",sha,remote,[],false));
});
test("R3 canonical origin rejects lookalike host and Actions spoof",()=>{
 assert.equal(canonicalRemote("https://github.com/gustavjung24-ops/ERP.git"),true);
 assert.equal(canonicalRemote("git@github.com:gustavjung24-ops/ERP.git"),true);
 assert.equal(canonicalRemote("https://evil.example/gustavjung24-ops/ERP.git"),false);
 assert.equal(canonicalRemote("https://github.com/other/ERP.git"),false);
 for(const env of [{CI:"true"},{GITHUB_ACTIONS:"true"},{CODESPACE_NAME:""},
   {GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:"evil.example"},
   {GITHUB_TOKEN:"ghp_local_user_pat"},{GITHUB_TOKEN:""},
   {GITHUB_REPOSITORY:"attacker/ERP"},{GITHUB_USER:"attacker"}]){
  assert.throws(()=>checkOperator({...base,...env},"main",sha,remote,[],true));
 }
});
test("R3 requires an authenticated active Codespace with exact repository",()=>{
 assert.doesNotThrow(()=>checkCodespaceRecord({
  name:"synthetic-erp-codespace",state:"Available",
  repository:{full_name:"gustavjung24-ops/ERP"}},"synthetic-erp-codespace"));
 assert.throws(()=>checkCodespaceRecord({
  name:"synthetic-erp-codespace",state:"Unavailable",
  repository:{full_name:"gustavjung24-ops/ERP"}},"synthetic-erp-codespace"));
 assert.throws(()=>checkCodespaceRecord({
  name:"synthetic-erp-codespace",state:"Available",
  repository:{full_name:"evil.example/ERP"}},"synthetic-erp-codespace"));
});
test("R3 derives direct Postgres URL only from Prisma's targeted credential result",()=>{
 const item=parsePrismaCredential({connection:{id:"con_synthetictest123"},
  connectionString:"postgres://temporary:synthetic@pooled.db.prisma.io:5432/postgres?sslmode=require"});
 assert.equal(item.id,"con_synthetictest123");
 assert.equal(item.url.hostname,"db.prisma.io");
 assert.equal(item.url.searchParams.get("sslmode"),"require");
 assert.throws(()=>parsePrismaCredential({
  connection:{id:"con_synthetictest123"},
  connectionString:"postgres://temporary:synthetic@evil.example:5432/postgres?sslmode=require"}));
});
test("R3 operator accepts exclusively 10 pre-migration and 14 post-migration versions",()=>{
 assert.equal(BASE.length,10);
 assert.equal(R3.length,4);
 assert.doesNotThrow(()=>checkVersions(BASE,"before"));
 assert.doesNotThrow(()=>checkVersions([...BASE,...R3],"after"));
 assert.throws(()=>checkVersions([...BASE,...R3],"before"),/MIGRATION_DRIFT/);
 assert.throws(()=>checkVersions(BASE,"after"),/MIGRATION_DRIFT/);
 assert.throws(()=>checkVersions([...BASE.slice(0,9)],"before"),/MIGRATION_DRIFT/);
 assert.throws(()=>checkVersions([...BASE,"0011_modified.sql",...R3.slice(1)],"after"),/MIGRATION_DRIFT/);
});
