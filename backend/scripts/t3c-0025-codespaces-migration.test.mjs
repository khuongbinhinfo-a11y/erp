import test from "node:test";
import assert from "node:assert/strict";
import {BASE,RELEASE,checkVersions,assertExactOperatorMigrationFiles,checkOperator,assertT3cSchemaState} from "./t3c-0025-codespaces-migration.mjs";
test("T3-C permits exactly 0024 to 0025, no drift or future migration",()=>{
 assert.equal(BASE.length,24);
 assert.equal(BASE.at(-1),"0024_t3b_manual_direct_issue.sql");
 assert.deepEqual(RELEASE,["0025_t3c_trip_preparation_dispatch.sql"]);
 assert.doesNotThrow(()=>checkVersions(BASE,"before"));
 assert.doesNotThrow(()=>checkVersions([...BASE,...RELEASE],"after"));
 assert.throws(()=>checkVersions(BASE,"after"),/DRIFT/);
 assert.doesNotThrow(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE]));
 assert.throws(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE,"0026_unapproved.sql"]),/MISMATCH/);
});
test("T3-C requires independent explicit owner approval, exact SHA and target",()=>{
 const sha="a".repeat(40),origin="https://github.com/gustavjung24-ops/ERP.git";
 const e={CODESPACES:"true",CODESPACE_NAME:"synthetic",GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:"app.github.dev",
 GITHUB_TOKEN:"ghu_synthetic_session_token_12345",GITHUB_REPOSITORY:"gustavjung24-ops/ERP",GITHUB_USER:"gustavjung24-ops",
 ERP_APPROVED_SHA:sha,ERP_TARGET_PROJECT_ID:"proj_ud3b1s5yn03vh0zp9cbs2upa",ERP_TARGET_DATABASE_ID:"db_jg2bl98hzi1jm06lwo0i4rqx"};
 assert.doesNotThrow(()=>checkOperator(e,"main",sha,origin,[],false));
 assert.throws(()=>checkOperator(e,"main",sha,origin,[],true),/APPROVAL/);
 const approved={...e,ERP_T3C_MIGRATION_APPROVAL:"OWNER_APPROVED_T3C_0025_ERP_DB"};
 assert.doesNotThrow(()=>checkOperator(approved,"main",sha,origin,[],true));
 assert.throws(()=>checkOperator({...approved,ERP_TARGET_DATABASE_ID:"other"},"main",sha,origin,[],true),/APPROVAL/);
});
test("T3-C verifies all four T3-C tables and nine guards, no invalid or backfilled rows",()=>{
 const valid={tables:"4",guards:"9",invalid_links:"0",new_rows:"0"};
 assert.doesNotThrow(()=>assertT3cSchemaState(valid,true));
 assert.throws(()=>assertT3cSchemaState({...valid,guards:"8"},true),/RECONCILIATION/);
 assert.throws(()=>assertT3cSchemaState({...valid,new_rows:"1"},true),/RECONCILIATION/);
 assert.doesNotThrow(()=>assertT3cSchemaState({...valid,new_rows:"1"},false));
});
