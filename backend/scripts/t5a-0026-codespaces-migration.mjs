/**
 * ERP T5-A MANUAL checkout, Codespaces-only production migration operator.
 * Run from backend with: node --experimental-strip-types scripts/t5a-0025-codespaces-migration.mjs --check|--apply
 *
 * Production writes are gated by observed Compute maintenance mode.
 * A private, encrypted durable backup and its isolated read-back/restore are
 * mandatory before applying versioned migration 0025.
 * NEVER print credentials, SQL driver errors, dump contents, or commercial rows.
 */
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { spawnSync, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, writeFileSync, rmSync, statSync, chmodSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { Pool } from "pg";
import { applyMigrations } from "../src/migrate.ts";

export const BASE = ["0001_identity.sql","0002_mutation_control.sql","0003_warehouse_scope.sql",
 "0004_auth_sessions.sql","0005_admin_revision_throttle.sql","0006_catalog.sql",
 "0007_catalog_controls.sql","0008_sales_orders.sql","0009_r1_catalog_pricing.sql",
 "0010_r1_sales_price_snapshot.sql","0011_r3_inventory_ledger.sql",
 "0012_r3_purchase_receipt.sql","0013_r3_transfer_in_transit.sql",
 "0014_r3_stocktake.sql","0015_r1_unit_dictionary.sql","0016_r1_product_media.sql",
 "0017_r1a_customer_directories.sql","0018_r1c_price_list_assignment.sql",
 "0019_p0_price_order_parity.sql","0020_catalog_hierarchy_locations.sql","0021_t0_partial_reservation_policy.sql","0022_t1_sales_order_context.sql","0023_t6_pos_checkout.sql","0024_t3b_manual_direct_issue.sql","0025_t3c_trip_preparation_dispatch.sql"];
export const RELEASE = ["0026_t5a_sales_execution.sql"];
const PROJECT="proj_ud3b1s5yn03vh0zp9cbs2upa";
const DATABASE="db_jg2bl98hzi1jm06lwo0i4rqx";
// Prisma Console display name differs from its opaque S3 provider bucket name.
// Verified from the Prisma Object Store bucket API for the approved project.
export const BUCKET_S3_NAME="user-hccjgwl892edb91ox3v3j5b2";
const API="https://gh30k50bvsc0o9298w9leivf.sin.prisma.build";
const BASE_TABLES=["inventory_storage_location","inventory_product_lot","inventory_product_tracking","inventory_scope_assignment","sales_direct_issue","sales_direct_issue_line","sales_trip_preparation","sales_trip_preparation_line","sales_trip_dispatch","sales_trip_dispatch_line","installation","branch","warehouse","app_user","app_role",
 "schema_migrations","role_permission","inventory_ledger","catalog_product","catalog_unit",
 "catalog_customer","catalog_sku_barcode","catalog_unit_definition","catalog_product_media",
 "catalog_customer_group","catalog_customer_region","catalog_price_list",
 "inventory_reservation","inventory_guard_policy","catalog_brand","catalog_product_category","catalog_customer_location","sales_order","sales_order_version","sales_order_line","sales_walk_in_customer","sales_order_version_context","sales_order_entry_preference","retail_shift","sales_fulfillment","retail_checkout","customer_receivable_ledger","payment_receipt","payment_allocation","retail_return"];
const REQUIRED_NEW=["sales_manual_return","sales_manual_return_line","sales_manual_delivery_line"];
const APPROVAL="OWNER_APPROVED_T5A_0026_ERP_DB";
const CLEAN_EXCEPT=new Set(["backend/package-lock.json","backend/deploy/package-lock.json"]);

function fail(code){throw new Error(code);}
let terminationSignal=null;
// Catchable SIGINT/SIGTERM mark a fail-closed abort. No forced process.exit:
// async finally must revoke the target credential, shred temporary files and
// delete Docker's anonymous plaintext volume. SIGKILL is not catchable.
export function assertNotInterrupted(signal){
 if(signal)fail("ERP_T5A_INTERRUPTED_CLEANUP_REQUIRED");
}
async function checkpoint(){
 // Yield to the event loop so pending OS signal handlers can run after spawnSync.
 await new Promise(resolve=>setImmediate(resolve));
 assertNotInterrupted(terminationSignal);
}
export function restoreContainerCleanupArgs(name){
 if(!/^erp-t5a-pg-[0-9a-f]{12}$/.test(name))
  fail("INVALID_ISOLATED_RESTORE_CONTAINER_ID");
 return ["rm","--force","--volumes",name];
}
function required(e,names){const missing=names.filter(n=>!e[n]);if(missing.length)fail("REQUIRED_CODESPACES_SECRETS_MISSING: "+missing.join(","));}
// Prevent any later 0026+ migration from silently being applied by this operator.
export function assertExactOperatorMigrationFiles(files){
 const present=files.filter(x=>/^\d{4}_[a-z0-9_]+\.sql$/.test(x)).sort();
 if(JSON.stringify(present)!==JSON.stringify([...BASE,...RELEASE]))
  fail("T5A_OPERATOR_MIGRATION_FILES_MISMATCH");
}
export function checkVersions(versions,stage){
 const wanted=stage==="before"?BASE:[...BASE,...RELEASE];
 if(JSON.stringify(versions)!==JSON.stringify(wanted))fail("ERP_DB_MIGRATION_DRIFT_"+stage.toUpperCase());
}
export function canonicalRemote(remote){
 return /^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)gustavjung24-ops\/ERP(?:\.git)?$/.test(remote.trim());
}
export function checkOperator(e,branch,sha,remote,changes,apply=false){
 if(e.CODESPACES!=="true"||!e.CODESPACE_NAME||
    !String(e.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN??"").endsWith("app.github.dev")||
    !/^ghu_[A-Za-z0-9_]{10,}$/.test(e.GITHUB_TOKEN??"")||
    e.GITHUB_REPOSITORY!=="gustavjung24-ops/ERP"||
    e.GITHUB_USER!=="gustavjung24-ops"||
    e.GITHUB_ACTIONS==="true"||e.CI==="true"||
    branch!=="main"||!canonicalRemote(remote))
   fail("ONLY_AUTHENTICATED_PRIMARY_MAIN_CODESPACES");
 if(!/^[a-f0-9]{40}$/.test(sha)||e.ERP_APPROVED_SHA!==sha)
   fail("EXACT_MAIN_SHA_APPROVAL_MISSING");
 if(changes.some(path=>!CLEAN_EXCEPT.has(path)))
   fail("WORKTREE_CHANGES_NOT_APPROVED");
 if(apply&&(e.ERP_T5A_MIGRATION_APPROVAL!==APPROVAL||
    e.ERP_TARGET_PROJECT_ID!==PROJECT||e.ERP_TARGET_DATABASE_ID!==DATABASE))
   fail("OWNER_T5A_TARGET_APPROVAL_MISSING");
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
    record?.repository?.full_name!=="gustavjung24-ops/ERP"||
    record?.owner?.login!=="gustavjung24-ops")
   fail("CODESPACES_IDENTITY_ATTESTATION_FAILED");
}
function verifyCodespaceSession(e){
 if(!git(["rev-parse","--show-toplevel"]).startsWith("/workspaces/ERP"))
   fail("CODESPACES_REPO_MOUNT_INVALID");
 // GitHub documents a short-lived ghu_ session token created on Codespaces
 // start. It is REQUIRED here; local gh credential-store authentication alone
 // cannot satisfy this check. Never print, persist, or pass it in argv.
 let record;
 try{
  record=JSON.parse(command("gh",["api","/user/codespaces/"+e.CODESPACE_NAME],
    {GH_TOKEN:e.GITHUB_TOKEN,GH_HOST:"github.com"}));
 }catch{fail("CODESPACES_SESSION_TOKEN_ATTESTATION_UNAVAILABLE");}
 checkCodespaceRecord(record,e.CODESPACE_NAME);
}
/**
 * Proof of the current PROCESS's location: GitHub's private forwarded-port
 * hostname routes to sockets inside the actual Codespace VM. A copied user
 * token can authenticate remotely but CANNOT route a local socket through
 * that VM. We start a fresh, unpredictable challenge server in THIS process
 * and require the remote GitHub tunnel to reach it over HTTPS.
 * Codespaces auto-forward when the terminal sees a localhost URL.
 * Failure is closed; never fall back to a local port-only probe.
 */
export async function attestProcessCodespace(e,{fetcher=fetch,port=0,maxAttempts=25}={}){
 const name=e.CODESPACE_NAME,domain=e.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN;
 if(!/^[a-z0-9-]{5,128}$/.test(name??"")||domain!=="app.github.dev")
   fail("CODESPACES_PORT_OR_NAME_INVALID");
 const nonce=randomBytes(32).toString("hex");
 const server=createServer((req,res)=>{
  if(req.method!=="GET"||req.url!=="/erp-t5a-attestation/"+nonce){
   res.writeHead(404).end();return;
  }
  res.writeHead(200,{"content-type":"text/plain; charset=utf-8","cache-control":"no-store"}).end(nonce);
 });
 await new Promise((resolveListen,rejectListen)=>{
  server.once("error",rejectListen);
  server.listen(port,"0.0.0.0",resolveListen);
 });
 const assigned=server.address()?.port;
 try{
  if(!Number.isInteger(assigned)||assigned<1024)
    fail("CODESPACES_ATTESTATION_PORT_UNAVAILABLE");
  // The Codespaces VS Code runtime detects this URL and forwards the port.
  console.log("CODESPACES_FORWARD_ATTESTATION http://localhost:"+assigned);
  const url="https://"+name+"-"+assigned+"."+domain+
    "/erp-t5a-attestation/"+nonce;
  for(let attempt=0;attempt<maxAttempts;attempt++){
   try{
    const response=await fetcher(url,{
     headers:{"X-Github-Token":e.GITHUB_TOKEN},
     redirect:"manual",signal:AbortSignal.timeout(2500)});
    if(response.status===200&&(await response.text())===nonce){
     console.log("CODESPACES_RUNNING_PROCESS_TUNNEL_ATTESTED");
     return;
    }
   }catch{}
   await new Promise(ok=>setTimeout(ok,900));
  }
  fail("CODESPACES_PROCESS_TUNNEL_ATTESTATION_FAILED");
 }finally{
  await new Promise(ok=>server.close(ok));
 }
}
function safeURL(raw){
 let u;try{u=new URL(raw);}catch{fail("INVALID_DIRECT_DATABASE_URL");}
 if(!["postgresql:","postgres:"].includes(u.protocol)||
    u.hostname!=="db.prisma.io"||u.searchParams.get("sslmode")!=="require"||
    !u.password||!u.username||u.pathname.length<2)
    fail("DIRECT_PRISMA_ERP_DB_TLS_URL_REQUIRED");
 return u;
}
// The CLI generates a one-time credential scoped by Prisma to the exact
// project + database IDs. A caller-supplied generic db.prisma.io URL is NEVER
// accepted as proof of ERP-DB identity.
function prismaCli(args){
 const p=spawnSync("npx",["--no-install","prisma",...args,"--json"],{
  cwd:resolve("deploy"),encoding:"utf8",env:process.env,
  maxBuffer:4*1024*1024,timeout:60000,stdio:["ignore","pipe","pipe"]});
 if(p.error||p.status!==0)fail("PRISMA_OPERATOR_CLI_FAILED");
 const envelope=p.stdout.split(/\r?\n/).map(line=>{
  try{return JSON.parse(line);}catch{return null;}
 }).find(x=>x?.kind==="result")?.envelope;
 if(!envelope||envelope.ok!==true)fail("PRISMA_OPERATOR_CLI_RESULT_FAILED");
 return envelope.result;
}
export function parsePrismaCredential(payload){
 const id=payload?.connection?.id;
 const raw=payload?.connectionString;
 if(!/^con_[a-z0-9]+$/i.test(id??"")||typeof raw!=="string")
   fail("ERP_DB_ONE_TIME_CREDENTIAL_MISSING");
 let url;
 try{url=new URL(raw);}catch{fail("ERP_DB_ONE_TIME_CREDENTIAL_INVALID");}
 if(url.hostname==="pooled.db.prisma.io")url.hostname="db.prisma.io";
 return {id,url:safeURL(url.toString())};
}
// A minted Prisma credential must never survive a bad one-time URL response.
// The create result carries its id even if the URL is invalid or incomplete;
// immediately revoke on validation failure, before any pool is constructed.
export function validateMintedCredentialOrRevoke(result,revoke){
 try{return parsePrismaCredential(result);}
 catch(original){
  const id=result?.connection?.id;
  if(!/^con_[a-z0-9]+$/i.test(id??""))
    fail("CREATED_CREDENTIAL_ID_UNKNOWN_MANUAL_REVOCATION_REQUIRED");
  try{revoke(id);}
  catch{fail("CREATED_CREDENTIAL_VALIDATION_REVOKE_FAILED");}
  throw original;
 }
}
function mintErpDbCredential(){
 const result=prismaCli(["postgres","connection","create",DATABASE,
  "--project",PROJECT]);
 return validateMintedCredentialOrRevoke(result,revokeErpDbCredential);
}
function revokeErpDbCredential(id){
 prismaCli(["postgres","connection","delete",id,"--confirm",id]);
}
function pgEnv(u){
 return {PGHOST:u.hostname,PGPORT:u.port||"5432",
  PGDATABASE:decodeURIComponent(u.pathname.slice(1)),PGUSER:decodeURIComponent(u.username),
  PGPASSWORD:decodeURIComponent(u.password),PGSSLMODE:u.searchParams.get("sslmode")||"require"};
}
export function requirePg17Client(version, binary){
 const major=/^pg_(?:dump|restore) \(PostgreSQL\) (\d+)(?:\.\d+)?(?:\s|$)/.exec(version)?.[1];
 if(major!=="17")fail("POSTGRES_17_CLIENT_REQUIRED_"+binary.toUpperCase().replaceAll("-","_"));
}
export function classifyPgDumpFailure(stderr){
 const problem=String(stderr??"").toLowerCase();
 // Only emit stable classifications; raw stderr can include connection details.
 if(/server version mismatch|aborting because of server version mismatch|server version:.*pg_dump version:/s.test(problem))
  return "PG_DUMP_SERVER_VERSION_MISMATCH";
 if(/password authentication failed|authentication failed|no password supplied/.test(problem))
  return "PG_DUMP_AUTHENTICATION_FAILED";
 if(/permission denied|must be owner|must have permission|insufficient privilege/.test(problem))
  return "PG_DUMP_DATABASE_PERMISSION_DENIED";
 if(/certificate|ssl error|tls error|certificate verify failed/.test(problem))
  return "PG_DUMP_TLS_VERIFY_FAILED";
 if(/could not translate host name|connection refused|could not connect|timeout expired|network is unreachable|no route to host/.test(problem))
  return "PG_DUMP_CONNECTION_FAILED";
 if(/serializable|deferrable|transaction isolation/.test(problem))
  return "PG_DUMP_SNAPSHOT_MODE_UNSUPPORTED";
 return "PG_DUMP_FAILED_DETAILS_REDACTED";
}
export function classifyAwsFailure(stderr){
 const message=String(stderr??"").toLowerCase();
 if(/nosuchbucket|the specified bucket does not exist|bucket name does not exist/.test(message))
  return "BUCKET_NOT_FOUND";
 if(/invalidaccesskeyid|invalid access key id|invalidclienttokenid/.test(message))
  return "ACCESS_KEY_INVALID";
 if(/signaturedoesnotmatch|signature mismatch|invalidsignature|requesttime.tooskewed/.test(message))
  return "SIGNATURE_OR_REGION_MISMATCH";
 if(/accessdenied|403 forbidden|explicit deny|not authorized/.test(message))
  return "ACCESS_DENIED";
 if(/could not connect to the endpoint url|endpointconnectionerror|name or service not known|nodename nor servname provided/.test(message))
  return "ENDPOINT_UNREACHABLE";
 if(/ssl validation failed|certificate verify failed|certificate_verify_failed/.test(message))
  return "TLS_CERTIFICATE_INVALID";
 if(/timeout|timed out|connection reset/.test(message))
  return "NETWORK_TIMEOUT";
 return "FAILED_DETAILS_REDACTED";
}
function dumpBaseDatabase(dump,u){
 const x=spawnSync("pg_dump",["--format=custom","--no-owner","--no-acl",
  "--serializable-deferrable","--file="+dump],{
    encoding:"utf8",env:{...process.env,...pgEnv(u)},
    maxBuffer:4*1024*1024,timeout:600000,stdio:["ignore","pipe","pipe"]});
 if(x.error||x.status!==0)fail(classifyPgDumpFailure(x.stderr));
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
const T5A_PERMISSIONS=[];
async function verifyOverrideGrants(pool,stage){
 const current=(await pool.query(`SELECT rp.installation_id::text,rp.role_id::text,rp.permission_code
  FROM role_permission rp WHERE rp.permission_code=ANY($1::text[])
  ORDER BY rp.installation_id,rp.role_id,rp.permission_code`,[T5A_PERMISSIONS])).rows;
 const expected=stage==="before"?[]:(await pool.query(`SELECT r.installation_id::text,r.id::text AS role_id,p.code AS permission_code
  FROM app_role r CROSS JOIN unnest($1::text[]) p(code) WHERE r.code='PRIMARY_OWNER_MAIN'
  ORDER BY r.installation_id,r.id,p.code`,[T5A_PERMISSIONS])).rows;
 if(JSON.stringify(current)!==JSON.stringify(expected))fail("T5A_GRANT_RECONCILIATION_FAILED");
}
/** Preserve every existing 0025 row while adding 0026 schema only. */
export function preservedRowJsonExpression(table){
 return table==="payment_receipt"?"(to_jsonb(x) - 'fulfillment_id')":"to_jsonb(x)";
}
async function signature(pool,exclusions=[]){
 const tables=(await pool.query(
 "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name"
 )).rows.map(x=>x.table_name).filter(x=>!exclusions.includes(x));
 const result={};
 for(const table of tables){
  const safe=table.replaceAll('"','""');
  const sql='SELECT count(*)::text AS n,'+
   'COALESCE(bit_xor(hashtextextended('+preservedRowJsonExpression(table)+'::text,0))::text,\'0\') AS xor,'+
   'COALESCE(sum(hashtextextended('+preservedRowJsonExpression(table)+'::text,1)::numeric)::text,\'0\') AS total '+
   'FROM public."'+safe+'" x'+(table==="role_permission"?" WHERE NOT (permission_code=ANY($1::text[]))":"");
  result[table]=(await pool.query(sql,table==="role_permission"?[T5A_PERMISSIONS]:[])).rows[0];
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
 const names=stage==="before"?BASE_TABLES:REQUIRED_NEW;
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
// Block stale source SHA even with a correct local checkout.
export function checkPrimaryMainSha(actual, expected){
 if(!/^[a-f0-9]{40}$/.test(actual??"")||actual!==expected)
  fail("PRIMARY_MAIN_SHA_MOVED_OR_UNVERIFIED");
}
function attestPrimaryMainSha(e, sha){
 let branch;
 try{branch=JSON.parse(command("gh",["api","/repos/gustavjung24-ops/ERP/branches/main"],
   {GH_TOKEN:e.GITHUB_TOKEN,GH_HOST:"github.com"}));}
 catch{fail("PRIMARY_MAIN_READBACK_FAILED");}
 checkPrimaryMainSha(branch?.commit?.sha,sha);
}
// The additive release must preserve every preexisting row and permission.
export function assertT5aSchemaState(row,empty=false){
 if(!row||row.tables!=="3"||row.guards!=="11"||row.invalid_links!=="0"||
  row.payment_source_columns!=="1"||(empty&&row.new_rows!=="0"))
   fail("T5A_SCHEMA_RECONCILIATION_FAILED");
}
async function verifyT5aSchema(pool,empty=false){
 const r=await pool.query(`SELECT
  (SELECT count(*)::text FROM information_schema.tables WHERE table_schema='public'
   AND table_name IN ('sales_manual_return','sales_manual_return_line','sales_manual_delivery_line')) AS tables,
  (SELECT count(*)::text FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='O'
   AND tgname IN ('t5a_return_line_guard','t5a_return_ledger_guard',
    't5a_return_commit_guard','t5a_return_immutable',
    't5a_return_line_immutable','t5a_delivery_line_immutable',
    't5a_allocation_guard','t5a_fulfillment_commit_guard',
    't5a_receipt_commit_guard','t5a_return_header_commit_guard',
    't5a_manual_fulfillment_order_lock')) AS guards,
  (SELECT count(*)::text FROM information_schema.columns WHERE
   table_schema='public' AND table_name='payment_receipt'
   AND column_name='fulfillment_id') AS payment_source_columns,
  (SELECT count(*)::text FROM (
   SELECT l.return_id FROM sales_manual_return_line l LEFT JOIN sales_manual_return h
    ON h.installation_id=l.installation_id AND h.branch_id=l.branch_id
    AND h.id=l.return_id WHERE h.id IS NULL
   UNION ALL
   SELECT l.fulfillment_id FROM sales_manual_delivery_line l
    LEFT JOIN sales_fulfillment f ON f.installation_id=l.installation_id
    AND f.branch_id=l.branch_id AND f.id=l.fulfillment_id WHERE f.id IS NULL
  ) invalid) AS invalid_links,
  ((SELECT count(*) FROM sales_manual_return)+
   (SELECT count(*) FROM sales_manual_return_line)+
   (SELECT count(*) FROM sales_manual_delivery_line))::text AS new_rows`);
 assertT5aSchemaState(r.rows[0],empty);
}

async function main(mode){
 const e=process.env;
 assertExactOperatorMigrationFiles(readdirSync(resolve("db/migrations")));
 const sha=git(["rev-parse","HEAD"]),branch=git(["branch","--show-current"]);
 const remote=git(["remote","get-url","origin"]);
 const tracked=git(["status","--porcelain","--untracked-files=all"]);
 const changes=tracked.split("\n").filter(Boolean).map(x=>x.slice(3));
 checkOperator(e,branch,sha,remote,changes,mode==="--apply");
 verifyCodespaceSession(e);
 attestPrimaryMainSha(e,sha);
 await attestProcessCodespace(e);
 await checkpoint();
 required(e,["ERP_APPROVED_SHA"]);
 if(mode==="--apply")await maintenance();
 const credential=mintErpDbCredential();
 const u=credential.url;
 let pool;
 try{
  pool=new Pool({connectionString:u.toString(),max:1,
   connectionTimeoutMillis:20000,statement_timeout:300000,query_timeout:300000});
  pool.on("error",()=>console.error("ERP_T5A_POSTGRES_POOL_DISCONNECTED"));
 }catch{
  revokeErpDbCredential(credential.id);
  fail("ERP_T5A_DB_POOL_INITIALIZATION_FAILED");
 }
 let tmp,container;
 try{
  const v=await versions(pool);
  if(v.length===26){await validateSchema(pool,"after");await verifyT5aSchema(pool);
    // Existing assignments may now contain live rows; a completed migration
    // is not expected to remain empty on subsequent read-only checks.
    console.log("ERP_T5A_ALREADY_MIGRATED_26");return;}
  await validateSchema(pool,"before");
  // Only migration history changes; reconcile every existing business table.
  const excluded=["schema_migrations"];
  await verifyOverrideGrants(pool,"before");
  const initial=await signature(pool,excluded);
  console.log("ERP_T5A_BASE_0025_CHECKSUM_AND_DATA_PREFLIGHT_PASS "+sha.slice(0,12));
  if(mode==="--check"){console.log("ERP_T5A_CHECK_ONLY_NO_DATABASE_WRITES");return;}
  required(e,["AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","ERP_BACKUP_S3_ENDPOINT",
    "ERP_AGE_RECIPIENT","ERP_AGE_RECOVERY_IDENTITY"]);
  const endpoint=new URL(e.ERP_BACKUP_S3_ENDPOINT);
  if(endpoint.protocol!=="https:"||endpoint.pathname!=="/"||endpoint.search)fail("S3_TLS_ENDPOINT_REQUIRED");
  // All external prerequisites must exist before creating the first production artifact.
  for(const tool of ["pg_dump","pg_restore","pg_isready","age","age-keygen","aws","docker"]){
   const version=command(tool,["--version"]);
   if(tool==="pg_dump"||tool==="pg_restore")requirePg17Client(version,tool);
  }
  if(!/^age1[0-9a-z]{30,}$/.test(e.ERP_AGE_RECIPIENT))
   fail("INVALID_OFFLINE_BACKUP_RECIPIENT");
  tmp=mkdtempSync(join(tmpdir(),"erp-t5a-recovery-"));
  chmodSync(tmp,0o700);
  const dump=join(tmp,"baseline.dump"),encrypted=join(tmp,"baseline.dump.age");
  const portableList=join(tmp,"portable-restore.list");
  const durableCopy=join(tmp,"durable-readback.age");
  const key=join(tmp,"production-recovery.agekey");
  const recovered=join(tmp,"verified-durable.dump");
  writeFileSync(key,e.ERP_AGE_RECOVERY_IDENTITY.trim()+"\n",{mode:0o600});
  const actualRecipient=command("age-keygen",["-y",key]).trim();
  if(actualRecipient!==e.ERP_AGE_RECIPIENT)
    fail("DURABLE_BACKUP_PRIVATE_KEY_RECIPIENT_MISMATCH");
  const base="s3://"+BUCKET_S3_NAME+"/erp-db/T5A/"+sha+"/" +
    Date.now().toString()+"-"+randomUUID()+"/";
  const aws=(action,source,dest)=>{
    const x=spawnSync("aws",[
      "--endpoint-url",endpoint.origin,"s3","cp",source,dest,"--only-show-errors"
    ],{encoding:"utf8",
      env:{...process.env,AWS_EC2_METADATA_DISABLED:"true",AWS_DEFAULT_REGION:"ap-southeast-1"},
      maxBuffer:4*1024*1024,timeout:600000,stdio:["ignore","pipe","pipe"]});
    if(x.error||x.status!==0)fail("ERP_T5A_S3_"+action.toUpperCase()+"_"+classifyAwsFailure(x.stderr));
  };
  // PgDump snapshot alone is not a release gate: read back, decrypt and RESTORE.
  dumpBaseDatabase(dump,u);
  await checkpoint();
  if(statSync(dump).size<256)fail("ERP_BACKUP_TOO_SMALL");
  command("age",["-r",e.ERP_AGE_RECIPIENT,"-o",encrypted,dump]);
  aws("upload",encrypted,base+"pre-0026.dump.age");
  aws("download",base+"pre-0026.dump.age",durableCopy);
  await checkpoint();
  if(fileHash(encrypted)!==fileHash(durableCopy))fail("DURABLE_BACKUP_READBACK_HASH_MISMATCH");
  const durableHash=fileHash(encrypted);
  // Decrypt the ACTUAL durable object using its actual recovery identity.
  // A separate ephemeral test key proves nothing about durable recoverability.
  command("age",["-d","-i",key,"-o",recovered,durableCopy]);
  await checkpoint();
  if(fileHash(dump)!==fileHash(recovered))
    fail("DURABLE_BACKUP_DECRYPT_RESTORE_HASH_MISMATCH");
  console.log("ERP_T5A_DURABLE_BACKUP_AND_READBACK_PASS key="+base+"pre-0026.dump.age sha256="+durableHash);
  // Separate PG17 Docker service: no restore, truncate or schema mutation on ERP-DB.
  const name="erp-t5a-pg-"+randomBytes(6).toString("hex");
  const password=randomBytes(24).toString("hex");
  let started=false;
  try{
   // Supply synthetic DB password as environment, never in process arguments.
   command("docker",["run","-d","--name",name,"-e","POSTGRES_USER=erp_rehearsal",
    "-e","POSTGRES_PASSWORD","-e","POSTGRES_DB=erp_t5a_restore",
    "-p","127.0.0.1::5432","postgres:17"],{POSTGRES_PASSWORD:password});
   started=true;
   const port=command("docker",["port",name,"5432/tcp"]).match(/127\.0\.0\.1:(\d+)/)?.[1];
   if(!port)fail("REHEARSAL_DOCKER_PORT_MISSING");
   const env={PGHOST:"127.0.0.1",PGPORT:port,PGUSER:"erp_rehearsal",
    PGPASSWORD:password,PGDATABASE:"erp_t5a_restore",PGSSLMODE:"disable"};
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
   const portable=listing.filter(x=>!/\bEXTENSION - |\bCOMMENT - EXTENSION /.test(x));
   writeFileSync(portableList,portable.join("\n"),{mode:0o600});
   command("pg_restore",["--no-owner","--no-acl","--exit-on-error",
      "--single-transaction","--use-list="+portableList,
      "--dbname=erp_t5a_restore",recovered],env);
   await checkpoint();
   const testPool=new Pool({host:"127.0.0.1",port:Number(port),user:env.PGUSER,
     password,database:env.PGDATABASE,max:1,statement_timeout:300000,query_timeout:300000});
   try{
    await validateSchema(testPool,"before");
    await verifyOverrideGrants(testPool,"before");
    checkPreserved(initial,await signature(testPool,excluded),"RESTORE");
    const rehearsal=await applyMigrations(testPool,resolve("db/migrations"));
    if(JSON.stringify(rehearsal.applied)!==JSON.stringify(RELEASE)||rehearsal.skipped.length!==25)
      fail("REHEARSAL_MIGRATION_SET_INVALID");
    await validateSchema(testPool,"after");
    await verifyT5aSchema(testPool,true);
    await verifyOverrideGrants(testPool,"after");
    checkPreserved(initial,await signature(testPool,excluded),
     "REHEARSAL");
   }finally{await testPool.end();}
  }finally{if(started)command("docker",restoreContainerCleanupArgs(name));}
  console.log("ERP_T5A_ISOLATED_RESTORE_AND_0025_REHEARSAL_PASS");
  await checkpoint();
  // No production SQL is issued before all previous gates have passed.
  await maintenance();
  await checkpoint();
  await validateSchema(pool,"before");
  await verifyOverrideGrants(pool,"before");
  checkPreserved(initial,await signature(pool,excluded),"PRODUCTION_PRECOMMIT");
  await checkpoint();
  const result=await applyMigrations(pool,resolve("db/migrations"));
  if(JSON.stringify(result.applied)!==JSON.stringify(RELEASE)||result.skipped.length!==25)
    fail("PRODUCTION_APPLIED_VERSION_SET_INVALID");
  await checkpoint();
  await validateSchema(pool,"after");
  await verifyT5aSchema(pool,true);
  await verifyOverrideGrants(pool,"after");
  checkPreserved(initial,await signature(pool,excluded),
   "PRODUCTION");
  console.log("ERP_T5A_0026_MIGRATION_PASS_AND_RECONCILED");
  console.log("ERP_T5A_BACKUP_OBJECT "+base+"pre-0026.dump.age");
  console.log("ERP_T5A_BACKUP_SHA256 "+durableHash);
 }finally{
  let cleanupFailed=false;
  try{await pool.end();}catch{cleanupFailed=true;}
  try{if(tmp)rmSync(tmp,{recursive:true,force:true});}catch{cleanupFailed=true;}
  try{revokeErpDbCredential(credential.id);}catch{cleanupFailed=true;}
  if(cleanupFailed)fail("ERP_T5A_CREDENTIAL_OR_TEMP_CLEANUP_UNVERIFIED");
 }
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 if(!["--check","--apply"].includes(process.argv[2])){console.error("USAGE: --check | --apply");process.exit(2);}
 else {
  const handleSignal=signal=>{
   if(terminationSignal)return;
   terminationSignal=signal;
   process.exitCode=signal==="SIGINT"?130:143;
   console.error("ERP_T5A_INTERRUPT_RECEIVED_CLEANUP_PENDING");
  };
  const onInt=()=>handleSignal("SIGINT"),onTerm=()=>handleSignal("SIGTERM");
  process.on("SIGINT",onInt);
  process.on("SIGTERM",onTerm);
  main(process.argv[2]).catch(e=>{
   const reason=e instanceof Error?e.message:"UNKNOWN";
   const safe=/^[A-Z0-9_ :,.-]+$/.test(reason)?reason:"MIGRATION_OR_BACKUP_FAILED_REVIEW_PROTECTED_LOGS";
   console.error("ERP_T5A_OPERATOR_STOPPED "+safe);
   process.exitCode ||= 1;
  }).finally(()=>{
   process.off("SIGINT",onInt);
   process.off("SIGTERM",onTerm);
  });
 }
}
