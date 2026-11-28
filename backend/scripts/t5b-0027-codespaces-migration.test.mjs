import {readFileSync} from "node:fs";
import test from "node:test";
import assert from "node:assert/strict";
import {BASE,RELEASE,checkVersions,assertExactOperatorMigrationFiles,
 assertT5bSchemaState,preservedRowJsonExpression}
 from "./t5b-0027-codespaces-migration.mjs";
test("T5-B operator pins exactly 26 baseline and 0027 only",()=>{
 assert.equal(BASE.length,26);
 assert.equal(BASE.at(-1),"0026_t5a_sales_execution.sql");
 assert.deepEqual(RELEASE,["0027_t5b_delivery_trip_planning.sql"]);
 assert.doesNotThrow(()=>checkVersions(BASE,"before"));
 assert.doesNotThrow(()=>checkVersions([...BASE,...RELEASE],"after"));
 assert.throws(()=>checkVersions(BASE,"after"),/DRIFT/);
 assert.doesNotThrow(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE]));
 assert.throws(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE,
  "0028_unapproved.sql"]),/MISMATCH/);
});
test("T5-B restore asserts exactly 6 tables, 4 guards, zero orphans and fresh rows",()=>{
 const valid={tables:"6",guards:"4",invalid_links:"0",new_rows:"0"};
 assert.doesNotThrow(()=>assertT5bSchemaState(valid,true));
 assert.throws(()=>assertT5bSchemaState({...valid,tables:"5"},true),/RECONCILIATION/);
 assert.throws(()=>assertT5bSchemaState({...valid,guards:"3"},true),/RECONCILIATION/);
 assert.throws(()=>assertT5bSchemaState({...valid,invalid_links:"1"},true),/RECONCILIATION/);
 assert.throws(()=>assertT5bSchemaState({...valid,new_rows:"1"},true),/RECONCILIATION/);
 assert.doesNotThrow(()=>assertT5bSchemaState({...valid,new_rows:"1"},false));
});
test("T5-B operator preserves ALL previous business row columns",()=>{
 assert.equal(preservedRowJsonExpression("payment_receipt"),"to_jsonb(x)");
 assert.equal(preservedRowJsonExpression("inventory_reservation"),"to_jsonb(x)");
});
test("T5-B SQL trigger functions use complete PostgreSQL dollar delimiters",()=>{
 const sql=readFileSync(new URL("../db/migrations/0027_t5b_delivery_trip_planning.sql",
   import.meta.url),"utf8");
 const tag=String.fromCharCode(36,36);
 assert.equal(sql.match(/LANGUAGE plpgsql AS \$\$/g)?.length,4);
 assert.equal(sql.match(/\$\$;/g)?.length,4);
 assert.ok(sql.includes("delivery_trip_locked_order_guard"));
});
