import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID, createHash } from "node:crypto";
import { mkdtemp, readdir, copyFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { Pool } from "pg";
import { applyMigrations } from "./migrate.ts";

const source=process.env.DATABASE_URL;
const local=(()=>{
 try{const u=new URL(source??"");return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";}
 catch{return false;}
})();

test("R1-A 0017: real 16→17 upgrade preserves existing customer group strings, scopes FK and replays cleanly",
 {skip:!local},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const dbName="erp_ci_r1a_"+randomUUID().replaceAll("-","").slice(0,12);
 const dir=await mkdtemp(join(tmpdir(),"erp-r1a-migrations-"));
 let db:Pool|null=null;
 try{
  await admin.query('CREATE DATABASE "'+dbName+'"');
  const uri=new URL(source!);uri.pathname="/"+dbName;
  db=new Pool({connectionString:uri.toString(),max:4,query_timeout:15000});
  db.on("error",()=>{});
  const original=resolve(process.cwd(),"db/migrations");
  const names=(await readdir(original)).filter(x=>/^\d{4}_[a-z0-9_]+\.sql$/.test(x)).sort();
  assert.equal(names.length,17,"exact expected production migration set");
  for(const name of names.slice(0,16))await copyFile(join(original,name),join(dir,name));
  assert.equal((await applyMigrations(db,dir)).applied.length,16);
  const install=(await db.query<{id:string}>(
   "INSERT INTO installation(code,display_name) VALUES($1,$2) RETURNING id",
   ["r1a-"+randomUUID().slice(0,10),"R1A migration integration"])).rows[0]!.id;
  const b=(await db.query<{id:string}>(
   "INSERT INTO branch(installation_id,code,name) VALUES($1,$2,$3) RETURNING id",
   [install,"MAIN","Chi nhánh chính"])).rows[0]!.id;
  const other=(await db.query<{id:string}>(
   "INSERT INTO branch(installation_id,code,name) VALUES($1,$2,$3) RETURNING id",
   [install,"OTHER","Chi nhánh khác"])).rows[0]!.id;
  const legacyGroups=["VIP","Bán sỉ","Bán sỉ","Đại lý cấp 1"];
  for(let i=0;i<legacyGroups.length;i++){
   await db.query(`INSERT INTO catalog_customer
    (installation_id,branch_id,code,name,customer_group)
    VALUES($1,$2,$3,$4,$5)`,
    [install,b,"KH-"+(i+1),"Khách thử "+(i+1),legacyGroups[i]]);
  }
  await copyFile(join(original,names[16]!),join(dir,names[16]!));
  const upgrade=await applyMigrations(db,dir);
  assert.deepEqual(upgrade.applied,["0017_r1a_customer_directories.sql"]);
  const result=await db.query<{
    customer_group:string;customer_group_id:string|null;
    customer_region_id:string|null;code:string;name:string;legacy_label:string|null;
   }>(`SELECT c.customer_group,c.customer_group_id,c.customer_region_id,
    g.code,g.name,g.legacy_label FROM catalog_customer c
    JOIN catalog_customer_group g ON g.installation_id=c.installation_id
     AND g.branch_id=c.branch_id AND g.id=c.customer_group_id
    WHERE c.installation_id=$1 AND c.branch_id=$2 ORDER BY c.code`,[install,b]);
  assert.equal(result.rowCount,4);
  assert.deepEqual(result.rows.map(x=>x.customer_group),legacyGroups);
  assert.ok(result.rows.every(x=>x.customer_group_id&&x.customer_region_id===null));
  assert.equal(result.rows[0]!.code,"VIP");
  assert.ok(result.rows.every(x=>x.legacy_label===x.customer_group));
  // Rename is allowed for UX, but historic price-rule identity remains fixed.
  await db.query(`UPDATE catalog_customer_group SET name='Tên mới'
    WHERE installation_id=$1 AND branch_id=$2 AND code='VIP'`,[install,b]);
  await assert.rejects(
    db.query(`UPDATE catalog_customer_group SET legacy_label='WRONG'
      WHERE installation_id=$1 AND branch_id=$2 AND code='VIP'`,[install,b]),
    /IMMUTABLE_CUSTOMER_GROUP_LEGACY_ALIAS/);
  const unicode="Bán sỉ";
  const hash=createHash("md5").update(unicode).digest("hex").slice(0,32);
  assert.equal(result.rows[1]!.code,"LEGACY-"+hash);
  assert.equal(result.rows[1]!.customer_group_id,result.rows[2]!.customer_group_id,
    "identical legacy labels share one canonical directory row");
  assert.equal((await db.query<{n:string}>(`SELECT count(*)::text AS n
    FROM catalog_customer_group WHERE installation_id=$1 AND branch_id=$2`,
    [install,b])).rows[0]!.n,"3");
  const foreign=(await db.query<{id:string}>(`INSERT INTO catalog_customer_region
    (installation_id,branch_id,code,name) VALUES($1,$2,'KV_OTHER','Khu vực khác')
    RETURNING id`,[install,other])).rows[0]!.id;
  await assert.rejects(
    db.query(`UPDATE catalog_customer SET customer_region_id=$1
      WHERE installation_id=$2 AND branch_id=$3 AND code='KH-1'`,[foreign,install,b]),
    (e:unknown)=>typeof e==="object"&&e!==null&&"code" in e&&e.code==="23503");
  assert.equal((await applyMigrations(db,dir)).skipped.length,17);
 }finally{
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)').catch(()=>{});
  await admin.end();
  await rm(dir,{recursive:true,force:true});
 }
});
