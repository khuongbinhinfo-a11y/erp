import { Pool } from "pg";

const EXPECTED=[
  "0001_identity.sql","0002_mutation_control.sql",
  "0003_warehouse_scope.sql","0004_auth_sessions.sql",
  "0005_admin_revision_throttle.sql",
];
const TABLES=[
  "app_role","app_session","app_user","audit_event","auth_event",
  "auth_login_throttle","branch","installation","mutation_receipt",
  "role_permission","schema_migrations","user_role",
  "user_role_warehouse","warehouse",
];
const raw=process.env.ERP_POSTGRES_DIRECT_URL;
if(!raw || process.env.GITHUB_ACTIONS!=="true" ||
   process.env.GITHUB_EVENT_NAME!=="issue_comment" ||
   process.env.GITHUB_REPOSITORY!=="gustavjung24-ops/ERP")
  throw new Error("PROTECTED_PREFLIGHT_RUNTIME_REQUIRED");
let uri;
try{uri=new URL(raw);}catch{throw new Error("INVALID_PROTECTED_CONNECTION");}
if(!["postgres:","postgresql:"].includes(uri.protocol) ||
   uri.hostname!=="db.prisma.io" || uri.searchParams.get("sslmode")!=="require")
  throw new Error("DIRECT_POSTGRES_CONNECTION_REQUIRED");
const pool=new Pool({connectionString:raw,max:1,
  connectionTimeoutMillis:10000,query_timeout:15000});
pool.on("error",()=>{console.error("PREFLIGHT_DATABASE_CONNECTION_LOST");});
let client;
try {
  client=await pool.connect();
  await client.query("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY");
  const [{rows:versions},{rows:tableRows},{rows:server}]=await Promise.all([
    client.query("SELECT version FROM public.schema_migrations ORDER BY version"),
    client.query("SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name"),
    client.query("SELECT current_setting('server_version_num')::integer AS version"),
  ]);
  const names=tableRows.map(r=>r.table_name), found=versions.map(r=>r.version);
  if(server[0]?.version<170000 || server[0]?.version>=180000)
    throw new Error("SOURCE_NOT_POSTGRES_17");
  if(JSON.stringify(names)!==JSON.stringify(TABLES.slice().sort()))
    throw new Error("SOURCE_TABLE_SET_DRIFT");
  if(JSON.stringify(found)!==JSON.stringify(EXPECTED))
    throw new Error("SOURCE_MIGRATION_HISTORY_DRIFT");
  const counts={};
  for(const table of TABLES){
    const {rows}=await client.query('SELECT count(*)::integer AS n FROM public."'+table+'"');
    counts[table]=rows[0].n;
  }
  if(counts.installation!==1||counts.app_user<1||counts.app_session<1)
    throw new Error("MISSING_BOOTSTRAPPED_IDENTITY");
  await client.query("COMMIT");
  console.log(JSON.stringify({event:"ERP_SOURCE_PRE_CUTOVER_READ_ONLY_PASS",
    sourceDatabaseId:"db_xg7823erugsd1ym7c8lf0l9h",
    targetDatabaseId:"db_jg2bl98hzi1jm06lwo0i4rqx",
    pgMajor:17,applicationTables:names.length,migrations:found,
    rowCounts:counts,sourceModified:false,targetModified:false}));
}catch(e){
  if(client){try{await client.query("ROLLBACK");}catch{}}
  const safe=new Set(["SOURCE_NOT_POSTGRES_17","SOURCE_TABLE_SET_DRIFT",
    "SOURCE_MIGRATION_HISTORY_DRIFT","MISSING_BOOTSTRAPPED_IDENTITY",
    "PROTECTED_PREFLIGHT_RUNTIME_REQUIRED","INVALID_PROTECTED_CONNECTION",
    "DIRECT_POSTGRES_CONNECTION_REQUIRED"]);
  console.error("ERP_DB_PREFLIGHT_FAILED "+(e instanceof Error&&safe.has(e.message)?e.message:"PROTECTED_CONNECTION_OR_QUERY_ERROR"));
  process.exitCode=1;
}finally{client?.release();await pool.end();}
