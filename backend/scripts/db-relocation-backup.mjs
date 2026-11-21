import { Pool } from "pg";
import { spawnSync } from "node:child_process";
import { mkdtempSync,readFileSync,writeFileSync,rmSync,statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";

const SOURCE="db_xg7823erugsd1ym7c8lf0l9h";
const TARGET_PROJECT="proj_ud3b1s5yn03vh0zp9cbs2upa";
const TARGET_DB="db_jg2bl98hzi1jm06lwo0i4rqx";
const BUCKET_NAME="erp-db-migration-encrypted-backups";
const RECIPIENT="age1jce83glh2tukl6rz5werqpzyz5rtr6dkcpyw8dwe5pp3nc04efyqx39qlr";
const TABLES=["app_role","app_session","app_user","audit_event","auth_event",
  "auth_login_throttle","branch","installation","mutation_receipt",
  "role_permission","schema_migrations","user_role","user_role_warehouse","warehouse"];
const VERSIONS=["0001_identity.sql","0002_mutation_control.sql","0003_warehouse_scope.sql",
  "0004_auth_sessions.sql","0005_admin_revision_throttle.sql"];
const sha=process.env.GITHUB_SHA;
const sourceUrl=process.env.ERP_POSTGRES_DIRECT_URL;
if(!/^[0-9a-f]{40}$/.test(sha??"")||!sourceUrl||
  process.env.GITHUB_ACTIONS!=="true"||process.env.GITHUB_EVENT_NAME!=="issue_comment"||
  process.env.GITHUB_REPOSITORY!=="gustavjung24-ops/ERP")
  throw new Error("OWNER_RUNNER_ONLY");
const temp=mkdtempSync(join(tmpdir(),"erp-db-backup-"));
const path=(x)=>join(temp,x);
const run=(label,command,args,env={})=>{
  const x=spawnSync(command,args,{env:{...process.env,...env},encoding:"utf8",
    maxBuffer:1024*1024,timeout:180000});
  if(x.status!==0)throw new Error(label+"_FAILED");
  return x.stdout;
};
const digest=file=>createHash("sha256").update(readFileSync(file)).digest("hex");
const pgEnv=url=>{
  const u=new URL(url);
  if(!["postgres:","postgresql:"].includes(u.protocol))throw new Error("INVALID_PG_URL");
  return {PGHOST:u.hostname,PGPORT:u.port||"5432",PGUSER:decodeURIComponent(u.username),
    PGPASSWORD:decodeURIComponent(u.password),PGDATABASE:decodeURIComponent(u.pathname.slice(1)),
    PGSSLMODE:u.searchParams.get("sslmode")||"require",PGTZ:"UTC"};
};
const source=pgEnv(sourceUrl);
if(source.PGHOST!=="db.prisma.io"||source.PGSSLMODE!=="require")
  throw new Error("SOURCE_DIRECT_CONNECTION_REQUIRED");
async function apiToken(){
  const a=await fetch(process.env.ACTIONS_ID_TOKEN_REQUEST_URL+"&audience=prisma-cloud",{
    headers:{authorization:"Bearer "+process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN},
    signal:AbortSignal.timeout(15000)});
  if(a.status!==200)throw new Error("OIDC_REQUEST_NOT_AUTHORIZED");
  const jwt=(await a.json()).value;
  const b=await fetch("https://api.prisma.io/v1/auth/github-actions/token",{
    method:"POST",headers:{"content-type":"application/json"},
    body:JSON.stringify({token:jwt}),signal:AbortSignal.timeout(15000)});
  // Prisma's documented OIDC exchange creates a token with HTTP 201 (Created).
  // Previous guard incorrectly expected only 200 and failed on a valid response.
  if(b.status!==201 && b.status!==200)throw new Error("PROJECT_OIDC_NOT_AUTHORIZED");
  const payload=await b.json();
  if(!payload.data?.value)throw new Error("MISSING_OIDC_TOKEN");
  return payload.data.value;
}
async function prismaApi(token,method,endpoint,body){
  const r=await fetch("https://api.prisma.io"+endpoint,{
    method,headers:{authorization:"Bearer "+token,"content-type":"application/json"},
    body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});
  if(!r.ok)throw new Error("PRISMA_"+endpoint.split("?")[0].replaceAll("/","_")+"_HTTP_"+r.status);
  return (await r.json()).data;
}
async function signature(pool){
  const c=await pool.connect();
  try{
    await c.query("SET TIME ZONE 'UTC'");
    const tables=(await c.query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name"
    )).rows.map(x=>x.table_name);
    if(JSON.stringify(tables)!==JSON.stringify(TABLES.slice().sort()))
      throw new Error("SOURCE_SCHEMA_DRIFT");
    const migrations=(await c.query("SELECT version FROM public.schema_migrations ORDER BY version")).rows.map(x=>x.version);
    if(JSON.stringify(migrations)!==JSON.stringify(VERSIONS))throw new Error("SOURCE_HISTORY_DRIFT");
    const evidence={};
    for(const t of TABLES){
      const {rows}=await c.query(
        'SELECT count(*)::text AS rows, coalesce(bit_xor(hashtextextended(row_to_json(z)::text,0))::text,\'0\') AS xor, coalesce(sum(hashtextextended(row_to_json(z)::text,1)::numeric)::text,\'0\') AS sum FROM public."'+t+'" z'
      );
      evidence[t]=rows[0];
    }
    return {tables,migrations,evidence};
  }finally{c.release();}
}
const live=new Pool({connectionString:sourceUrl,max:1,connectionTimeoutMillis:15000});
live.on("error",()=>{});
try{
  const initial=await signature(live);
  if(Number(initial.evidence.installation.rows)!==1||Number(initial.evidence.app_user.rows)<1)
    throw new Error("INVALID_SOURCE_IDENTITY");
  const token=await apiToken();
  const buckets=await prismaApi(token,"GET","/v1/buckets");
  const candidates=Array.isArray(buckets)?buckets:Array.isArray(buckets?.items)?buckets.items:[];
  let bucket=candidates.find(x=>x.name===BUCKET_NAME&&
    (x.project?.id===TARGET_PROJECT||x.projectId===TARGET_PROJECT));
  if(!bucket) bucket=await prismaApi(token,"POST","/v1/buckets",{
    projectId:TARGET_PROJECT,name:BUCKET_NAME
  });
  if(!bucket?.id||!(bucket.project?.id===TARGET_PROJECT||bucket.projectId===TARGET_PROJECT))
    throw new Error("BACKUP_BUCKET_PROJECT_MISMATCH");
  const access=await prismaApi(token,"POST",'/v1/buckets/'+bucket.id+'/keys',{
    name:"erp-db-move-operator-"+sha.slice(0,8),role:"read_write"
  });
  if(!access?.accessKeyId||!access?.secretAccessKey||!access?.endpoint||!access?.bucketName)
    throw new Error("BACKUP_STORAGE_CREDENTIAL_MISSING");
  const aws={AWS_ACCESS_KEY_ID:access.accessKeyId,AWS_SECRET_ACCESS_KEY:access.secretAccessKey,
    AWS_DEFAULT_REGION:"ap-southeast-1",AWS_EC2_METADATA_DISABLED:"true"};
  const file=path("source.dump");
  run("POSTGRES17_BACKUP","pg_dump",["--version"]);
  run("SOURCE_PG_DUMP","pg_dump",["--format=custom","--no-owner","--no-acl",
    "--serializable-deferrable","--file="+file],source);
  if(statSync(file).size<256)throw new Error("BACKUP_ARCHIVE_TOO_SMALL");
  // An independent age identity verifies upload/download/decrypt interoperability.
  const ephemeral=path("rehearsal-identity");
  run("AGE_IDENTITY","age-keygen",["-o",ephemeral]);
  const ephPublic=run("AGE_RECIPIENT","age-keygen",["-y",ephemeral]).trim();
  const testEncrypted=path("rehearsal.dump.age"),testReadback=path("rehearsal-readback.age");
  run("ENCRYPT_TEST","age",["-r",ephPublic,"-o",testEncrypted,file]);
  const name="erp-demo/"+sha+"/rehearsal-test.dump.age";
  const url="s3://"+access.bucketName+"/"+name;
  run("S3_UPLOAD_TEST","aws",["--endpoint-url",access.endpoint,"s3","cp",testEncrypted,url,
    "--only-show-errors"],aws);
  run("S3_DOWNLOAD_TEST","aws",["--endpoint-url",access.endpoint,"s3","cp",url,testReadback,
    "--only-show-errors"],aws);
  if(digest(testEncrypted)!==digest(testReadback))throw new Error("REHEARSAL_S3_HASH_MISMATCH");
  run("AGE_DECRYPT_TEST","age",["-d","-i",ephemeral,"-o",path("decrypted.dump"),testReadback]);
  if(digest(file)!==digest(path("decrypted.dump")))throw new Error("AGE_RECOVERY_MISMATCH");
  // Durable backup is encrypted for the separate Vercel vault's established recovery key.
  const durable=path("durable.dump.age"),verified=path("durable-readback.age");
  run("DURABLE_ENCRYPT","age",["-r",RECIPIENT,"-o",durable,file]);
  const object="erp-demo/"+sha+"/pre-move-0001-to-0005.dump.age";
  const remote="s3://"+access.bucketName+"/"+object;
  run("S3_DURABLE_UPLOAD","aws",["--endpoint-url",access.endpoint,"s3","cp",durable,remote,
    "--only-show-errors"],aws);
  run("S3_DURABLE_DOWNLOAD","aws",["--endpoint-url",access.endpoint,"s3","cp",remote,verified,
    "--only-show-errors"],aws);
  if(digest(durable)!==digest(verified))throw new Error("DURABLE_S3_READBACK_MISMATCH");

  // PostgreSQL 17 in a separate Docker service, never the existing source/destination.
  const lines=run("PG_RESTORE_LIST","pg_restore",["-l",file]).split("\n");
  const filtered=lines.filter(x=>!/\bEXTENSION - |\bCOMMENT - EXTENSION /.test(x));
  writeFileSync(path("portable.list"),filtered.join("\n"));
  const local="postgresql://erp_rehearsal:erp_rehearsal_password@127.0.0.1:5432/erp_restore_20261120?sslmode=disable";
  const rehearsal=pgEnv(local);
  run("PORTABLE_ISOLATED_RESTORE","pg_restore",["--exit-on-error","--no-owner","--no-acl",
    "--dbname=erp_restore_20261120","--use-list="+path("portable.list"),file],rehearsal);
  const restored=new Pool({connectionString:local,max:1,connectionTimeoutMillis:15000});
  let matches;
  try {
    const after=await signature(restored);
    matches=JSON.stringify(initial)===JSON.stringify(after);
    if(!matches)throw new Error("ISOLATED_RESTORE_DATA_RECONCILIATION_FAILED");
  } finally{await restored.end();}
  // A final source read detects drift during the backup window. No cutover in this action.
  const final=await signature(live);
  if(JSON.stringify(initial)!==JSON.stringify(final))
    throw new Error("SOURCE_WROTE_DURING_BACKUP_RETRY_REQUIRED");
  const manifest={
    status:"PASS",type:"source-backup-rehearsal",sourceDatabaseId:SOURCE,
    targetDatabaseId:TARGET_DB,targetProjectId:TARGET_PROJECT,repoSha:sha,
    appliedMigrations:VERSIONS,publicTables:TABLES.length,
    rowCounts:Object.fromEntries(TABLES.map(t=>[t,Number(initial.evidence[t].rows)])),
    ciphertextSha256:digest(durable),plaintextSha256:digest(file),
    encryptedRemoteReadback:true,ephemeralEncryptedRestoreVerified:true,
    postgresql17IsolatedRestoreReconciled:true,sourceUnchangedDuringBackup:true,
    targetWasNotModified:true,verifiedAt:new Date().toISOString()
  };
  writeFileSync(path("manifest.json"),JSON.stringify(manifest,null,2)+"\n");
  run("MANIFEST_UPLOAD","aws",["--endpoint-url",access.endpoint,"s3","cp",
    path("manifest.json"),remote+".manifest.json","--only-show-errors"],aws);
  console.log(JSON.stringify({event:"ERP_BACKUP_ISOLATED_RESTORE_PASS",
    manifestUri:remote+".manifest.json",ciphertextSha256:manifest.ciphertextSha256,
    tableCount:TABLES.length,sourceModified:false,targetModified:false,
    requiresSeparateCutoverApproval:true}));
}catch(error){
  const safe=new Set(["OWNER_RUNNER_ONLY","SOURCE_DIRECT_CONNECTION_REQUIRED",
    "SOURCE_SCHEMA_DRIFT","SOURCE_HISTORY_DRIFT","INVALID_SOURCE_IDENTITY",
    "OIDC_REQUEST_NOT_AUTHORIZED","PROJECT_OIDC_NOT_AUTHORIZED","MISSING_OIDC_TOKEN",
    "BACKUP_BUCKET_PROJECT_MISMATCH","BACKUP_STORAGE_CREDENTIAL_MISSING",
    "SOURCE_PG_DUMP_FAILED","POSTGRES17_BACKUP_FAILED",
    "BACKUP_ARCHIVE_TOO_SMALL","REHEARSAL_S3_HASH_MISMATCH","AGE_RECOVERY_MISMATCH",
    "DURABLE_S3_READBACK_MISMATCH","PORTABLE_ISOLATED_RESTORE_FAILED",
    "ISOLATED_RESTORE_DATA_RECONCILIATION_FAILED","SOURCE_WROTE_DURING_BACKUP_RETRY_REQUIRED"]);
  const reason=error instanceof Error&&safe.has(error.message)?error.message:"PROVIDER_BACKUP_REHEARSAL_GATE_FAILED";
  console.error("ERP_BACKUP_FAILED "+reason);
  process.exitCode=1;
}finally{
  await live.end().catch(()=>{});
  rmSync(temp,{recursive:true,force:true});
}
