/**
 * Resume-only ERP demo cutover: target was ALREADY restored and migrated (21 tables/7 versions).
 * Never pg_dump, pg_restore, reapply migrations, seed, or modify either database in this script.
 * Uses GitHub OIDC; operator credentials never leave this protected GitHub runner.
 */
import { Pool } from "pg";
import { appendFileSync } from "node:fs";
import { randomBytes } from "node:crypto";

const e=process.env,PROJECT="proj_ud3b1s5yn03vh0zp9cbs2upa";
const TARGET="db_jg2bl98hzi1jm06lwo0i4rqx";
const BASE=["0001_identity.sql","0002_mutation_control.sql","0003_warehouse_scope.sql",
 "0004_auth_sessions.sql","0005_admin_revision_throttle.sql"];
const EXTRA=["0006_catalog.sql","0007_catalog_controls.sql"];
const TABLES=["app_role","app_session","app_user","audit_event","auth_event","auth_login_throttle",
 "branch","installation","mutation_receipt","role_permission","schema_migrations","user_role",
 "user_role_warehouse","warehouse"];
const NEW=["catalog_customer","catalog_supplier","catalog_product_group","catalog_product",
 "catalog_unit","catalog_price_list","catalog_price_entry"];
function gate(){
 if(e.GITHUB_ACTIONS!=="true"||e.GITHUB_EVENT_NAME!=="issue_comment"||
   e.GITHUB_REPOSITORY!=="gustavjung24-ops/ERP"||
   e.GITHUB_REF!=="refs/heads/main"||e.GITHUB_ACTOR!=="gustavjung24-ops"||
   e.OWNER_COMMENT_AUTHOR!=="gustavjung24-ops"||
   !/^[0-9a-f]{40}$/.test(e.GITHUB_SHA??"")||
   e.APPROVAL_COMMENT!=="ERP_DB_RESUME "+e.GITHUB_SHA||
   !e.ERP_POSTGRES_DIRECT_URL||!e.GITHUB_ENV)
  throw Error("OWNER_RESUME_GATE_REFUSED");
}
function tls(raw){
 const u=new URL(raw);
 if(!["postgresql:","postgres:"].includes(u.protocol)||u.hostname!=="db.prisma.io"||
  u.searchParams.get("sslmode")!=="require"||!u.password)
  throw Error("DIRECT_POSTGRES_TLS_REQUIRED");
 return raw;
}
function rowsOf(x){return Array.isArray(x)?x:Array.isArray(x?.items)?x.items:[];}
async function api(token,method,path,body){
 const r=await fetch("https://api.prisma.io"+path,{method,
  headers:{authorization:"Bearer "+token,"content-type":"application/json"},
  body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});
 if(!r.ok)throw Error("PRISMA_HTTP_"+r.status);
 return r.status===204?null:(await r.json()).data;
}
async function oidc(){
 const x=await fetch(e.ACTIONS_ID_TOKEN_REQUEST_URL+"&audience=prisma-cloud",{
  headers:{authorization:"Bearer "+e.ACTIONS_ID_TOKEN_REQUEST_TOKEN},signal:AbortSignal.timeout(15000)});
 if(x.status!==200)throw Error("GITHUB_OIDC_UNAVAILABLE");
 const jwt=(await x.json()).value;
 const r=await fetch("https://api.prisma.io/v1/auth/github-actions/token",{
  method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({token:jwt}),
  signal:AbortSignal.timeout(15000)});
 if(![200,201].includes(r.status))throw Error("PRISMA_OIDC_UNAVAILABLE");
 const token=(await r.json()).data?.value;
 if(!token)throw Error("PRISMA_OIDC_TOKEN_MISSING");
 return token;
}
async function credential(token,kind){
 const c=await api(token,"POST","/v1/databases/"+TARGET+"/connections",{
  name:"erp-resume-"+kind+"-"+e.GITHUB_RUN_ID});
 const raw=c?.endpoints?.direct?.connectionString;
 if(!c?.id||!raw)throw Error("TARGET_CREDENTIAL_MISSING");
 return {id:c.id,url:tls(raw)};
}
async function evidence(pool,expectedTables,expectedVersions){
 const c=await pool.connect();
 try{
  await c.query("SET TIME ZONE 'UTC'");
  const t=(await c.query("SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name")).rows.map(x=>x.table_name);
  if(JSON.stringify(t)!==JSON.stringify([...expectedTables].sort()))throw Error("TABLE_SET_DRIFT");
  const versions=(await c.query("SELECT version,checksum FROM schema_migrations ORDER BY version")).rows;
  if(JSON.stringify(versions.map(v=>v.version))!==JSON.stringify(expectedVersions))
   throw Error("MIGRATION_HISTORY_DRIFT");
  const data={};
  for(const table of TABLES.filter(x=>x!=="schema_migrations")){
   data[table]=(await c.query('SELECT count(*)::text AS rows,coalesce(bit_xor(hashtextextended(row_to_json(z)::text,0))::text,\'0\') AS xor,coalesce(sum(hashtextextended(row_to_json(z)::text,1)::numeric)::text,\'0\') AS total FROM public."'+table+'" z')).rows[0];
  }
  return {versions,data};
 }finally{c.release();}
}
function eq(a,b,code){if(JSON.stringify(a)!==JSON.stringify(b))throw Error(code+"_RECONCILIATION_FAILED");}
let token,operator,runtime,src,target,runtimeSet=false,passed=false;
try{
 gate();
 src=new Pool({connectionString:tls(e.ERP_POSTGRES_DIRECT_URL),max:1,connectionTimeoutMillis:15000});
 src.on("error",()=>{});
 const original=await evidence(src,TABLES,BASE);
 console.log("ERP_RESUME_SOURCE_5_MIGRATIONS_VERIFIED");
 const live=await fetch("https://gh30k50bvsc0o9298w9leivf.sin.prisma.build/health/live",{
  signal:AbortSignal.timeout(15000),headers:{"cache-control":"no-store"}});
 if(live.status!==200||(await live.json()).maintenance!==true)
  throw Error("CANONICAL_SOURCE_NOT_READ_ONLY");
 token=await oidc();
 operator=await credential(token,"operator");
 target=new Pool({connectionString:operator.url,max:1,connectionTimeoutMillis:15000});
 target.on("error",()=>{});
 const next=await evidence(target,[...TABLES,...NEW],[...BASE,...EXTRA]);
 eq(original.versions,next.versions.slice(0,5),"BASE_MIGRATIONS");
 for(const t of TABLES.filter(x=>x!=="schema_migrations"))
  eq(original.data[t],next.data[t],"SOURCE_TARGET_"+t);
 const qa=await target.query("SELECT (SELECT count(*)::integer FROM catalog_customer) AS customers,(SELECT count(*)::integer FROM catalog_supplier) AS suppliers");
 if(qa.rows[0]?.customers!==0||qa.rows[0]?.suppliers!==0)
  throw Error("CATALOG_UNEXPECTED_NONEMPTY");
 console.log("ERP_RESUME_TARGET_21_TABLES_7_MIGRATIONS_13_DATA_SIGNATURES_PASS");
 runtime=await credential(token,"runtime");
 const app=new Pool({connectionString:runtime.url,max:1,connectionTimeoutMillis:15000});
 try{
  const accessible=await evidence(app,[...TABLES,...NEW],[...BASE,...EXTRA]);
  for(const t of TABLES.filter(x=>x!=="schema_migrations"))
   eq(original.data[t],accessible.data[t],"RUNTIME_GRANT_"+t);
 }finally{await app.end();}
 console.log("ERP_RESUME_RUNTIME_CREDENTIAL_READBACK_PASS");
 eq(original.data, (await evidence(src,TABLES,BASE)).data,"SOURCE_STILL_FROZEN");
 const envs=rowsOf(await api(token,"GET","/v1/environment-variables?projectId="+PROJECT+"&class=production"));
 const current=envs.find(x=>x.key==="ERP_POSTGRES_URL"&&x.class==="production"&&x.projectId===PROJECT);
 const maintenance=envs.find(x=>x.key==="ERP_MAINTENANCE_MODE"&&x.class==="production"&&x.projectId===PROJECT);
 if(!current?.id||!maintenance?.id)throw Error("COMPUTE_ENVIRONMENT_NOT_FOUND");
 await api(token,"PATCH","/v1/environment-variables/"+current.id,{value:runtime.url});
 runtimeSet=true;
 await api(token,"PATCH","/v1/environment-variables/"+maintenance.id,{value:"NORMAL"});
 const install=(await target.query("SELECT id::text FROM installation WHERE code='erp-demo'")).rows;
 const branch=(await target.query("SELECT id::text FROM branch LIMIT 2")).rows;
 if(install.length!==1||branch.length!==1)throw Error("TARGET_INSTALLATION_NOT_EXACT");
 const throttle=randomBytes(48).toString("base64url");
 const installationId=install[0].id,branchId=branch[0].id;
 for(const value of [installationId,branchId,throttle])console.log("::add-mask::"+value);
 appendFileSync(e.GITHUB_ENV,
  "ERP_INSTALLATION_ID="+installationId+"\n"+
  "ERP_BRANCH_ID="+branchId+"\n"+
  "ERP_UI_ORIGIN=https://erp-gustavjung24-ops-projects.vercel.app\n"+
  "ERP_THROTTLE_SECRET="+throttle+"\n");
 passed=true;
 console.log("ERP_RESUME_EXISTING_TARGET_COMPUTE_SECRET_STAGED");
}catch(error){
 console.error("ERP_RESUME_FAILED "+(error instanceof Error&&
  /^(OWNER_RESUME_GATE_REFUSED|CANONICAL_SOURCE_NOT_READ_ONLY|MIGRATION_HISTORY_DRIFT|TABLE_SET_DRIFT|CATALOG_UNEXPECTED_NONEMPTY|COMPUTE_ENVIRONMENT_NOT_FOUND|TARGET_INSTALLATION_NOT_EXACT)$/.test(error.message)
  ?error.message:"PROTECTED_PROVIDER_OR_RECONCILIATION_FAILED"));
 process.exitCode=1;
}finally{
 await src?.end().catch(()=>{});await target?.end().catch(()=>{});
 if(token&&operator)try{await api(token,"DELETE","/v1/connections/"+operator.id);
  console.log("ERP_RESUME_OPERATOR_CONNECTION_REVOKED");
 }catch{console.error("ERP_RESUME_OPERATOR_REVOKE_UNVERIFIED");process.exitCode=1;}
 if(token&&runtime&&!runtimeSet)try{await api(token,"DELETE","/v1/connections/"+runtime.id);}
  catch{console.error("ERP_RESUME_RUNTIME_CLEANUP_UNVERIFIED");process.exitCode=1;}
}
if(!passed||process.exitCode)process.exitCode=1;
