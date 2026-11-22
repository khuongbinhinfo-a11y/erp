import test from "node:test";
import assert from "node:assert/strict";
import {
 BASE, RELEASE, checkVersions, checkOperator, checkPrimaryMainSha,
 assertUnitCodeValidity, assertNewTableBackfill, canonicalRemote,
 parsePrismaCredential, requirePg17Client, BUCKET_S3_NAME
} from "./r1-media-codespaces-migration.mjs";

const sha="a".repeat(40);
const primary="https://github.com/gustavjung24-ops/ERP.git";
const operator={
 CODESPACES:"true",CODESPACE_NAME:"synthetic-erp-codespace",
 GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:"app.github.dev",
 GITHUB_REPOSITORY:"gustavjung24-ops/ERP",GITHUB_USER:"gustavjung24-ops",
 GITHUB_TOKEN:"ghu_synthetic_session_token_12345",ERP_APPROVED_SHA:sha,
 ERP_R1_MEDIA_MIGRATION_APPROVAL:"OWNER_APPROVED_R1_MEDIA_0015_0016_ERP_DB",
 ERP_TARGET_PROJECT_ID:"proj_ud3b1s5yn03vh0zp9cbs2upa",
 ERP_TARGET_DATABASE_ID:"db_jg2bl98hzi1jm06lwo0i4rqx"
};

test("R1 media applies only 0015–0016 after exactly 14 checked historical migrations",()=>{
 assert.equal(BASE.length,14);
 assert.deepEqual(RELEASE,["0015_r1_unit_dictionary.sql","0016_r1_product_media.sql"]);
 assert.doesNotThrow(()=>checkVersions(BASE,"before"));
 assert.doesNotThrow(()=>checkVersions([...BASE,...RELEASE],"after"));
 assert.throws(()=>checkVersions([...BASE,...RELEASE],"before"),/ERP_DB_MIGRATION_DRIFT/);
 assert.throws(()=>checkVersions(BASE,"after"),/ERP_DB_MIGRATION_DRIFT/);
 assert.throws(()=>checkVersions([...BASE.slice(0,13)],"before"),/ERP_DB_MIGRATION_DRIFT/);
 assert.throws(()=>checkVersions([...BASE,"0015_wrong.sql",RELEASE[1]],"after"),/ERP_DB_MIGRATION_DRIFT/);
});
test("Only authenticated primary main Codespaces may run; apply needs explicit exact ERP-DB approval",()=>{
 assert.doesNotThrow(()=>checkOperator(operator,"main",sha,primary,[],false));
 assert.doesNotThrow(()=>checkOperator(operator,"main",sha,primary,[],true));
 for(const e of [
  {...operator,ERP_R1_MEDIA_MIGRATION_APPROVAL:""},
  {...operator,ERP_TARGET_PROJECT_ID:"proj_other"},
  {...operator,ERP_TARGET_DATABASE_ID:"db_other"}
 ])assert.throws(()=>checkOperator(e,"main",sha,primary,[],true),/OWNER_R1_MEDIA_TARGET_APPROVAL_MISSING/);
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
test("Legacy unit preflight blocks invalid values instead of silently modifying source",()=>{
 assert.doesNotThrow(()=>assertUnitCodeValidity("0"));
 for(const n of ["1",undefined,null,0,1])assert.throws(()=>assertUnitCodeValidity(n),/LEGACY_UNIT_CODE_INVALID_REQUIRES_REVIEW/);
});
test("Backfill must reproduce distinct legacy units; new media starts empty",()=>{
 const ok={expected:"3",actual:"3",missing:"0",media_count:"0",bad_labels:"0"};
 assert.doesNotThrow(()=>assertNewTableBackfill(ok));
 for(const patch of [
  {actual:"2"},{missing:"1"},{media_count:"1"},{bad_labels:"1"}
 ])assert.throws(()=>assertNewTableBackfill({...ok,...patch}),/R1_MEDIA_BACKFILL/);
 assert.throws(()=>assertNewTableBackfill(null),/R1_MEDIA_BACKFILL/);
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
