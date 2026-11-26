import test from "node:test";
import assert from "node:assert/strict";
import {BASE,RELEASE,checkVersions,assertExactOperatorMigrationFiles,checkOperator,assertT6SchemaState} from "./t6-0023-codespaces-migration.mjs";
test("T6 permits exactly 0022 to 0023, no drift or future migration",()=>{
 assert.equal(BASE.length,22);
 assert.equal(BASE.at(-1),"0022_t1_sales_order_context.sql");
 assert.deepEqual(RELEASE,["0023_t6_pos_checkout.sql"]);
 assert.doesNotThrow(()=>checkVersions(BASE,"before"));
 assert.doesNotThrow(()=>checkVersions([...BASE,...RELEASE],"after"));
 assert.throws(()=>checkVersions(BASE,"after"),/DRIFT/);
 assert.doesNotThrow(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE]));
 assert.throws(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE,"0024_unapproved.sql"]),/MISMATCH/);
});
test("T6 requires independent explicit owner approval, exact SHA and target",()=>{
 const sha="a".repeat(40),origin="https://github.com/gustavjung24-ops/ERP.git";
 const e={CODESPACES:"true",CODESPACE_NAME:"synthetic",GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:"app.github.dev",
 GITHUB_TOKEN:"ghu_synthetic_session_token_12345",GITHUB_REPOSITORY:"gustavjung24-ops/ERP",GITHUB_USER:"gustavjung24-ops",
 ERP_APPROVED_SHA:sha,ERP_TARGET_PROJECT_ID:"proj_ud3b1s5yn03vh0zp9cbs2upa",ERP_TARGET_DATABASE_ID:"db_jg2bl98hzi1jm06lwo0i4rqx"};
 assert.doesNotThrow(()=>checkOperator(e,"main",sha,origin,[],false));
 assert.throws(()=>checkOperator(e,"main",sha,origin,[],true),/APPROVAL/);
 const approved={...e,ERP_T6_MIGRATION_APPROVAL:"OWNER_APPROVED_T6_0022_ERP_DB"};
 assert.doesNotThrow(()=>checkOperator(approved,"main",sha,origin,[],true));
 assert.throws(()=>checkOperator({...approved,ERP_TARGET_DATABASE_ID:"other"},"main",sha,origin,[],true),/APPROVAL/);
});
test("T6 verifies all seven POS tables and guards, no invalid or backfilled rows",()=>{
 const valid={tables:"7",guards:"7",invalid_links:"0",new_rows:"0"};
 assert.doesNotThrow(()=>assertT6SchemaState(valid,true));
 assert.throws(()=>assertT6SchemaState({...valid,guards:"6"},true),/RECONCILIATION/);
 assert.throws(()=>assertT6SchemaState({...valid,new_rows:"1"},true),/RECONCILIATION/);
 assert.doesNotThrow(()=>assertT6SchemaState({...valid,new_rows:"1"},false));
});
