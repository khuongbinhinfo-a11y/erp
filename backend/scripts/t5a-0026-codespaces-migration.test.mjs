import test from "node:test";
import assert from "node:assert/strict";
import {
 BASE, RELEASE, checkVersions, assertExactOperatorMigrationFiles,
 assertT5aSchemaState, preservedRowJsonExpression
} from "./t5a-0026-codespaces-migration.mjs";

test("T5-A operator requires exactly 25 baseline migrations and immutable 0026",()=>{
 assert.equal(BASE.length,25);
 assert.equal(BASE.at(-1),"0025_t3c_trip_preparation_dispatch.sql");
 assert.deepEqual(RELEASE,["0026_t5a_sales_execution.sql"]);
 assert.doesNotThrow(()=>checkVersions(BASE,"before"));
 assert.doesNotThrow(()=>checkVersions([...BASE,...RELEASE],"after"));
 assert.throws(()=>checkVersions(BASE,"after"),/DRIFT/);
 assert.doesNotThrow(()=>assertExactOperatorMigrationFiles([...BASE,...RELEASE]));
 assert.throws(()=>assertExactOperatorMigrationFiles(
   [...BASE,...RELEASE,"0027_unapproved.sql"]),/MISMATCH/);
});
test("T5-A operator requires isolated restore schema and no orphan facts",()=>{
 const valid={tables:"3",guards:"12",payment_source_columns:"1",
  invalid_links:"0",new_rows:"0"};
 assert.doesNotThrow(()=>assertT5aSchemaState(valid,true));
 assert.throws(()=>assertT5aSchemaState({...valid,tables:"2"},true),/RECONCILIATION/);
 assert.throws(()=>assertT5aSchemaState({...valid,guards:"11"},true),/RECONCILIATION/);
 assert.throws(()=>assertT5aSchemaState({...valid,invalid_links:"1"},true),/RECONCILIATION/);
 assert.throws(()=>assertT5aSchemaState({...valid,new_rows:"1"},true),/RECONCILIATION/);
 assert.doesNotThrow(()=>assertT5aSchemaState({...valid,new_rows:"1"},false));
});
test("T5-A preserved rows subtract only new payment column",()=>{
 assert.equal(preservedRowJsonExpression("payment_receipt"),
   "(to_jsonb(x) - 'fulfillment_id')");
 assert.equal(preservedRowJsonExpression("inventory_reservation"),"to_jsonb(x)");
 assert.equal(preservedRowJsonExpression("customer_receivable_ledger"),"to_jsonb(x)");
});
