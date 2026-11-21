/**
 * Manual-only Issue #7 versioned production migration gate (0006 and 0007).
 * Never run on CI, Compute, Vercel or automatic deploy.
 * Use only after an owner-approved, independently verified encrypted backup,
 * portable isolated restore and reconciliation for the CURRENT production DB.
 */
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { existsSync } from "node:fs";
import { Pool } from "pg";
import { applyMigrations } from "./migrate.ts";

const DATABASE_ID = "db_xg7823erugsd1ym7c8lf0l9h";
const BASE = ["0001_identity.sql","0002_mutation_control.sql",
  "0003_warehouse_scope.sql","0004_auth_sessions.sql",
  "0005_admin_revision_throttle.sql"];
const DELTA = ["0006_catalog.sql","0007_catalog_controls.sql"];
const SHA = /^[0-9a-f]{40}$/;
const CHECKSUM = /^[0-9a-f]{64}$/;
const MANIFEST = /^s3:\/\/[a-zA-Z0-9.-]+\/[a-zA-Z0-9._/-]+\.manifest\.json$/;

function gate():string {

  const e=process.env;
  if(e.GITHUB_ACTIONS==="true" || e.VERCEL==="1" || e.ERP_RUNTIME==="compute")
    throw new Error("PROTECTED_OPERATOR_ONLY");
  if (existsSync(resolve(process.cwd(),"db/migrations/0008_sales_orders.sql")))
    throw new Error("LEGACY_SOURCE_MIGRATION_RETIRED");
  if(e.ERP_MIGRATION_CONFIRM!=="OWNER_APPROVED_CATALOG_0006_0007" ||
      e.ERP_TARGET_DATABASE_ID!==DATABASE_ID ||
      !SHA.test(e.ERP_APPROVED_GIT_SHA??"") ||
      !CHECKSUM.test(e.ERP_BACKUP_ENCRYPTED_SHA256??"") ||
      !MANIFEST.test(e.ERP_BACKUP_RESTORE_MANIFEST_URI??"") ||
      e.ERP_BACKUP_RESTORE_RECONCILIATION!=="PASS_ISOLATED_CURRENT_SOURCE" ||
      e.ERP_PRODUCTION_WRITES_FROZEN!=="YES" ||
      !/^OWNER-[A-Za-z0-9_-]{8,100}$/.test(e.ERP_MIGRATION_APPROVAL_REFERENCE??""))
    throw new Error("OWNER_BACKUP_RESTORE_APPROVAL_MISSING");
  const actual=execFileSync("git",["rev-parse","HEAD"],{
    cwd:resolve(process.cwd(),".."),encoding:"utf8",
    stdio:["ignore","pipe","ignore"],
  }).trim();
  if(actual!==e.ERP_APPROVED_GIT_SHA)throw new Error("RELEASE_SHA_MISMATCH");
  const raw=e.ERP_POSTGRES_DIRECT_URL;
  if(!raw)throw new Error("MISSING_PROTECTED_DATABASE_URL");
  let parsed:URL;
  try{parsed=new URL(raw);}catch{throw new Error("INVALID_DATABASE_URL");}
  if(!["postgresql:","postgres:"].includes(parsed.protocol) ||
      parsed.hostname!=="db.prisma.io" ||
      parsed.searchParams.get("sslmode")!=="require" ||
      !parsed.password||!parsed.username||!parsed.pathname.startsWith("/"))
    throw new Error("INVALID_DIRECT_DATABASE_TARGET");
  return raw;
}
async function main(){
  const direct=gate();
  const db=new Pool({connectionString:direct,max:1,
    connectionTimeoutMillis:10000,query_timeout:120000,statement_timeout:120000});
  db.on("error",()=>{console.error("CATALOG_MIGRATION_CONNECTION_LOST");});
  try{
    const rows=await db.query<{version:string}>(
      "SELECT version FROM public.schema_migrations ORDER BY version");
    const versions=rows.rows.map(x=>x.version);
    if(versions.length!==BASE.length || BASE.some((s,i)=>versions[i]!==s))
      throw new Error("SOURCE_HISTORY_NOT_0001_0005");
    const report=await applyMigrations(db,resolve(process.cwd(),"db/migrations"));
    if(report.applied.length!==2 ||
       DELTA.some((s,i)=>report.applied[i]!==s) ||
       report.skipped.length!==5)
      throw new Error("UNEXPECTED_APPLIED_VERSIONS");
    const check=await db.query<{versions:number;tables:number}>(
      `SELECT
       (SELECT count(*)::integer FROM public.schema_migrations) AS versions,
       (SELECT count(*)::integer FROM information_schema.tables
         WHERE table_schema='public' AND table_name LIKE 'catalog_%') AS tables`);
    if(check.rows[0]?.versions!==7 || check.rows[0]?.tables!==7)
      throw new Error("SCHEMA_READBACK_FAILED");
    console.info(JSON.stringify({event:"catalog_migration_approved",
      databaseId:DATABASE_ID,applied:report.applied,
      schemaVerified:true,requiresSmoke:true}));
  }finally{await db.end();}
}
main().catch((error:unknown)=>{
  const safe=new Set([
    "PROTECTED_OPERATOR_ONLY","OWNER_BACKUP_RESTORE_APPROVAL_MISSING",
    "RELEASE_SHA_MISMATCH","MISSING_PROTECTED_DATABASE_URL",
    "INVALID_DATABASE_URL","INVALID_DIRECT_DATABASE_TARGET",
    "SOURCE_HISTORY_NOT_0001_0005","UNEXPECTED_APPLIED_VERSIONS",
    "SCHEMA_READBACK_FAILED","LEGACY_SOURCE_MIGRATION_RETIRED",
  ]);
  const category=error instanceof Error && safe.has(error.message)
    ? error.message : "DATABASE_MIGRATION_FAILED";
  console.error("CATALOG_MIGRATION_GATE_BLOCKED category="+category);
  process.exitCode=1;
});
