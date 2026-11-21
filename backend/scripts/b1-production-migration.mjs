/**
 * B1 one-time operator gate for the EXISTING ERP-DB. Must run only after
 * exact green main SHA, owner approval, protected environment, and OIDC.
 * Backup is encrypted to durable private object storage; restore is isolated.
 * Only versioned 0008 is allowed on production. No destructive restore.
 */
import { Pool } from "pg";
import { randomUUID, createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readFileSync,writeFileSync,mkdtempSync,rmSync,statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join,resolve } from "node:path";
import { existsSync } from "node:fs";
import { applyMigrations } from "../src/migrate.ts";

// Retired B1-only operator MUST refuse before opening a production connection
// whenever a newer versioned migration is present in the checked-out tree.
if (existsSync(resolve(process.cwd(),"db/migrations/0009_r1_catalog_pricing.sql")))
  throw new Error("B1_OPERATOR_RETIRED_NEWER_SCHEMA");
const e=process.env;
const PROJECT="proj_ud3b1s5yn03vh0zp9cbs2upa";
const DATABASE="db_jg2bl98hzi1jm06lwo0i4rqx";
const BUCKET="erp-db-migration-encrypted-backups";
const RECIPIENT="age1jce83glh2tukl6rz5werqpzyz5rtr6dkcpyw8dwe5pp3nc04efyqx39qlr";
const BEFORE=["0001_identity.sql","0002_mutation_control.sql","0003_warehouse_scope.sql",
  "0004_auth_sessions.sql","0005_admin_revision_throttle.sql",
  "0006_catalog.sql","0007_catalog_controls.sql"];
const AFTER=[...BEFORE,"0008_sales_orders.sql"];
const OLD_TABLES=["app_role","app_session","app_user","audit_event","auth_event",
  "auth_login_throttle","branch","installation","mutation_receipt",
  "role_permission","schema_migrations","user_role","user_role_warehouse","warehouse",
  "catalog_customer","catalog_supplier","catalog_product_group","catalog_product",
  "catalog_unit","catalog_price_list","catalog_price_entry"];
const NEW_TABLES=["sales_order","sales_order_version","sales_order_line","sales_order_sequence"];
const local="postgresql://erp_rehearsal:erp_rehearsal_password@127.0.0.1:5432/erp_restore_b1?sslmode=disable";
const head=e.GITHUB_SHA;
const command=e.APPROVAL_COMMENT??"";
if(e.GITHUB_ACTIONS!=="true"||e.GITHUB_EVENT_NAME!=="issue_comment"||
 e.GITHUB_REPOSITORY!=="gustavjung24-ops/ERP"||e.GITHUB_REF!=="refs/heads/main"||
 e.OWNER_COMMENT_AUTHOR!=="gustavjung24-ops"||
 e.GITHUB_ACTOR!=="gustavjung24-ops"||
 e.ERP_PRODUCTION_WRITES_FROZEN!=="YES"||
 !/^[0-9a-f]{40}$/.test(head??"")||command!=="ERP_B1_MIGRATE "+head||
 !e.ACTIONS_ID_TOKEN_REQUEST_URL||!e.GITHUB_RUN_ID)throw Error("B1_OWNER_RELEASE_GATE_DENIED");

const tmp=mkdtempSync(join(tmpdir(),"erp-b1-migration-"));
const path=s=>join(tmp,s);
const hash=file=>createHash("sha256").update(readFileSync(file)).digest("hex");
function run(label,cmd,args,env={}){
 const r=spawnSync(cmd,args,{cwd:process.cwd(),env:{...e,...env},
   encoding:"utf8",maxBuffer:1024*1024,timeout:180000});
 if(r.status!==0)throw Error(label+"_FAILED");
 return r.stdout;
}
function pgEnv(raw){
 const u=new URL(raw);
 if(!["postgres:","postgresql:"].includes(u.protocol))throw Error("INVALID_POSTGRES_URL");
 return {PGHOST:u.hostname,PGPORT:u.port||"5432",
  PGDATABASE:decodeURIComponent(u.pathname.slice(1)),
  PGUSER:decodeURIComponent(u.username),PGPASSWORD:decodeURIComponent(u.password),
  PGSSLMODE:u.searchParams.get("sslmode")||"require"};
}
async function oidc(){
 const a=await fetch(e.ACTIONS_ID_TOKEN_REQUEST_URL+"&audience=prisma-cloud",{
  headers:{authorization:"Bearer "+e.ACTIONS_ID_TOKEN_REQUEST_TOKEN},
  signal:AbortSignal.timeout(15000)});
 if(!a.ok)throw Error("PRISMA_OIDC_REQUEST_DENIED");
 const jwt=(await a.json()).value;
 const b=await fetch("https://api.prisma.io/v1/auth/github-actions/token",{
  method:"POST",headers:{"content-type":"application/json"},
  body:JSON.stringify({token:jwt}),signal:AbortSignal.timeout(15000)});
 if(![200,201].includes(b.status))throw Error("PRISMA_OIDC_EXCHANGE_DENIED");
 const token=(await b.json()).data?.value;
 if(!token)throw Error("PRISMA_OIDC_TOKEN_MISSING");
 return token;
}
async function api(token,method,resource,body){
 const r=await fetch("https://api.prisma.io"+resource,{
  method,headers:{authorization:"Bearer "+token,"content-type":"application/json"},
  body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});
 if(!r.ok)throw Error("PRISMA_API_"+resource.split("?")[0].replaceAll("/","_")+"_"+r.status);
 if(r.status===204)return null;
 return (await r.json()).data;
}
function items(x){return Array.isArray(x)?x:Array.isArray(x?.items)?x.items:[];}
function equal(a,b,label){
 if(JSON.stringify(a)!==JSON.stringify(b))throw Error(label+"_RECONCILIATION_FAILED");
}
async function signature(pool,versions=BEFORE,tables=OLD_TABLES){
 const db=await pool.connect();
 try{
  await db.query("SET TIME ZONE 'UTC'");
  const found=(await db.query(
    "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name"
  )).rows.map(x=>x.table_name);
  equal(found,[...tables].sort(),"TABLES");
  const history=(await db.query(
    "SELECT version FROM public.schema_migrations ORDER BY version"
  )).rows.map(x=>x.version);
  equal(history,versions,"MIGRATION_VERSIONS");
  const rows={};
  for(const t of tables){
   // Names are only from the fixed allowlist above, never client input.
   const r=await db.query('SELECT count(*)::text AS count,'+
    'coalesce(bit_xor(hashtextextended(row_to_json(x)::text,0))::text,\'0\') AS xor,'+
    'coalesce(sum(hashtextextended(row_to_json(x)::text,1)::numeric)::text,\'0\') AS total '+
    'FROM public."'+t+'" x');
   rows[t]=r.rows[0];
  }
  return {history,rows};
 }finally{db.release();}
}
let token,connection,bucket,access,pool;
let migrationDone=false,backupDone=false;
try{
 token=await oidc();
 const c=await api(token,"POST","/v1/databases/"+DATABASE+"/connections",{
  name:"erp-b1-operator-"+e.GITHUB_RUN_ID+"-"+randomUUID().slice(0,8)});
 const raw=c?.endpoints?.direct?.connectionString;
 if(!c?.id||!raw)throw Error("OPERATOR_CONNECTION_MISSING");
 connection={id:c.id,url:raw};
 const parsed=new URL(raw);
 if(parsed.hostname!=="db.prisma.io"||parsed.searchParams.get("sslmode")!=="require")
   throw Error("ERP_TARGET_DATABASE_INVALID");
 pool=new Pool({connectionString:raw,max:1,connectionTimeoutMillis:15000});
 pool.on("error",()=>{});
 const before=await signature(pool);
 if(Number(before.rows.installation.count)!==1)
   throw Error("ERP_INSTALLATION_COUNT_INVALID");
 const stored=items(await api(token,"GET","/v1/buckets"));
 bucket=stored.find(x=>x.name===BUCKET&&
  (x.projectId===PROJECT||x.project?.id===PROJECT));
 if(!bucket?.id)throw Error("BACKUP_BUCKET_NOT_FOUND");
 access=await api(token,"POST","/v1/buckets/"+bucket.id+"/keys",{
  name:"erp-b1-release-"+e.GITHUB_RUN_ID,role:"read_write"});
 if(!access?.id||!access?.accessKeyId||!access?.secretAccessKey||
  !access?.endpoint||!access?.bucketName)throw Error("BACKUP_ACCESS_MISSING");
 const aws={AWS_ACCESS_KEY_ID:access.accessKeyId,AWS_SECRET_ACCESS_KEY:access.secretAccessKey,
  AWS_DEFAULT_REGION:"ap-southeast-1",AWS_EC2_METADATA_DISABLED:"true"};
 const dump=path("baseline.dump");
 run("ERP_PGDUMP","pg_dump",["--format=custom","--no-owner","--no-acl",
  "--serializable-deferrable","--file="+dump],pgEnv(raw));
 if(statSync(dump).size<256)throw Error("DUMP_TOO_SMALL");
 const key=path("recovery-key");
 run("ISOLATED_RECOVERY_IDENTITY","age-keygen",["-o",key]);
 const ephemeral=run("ISOLATED_RECOVERY_RECIPIENT","age-keygen",["-y",key]).trim();
 const cipher=path("check.dump.age"),download=path("check-readback.dump.age");
 run("ENCRYPT_REHEARSAL","age",["-r",ephemeral,"-o",cipher,dump]);
 const durable=path("erp-b1.dump.age"),back=path("erp-b1-readback.dump.age");
 run("ENCRYPT_DURABLE","age",["-r",RECIPIENT,"-o",durable,dump]);
 const base="s3://"+access.bucketName+"/erp-db/B1/"+head+"/run-"+e.GITHUB_RUN_ID+
   "-attempt-"+(e.GITHUB_RUN_ATTEMPT??"1")+"/";
 const durableUri=base+"pre-0008.dump.age";
 run("DURABLE_UPLOAD","aws",["--endpoint-url",access.endpoint,"s3","cp",
   durable,durableUri,"--only-show-errors"],aws);
 run("DURABLE_READBACK","aws",["--endpoint-url",access.endpoint,"s3","cp",
   durableUri,back,"--only-show-errors"],aws);
 if(hash(durable)!==hash(back))throw Error("DURABLE_BACKUP_HASH_MISMATCH");
 const proof=base+"rehearsal.dump.age";
 run("REHEARSAL_UPLOAD","aws",["--endpoint-url",access.endpoint,"s3","cp",
   cipher,proof,"--only-show-errors"],aws);
 run("REHEARSAL_READBACK","aws",["--endpoint-url",access.endpoint,"s3","cp",
   proof,download,"--only-show-errors"],aws);
 if(hash(cipher)!==hash(download))throw Error("REHEARSAL_BACKUP_HASH_MISMATCH");
 const verified=path("verified.dump");
 run("REHEARSAL_DECRYPT","age",["-d","-i",key,"-o",verified,download]);
 if(hash(verified)!==hash(dump))throw Error("REHEARSAL_DECRYPT_HASH_MISMATCH");
 const listing=run("PG_RESTORE_LIST","pg_restore",["-l",verified]).split("\n");
 const portable=listing.filter(x=>!/\bEXTENSION - |\bCOMMENT - EXTENSION /.test(x));
 writeFileSync(path("portable.list"),portable.join("\n"));
 run("ISOLATED_RESTORE","pg_restore",["--exit-on-error","--single-transaction",
  "--no-owner","--no-acl","--dbname=erp_restore_b1",
  "--use-list="+path("portable.list"),verified],pgEnv(local));
 const copy=new Pool({connectionString:local,max:1});
 try{equal(before,await signature(copy),"ISOLATED_RESTORE");}
 finally{await copy.end();}
 equal(before,await signature(pool),"TARGET_BEFORE_MIGRATION");
 backupDone=true;
 // Durable pre-migration proof exists BEFORE schema mutation, allowing a
 // fail-closed post-COMMIT recovery if later provider steps fail.
 const restoreProof={type:"ERP-B1-BEFORE-0008",sha:head,databaseId:DATABASE,
  backupUri:durableUri,backupSha256:hash(durable),versions:BEFORE,rows:before.rows,
  remoteReadback:true,isolatedRestoreVerified:true,sourceReconciled:true,
  verifiedAt:new Date().toISOString()};
 const gateFile=path("pre-0008-gate.json"),gateReadback=path("pre-0008-gate-readback.json");
 writeFileSync(gateFile,JSON.stringify(restoreProof)+"\n");
 const gateUri=base+"pre-0008-gate.json";
 run("PRE_MIGRATION_PROOF_UPLOAD","aws",["--endpoint-url",access.endpoint,"s3","cp",
  gateFile,gateUri,"--only-show-errors"],aws);
 run("PRE_MIGRATION_PROOF_READBACK","aws",["--endpoint-url",access.endpoint,"s3","cp",
  gateUri,gateReadback,"--only-show-errors"],aws);
 if(hash(gateFile)!==hash(gateReadback))throw Error("PRE_MIGRATION_PROOF_HASH_MISMATCH");
 console.info("ERP_B1_BACKUP_ENCRYPTED_OFFSITE_RESTORED_RECONCILED_PASS");
 const result=await applyMigrations(pool,resolve(process.cwd(),"db/migrations"));
 equal(result.applied,["0008_sales_orders.sql"],"B1_ONLY_MIGRATION");
 equal(result.skipped,BEFORE,"B1_EXISTING_MIGRATIONS");
 const after=await signature(pool,AFTER,[...OLD_TABLES,...NEW_TABLES]);
 for(const t of OLD_TABLES.filter(x=>x!=="schema_migrations"&&x!=="role_permission"))
  equal(before.rows[t],after.rows[t],"EXISTING_"+t);
 for(const t of NEW_TABLES)
  if(after.rows[t].count!=="0")throw Error("UNEXPECTED_B1_BUSINESS_DATA");
 migrationDone=true;
 console.info("ERP_B1_VERSION_0008_APPLIED_SCHEMA_READBACK_PASS");
 const manifest={type:"ERP-B1-PRODUCTION-MIGRATION",sha:head,
  databaseId:DATABASE,versions:AFTER,backupSha256:hash(durable),
  backupReadback:true,isolatedRestore:true,sourceReconciled:true,
  migrationApplied:true,verifiedAt:new Date().toISOString()};
 const manifestFile=path("manifest.json");
 writeFileSync(manifestFile,JSON.stringify(manifest)+"\n");
 run("MANIFEST_UPLOAD","aws",["--endpoint-url",access.endpoint,"s3","cp",
  manifestFile,durableUri+".manifest.json","--only-show-errors"],aws);
 console.info("ERP_B1_MANIFEST_STORED");
}catch(error){
 const permitted=new Set(["B1_OWNER_RELEASE_GATE_DENIED","ERP_TARGET_DATABASE_INVALID",
  "B1_ONLY_MIGRATION_RECONCILIATION_FAILED","B1_EXISTING_MIGRATIONS_RECONCILIATION_FAILED",
  "UNEXPECTED_B1_BUSINESS_DATA","DURABLE_BACKUP_HASH_MISMATCH",
  "REHEARSAL_BACKUP_HASH_MISMATCH","REHEARSAL_DECRYPT_HASH_MISMATCH"]);
 const reason=error instanceof Error&&permitted.has(error.message)
  ?error.message:"ERP_B1_PROTECTED_MIGRATION_FAILURE";
 console.error("ERP_B1_MIGRATION_BLOCKED "+reason);
 process.exitCode=1;
}finally{
 await pool?.end().catch(()=>{});
 if(token&&connection?.id)try{
  await api(token,"DELETE","/v1/connections/"+connection.id);
  console.info("ERP_B1_TEMP_DB_CREDENTIAL_REVOKED");
 }catch{console.error("ERP_B1_DB_CREDENTIAL_REVOCATION_UNVERIFIED");process.exitCode=1;}
 if(token&&access?.id&&bucket?.id)try{
  await api(token,"DELETE","/v1/buckets/"+bucket.id+"/keys/"+access.id);
  console.info("ERP_B1_TEMP_BUCKET_KEY_REVOKED");
 }catch{console.error("ERP_B1_BUCKET_KEY_REVOCATION_UNVERIFIED");process.exitCode=1;}
 rmSync(tmp,{recursive:true,force:true});
 if(!migrationDone||!backupDone)process.exitCode=1;
}
