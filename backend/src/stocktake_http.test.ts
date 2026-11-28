import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { resolve } from "node:path";
import type { AddressInfo } from "node:net";
import { Pool } from "pg";
import { applyMigrations } from "./migrate.ts";
import { bootstrapInstallation } from "./bootstrap.ts";
import { buildApp } from "./server.ts";
import { isDatabaseReady } from "./db.ts";
import { hashPassword } from "./auth.ts";
import { validNonnegativeQty, createStocktake } from "./stocktake.ts";
import type { PoolClient } from "pg";

test("R3.4 precise nonnegative counts include zero but reject NaN/floats",()=>{
 for(const x of ["0","0.000000","3","9999.123456"])
   assert.equal(validNonnegativeQty(x),true,x);
 for(const x of ["-1","NaN","Infinity","1e2","00","1.1234567",1,0,null])
   assert.equal(validNonnegativeQty(x),false,String(x));
});
test("R3.4 rejects oversized stocktake snapshots before writing any document",async()=>{
 let queries=0;
 const fake={query:async(sql:string)=>{
  queries++;
  if(sql.startsWith("SELECT 1 FROM warehouse"))return {rowCount:1,rows:[{id:"fixture"}]};
  if(sql.includes("FROM inventory_stock_balance v")){
   assert.match(sql,/LIMIT 10001/);
   return {rows:Array.from({length:10001},(_,i)=>({
     product_id:String(i),on_hand:"1.000000",movement_count:"1"}))};
  }
  throw new Error("Oversized stocktake attempted an unexpected database write");
 }} as unknown as PoolClient;
 await assert.rejects(createStocktake(fake,{
  installationId:randomUUID(),actorId:randomUUID(),requestId:"stocktake-overflow",
  action:"inventory.stocktake.create",idempotencyKey:"overflow-fixture",
  expectedRevision:0,payload:{},
 },{branchId:randomUUID(),warehouseId:randomUUID(),note:""}),
  {code:"STOCKTAKE_NO_STOCK_SCOPE"});
 assert.equal(queries,2);
});
const source=process.env.DATABASE_URL;
const ci=(()=>{
 try{const u=new URL(source??"");return ["localhost","127.0.0.1"].includes(u.hostname)
  &&u.pathname==="/erp_ci"&&u.username==="erp_ci";}
 catch{return false;}
})();
test("R3.4 PostgreSQL: capture, recount, separate approval, stale guard and exact ledger",
 {skip:!ci},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const dbName="erp_ci_stocktake_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+dbName+'"');
  const uri=new URL(source!);uri.pathname="/"+dbName;
  db=new Pool({connectionString:uri.toString(),max:8,query_timeout:12000});
  db.on("error",()=>{});
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).applied.length,30);
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).skipped.length,30);
  const password="Synthetic-stocktake-"+randomUUID();
  const root=await bootstrapInstallation(db,{code:"stocktake-ci",displayName:"Stocktake CI",
    adminLogin:"owner",adminPassword:password});
  const t=root.installationId,b=root.branchId,w=root.warehouseId;
  // PostgreSQL must reject forged lifecycle facts, even with all required actors.
  await assert.rejects(db.query(`
    INSERT INTO inventory_stocktake(installation_id,branch_id,warehouse_id,
      status,revision,created_by,submitted_by,submitted_at,request_id)
    VALUES($1,$2,$3,'SUBMITTED',1,$4,$4,now(),'forged-stocktake-fixture')`,
    [t,b,w,root.actorId]),/must begin in CREATED/i);
  server=buildApp(()=>isDatabaseReady(db!),async()=>true,{
   pool:db,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"synthetic-"+randomUUID(),
  });
  await new Promise<void>(ok=>server!.listen(0,"127.0.0.1",ok));
  const host="http://127.0.0.1:"+(server.address() as AddressInfo).port;
  const call=async(path:string,method="GET",data?:unknown,token?:string,
   headers:Record<string,string>={})=>{
   const r=await fetch(host+path,{method,headers:{
     origin:"https://erp.example.test",
     ...(data===undefined?{}:{"content-type":"application/json"}),
     ...(token?{authorization:"Bearer "+token}:{}),...headers,
    },body:data===undefined?undefined:JSON.stringify(data)});
   return {status:r.status,body:r.status===204?{}:await r.json() as Record<string,any>};
  };
  const login=await call("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(login.status,200,JSON.stringify(login.body));
  const token=login.body.token as string;
  const make=(path:string,data:unknown,revision=0,key="count-"+randomUUID(),who=token)=>
    call(path,"POST",data,who,{"if-match":String(revision),"idempotency-key":key});
  const product=await make("/v1/catalog/products",{
   branchId:b,code:"ST1",name:"Stocktake synthetic",baseUnit:"cai"});
  assert.equal(product.status,201,JSON.stringify(product.body));
  const p=product.body.id as string;
  const opened=await make("/v1/inventory/openings",{
   branchId:b,warehouseId:w,productId:p,quantity:"5"});
  assert.equal(opened.status,201,JSON.stringify(opened.body));
  const endpoint="/v1/inventory/stocktakes";
  const scope={branchId:b,warehouseId:w};
  // Create-only operator must see the assigned warehouse and create without
  // inheriting read access to existing documents.
  const creatorPass="Synthetic-stocktake-creator-"+randomUUID();
  const creator=(await db.query<{id:string}>(
    `INSERT INTO app_user(installation_id,login_name,password_hash)
     VALUES($1,'stock_creator',$2) RETURNING id`,
    [t,await hashPassword(creatorPass)])).rows[0]!.id;
  const creatorRole=(await db.query<{id:string}>(
    `INSERT INTO app_role(installation_id,code)
     VALUES($1,'STOCKTAKE_CREATE_ONLY') RETURNING id`,[t])).rows[0]!.id;
  await db.query(`INSERT INTO user_role(installation_id,user_id,role_id,branch_id)
    VALUES($1,$2,$3,$4)`,[t,creator,creatorRole,b]);
  await db.query(`INSERT INTO user_role_warehouse(
    installation_id,user_id,role_id,branch_id,warehouse_id)
    VALUES($1,$2,$3,$4,$5)`,[t,creator,creatorRole,b,w]);
  await db.query(`INSERT INTO role_permission(installation_id,role_id,permission_code)
    VALUES($1,$2,'inventory.stocktake.create')`,[t,creatorRole]);
  const creatorLogin=await call("/v1/auth/login","POST",
    {loginName:"stock_creator",password:creatorPass});
  assert.equal(creatorLogin.status,200,JSON.stringify(creatorLogin.body));
  const creatorToken=creatorLogin.body.token as string;
  const scopes=await call(endpoint+"/scopes?branchId="+b,
    "GET",undefined,creatorToken);
  assert.equal(scopes.status,200,JSON.stringify(scopes.body));
  assert.deepEqual(scopes.body.branches.map((x:Record<string,string>)=>x.id),[b]);
  assert.deepEqual(scopes.body.warehouses.map((x:Record<string,string>)=>x.id),[w]);
  assert.equal((await call(endpoint+"?branchId="+b+"&warehouseId="+w,
    "GET",undefined,creatorToken)).status,403);
  const createOnly=await make(endpoint,{...scope,note:"Counting-only create"},0,
    "creator-"+randomUUID(),creatorToken);
  assert.equal(createOnly.status,201,JSON.stringify(createOnly.body));
  // A direct SQL writer must not forge a snapshot quantity or omit stock SKUs.
  const forgedSnapshot=await db.query<{id:string}>(`
    INSERT INTO inventory_stocktake(installation_id,branch_id,warehouse_id,
      created_by,request_id)
    VALUES($1,$2,$3,$4,'forged-snapshot-fixture') RETURNING id`,
    [t,b,w,root.actorId]);
  await db.query(`INSERT INTO inventory_stocktake_line(
    installation_id,branch_id,stocktake_id,line_no,product_id,
    snapshot_on_hand,snapshot_movement_count)
    VALUES($1,$2,$3,1,$4,4,1)`,[t,b,forgedSnapshot.rows[0]!.id,p]);
  await assert.rejects(db.query(`UPDATE inventory_stocktake
    SET status='COUNTING',revision=revision+1
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [t,b,forgedSnapshot.rows[0]!.id]),
    /captured snapshot must match warehouse inventory ledger/i);
  const omittedSnapshot=await db.query<{id:string}>(`
    INSERT INTO inventory_stocktake(installation_id,branch_id,warehouse_id,
      created_by,request_id)
    VALUES($1,$2,$3,$4,'omitted-snapshot-fixture') RETURNING id`,
    [t,b,w,root.actorId]);
  await assert.rejects(db.query(`UPDATE inventory_stocktake
    SET status='COUNTING',revision=revision+1
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [t,b,omittedSnapshot.rows[0]!.id]),
    /captured snapshot must match warehouse inventory ledger/i);
  const createKey="stocktake-"+randomUUID();
  const created=await make(endpoint,{...scope,note:"Reconcile synthetic"},0,createKey);
  assert.equal(created.status,201,JSON.stringify(created.body));
  assert.equal(created.body.status,"COUNTING");
  assert.equal(created.body.revision,1);
  const id=created.body.id as string;
  assert.deepEqual((await make(endpoint,{...scope,note:"Reconcile synthetic"},0,createKey)).body,
   created.body);
  const detailed=await call(endpoint+"/"+id+"?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(detailed.status,200,JSON.stringify(detailed.body));
  assert.equal(detailed.body.stocktake.lines.length,1);
  assert.equal(detailed.body.stocktake.lines[0].snapshotOnHand,"5.000000");
  assert.equal(detailed.body.stocktake.lines[0].countedBase,null);
  const countPath=endpoint+"/"+id+"/counts";
  await assert.rejects(db.query(`INSERT INTO inventory_stocktake_count(
    installation_id,branch_id,stocktake_id,line_no,round_no,
    counted_base,counted_by,request_id)
    VALUES($1,$2,$3,1,3,4,$4,'round-skip-fixture')`,
    [t,b,id,root.actorId]),/count rounds must be sequential/i);
  const premature=await make(countPath,{...scope,lines:[
    {lineNo:1,round:3,quantity:"4"}]},1);
  assert.equal(premature.status,409,JSON.stringify(premature.body));
  const countKey="stock-count-"+randomUUID();
  const recorded=await make(countPath,{...scope,lines:[
   {lineNo:1,round:1,quantity:"4"}]},1,countKey);
  assert.equal(recorded.status,201,JSON.stringify(recorded.body));
  assert.deepEqual((await make(countPath,{...scope,lines:[
   {lineNo:1,round:1,quantity:"4"}]},1,countKey)).body,recorded.body);
  assert.equal((await make(countPath,{...scope,lines:[
   {lineNo:1,round:1,quantity:"1"}]},1)).status,409);
  // After round one, round three still cannot skip round two.
  assert.equal((await make(countPath,{...scope,lines:[
   {lineNo:1,round:3,quantity:"3"}]},1)).status,409);
  assert.equal((await make(countPath,{...scope,lines:[
   {lineNo:1,round:2,quantity:"3"}]},1)).status,201);
  const afterCount=await call(endpoint+"/"+id+"?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(afterCount.body.stocktake.lines[0].roundNo,2);
  assert.equal(afterCount.body.stocktake.lines[0].countedBase,"3.000000");
  assert.equal(afterCount.body.stocktake.lines[0].differenceBase,"-2.000000");
  const submitted=await make(endpoint+"/"+id+"/submit",scope,1);
  assert.equal(submitted.status,200,JSON.stringify(submitted.body));
  assert.equal(submitted.body.revision,2);
  assert.equal((await make(countPath,{...scope,lines:[
   {lineNo:1,round:3,quantity:"0"}]},2)).status,409);
  assert.equal((await make(endpoint+"/"+id+"/approve",scope,2)).status,403);
  const anotherPass="Synthetic-approver-"+randomUUID();
  const secondUser=(await db.query<{id:string}>(
   "INSERT INTO app_user(installation_id,login_name,password_hash) VALUES($1,'approver',$2) RETURNING id",
   [t,await hashPassword(anotherPass)])).rows[0]!.id;
  const role=(await db.query<{id:string}>(
   "SELECT id FROM app_role WHERE installation_id=$1 AND code='PRIMARY_OWNER_MAIN'",
   [t])).rows[0]!.id;
  await db.query("INSERT INTO user_role(installation_id,user_id,role_id,branch_id) VALUES($1,$2,$3,$4)",
   [t,secondUser,role,b]);
  await db.query(`INSERT INTO user_role_warehouse(installation_id,user_id,role_id,branch_id,warehouse_id)
   VALUES($1,$2,$3,$4,$5)`,[t,secondUser,role,b,w]);
  const secondLogin=await call("/v1/auth/login","POST",
   {loginName:"approver",password:anotherPass});
  assert.equal(secondLogin.status,200,JSON.stringify(secondLogin.body));
  const approved=await make(endpoint+"/"+id+"/approve",scope,2,"approve-"+randomUUID(),
   secondLogin.body.token);
  assert.equal(approved.status,200,JSON.stringify(approved.body));
  assert.equal(approved.body.status,"APPROVED");
  // Direct PostgreSQL updates must not falsely mark a counted difference as
  // posted without the exact immutable adjustment movement.
  await assert.rejects(db.query(`UPDATE inventory_stocktake
    SET status='POSTED',revision=revision+1,posted_by=$4,posted_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [t,b,id,root.actorId]),/requires counted and reconciled ledger facts/i);
  const posted=await make(endpoint+"/"+id+"/post",scope,3,"post-"+randomUUID());
  assert.equal(posted.status,200,JSON.stringify(posted.body));
  assert.equal(posted.body.status,"POSTED");
  const balance=await call("/v1/inventory/balances?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(balance.status,200);
  assert.equal(balance.body.items.find((x:Record<string,string>)=>x.productId===p)?.onHand,
   "3.000000");
  const ledger=await db.query<{delta_base:string;kind:string}>(
   `SELECT delta_base::text,kind FROM inventory_ledger WHERE installation_id=$1
      AND branch_id=$2 AND warehouse_id=$3 AND source_type='STOCKTAKE' AND source_id=$4`,
   [t,b,w,id]);
  assert.deepEqual(ledger.rows,[{delta_base:"-2.000000",kind:"ADJUSTMENT"}]);
  assert.equal((await make(endpoint+"/"+id+"/post",scope,4)).status,409);
  await assert.rejects(db.query(
   "UPDATE inventory_stocktake_count SET counted_base=100 WHERE installation_id=$1",[t]),
   /immutable/i);
  await assert.rejects(db.query(
   "UPDATE inventory_stocktake_line SET snapshot_on_hand=100 WHERE installation_id=$1",[t]),
   /immutable/i);
  const stale=await make(endpoint,{...scope,note:"Stale fixture"});
  assert.equal(stale.status,201);
  const staleId=stale.body.id;
  // A later committed warehouse movement invalidates the earlier snapshot.
  await db.query(`INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,
    product_id,kind,source_type,source_id,source_line,delta_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,'RECEIPT','PURCHASE_RECEIPT',$5,1,1,$6,'after-snapshot-fixture')`,
    [t,b,w,p,randomUUID(),root.actorId]);
  assert.equal((await make(endpoint+"/"+staleId+"/counts",{
    ...scope,lines:[{lineNo:1,round:1,quantity:"4"}]},1)).status,201);
  assert.equal((await make(endpoint+"/"+staleId+"/submit",scope,1)).status,200);
  assert.equal((await make(endpoint+"/"+staleId+"/approve",scope,2,
    "approve-stale-"+randomUUID(),secondLogin.body.token)).status,200);
  const shouldNotPost=await make(endpoint+"/"+staleId+"/post",scope,3);
  assert.equal(shouldNotPost.status,409,JSON.stringify(shouldNotPost.body));
  const q=await db.query<{n:string}>(
   "SELECT count(*)::text AS n FROM inventory_ledger WHERE installation_id=$1 AND source_type='STOCKTAKE'",
   [t]);
  assert.equal(q.rows[0]?.n,"1");
  const foreignWh=randomUUID();
  assert.equal((await call(endpoint+"?branchId="+b+"&warehouseId="+foreignWh,
   "GET",undefined,token)).status,403);
 }finally{
  if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)');
  await admin.end();
 }
});
