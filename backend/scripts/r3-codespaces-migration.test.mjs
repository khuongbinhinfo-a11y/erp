import test from "node:test";
import assert from "node:assert/strict";
import { BASE, R3, checkOperator, checkVersions } from "./r3-codespaces-migration.mjs";
const sha="a".repeat(40);
const remote="https://github.com/gustavjung24-ops/ERP.git";
const base={CODESPACES:"true",ERP_APPROVED_SHA:sha,
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
