/**
 * ERP R3, Codespaces-only production migration operator.
 * Run from backend with: node --experimental-strip-types scripts/r3-codespaces-migration.mjs --check|--apply
 *
 * Production writes are gated by observed Compute maintenance mode.
 * A private, encrypted durable backup and its isolated read-back/restore are
 * mandatory before applying versioned migrations 0011..0014.
 * NEVER print credentials, SQL driver errors, dump contents, or customer rows.
 */
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { spawnSync, execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync, statSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { Pool } from "pg";
import { applyMigrations } from "../src/migrate.ts";

export const BASE = ["0001_identity.sql","0002_mutation_control.sql","0003_warehouse_scope.sql",
 "0004_auth_sessions.sql","0005_admin_revision_throttle.sql","0006_catalog.sql",
 "0007_catalog_controls.sql","0008_sales_orders.sql",
 "0009_r1_catalog_pricing.sql","0010_r1_sales_price_snapshot.sql"];
export const R3 = ["0011_r3_inventory_ledger.sql","0012_r3_purchase_receipt.sql",
 "0013_r3_transfer_in_transit.sql","0014_r3_stocktake.sql"];
const PROJECT="proj_ud3b1s5yn03vh0zp9cbs2upa";
const DATABASE="db_jg2bl98hzi1jm06lwo0i4rqx";
const BUCKET="erp-db-migration-encrypted-backups";
const API="https://gh30k50bvsc0o9298w9leivf.sin.prisma.build";
const BASE_TABLES=["installation","branch","warehouse","app_user","app_role",
 "schema_migrations","role_permission","inventory_ledger"];
const REQUIRED_R3=["inventory_ledger","inventory_reservation",
 "purchase_order_sequence","purchase_order","purchase_order_line",
 "purchase_receipt","purchase_receipt_line","inventory_transfer",
 "inventory_transfer_line","inventory_transfer_receipt",
 "inventory_transfer_receipt_line","inventory_stocktake",
 "inventory_stocktake_line","inventory_stocktake_count"];
const APPROVAL="OWNER_APPROVED_R3_0011_0014_ERP_DB";
const CLEAN_EXCEPT=new Set(["backend/package-lock.json","backend/deploy/package-lock.json"]);

function fail(code){throw new Error(code);}
function required(e,names){const missing=names.filter(n=>!e[n]);if(missing.length)fail("REQUIRED_CODESPACES_SECRETS_MISSING: "+missing.join(","));}
export function checkVersions(versions,stage){
 const wanted=stage==="before"?BASE:[...BASE,...R3];
 if(JSON.stringify(versions)!==JSON.stringify(wanted))fail("ERP_DB_MIGRATION_DRIFT_"+stage.toUpperCase());
}
export function canonicalRemote(remote){
 return /^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)gustavjung24-ops\/ERP(?:\.git)?$/.test(remote.trim());
}
export function checkOperator(e,branch,sha,remote,changes,apply=false){
 if(e.CODESPACES!=="true"||!e.CODESPACE_NAME||
    !String(e.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN??"").endsWith("app.github.dev")||
    e.GITHUB_ACTIONS==="true"||e.CI==="true"||
    branch!=="main"||!canonicalRemote(remote))
   fail("ONLY_AUTHENTICATED_PRIMARY_MAIN_CODESPACES");
 if(!/^[a-f0-9]{40}$/.test(sha)||e.ERP_APPROVED_SHA!==sha)
   fail("EXACT_MAIN_SHA_APPROVAL_MISSING");
 if(changes.some(path=>!CLEAN_EXCEPT.has(path)))
   fail("WORKTREE_CHANGES_NOT_APPROVED");
 if(apply&&(e.ERP_R3_MIGRATION_APPROVAL!==APPROVAL||
    e.ERP_TARGET_PROJECT_ID!==PROJECT||e.ERP_TARGET_DATABASE_ID!==DATABASE))
   fail("OWNER_R3_TARGET_APPROVAL_MISSING");
}
function git(args){return execFileSync("git",args,{cwd:resolve(process.cwd(),".."),
 encoding:"utf8",stdio:["ignore","pipe","ignore"]}).trim();}
function command(name,args,extraEnv={}){
 const x=spawnSync(name,args,{encoding:"utf8",env:{...process.env,...extraEnv},
  maxBuffer:4*1024*1024,timeout:600000,stdio:["ignore","pipe","pipe"]});
 if(x.error||x.status!==0)fail("OPERATOR_COMMAND_FAILED_"+name.replaceAll(/[^a-z0-9]/gi,"_").toUpperCase());
 return x.stdout.trim();
}
// GitHub's authenticated Codespaces API attests an active Codespace under the
// intended repository. Environment flags alone are never treated as identity.
export function checkCodespaceRecord(record,name){
 if(record?.name!==name||record?.state!=="Available"||
    record?.repository?.full_name!=="gustavjung24-ops/ERP")
   fail("CODESPACES_IDENTITY_ATTESTATION_FAILED");
}
function verifyCodespaceSession(e){
 if(!git(["rev-parse","--show-toplevel"]).startsWith("/workspaces/ERP"))
   fail("CODESPACES_REPO_MOUNT_INVALID");
 let record;
 try{record=JSON.parse(command("gh",["api","/user/codespaces/"+e.CODESPACE_NAME]));}
 catch{fail("CODESPACES_API_ATTESTATION_UNAVAILABLE");}
 checkCodespaceRecord(record,e.CODESPACE_NAME);
}
function safeURL(raw){
 let u;try{u=new URL(raw);}catch{fail("INVALID_DIRECT_DATABASE_URL");}
 if(!["postgresql:","postgres:"].includes(u.protocol)||
    u.hostname!=="db.prisma.io"||u.searchParams.get("sslmode")!=="require"||
    !u.password||!u.username||u.pathname.length<2)
    fail("DIRECT_PRISMA_ERP_DB_TLS_URL_REQUIRED");
 return u;
}
function pgEnv(u){
 return {PGHOST:u.hostname,PGPORT:u.port||"5432",
  PGDATABASE:decodeURIComponent(u.pathname.slice(1)),PGUSER:decodeURIComponent(u.username),
  PGPASSWORD:decodeURIComponent(u.password),PGSSLMODE:u.searchParams.get("sslmode")||"require"};
}
function fileHash(file){return createHash("sha256").update(readFileSync(file)).digest("hex");}
async function maintenance(){
 const r=await fetch(API+"/health/live",{signal:AbortSignal.timeout(15000)});
 if(!r.ok)fail("BACKEND_MAINTENANCE_PROBE_FAILED");
 const body=await r.json();
 if(body.service!=="erp-api"||body.maintenance!==true)
   fail("PRODUCTION_COMPUTE_READ_ONLY_REQUIRED");
}
async function versions(pool){
 return (await pool.query("SELECT version FROM public.schema_migrations ORDER BY version"))
   .rows.map(x=>x.version);
}
async function signature(pool,exclusions=[]){
 const tables=(await pool.query(
 "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name"
 )).rows.map(x=>x.table_name).filter(x=>!exclusions.includes(x));
 const result={};
 for(const table of tables){
  const safe=table.replaceAll('"','""');
  const sql='SELECT count(*)::text AS n,'+
   'COALESCE(bit_xor(hashtextextended(to_jsonb(x)::text,0))::text,\'0\') AS xor,'+
   'COALESCE(sum(hashtextextended(to_jsonb(x)::text,1)::numeric)::text,\'0\') AS total '+
   'FROM public."'+safe+'" x';
  result[table]=(await pool.query(sql)).rows[0];
 }
 return result;
}
function checkPreserved(before,after,description){
 for(const [name,value] of Object.entries(before)){
  if(JSON.stringify(after[name])!==JSON.stringify(value))fail(description+"_DATA_RECONCILIATION_FAILED");
 }
}
async function validateSchema(pool,stage){
 const v=await versions(pool);checkVersions(v,stage);
 const names=stage==="before"?BASE_TABLES.slice(0,7):REQUIRED_R3;
 for(const name of names){
  const result=await pool.query("SELECT to_regclass($1) IS NOT NULL AS ok",["public."+name]);
  if(result.rows[0]?.ok!==true)fail("ERP_SCHEMA_MISSING_"+name);
 }
 const pg=await pool.query("SHOW server_version_num");
 if(Number(pg.rows[0]?.server_version_num)<170000||Number(pg.rows[0]?.server_version_num)>=180000)
   fail("POSTGRES_17_REQUIRED");
 for(const ver of v){
  const sql=readFileSync(resolve("db/migrations",ver),"utf8");
  const checksum=createHash("sha256").update(sql).digest("hex");
  const found=await pool.query("SELECT checksum FROM schema_migrations WHERE version=$1",[ver]);
  if(found.rows[0]?.checksum!==checksum)fail("ERP_MIGRATION_CHECKSUM_DRIFT");
 }
}
async function main(mode){
 const e=process.env;
 const sha=git(["rev-parse","HEAD"]),branch=git(["branch","--show-current"]);
 const remote=git(["remote","get-url","origin"]);
 const tracked=git(["status","--porcelain","--untracked-files=all"]);
 const changes=tracked.split("\n").filter(Boolean).map(x=>x.slice(3));
 checkOperator(e,branch,sha,remote,changes,mode==="--apply");
 verifyCodespaceSession(e);
 required(e,["ERP_POSTGRES_DIRECT_URL","ERP_APPROVED_SHA"]);
 const u=safeURL(e.ERP_POSTGRES_DIRECT_URL);
 if(mode==="--apply")await maintenance();
 const pool=new Pool({connectionString:e.ERP_POSTGRES_DIRECT_URL,max:1,
  connectionTimeoutMillis:20000,statement_timeout:300000,query_timeout:300000});
 pool.on("error",()=>console.error("ERP_R3_POSTGRES_POOL_DISCONNECTED"));
 let tmp,container;
 try{
  const v=await versions(pool);
  if(v.length===14){await validateSchema(pool,"after");console.log("ERP_R3_ALREADY_MIGRATED_14");return;}
  await validateSchema(pool,"before");
  const initial=await signature(pool,["schema_migrations","role_permission"]);
  console.log("ERP_R3_BASE_0010_CHECKSUM_AND_LEDGER_PREFLIGHT_PASS "+sha.slice(0,12));
  if(mode==="--check"){console.log("ERP_R3_CHECK_ONLY_NO_DATABASE_WRITES");return;}
  required(e,["AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","ERP_BACKUP_S3_ENDPOINT",
    "ERP_AGE_RECIPIENT","ERP_BACKUP_RECOVERY_KEY_CUSTODY"]);
  if(e.ERP_BACKUP_RECOVERY_KEY_CUSTODY!=="VERIFIED")
    fail("RECOVERY_KEY_CUSTODY_NOT_VERIFIED");
  const endpoint=new URL(e.ERP_BACKUP_S3_ENDPOINT);
  if(endpoint.protocol!=="https:"||endpoint.pathname!=="/"||endpoint.search)fail("S3_TLS_ENDPOINT_REQUIRED");
  // All external prerequisites must exist before creating the first production artifact.
  for(const tool of ["pg_dump","pg_restore","pg_isready","age","age-keygen","aws","docker"])
   command(tool,["--version"]);
  if(!/^age1[0-9a-z]{30,}$/.test(e.ERP_AGE_RECIPIENT))
   fail("INVALID_OFFLINE_BACKUP_RECIPIENT");
  tmp=mkdtempSync(join(tmpdir(),"erp-r3-recovery-"));
  chmodSync(tmp,0o700);
  const dump=join(tmp,"baseline.dump"),encrypted=join(tmp,"baseline.dump.age");
  const portableList=join(tmp,"portable-restore.list");
  const durableCopy=join(tmp,"durable-readback.age");
  const key=join(tmp,"rehearsal.agekey"),rehCipher=join(tmp,"rehearsal.dump.age");
  const rehabCopy=join(tmp,"rehearsal-readback.age"),recovered=join(tmp,"verified.dump");
  const base="s3://"+BUCKET+"/erp-db/R3/"+sha+"/"+
    Date.now().toString()+"-"+randomUUID()+"/";
  const aws=(action,source,dest)=>command("aws",[
    "--endpoint-url",endpoint.origin,"s3","cp",source,dest,"--only-show-errors"
  ],{AWS_EC2_METADATA_DISABLED:"true",AWS_DEFAULT_REGION:"ap-southeast-1"});
  // PgDump snapshot alone is not a release gate: read back, decrypt and RESTORE.
  command("pg_dump",["--format=custom","--no-owner","--no-acl",
    "--serializable-deferrable","--file="+dump],pgEnv(u));
  if(statSync(dump).size<256)fail("ERP_BACKUP_TOO_SMALL");
  command("age",["-r",e.ERP_AGE_RECIPIENT,"-o",encrypted,dump]);
  aws("upload",encrypted,base+"pre-0011-0014.dump.age");
  aws("download",base+"pre-0011-0014.dump.age",durableCopy);
  if(fileHash(encrypted)!==fileHash(durableCopy))fail("DURABLE_BACKUP_READBACK_HASH_MISMATCH");
  const durableHash=fileHash(encrypted);
  command("age-keygen",["-o",key]);
  const recipient=command("age-keygen",["-y",key]);
  command("age",["-r",recipient,"-o",rehCipher,dump]);
  aws("upload",rehCipher,base+"rehearsal.dump.age");
  aws("download",base+"rehearsal.dump.age",rehabCopy);
  if(fileHash(rehCipher)!==fileHash(rehabCopy))fail("REHEARSAL_CIPHERTEXT_HASH_MISMATCH");
  command("age",["-d","-i",key,"-o",recovered,rehabCopy]);
  if(fileHash(dump)!==fileHash(recovered))fail("REHEARSAL_DECRYPTED_DUMP_HASH_MISMATCH");
  console.log("ERP_R3_DURABLE_BACKUP_AND_READBACK_PASS key="+base+"pre-0011-0014.dump.age sha256="+durableHash);
  // Separate PG17 Docker service: no restore, truncate or schema mutation on ERP-DB.
  const name="erp-r3-pg-"+randomBytes(6).toString("hex");
  const password=randomBytes(24).toString("hex");
  let started=false;
  try{
   command("docker",["run","-d","--name",name,"-e","POSTGRES_USER=erp_rehearsal",
    "-e","POSTGRES_PASSWORD="+password,"-e","POSTGRES_DB=erp_r3_restore",
    "-p","127.0.0.1::5432","postgres:17"]);
   started=true;
   const port=command("docker",["port",name,"5432/tcp"]).match(/127\.0\.0\.1:(\d+)/)?.[1];
   if(!port)fail("REHEARSAL_DOCKER_PORT_MISSING");
   const env={PGHOST:"127.0.0.1",PGPORT:port,PGUSER:"erp_rehearsal",
    PGPASSWORD:password,PGDATABASE:"erp_r3_restore",PGSSLMODE:"disable"};
   let ready=false;
   for(let n=0;n<60;n++){
    const x=spawnSync("pg_isready",["-q"],{env:{...process.env,...env},stdio:"ignore"});
    if(x.status===0){ready=true;break;}
    await new Promise(ok=>setTimeout(ok,1000));
   }
   if(!ready)fail("RESTORE_CONTAINER_NOT_READY");
   // Prisma Postgres provider-only extensions are not present in stock PG17.
   // The portable snapshot deliberately excludes those extension objects,
   // while retaining every application table, index, trigger and row.
   const listing=command("pg_restore",["-l",recovered]).split("\n");
   const portable=listing.filter(x=>!/\\bEXTENSION - |\\bCOMMENT - EXTENSION /.test(x));
   writeFileSync(portableList,portable.join("\n"),{mode:0o600});
   command("pg_restore",["--no-owner","--no-acl","--exit-on-error",
      "--single-transaction","--use-list="+portableList,
      "--dbname=erp_r3_restore",recovered],env);
   const testPool=new Pool({host:"127.0.0.1",port:Number(port),user:env.PGUSER,
     password,database:env.PGDATABASE,max:1,statement_timeout:300000,query_timeout:300000});
   try{
    await validateSchema(testPool,"before");
    checkPreserved(initial,await signature(testPool,["schema_migrations","role_permission"]),
     "RESTORE");
    const rehearsal=await applyMigrations(testPool,resolve("db/migrations"));
    if(JSON.stringify(rehearsal.applied)!==JSON.stringify(R3)||rehearsal.skipped.length!==10)
      fail("REHEARSAL_MIGRATION_SET_INVALID");
    await validateSchema(testPool,"after");
    checkPreserved(initial,await signature(testPool,["schema_migrations","role_permission"]),
     "REHEARSAL");
   }finally{await testPool.end();}
  }finally{if(started)command("docker",["rm","-f",name]);}
  console.log("ERP_R3_ISOLATED_RESTORE_AND_0011_0014_REHEARSAL_PASS");
  // No production SQL is issued before all previous gates have passed.
  await maintenance();
  await validateSchema(pool,"before");
  checkPreserved(initial,await signature(pool,["schema_migrations","role_permission"]),
   "PRODUCTION_PRECOMMIT");
  const result=await applyMigrations(pool,resolve("db/migrations"));
  if(JSON.stringify(result.applied)!==JSON.stringify(R3)||result.skipped.length!==10)
    fail("PRODUCTION_APPLIED_VERSION_SET_INVALID");
  await validateSchema(pool,"after");
  checkPreserved(initial,await signature(pool,["schema_migrations","role_permission"]),
   "PRODUCTION");
  console.log("ERP_R3_0011_0014_MIGRATION_PASS_AND_RECONCILED");
  console.log("ERP_R3_BACKUP_OBJECT "+base+"pre-0011-0014.dump.age");
  console.log("ERP_R3_BACKUP_SHA256 "+durableHash);
 }finally{
  await pool.end();
  if(tmp)rmSync(tmp,{recursive:true,force:true});
 }
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 if(!["--check","--apply"].includes(process.argv[2])){console.error("USAGE: --check | --apply");process.exit(2);}
 else main(process.argv[2]).catch(e=>{
   const reason=e instanceof Error?e.message:"UNKNOWN";
   const safe=/^[A-Z0-9_ :,.-]+$/.test(reason)?reason:"MIGRATION_OR_BACKUP_FAILED_REVIEW_PROTECTED_LOGS";
   console.error("ERP_R3_OPERATOR_STOPPED "+safe);
   process.exitCode=1;
 });
}
