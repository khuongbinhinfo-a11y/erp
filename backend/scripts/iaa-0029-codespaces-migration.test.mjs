import {readFileSync} from "node:fs";
import test from "node:test";
import assert from "node:assert/strict";
import {BASE,RELEASE,BUCKET_S3_NAME,checkVersions,assertExactOperatorMigrationFiles,
 assertIaaSchemaState,preservedRowJsonExpression,checkPrimaryMainSha,
 checkOperator,canonicalRemote} from "./iaa-0029-codespaces-migration.mjs";
test("IA-A operator pins 28 migrations and ONLY 0029",()=>{
 assert.equal(BASE.length,28);
 assert.equal(BASE.at(-1),"0028_t5c_canonical_employee_driver.sql");
 assert.deepEqual(RELEASE,["0029_iaa_employee_access.sql"]);
 assert.doesNotThrow(()=>checkVersions(BASE,"before"));
 assert.doesNotThrow(()=>checkVersions([...BASE,...RELEASE],"after"));
 assert.throws(()=>checkVersions(BASE,"after"),/DRIFT/);
 assert.doesNotThrow(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE]));
 assert.throws(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE,
  "0030_unapproved.sql"]),/MISMATCH/);
 assert.ok(BUCKET_S3_NAME.startsWith("user-"));
});
test("IA-A schema and data preservation: staff column & constraint",()=>{
 const valid={tables:"1",guards:"2",employee_column:"1",active_unique:"1",
  department_column:"1",department_constraint:"1",invalid_links:"0",new_rows:"7"};
 assert.doesNotThrow(()=>assertIaaSchemaState(valid,false));
 for(const key of ["tables","guards","employee_column","active_unique",
   "department_column","department_constraint"]){
  assert.throws(()=>assertIaaSchemaState({...valid,[key]:"0"},false),/RECONCILIATION/);
 }
 assert.throws(()=>assertIaaSchemaState({...valid,invalid_links:"1"},false),/RECONCILIATION/);
 assert.equal(preservedRowJsonExpression("org_employee"),
  "(to_jsonb(x) - 'department')");
 assert.equal(preservedRowJsonExpression("delivery_driver"),"to_jsonb(x)");
 assert.equal(preservedRowJsonExpression("payment_receipt"),"to_jsonb(x)");
});
test("IA-A operator requires exact primary Codespaces, approved SHA and project",()=>{
 const sha="a".repeat(40), env={
  CODESPACES:"true",CODESPACE_NAME:"example-branch",
  GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:"example.app.github.dev",
  GITHUB_TOKEN:"ghu_"+"x".repeat(30),
  GITHUB_REPOSITORY:"gustavjung24-ops/ERP",GITHUB_USER:"gustavjung24-ops",
  ERP_APPROVED_SHA:sha,ERP_TARGET_PROJECT_ID:"proj_ud3b1s5yn03vh0zp9cbs2upa",
  ERP_TARGET_DATABASE_ID:"db_jg2bl98hzi1jm06lwo0i4rqx",
 };
 assert.ok(canonicalRemote("https://github.com/gustavjung24-ops/ERP.git"));
 assert.doesNotThrow(()=>checkOperator(env,"main",sha,
  "https://github.com/gustavjung24-ops/ERP.git",[],false));
 assert.throws(()=>checkOperator(env,"other",sha,
  "https://github.com/gustavjung24-ops/ERP.git",[],false),/ONLY_AUTHENTICATED/);
 assert.throws(()=>checkOperator(env,"main",sha,
  "https://github.com/gustavjung24-ops/ERP.git",[],true),/OWNER_IAA/);
 assert.throws(()=>checkPrimaryMainSha("b".repeat(40),sha),/MOVED/);
});
test("IA-A schema adds only personnel department and owner grants",()=>{
 const sql=readFileSync(new URL("../db/migrations/0029_iaa_employee_access.sql",import.meta.url),"utf8");
 assert.match(sql,/ALTER TABLE org_employee ADD COLUMN department/);
 assert.match(sql,/PRIMARY_OWNER_MAIN/);
 assert.match(sql,/OWNER_BRANCH_/);
 assert.doesNotMatch(sql,/DROP TABLE|TRUNCATE|DELETE FROM org_employee/i);
});
