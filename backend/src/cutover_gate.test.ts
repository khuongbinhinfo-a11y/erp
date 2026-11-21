import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

function rejected(script:string,extra:Record<string,string>={}){
 const env={...process.env,...extra};
 for(const key of ["ERP_POSTGRES_DIRECT_URL","APPROVAL_COMMENT","OWNER_COMMENT_AUTHOR",
   "ERP_PRODUCTION_WRITES_FROZEN","ACTION_ID_TOKEN_REQUEST_TOKEN",
   "ACTION_ID_TOKEN_REQUEST_URL","GITHUB_ENV"])delete env[key];
 const r=spawnSync(process.execPath,["--experimental-strip-types",resolve("scripts",script)],{
  cwd:process.cwd(),env,encoding:"utf8",timeout:10000});
 assert.notEqual(r.status,0);
 assert.doesNotMatch(r.stdout+r.stderr,/postgres(?:ql)?:\/\//i);
 return r.stderr;
}
test("cutover refuses missing owner approval even inside CI",()=>{
 assert.match(rejected("db-cutover.mjs"),/ERP_DB_CUTOVER_FAILED OWNER_PRODUCTION_GATE_REFUSED/);
});
test("maintenance freeze refuses missing protected source target",()=>{
 assert.match(rejected("db-cutover-maintenance.mjs"),/ERP_SOURCE_MAINTENANCE_PREPARE_FAILED/);
});
test("target release refuses ordinary CI and preview context",()=>{
 assert.match(rejected("compute-target-preflight.mjs"),/COMPUTE_TARGET_OPERATOR_ONLY/);
});

test("resume refuses missing owner/maintenance confirmation",()=>{
 assert.match(rejected("db-cutover-resume.mjs"),/ERP_RESUME_FAILED OWNER_RESUME_GATE_REFUSED/);
});
