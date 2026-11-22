import test from "node:test";
import assert from "node:assert/strict";
import { BASE, R3, checkOperator, checkVersions, canonicalRemote, checkCodespaceRecord, attestProcessCodespace, parsePrismaCredential, validateMintedCredentialOrRevoke, requirePg17Client, classifyPgDumpFailure } from "./r3-codespaces-migration.mjs";
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
  repository:{full_name:"gustavjung24-ops/ERP"},
  owner:{login:"gustavjung24-ops"}},"synthetic-erp-codespace"));
 assert.throws(()=>checkCodespaceRecord({
  name:"synthetic-erp-codespace",state:"Unavailable",
  repository:{full_name:"gustavjung24-ops/ERP"},
  owner:{login:"gustavjung24-ops"}},"synthetic-erp-codespace"));
 assert.throws(()=>checkCodespaceRecord({
  name:"synthetic-erp-codespace",state:"Available",
  repository:{full_name:"evil.example/ERP"},
  owner:{login:"gustavjung24-ops"}},"synthetic-erp-codespace"));
});
test("R3 rejects a collaborator-owned Codespace on the canonical repo",()=>{
 assert.throws(()=>checkCodespaceRecord({
  name:"synthetic-erp-codespace",state:"Available",
  repository:{full_name:"gustavjung24-ops/ERP"},
  owner:{login:"collaborator"}},"synthetic-erp-codespace"));
});
test("R3 process proof requires nonce from GitHub's forwarded-port route",async()=>{
 const e={CODESPACE_NAME:"synthetic-erp-codespace",
  GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:"app.github.dev",
  GITHUB_TOKEN:"ghu_synthetic_session_token_12345"};
 const good=async url=>({status:200,text:async()=>new URL(url).pathname.split("/").at(-1)});
 await assert.doesNotReject(attestProcessCodespace(e,{fetcher:good,maxAttempts:1}));
 await assert.rejects(attestProcessCodespace(e,{fetcher:async()=>({
  status:200,text:async()=>"unrelated-local-server"}) ,maxAttempts:1}),
  /CODESPACES_PROCESS_TUNNEL_ATTESTATION_FAILED/);
});
test("R3 revokes a new credential when Prisma returns an invalid one-time URL",()=>{
 const id="con_badurlfixture123";
 const revoked=[];
 assert.throws(()=>validateMintedCredentialOrRevoke({
  connection:{id},connectionString:"postgres://u:p@evil.example/postgres?sslmode=require"
 },credential=>revoked.push(credential)),/DIRECT_PRISMA_ERP_DB_TLS_URL_REQUIRED/);
 assert.deepEqual(revoked,[id]);
 assert.throws(()=>validateMintedCredentialOrRevoke({
  connection:{id},connectionString:"invalid-url"
 },()=>{throw Error("revocation failed");}),/CREATED_CREDENTIAL_VALIDATION_REVOKE_FAILED/);
 assert.throws(()=>validateMintedCredentialOrRevoke({
  connection:{},connectionString:"invalid-url"
 },()=>{throw Error("should not be called");}),/MANUAL_REVOCATION_REQUIRED/);
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

test("R3 accepts only PostgreSQL client 17 before production backup",()=>{
 assert.doesNotThrow(()=>requirePg17Client("pg_dump (PostgreSQL) 17.7","pg_dump"));
 assert.doesNotThrow(()=>requirePg17Client("pg_restore (PostgreSQL) 17.2 (Ubuntu)","pg_restore"));
 assert.throws(()=>requirePg17Client("pg_dump (PostgreSQL) 16.10","pg_dump"),/POSTGRES_17_CLIENT_REQUIRED_PG_DUMP/);
 assert.throws(()=>requirePg17Client("pg_restore (PostgreSQL) 18.1","pg_restore"),/POSTGRES_17_CLIENT_REQUIRED_PG_RESTORE/);
 assert.throws(()=>requirePg17Client("unknown binary","pg_dump"),/POSTGRES_17_CLIENT_REQUIRED/);
});
test("R3 diagnostic categories never expose credentials or connection URLs",()=>{
 const secret="example-sensitive-password";
 assert.equal(classifyPgDumpFailure("pg_dump: error: aborting because of server version mismatch"),
  "PG_DUMP_SERVER_VERSION_MISMATCH");
 assert.equal(classifyPgDumpFailure("pg_dump: error: permission denied for schema public"),
  "PG_DUMP_DATABASE_PERMISSION_DENIED");
 assert.equal(classifyPgDumpFailure("pg_dump: error: server closed connection, password authentication failed"),
  "PG_DUMP_AUTHENTICATION_FAILED");
 assert.equal(classifyPgDumpFailure("pg_dump: error: unable to verify SSL certificate"),
  "PG_DUMP_TLS_VERIFY_FAILED");
 assert.equal(classifyPgDumpFailure("password="+secret+" secret-db.example:5432 unexpected"),
  "PG_DUMP_FAILED_DETAILS_REDACTED");
 assert.equal(classifyPgDumpFailure("feature is unsupported: serializable deferrable"),
  "PG_DUMP_SNAPSHOT_MODE_UNSUPPORTED");
 assert.equal(classifyPgDumpFailure("connection refused"),
  "PG_DUMP_CONNECTION_FAILED");
 assert.ok(!classifyPgDumpFailure("password="+secret).includes(secret));
});
