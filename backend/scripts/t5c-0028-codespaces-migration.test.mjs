import {readFileSync} from "node:fs";
import test from "node:test";
import assert from "node:assert/strict";
import {BASE,RELEASE,checkVersions,assertExactOperatorMigrationFiles,
 assertT5cSchemaState,preservedRowJsonExpression}
 from "./t5c-0028-codespaces-migration.mjs";
test("T5-C operator pins exactly 27 baseline and 0028 only",()=>{
 assert.equal(BASE.length,27);
 assert.equal(BASE.at(-1),"0027_t5b_delivery_trip_planning.sql");
 assert.deepEqual(RELEASE,["0028_t5c_canonical_employee_driver.sql"]);
 assert.doesNotThrow(()=>checkVersions(BASE,"before"));
 assert.doesNotThrow(()=>checkVersions([...BASE,...RELEASE],"after"));
 assert.throws(()=>checkVersions(BASE,"after"),/DRIFT/);
 assert.doesNotThrow(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE]));
 assert.throws(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE,
  "0029_unapproved.sql"]),/MISMATCH/);
});
test("T5-C restore checks employee table, 2 guards, unique link and no orphan",()=>{
 const valid={tables:"1",guards:"2",employee_column:"1",active_unique:"1",
  invalid_links:"0",new_rows:"0"};
 assert.doesNotThrow(()=>assertT5cSchemaState(valid,true));
 for(const key of ["tables","guards","employee_column","active_unique"]){
  assert.throws(()=>assertT5cSchemaState({...valid,[key]:"0"},true),/RECONCILIATION/);
 }
 assert.throws(()=>assertT5cSchemaState({...valid,invalid_links:"1"},true),/RECONCILIATION/);
 assert.throws(()=>assertT5cSchemaState({...valid,new_rows:"1"},true),/RECONCILIATION/);
 assert.doesNotThrow(()=>assertT5cSchemaState({...valid,new_rows:"1"},false));
});
test("T5-C row-preservation hashes complete pre-existing driver columns",()=>{
 assert.equal(preservedRowJsonExpression("delivery_driver"),"(to_jsonb(x) - 'employee_id')");
 assert.equal(preservedRowJsonExpression("payment_receipt"),"to_jsonb(x)");
 assert.equal(preservedRowJsonExpression("org_employee"),"to_jsonb(x)");
});
test("T5-C migration uses complete PL/pgSQL delimiters and scoped FKs",()=>{
 const sql=readFileSync(new URL("../db/migrations/0028_t5c_canonical_employee_driver.sql",
  import.meta.url),"utf8");
 assert.equal(sql.match(/LANGUAGE plpgsql AS \$\$/g)?.length,2);
 assert.equal(sql.match(/\$\$;/g)?.length,2);
 assert.match(sql,/driver_canonical_employee_fk/);
 assert.match(sql,/delivery_driver_one_active_employee/);
 assert.match(sql,/org_employee_identity_guard/);
});
