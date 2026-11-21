import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

const script=resolve(process.cwd(),"src/migrate_catalog_production.ts");
const keys=[
  "ERP_MIGRATION_CONFIRM","ERP_TARGET_DATABASE_ID","ERP_APPROVED_GIT_SHA",
  "ERP_BACKUP_ENCRYPTED_SHA256","ERP_BACKUP_RESTORE_MANIFEST_URI",
  "ERP_BACKUP_RESTORE_RECONCILIATION","ERP_PRODUCTION_WRITES_FROZEN",
  "ERP_MIGRATION_APPROVAL_REFERENCE","ERP_POSTGRES_DIRECT_URL",
];
test("catalog production migration fails closed without owner, backup and restore gate",()=>{
  const env={...process.env};
  for(const key of keys)delete env[key];
  const r=spawnSync(process.execPath,["--experimental-strip-types",script],{
    cwd:process.cwd(),env,encoding:"utf8",timeout:15000});
  assert.notEqual(r.status,0);
  assert.match(r.stderr,/CATALOG_MIGRATION_GATE_BLOCKED/);
  assert.doesNotMatch(r.stderr,/postgres:\/\//);
});
test("catalog production operator refuses CI and Vercel runtime",()=>{
  for(const mark of [{GITHUB_ACTIONS:"true"},{VERCEL:"1"},{ERP_RUNTIME:"compute"}]){
    const env={...process.env,...mark};
    const r=spawnSync(process.execPath,["--experimental-strip-types",script],{
      cwd:process.cwd(),env,encoding:"utf8",timeout:15000});
    assert.notEqual(r.status,0);
    assert.match(r.stderr,/PROTECTED_OPERATOR_ONLY/);
  }
});
