import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
 BASE,RELEASE,checkVersions,checkOperator,checkPrimaryMainSha,
 assertCAT20SchemaState,canonicalRemote,parsePrismaCredential,
 requirePg17Client,BUCKET_S3_NAME,assertNotInterrupted,
 restoreContainerCleanupArgs
} from "./catalog-0020-codespaces-migration.mjs";

test("Compute deployment config declares the exact ERP Composer module",()=>{
 const config=readFileSync(new URL("../deploy/prisma.config.ts",import.meta.url),"utf8");
 const moduleText=readFileSync(new URL("../deploy/module.ts",import.meta.url),"utf8");
 assert.ok(config.includes('entry: "./module.ts"'),
   "Prisma Composer CLI needs an explicit module entry");
 assert.ok(moduleText.includes('export default module("erp-backend"'),
   "Composer entry must be the existing ERP backend module");
});

const sha="a".repeat(40);
const origin="https://github.com/gustavjung24-ops/ERP.git";
const operator={
 CODESPACES:"true",CODESPACE_NAME:"synthetic-erp-codespace",
 GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:"app.github.dev",
 GITHUB_REPOSITORY:"gustavjung24-ops/ERP",GITHUB_USER:"gustavjung24-ops",
 GITHUB_TOKEN:"ghu_synthetic_session_token_12345",ERP_APPROVED_SHA:sha,
 ERP_CAT20_MIGRATION_APPROVAL:"OWNER_APPROVED_CAT20_0020_ERP_DB",
 ERP_TARGET_PROJECT_ID:"proj_ud3b1s5yn03vh0zp9cbs2upa",
 ERP_TARGET_DATABASE_ID:"db_jg2bl98hzi1jm06lwo0i4rqx"
};

test("CAT20 only permits exact 0019 -> 0020 lineage",()=>{
 assert.equal(BASE.length,19);
 assert.equal(BASE[18],"0019_p0_price_order_parity.sql");
 assert.deepEqual(RELEASE,["0020_catalog_hierarchy_locations.sql"]);
 assert.doesNotThrow(()=>checkVersions(BASE,"before"));
 assert.doesNotThrow(()=>checkVersions([...BASE,...RELEASE],"after"));
 for(const [history,stage] of [
  [BASE,"after"],[[...BASE,...RELEASE],"before"],
  [BASE.slice(0,18),"before"],
  [[...BASE,"0020_wrong.sql"],"after"]
 ])assert.throws(()=>checkVersions(history,stage),/ERP_DB_MIGRATION_DRIFT/);
});

test("Reject wrong Codespace, SHA, remote, approval, or target",()=>{
 assert.doesNotThrow(()=>checkOperator(operator,"main",sha,origin,[],false));
 assert.doesNotThrow(()=>checkOperator(operator,"main",sha,origin,[],true));
 for(const e of [
  {...operator,ERP_CAT20_MIGRATION_APPROVAL:""},
  {...operator,ERP_TARGET_PROJECT_ID:"proj_elsewhere"},
  {...operator,ERP_TARGET_DATABASE_ID:"db_elsewhere"}
 ])assert.throws(()=>checkOperator(e,"main",sha,origin,[],true),
   /OWNER_CAT20_TARGET_APPROVAL_MISSING/);
 for(const [e,branch,remote,changes] of [
  [{...operator,CODESPACES:"false"},"main",origin,[]],
  [{...operator,GITHUB_TOKEN:"ghp_not_codespace"},"main",origin,[]],
  [{...operator,ERP_APPROVED_SHA:"b".repeat(40)},"main",origin,[]],
  [operator,"agent/unsafe",origin,[]],
  [operator,"main","https://github.com/attacker/ERP",[]],
  [operator,"main",origin,["backend/src/unauthorized.ts"]]
 ])assert.throws(()=>checkOperator(e,branch,sha,remote,changes,true));
 assert.equal(canonicalRemote(origin),true);
 assert.equal(canonicalRemote("https://github.com/attacker/ERP.git"),false);
 assert.doesNotThrow(()=>checkPrimaryMainSha(sha,sha));
 assert.throws(()=>checkPrimaryMainSha("b".repeat(40),sha),
   /PRIMARY_MAIN_SHA_MOVED_OR_UNVERIFIED/);
});

test("CAT20 verifier rejects missing taxonomy columns, FKs or unique default",()=>{
 const state={product_category_column:"1",group_brand_column:"1",
  category_tree_trigger:"1",brand_fk:"1",category_fk:"1",location_default_unique:"1"};
 assert.doesNotThrow(()=>assertCAT20SchemaState(state));
 for(const key of Object.keys(state))
   assert.throws(()=>assertCAT20SchemaState({...state,[key]:"0"}),
     /CAT20_CATALOG_HIERARCHY_SCHEMA_RECONCILIATION_FAILED/);
 assert.throws(()=>assertCAT20SchemaState(null),
   /CAT20_CATALOG_HIERARCHY_SCHEMA_RECONCILIATION_FAILED/);
});

test("CAT20 requires PG17, fixed bucket, and direct short-lived ERP-DB credential",()=>{
 assert.equal(BUCKET_S3_NAME,"user-hccjgwl892edb91ox3v3j5b2");
 assert.doesNotThrow(()=>requirePg17Client("pg_dump (PostgreSQL) 17.7","pg_dump"));
 assert.throws(()=>requirePg17Client("pg_dump (PostgreSQL) 16.9","pg_dump"),
   /POSTGRES_17_CLIENT_REQUIRED/);
 const v=parsePrismaCredential({connection:{id:"con_synthetic12345"},
  connectionString:"postgresql://synthetic:synthetic@pooled.db.prisma.io:5432/postgres?sslmode=require"});
 assert.equal(v.url.hostname,"db.prisma.io");
 assert.throws(()=>parsePrismaCredential({connection:{id:"con_synthetic12345"},
  connectionString:"postgresql://synthetic:synthetic@attacker.invalid:5432/postgres?sslmode=require"}));
});

test("Isolated recovery cleanup and graceful signals are fail-closed",()=>{
 assert.deepEqual(restoreContainerCleanupArgs("erp-cat20-pg-abcdef012345"),
  ["rm","--force","--volumes","erp-cat20-pg-abcdef012345"]);
 for(const bad of ["erp-r1a-pg-abcdef012345","abc; rm /",""])
  assert.throws(()=>restoreContainerCleanupArgs(bad),
    /INVALID_ISOLATED_RESTORE_CONTAINER_ID/);
 assert.doesNotThrow(()=>assertNotInterrupted(null));
 for(const sig of ["SIGINT","SIGTERM"])
  assert.throws(()=>assertNotInterrupted(sig),
    /ERP_CAT20_INTERRUPTED_CLEANUP_REQUIRED/);
});
