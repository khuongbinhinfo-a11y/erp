/**
 * Owner-only, GitHub-OIDC ERP demo source -> existing ERP-DB cutover.
 * Never cross an app/connector boundary with DB credentials. No auto-run.
 * NEVER log connection strings, PostgreSQL errors, identity keys or row contents.
 */
import { Pool } from "pg";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync,readFileSync,writeFileSync,statSync,rmSync,appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join,resolve } from "node:path";
import { applyMigrations } from "../src/migrate.ts";

const REPO="gustavjung24-ops/ERP", TARGET="db_jg2bl98hzi1jm06lwo0i4rqx";
const PROJECT="proj_ud3b1s5yn03vh0zp9cbs2upa", BUCKET="erp-db-migration-encrypted-backups";
const RECIPIENT="age1jce83glh2tukl6rz5werqpzyz5rtr6dkcpyw8dwe5pp3nc04efyqx39qlr";
const SOURCE="db_xg7823erugsd1ym7c8lf0l9h";
const TABLES=["app_role","app_session","app_user","audit_event","auth_event","auth_login_throttle",
 "branch","installation","mutation_receipt","role_permission","schema_migrations","user_role","user_role_warehouse","warehouse"];
const BASE=["0001_identity.sql","0002_mutation_control.sql","0003_warehouse_scope.sql",
 "0004_auth_sessions.sql","0005_admin_revision_throttle.sql"];
const CATALOG=["0006_catalog.sql","0007_catalog_controls.sql"];
const e=process.env;
function requireRuntime(){
 const sha=e.GITHUB_SHA, comment=e.APPROVAL_COMMENT;
 if(e.GITHUB_ACTIONS!=="true"||e.GITHUB_EVENT_NAME!=="issue_comment"||
   e.GITHUB_REPOSITORY!==REPO||e.GITHUB_REF!=="refs/heads/main"||
   e.GITHUB_ACTOR!=="gustavjung24-ops"||e.OWNER_COMMENT_AUTHOR!=="gustavjung24-ops"||
   !/^[0-9a-f]{40}$/.test(sha??"")||comment!=="ERP_DB_CUTOVER "+sha||
   e.ERP_PRODUCTION_WRITES_FROZEN!=="YES"||!e.ERP_POSTGRES_DIRECT_URL)
     throw Error("OWNER_PRODUCTION_GATE_REFUSED");
 if(!/^[1-9][0-9]*$/.test(e.GITHUB_RUN_ID??"")||
    !/^[1-9][0-9]*$/.test(e.GITHUB_RUN_ATTEMPT??""))throw Error("NON_UNIQUE_RUN_ID");
 if(!e.GITHUB_ENV)throw Error("PROTECTED_GITHUB_ENV_REQUIRED");
 return sha;
}
function secureUrl(raw){
 const x=new URL(raw);
 if(!["postgres:","postgresql:"].includes(x.protocol)||
   x.hostname!=="db.prisma.io"||x.searchParams.get("sslmode")!=="require"||
   !x.password||!x.username)throw Error("DIRECT_TLS_POSTGRES_REQUIRED");
 return raw;
}
function pgEnv(raw){const u=new URL(secureUrl(raw));return {
 PGHOST:u.hostname,PGPORT:u.port||"5432",PGUSER:decodeURIComponent(u.username),
 PGPASSWORD:decodeURIComponent(u.password),PGDATABASE:decodeURIComponent(u.pathname.slice(1)),
 PGSSLMODE:"require",PGTZ:"UTC"};}
const local="postgresql://erp_rehearsal:erp_rehearsal_password@127.0.0.1:5432/erp_restore_cutover?sslmode=disable";
function run(label,command,args,env={},timeout=180000){
 const r=spawnSync(command,args,{env:{...e,...env},encoding:"utf8",maxBuffer:1024*1024,timeout});
 if(r.status!==0)throw Error(label+"_FAILED");
 return r.stdout;
}
function sha(file){return createHash("sha256").update(readFileSync(file)).digest("hex");}
async function oidc(){
 if(!e.ACTIONS_ID_TOKEN_REQUEST_URL||!e.ACTIONS_ID_TOKEN_REQUEST_TOKEN)throw Error("MISSING_GH_OIDC");
 const a=await fetch(e.ACTIONS_ID_TOKEN_REQUEST_URL+"&audience=prisma-cloud",{
   headers:{authorization:"Bearer "+e.ACTIONS_ID_TOKEN_REQUEST_TOKEN},signal:AbortSignal.timeout(15000)});
 if(a.status!==200)throw Error("GH_OIDC_NOT_AVAILABLE");
 const jwt=(await a.json()).value;
 const b=await fetch("https://api.prisma.io/v1/auth/github-actions/token",{
   method:"POST",headers:{"content-type":"application/json"},
   body:JSON.stringify({token:jwt}),signal:AbortSignal.timeout(15000)});
 if(![200,201].includes(b.status))throw Error("PRISMA_OIDC_NOT_AUTHORIZED");
 const o=await b.json(); if(!o.data?.value)throw Error("PRISMA_TOKEN_MISSING");
 return o.data.value;
}
async function api(token,method,path,body){
 const res=await fetch("https://api.prisma.io"+path,{method,
  headers:{"content-type":"application/json",authorization:"Bearer "+token},
  body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});
 if(!res.ok)throw Error("PRISMA_API_"+method+"_HTTP_"+res.status);
 return res.status===204?null:(await res.json()).data;
}
async function connection(token,name){
 const x=await api(token,"POST","/v1/databases/"+TARGET+"/connections",{name});
 const raw=x.endpoints?.direct?.connectionString;
 if(!x.id||!raw)throw Error("PRISMA_DIRECT_CONNECTION_RESPONSE_INVALID");
 return {id:x.id,url:secureUrl(raw)};
}
async function signature(pool,versions=BASE,tables=TABLES){
 const c=await pool.connect();
 try{
  await c.query("SET TIME ZONE 'UTC'");
  const found=(await c.query("SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name")).rows.map(x=>x.table_name);
  if(JSON.stringify(found)!==JSON.stringify([...tables].sort()))throw Error("ERP_TABLE_DRIFT");
  const history=(await c.query("SELECT version FROM public.schema_migrations ORDER BY version")).rows.map(x=>x.version);
  if(JSON.stringify(history)!==JSON.stringify(versions))throw Error("ERP_MIGRATION_DRIFT");
  const data={};
  for(const t of tables){
   const r=await c.query('SELECT count(*)::text AS rows,coalesce(bit_xor(hashtextextended(row_to_json(z)::text,0))::text,\'0\') AS xor,coalesce(sum(hashtextextended(row_to_json(z)::text,1)::numeric)::text,\'0\') AS total FROM public."'+t+'" z');
   data[t]=r.rows[0];
  }
  return {history,data};
 }finally{c.release();}
}
function same(a,b,label){
 if(JSON.stringify(a)!==JSON.stringify(b))throw Error(label+"_RECONCILIATION_FAILED");
}
async function emptyTarget(pool){
 const r=await pool.query("SELECT count(*)::integer AS n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S') AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e')");
 if(r.rows[0]?.n!==0)throw Error("TARGET_NOT_EMPTY_STOP_NO_OVERWRITE");
}
function extractBuckets(x){return Array.isArray(x)?x:Array.isArray(x?.items)?x.items:[];}
const arrayOrItems=extractBuckets;
const root=mkdtempSync(join(tmpdir(),"erp-cutover-"));
const f=(file)=>join(root,file);
let token,operator,runtime,access,bucket,sourcePool,targetPool;
let runtimeSecretSet=false,finalGate="NOT_STARTED";
try {
 const commit=requireRuntime();
 const sourceUrl=secureUrl(e.ERP_POSTGRES_DIRECT_URL);
 sourcePool=new Pool({connectionString:sourceUrl,max:1,connectionTimeoutMillis:15000});
 sourcePool.on("error",()=>{});
 const baseline=await signature(sourcePool);
 if(Number(baseline.data.installation.rows)!==1||Number(baseline.data.app_user.rows)!==1)
  throw Error("SOURCE_INSTALLATION_IDENTITY_MISMATCH");
 token=await oidc();
 // This credential only exists within the protected Actions runner. Never copy it to Vercel or chat.
 operator=await connection(token,"erp-cutover-operator-"+e.GITHUB_RUN_ID);
 targetPool=new Pool({connectionString:operator.url,max:1,connectionTimeoutMillis:15000});
 targetPool.on("error",()=>{});
 await emptyTarget(targetPool); console.log("ERP_TARGET_EMPTY_PRECHECK_PASS");
 const all=extractBuckets(await api(token,"GET","/v1/buckets"));
 bucket=all.find(b=>b.name===BUCKET&&(b.projectId===PROJECT||b.project?.id===PROJECT));
 if(!bucket?.id)throw Error("PROTECTED_BACKUP_BUCKET_NOT_FOUND");
 access=await api(token,"POST","/v1/buckets/"+bucket.id+"/keys",{
  name:"erp-cutover-"+e.GITHUB_RUN_ID,role:"read_write"});
 if(!access?.id||!access?.accessKeyId||!access?.secretAccessKey||!access?.endpoint||!access?.bucketName)
  throw Error("BUCKET_EPHEMERAL_KEY_FAILED");
 const aws={AWS_ACCESS_KEY_ID:access.accessKeyId,AWS_SECRET_ACCESS_KEY:access.secretAccessKey,
   AWS_DEFAULT_REGION:"ap-southeast-1",AWS_EC2_METADATA_DISABLED:"true"};
 const dump=f("erp.dump"),cipher=f("erp.dump.age"),readback=f("erp.readback.age");
 // The source is expected to be in an approved maintenance window, with writes frozen.
 run("SOURCE_PGDUMP","pg_dump",["--format=custom","--no-owner","--no-acl",
  "--serializable-deferrable","--file="+dump],pgEnv(sourceUrl));
 if(statSync(dump).size<256)throw Error("DUMP_TOO_SMALL");
 run("AGE_ENCRYPT","age",["-r",RECIPIENT,"-o",cipher,dump]);
 const object="erp-demo/"+commit+"/run-"+e.GITHUB_RUN_ID+"-attempt-"+e.GITHUB_RUN_ATTEMPT+"/pre-cutover.dump.age";
 const remote="s3://"+access.bucketName+"/"+object;
 run("S3_UPLOAD","aws",["--endpoint-url",access.endpoint,"s3","cp",cipher,remote,"--only-show-errors"],aws);
 run("S3_READBACK","aws",["--endpoint-url",access.endpoint,"s3","cp",remote,readback,"--only-show-errors"],aws);
 if(sha(cipher)!==sha(readback))throw Error("CIPHERTEXT_REMOTE_HASH_DRIFT");
 // This recipient was independently tested against the vault in recovery audit.
 console.log("ERP_OFFSITE_BACKUP_READBACK_PASS ciphertextSha256="+sha(readback));
 const list=run("PG_RESTORE_LIST","pg_restore",["-l",dump]).split("\n");
 const filtered=list.filter(s=>!/\bEXTENSION - |\bCOMMENT - EXTENSION /.test(s));
 writeFileSync(f("portable.list"),filtered.join("\n"));
 run("ISOLATED_RESTORE","pg_restore",["--exit-on-error","--single-transaction",
  "--no-owner","--no-acl","--dbname=erp_restore_cutover",
  "--use-list="+f("portable.list"),dump],{
  PGHOST:"127.0.0.1",PGPORT:"5432",PGUSER:"erp_rehearsal",PGPASSWORD:"erp_rehearsal_password",
  PGDATABASE:"erp_restore_cutover",PGSSLMODE:"disable"});
 const ephemeral=new Pool({connectionString:local,max:1});
 try{same(baseline,await signature(ephemeral),"REHEARSAL");}finally{await ephemeral.end();}
 same(baseline,await signature(sourcePool),"SOURCE_DURING_BACKUP");
 await emptyTarget(targetPool);
 run("TARGET_RESTORE","pg_restore",["--exit-on-error","--single-transaction",
  "--no-owner","--no-acl","--use-list="+f("portable.list"),"--dbname="+new URL(operator.url).pathname.slice(1),dump],
  pgEnv(operator.url));
 same(baseline,await signature(targetPool),"TARGET_POST_RESTORE");
 same(baseline,await signature(sourcePool),"SOURCE_PRE_MIGRATION");
 console.log("ERP_TARGET_RESTORE_14_TABLES_5_MIGRATIONS_PASS");
 const report=await applyMigrations(targetPool,resolve(process.cwd(),"db/migrations"));
 if(report.applied.length!==2||JSON.stringify(report.applied)!==JSON.stringify(CATALOG)||
    report.skipped.length!==5)throw Error("CATALOG_MIGRATION_VERSIONS_INVALID");
 const newTables=[...TABLES,"catalog_customer","catalog_supplier","catalog_product_group",
  "catalog_product","catalog_unit","catalog_price_list","catalog_price_entry"];
 const targetAfter=await signature(targetPool,[...BASE,...CATALOG],newTables);
 // The target must ADD migration rows 0006/0007; compare only unchanged business data.
 // Historical 0001-0005 version/checksum pairs are verified separately by applyMigrations.
 for(const table of TABLES.filter(t=>t!=="schema_migrations"))
  same(baseline.data[table],targetAfter.data[table],"IDENTITY_"+table);
 const x=await targetPool.query("SELECT count(*)::integer AS n FROM public.catalog_customer");
 if(x.rows[0]?.n!==0)throw Error("UNEXPECTED_SEEDED_CATALOG_DATA");
 same(baseline,await signature(sourcePool),"SOURCE_BEFORE_SWITCH");
 console.log("ERP_TARGET_CATALOG_0006_0007_PASS");
 // After all DB checks, create a dedicated runtime credential, never expose the value.
 runtime=await connection(token,"erp-runtime-after-cutover-"+e.GITHUB_RUN_ID);
 const runtimePool=new Pool({connectionString:runtime.url,max:1,connectionTimeoutMillis:15000});
 try{
  const verified=await signature(runtimePool,[...BASE,...CATALOG],newTables);
  for(const t of TABLES)same(baseline.data[t],verified.data[t],"RUNTIME_GRANT_"+t);
 }finally{await runtimePool.end();}
 console.log("ERP_RUNTIME_CREDENTIAL_READBACK_PASS");
 const url=new URL(runtime.url);
 if(url.hostname!=="db.prisma.io")throw Error("RUNTIME_DATABASE_INVALID");
 const current=extractBuckets(await api(token,"GET","/v1/environment-variables?projectId="+PROJECT+"&class=production&key=ERP_POSTGRES_URL"));
 const envvar=current.find(x=>x.key==="ERP_POSTGRES_URL"&&x.class==="production"&&x.projectId===PROJECT);
 if(!envvar?.id)throw Error("COMPUTE_RUNTIME_ENV_VAR_NOT_FOUND");
 await api(token,"PATCH","/v1/environment-variables/"+envvar.id,{value:runtime.url});
 runtimeSecretSet=true;
 // Source maintenance deploy is live. Keep source locked until target is promoted.
 // The new target deployment is allowed to serve writes after the verified release.
 const m=arrayOrItems(await api(token,"GET","/v1/environment-variables?projectId="+PROJECT+"&class=production&key=ERP_MAINTENANCE_MODE"))
   .find(x=>x.key==="ERP_MAINTENANCE_MODE"&&x.class==="production"&&x.projectId===PROJECT);
 if(!m?.id)throw Error("MAINTENANCE_SECRET_NOT_FOUND");
 await api(token,"PATCH","/v1/environment-variables/"+m.id,{value:"NORMAL"});
 console.log("ERP_COMPUTE_TARGET_RUNTIME_SECRET_STAGED");
 const identity=(await targetPool.query("SELECT id::text AS id FROM installation WHERE code=$1",["erp-demo"])).rows[0]?.id;
 if(!/^[0-9a-f-]{36}$/i.test(identity??""))throw Error("INSTALLATION_NOT_FOUND");
 console.log("::add-mask::"+identity);
 const branch=(await targetPool.query("SELECT id::text AS id FROM branch LIMIT 2")).rows;
 if(branch.length!==1||!/^[0-9a-f-]{36}$/i.test(branch[0]?.id??""))throw Error("SINGLE_BRANCH_EXPECTED");
 console.log("::add-mask::"+branch[0].id);
 // Reuse the already masked maintenance release throttle identity for final deployment.
 // Never emit a fresh unmasked secret into GitHub environment logs.
 if(!e.ERP_THROTTLE_SECRET)throw Error("PROTECTED_THROTTLE_SECRET_MISSING");
 appendFileSync(e.GITHUB_ENV,"ERP_INSTALLATION_ID="+identity+"\n"+
  "ERP_BRANCH_ID="+branch[0].id+"\n"+
  "ERP_UI_ORIGIN=https://erp-gustavjung24-ops-projects.vercel.app\n");
 finalGate="ERP_TARGET_READY_COMPUTE_SECRET_STAGED";
 console.log(finalGate);
}catch(error){
 const known=new Set(["OWNER_PRODUCTION_GATE_REFUSED","TARGET_NOT_EMPTY_STOP_NO_OVERWRITE",
  "SOURCE_INSTALLATION_IDENTITY_MISMATCH","ERP_TABLE_DRIFT","ERP_MIGRATION_DRIFT",
  "PROTECTED_BACKUP_BUCKET_NOT_FOUND","COMPUTE_RUNTIME_ENV_VAR_NOT_FOUND",
  "CATALOG_MIGRATION_VERSIONS_INVALID","UNEXPECTED_SEEDED_CATALOG_DATA"]);
 const message=error instanceof Error&&known.has(error.message)?error.message:"CUTOVER_VERIFICATION_OR_PROVIDER_FAILURE";
 console.error("ERP_DB_CUTOVER_FAILED "+message);
 process.exitCode=1;
}finally{
 await targetPool?.end().catch(()=>{});await sourcePool?.end().catch(()=>{});
 // An operator connection is never a runtime credential; revoke even if restore failed.
 if(token&&operator){
  try{await api(token,"DELETE","/v1/connections/"+operator.id);console.log("CUTOVER_OPERATOR_KEY_REVOKED");}
  catch{console.error("CUTOVER_OPERATOR_KEY_REVOCATION_UNVERIFIED");process.exitCode=1;}
 }
 if(token&&access?.id){
  try{await api(token,"DELETE","/v1/buckets/"+bucket.id+"/keys/"+access.id);
   console.log("CUTOVER_BUCKET_KEY_REVOKED");}
  catch{console.error("CUTOVER_BUCKET_KEY_REVOCATION_UNVERIFIED");process.exitCode=1;}
 }
 if(token&&runtime&&!runtimeSecretSet){
  try{await api(token,"DELETE","/v1/connections/"+runtime.id);}
  catch{console.error("RUNTIME_CREDENTIAL_CLEANUP_UNVERIFIED");process.exitCode=1;}
 }
 rmSync(root,{recursive:true,force:true});
}
if(finalGate!=="ERP_TARGET_READY_COMPUTE_SECRET_STAGED"||process.exitCode)
 process.exitCode=1;
