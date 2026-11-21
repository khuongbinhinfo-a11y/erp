/**
 * Post-COMMIT R1 recovery only. No SQL mutation, no backup overwrite,
 * no migration re-run. Read-only proof and row reconciliation before
 * maintenance NORMAL can be staged.
 */
import { Pool } from "pg";
import { randomUUID,createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readFileSync,mkdtempSync,rmSync,readdirSync } from "node:fs";
import { join,resolve } from "node:path";
import { tmpdir } from "node:os";

// Keep R1 recovery locked to the migration shape that created its proof.
if (readdirSync(resolve(process.cwd(),"db/migrations")).some(
  file => /^\d{4}_[a-z0-9_]+\.sql$/.test(file) && file.slice(0,4)>"0010"
)) throw new Error("R1_OPERATOR_RETIRED_NEWER_SCHEMA");
const e=process.env,sha=e.GITHUB_SHA;
const project="proj_ud3b1s5yn03vh0zp9cbs2upa";
const database="db_jg2bl98hzi1jm06lwo0i4rqx";
const bucketName="erp-db-migration-encrypted-backups";
const previous=["0001_identity.sql","0002_mutation_control.sql","0003_warehouse_scope.sql",
 "0004_auth_sessions.sql","0005_admin_revision_throttle.sql","0006_catalog.sql","0007_catalog_controls.sql",
 "0008_sales_orders.sql"];
const versions=[...previous,"0009_r1_catalog_pricing.sql","0010_r1_sales_price_snapshot.sql"];
const oldTables=["app_role","app_session","app_user","audit_event","auth_event",
 "auth_login_throttle","branch","installation","mutation_receipt",
 "role_permission","schema_migrations","user_role","user_role_warehouse","warehouse",
 "catalog_customer","catalog_supplier","catalog_product_group","catalog_product",
 "catalog_unit","catalog_price_list","catalog_price_entry",
 "sales_order","sales_order_version","sales_order_line","sales_order_sequence"];
const allTables=[...oldTables,"catalog_sell_sku","catalog_sku_barcode","catalog_sales_channel",
 "catalog_sku_price_rule","catalog_sku_price_retirement"];
if(e.GITHUB_ACTIONS!=="true"||e.GITHUB_EVENT_NAME!=="issue_comment"||
 e.GITHUB_REPOSITORY!=="gustavjung24-ops/ERP"||
 e.GITHUB_REF!=="refs/heads/main"||e.GITHUB_ACTOR!=="gustavjung24-ops"||
 e.OWNER_COMMENT_AUTHOR!=="gustavjung24-ops"||
 !/^[0-9a-f]{40}$/.test(sha??"")||e.APPROVAL_COMMENT!=="ERP_R1_RESUME "+sha)
 throw Error("R1_RESUME_OWNER_GATE_DENIED");
const dir=mkdtempSync(join(tmpdir(),"erp-r1-resume-"));
function run(label,cmd,args,env={}){
 const r=spawnSync(cmd,args,{env:{...e,...env},encoding:"utf8",
  maxBuffer:1024*1024,timeout:180000});
 if(r.status!==0)throw Error(label+"_FAILED");
 return r.stdout;
}
const checksum=file=>createHash("sha256").update(readFileSync(file)).digest("hex");
async function oidc(){
 const a=await fetch(e.ACTIONS_ID_TOKEN_REQUEST_URL+"&audience=prisma-cloud",{
  headers:{authorization:"Bearer "+e.ACTIONS_ID_TOKEN_REQUEST_TOKEN},
  signal:AbortSignal.timeout(15000)});
 if(a.status!==200)throw Error("OIDC_REQUEST_DENIED");
 const jwt=(await a.json()).value;
 const b=await fetch("https://api.prisma.io/v1/auth/github-actions/token",{
  method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({token:jwt}),
  signal:AbortSignal.timeout(15000)});
 if(![200,201].includes(b.status))throw Error("OIDC_TOKEN_DENIED");
 const token=(await b.json()).data?.value;
 if(!token)throw Error("OIDC_TOKEN_EMPTY");
 return token;
}
async function api(token,method,resource,body){
 const r=await fetch("https://api.prisma.io"+resource,{
  method,headers:{authorization:"Bearer "+token,"content-type":"application/json"},
  body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});
 if(!r.ok)throw Error("R1_RESUME_PROVIDER_HTTP_FAILURE");
 return r.status===204?null:(await r.json()).data;
}
function equal(a,b,reason){
 if(JSON.stringify(a)!==JSON.stringify(b))throw Error(reason+"_DRIFT");
}
async function inspect(pool){
 const c=await pool.connect();
 try{
  await c.query("SET TIME ZONE 'UTC'");
  const found=(await c.query(
   "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name"
  )).rows.map(x=>x.table_name);
  equal(found,[...allTables].sort(),"R1_TABLES");
  const history=(await c.query("SELECT version FROM schema_migrations ORDER BY version")).rows.map(x=>x.version);
  equal(history,versions,"R1_SCHEMA_VERSION");
  const recorded=(await c.query("SELECT version,checksum FROM schema_migrations ORDER BY version")).rows;
  for(const row of recorded){
   const file=resolve(process.cwd(),"db/migrations",row.version);
   const digest=createHash("sha256").update(readFileSync(file)).digest("hex");
   if(row.checksum!==digest)throw Error("R1_RESUME_MIGRATION_CHECKSUM_DRIFT");
  }
  const rows={};
  for(const table of oldTables.filter(x=>x!=="schema_migrations")){
   // Same projection/fingerprints as original signed pre-migration gate.
   const omit=table==="catalog_customer"?["phone","delivery_address","payment_terms_days"]:
     table==="sales_order"?["channel_id"]:
     table==="sales_order_line"?["sell_sku_id","pricing_engine","price_snapshot","price_signature"]:[];
   const r=await c.query('SELECT count(*)::text AS count,'+
    'coalesce(bit_xor(hashtextextended((to_jsonb(x)-$1::text[])::text,0))::text,\'0\') AS xor,'+
    'coalesce(sum(hashtextextended((to_jsonb(x)-$1::text[])::text,1)::numeric)::text,\'0\') AS total '+
    'FROM public."'+table+'" x',[omit]);
   rows[table]=r.rows[0];
  }
  const inst=await c.query("SELECT count(*)::integer AS n FROM installation");
  if(inst.rows[0]?.n!==1)throw Error("R1_INSTALLATION_DRIFT");
  return rows;
 }finally{c.release();}
}
let token,connection,bucket,key,pool;
try{
 token=await oidc();
 const c=await api(token,"POST","/v1/databases/"+database+"/connections",{
  name:"erp-r1-resume-"+e.GITHUB_RUN_ID+"-"+randomUUID().slice(0,8)});
 const url=c?.endpoints?.direct?.connectionString;
 if(!c?.id||!url)throw Error("R1_RESUME_DIRECT_CONNECTION_FAILED");
 connection=c.id;
 const parsed=new URL(url);
 if(parsed.hostname!=="db.prisma.io"||parsed.searchParams.get("sslmode")!=="require")
  throw Error("R1_RESUME_WRONG_DATABASE");
 pool=new Pool({connectionString:url,max:1,connectionTimeoutMillis:15000});
 pool.on("error",()=>{});
 const currentRows=await inspect(pool);
 const list=await api(token,"GET","/v1/buckets");
 const buckets=Array.isArray(list)?list:Array.isArray(list?.items)?list.items:[];
 bucket=buckets.find(b=>b.name===bucketName&&(b.projectId===project||b.project?.id===project));
 if(!bucket?.id)throw Error("R1_RESUME_BUCKET_MISSING");
 const access=await api(token,"POST","/v1/buckets/"+bucket.id+"/keys",{
  name:"erp-r1-resume-"+e.GITHUB_RUN_ID,role:"read_write"});
 if(!access?.id||!access?.accessKeyId||!access?.secretAccessKey||
    !access?.endpoint||!access?.bucketName)throw Error("R1_RESUME_S3_ACCESS_MISSING");
 key=access.id;
 const aws={AWS_ACCESS_KEY_ID:access.accessKeyId,AWS_SECRET_ACCESS_KEY:access.secretAccessKey,
  AWS_DEFAULT_REGION:"ap-southeast-1",AWS_EC2_METADATA_DISABLED:"true"};
 const prefix="erp-db/R1/"+sha+"/";
 const result=JSON.parse(run("R1_RESUME_PROOF_LIST","aws",[
  "--endpoint-url",access.endpoint,"s3api","list-objects-v2",
  "--bucket",access.bucketName,"--prefix",prefix,"--output","json"],aws));
 if(result.IsTruncated===true)throw Error("R1_RESUME_PROOF_LIST_INCOMPLETE");
 const candidates=(result.Contents??[]).map(x=>x.Key).filter(x=>
  typeof x==="string"&&x.endsWith("/pre-0009-0010-gate.json"));
 if(candidates.length<1)throw Error("R1_RESUME_BACKUP_PROOF_MISSING");
 let valid=false;
 for(let i=0;i<candidates.length;i++){
  const source="s3://"+access.bucketName+"/"+candidates[i];
  const file=join(dir,"proof-"+i+".json");
  run("R1_RESUME_READ_GATE","aws",["--endpoint-url",access.endpoint,
    "s3","cp",source,file,"--only-show-errors"],aws);
  const proof=JSON.parse(readFileSync(file,"utf8"));
  if(proof.type!=="ERP-R1-BEFORE-0009-0010"||proof.sha!==sha||
     proof.databaseId!==database||proof.remoteReadback!==true||
     proof.isolatedRestoreVerified!==true||proof.sourceReconciled!==true)
   continue;
  if(JSON.stringify(proof.versions)!==JSON.stringify(previous))continue;
  let matched=true;
  for(const table of Object.keys(currentRows))
   if(JSON.stringify(currentRows[table])!==JSON.stringify(proof.rows?.[table]))
    matched=false;
  if(!matched)continue;
  if(typeof proof.backupUri!=="string"||!proof.backupUri.startsWith(
      "s3://"+access.bucketName+"/"+prefix)||!proof.backupUri.endsWith("/pre-0009-0010.dump.age"))
    continue;
  const archive=join(dir,"baseline-"+i+".age");
  run("R1_RESUME_BACKUP_READBACK","aws",["--endpoint-url",access.endpoint,
   "s3","cp",proof.backupUri,archive,"--only-show-errors"],aws);
  if(checksum(archive)!==proof.backupSha256)continue;
  valid=true;
  break;
 }
 if(!valid)throw Error("R1_RESUME_PROOF_OR_DATA_MISMATCH");
 console.info("ERP_R1_RECOVERY_SCHEMA_AND_DURABLE_BACKUP_VERIFIED");
}catch{
 console.error("ERP_R1_RESUME_READONLY_PREFLIGHT_BLOCKED");
 process.exitCode=1;
}finally{
 await pool?.end().catch(()=>{});
 if(token&&connection)try{await api(token,"DELETE","/v1/connections/"+connection);
  console.info("ERP_R1_RESUME_CONNECTION_REVOKED");
 }catch{console.error("ERP_R1_RESUME_CONNECTION_REVOCATION_UNVERIFIED");process.exitCode=1;}
 if(token&&bucket?.id&&key)try{
  await api(token,"DELETE","/v1/buckets/"+bucket.id+"/keys/"+key);
  console.info("ERP_R1_RESUME_BUCKET_KEY_REVOKED");
 }catch{console.error("ERP_R1_RESUME_BUCKET_REVOCATION_UNVERIFIED");process.exitCode=1;}
 rmSync(dir,{recursive:true,force:true});
}
