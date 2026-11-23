import test from "node:test";
import assert from "node:assert/strict";
import {
 BASE, RELEASE, checkVersions, checkOperator, checkPrimaryMainSha,
 assertNewTableBackfill, canonicalRemote,
 parsePrismaCredential, requirePg17Client, BUCKET_S3_NAME,
 assertNotInterrupted, restoreContainerCleanupArgs
} from "./r1a-codespaces-migration.mjs";

const sha="a".repeat(40);
const primary="https://github.com/gustavjung24-ops/ERP.git";
const operator={
 CODESPACES:"true",CODESPACE_NAME:"synthetic-erp-codespace",
 GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:"app.github.dev",
 GITHUB_REPOSITORY:"gustavjung24-ops/ERP",GITHUB_USER:"gustavjung24-ops",
 GITHUB_TOKEN:"ghu_synthetic_session_token_12345",ERP_APPROVED_SHA:sha,
 ERP_R1A_MIGRATION_APPROVAL:"OWNER_APPROVED_R1A_0017_ERP_DB",
 ERP_TARGET_PROJECT_ID:"proj_ud3b1s5yn03vh0zp9cbs2upa",
 ERP_TARGET_DATABASE_ID:"db_jg2bl98hzi1jm06lwo0i4rqx"
};

test("R1-A applies only 0017 after exactly 16 checked historical migrations",()=>{
 assert.equal(BASE.length,16);
 assert.deepEqual(RELEASE,["0017_r1a_customer_directories.sql"]);
 assert.doesNotThrow(()=>checkVersions(BASE,"before"));
 assert.doesNotThrow(()=>checkVersions([...BASE,...RELEASE],"after"));
 assert.throws(()=>checkVersions([...BASE,...RELEASE],"before"),/ERP_DB_MIGRATION_DRIFT/);
 assert.throws(()=>checkVersions(BASE,"after"),/ERP_DB_MIGRATION_DRIFT/);
 assert.throws(()=>checkVersions([...BASE.slice(0,15)],"before"),/ERP_DB_MIGRATION_DRIFT/);
 assert.throws(()=>checkVersions([...BASE,"0017_wrong.sql"],"after"),/ERP_DB_MIGRATION_DRIFT/);
});
test("Only authenticated primary main Codespaces may run; apply needs explicit exact ERP-DB approval",()=>{
 assert.doesNotThrow(()=>checkOperator(operator,"main",sha,primary,[],false));
 assert.doesNotThrow(()=>checkOperator(operator,"main",sha,primary,[],true));
 for(const e of [
  {...operator,ERP_R1A_MIGRATION_APPROVAL:""},
  {...operator,ERP_TARGET_PROJECT_ID:"proj_other"},
  {...operator,ERP_TARGET_DATABASE_ID:"db_other"}
 ])assert.throws(()=>checkOperator(e,"main",sha,primary,[],true),/OWNER_R1A_TARGET_APPROVAL_MISSING/);
 for(const [e,branch,remote,changes] of [
  [{...operator,CODESPACES:"false"},"main",primary,[]],
  [{...operator,GITHUB_TOKEN:"ghp_wrong_token"},"main",primary,[]],
  [{...operator,ERP_APPROVED_SHA:"b".repeat(40)},"main",primary,[]],
  [operator,"agent/unsafe",primary,[]],
  [operator,"main","https://github.com/other/repo.git",[]],
  [operator,"main",primary,["backend/src/main.ts"]]
 ])assert.throws(()=>checkOperator(e,branch,sha,remote,changes,true));
 assert.equal(canonicalRemote(primary),true);
 assert.equal(canonicalRemote("https://github.com/attacker/ERP.git"),false);
});
test("Main SHA read-back is exact and denies stale checkout",()=>{
 assert.doesNotThrow(()=>checkPrimaryMainSha(sha,sha));
 assert.throws(()=>checkPrimaryMainSha("b".repeat(40),sha),/PRIMARY_MAIN_SHA_MOVED_OR_UNVERIFIED/);
 assert.throws(()=>checkPrimaryMainSha(undefined,sha),/PRIMARY_MAIN_SHA_MOVED_OR_UNVERIFIED/);
});
test("R1A customer backfill requires lossless group mapping and empty regions",()=>{
 const ok={expected:"3",actual:"3",missing:"0",regions:"0",assigned_regions:"0",
  bad_labels:"0",bad_barcode_revisions:"0"};
 assert.doesNotThrow(()=>assertNewTableBackfill(ok));
 for(const p of [{actual:"2"},{missing:"1"},{regions:"1"},{assigned_regions:"1"},
  {bad_labels:"1"},{bad_barcode_revisions:"1"}])
   assert.throws(()=>assertNewTableBackfill({...ok,...p}),/R1A_BACKFILL_RECONCILIATION_FAILED/);
 assert.throws(()=>assertNewTableBackfill(null),/R1A_BACKFILL_RECONCILIATION_FAILED/);
});
test("Prisma credential and backup tooling remain restricted to ERP-DB and PG17",()=>{
 assert.equal(BUCKET_S3_NAME,"user-hccjgwl892edb91ox3v3j5b2");
 assert.doesNotThrow(()=>requirePg17Client("pg_dump (PostgreSQL) 17.7","pg_dump"));
 assert.throws(()=>requirePg17Client("pg_dump (PostgreSQL) 16.9","pg_dump"),/POSTGRES_17_CLIENT_REQUIRED/);
 const credential=parsePrismaCredential({connection:{id:"con_synthetictest123"},
  connectionString:"postgresql://temporary:synthetic@pooled.db.prisma.io:5432/postgres?sslmode=require"});
 assert.equal(credential.url.hostname,"db.prisma.io");
 assert.throws(()=>parsePrismaCredential({connection:{id:"con_synthetictest123"},
  connectionString:"postgresql://temporary:synthetic@attacker.invalid:5432/postgres?sslmode=require"}));
});

test("Rehearsal cleanup must remove Docker anonymous plaintext volumes",()=>{
 const name="erp-r1a-pg-abcdef012345";
 assert.deepEqual(restoreContainerCleanupArgs(name),["rm","--force","--volumes",name]);
 for(const bad of ["erp-r3-pg-abcdef012345","abc;docker volume rm -f","",undefined])
  assert.throws(()=>restoreContainerCleanupArgs(bad),/INVALID_ISOLATED_RESTORE_CONTAINER_ID/);
});
test("Catchable termination takes fail-closed cleanup path",()=>{
 assert.doesNotThrow(()=>assertNotInterrupted(null));
 for(const signal of ["SIGINT","SIGTERM"])
  assert.throws(()=>assertNotInterrupted(signal),/ERP_R1A_INTERRUPTED_CLEANUP_REQUIRED/);
});
