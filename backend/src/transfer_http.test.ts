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

const source=process.env.DATABASE_URL;
const ci=(()=>{
 try{const u=new URL(source??"");return ["localhost","127.0.0.1"].includes(u.hostname)
   &&u.pathname==="/erp_ci"&&u.username==="erp_ci";}
 catch{return false;}
})();
test("R3.3 transfer PostgreSQL: physical dispatch, in-transit, partial and raced receipt",
 {skip:!ci},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const name="erp_ci_transfer_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+name+'"');
  const uri=new URL(source!);uri.pathname="/"+name;
  db=new Pool({connectionString:uri.toString(),max:8,query_timeout:12000});
  db.on("error",()=>{});
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).applied.length,14);
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).skipped.length,14);
  const password="Synthetic-transfer-"+randomUUID();
  const root=await bootstrapInstallation(db,{code:"transfer-r3",displayName:"Transfer synthetic",
    adminLogin:"owner",adminPassword:password});
  const t=root.installationId,b=root.branchId,w=root.warehouseId;
  const dest=(await db.query<{id:string}>(
   "INSERT INTO warehouse(installation_id,branch_id,code,name) VALUES($1,$2,'DEST','Kho nhận') RETURNING id",
   [t,b])).rows[0]!.id;
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
    ...(token?{authorization:"Bearer "+token}:{}),...headers},
    body:data===undefined?undefined:JSON.stringify(data)});
   return {status:r.status,body:r.status===204?{}:await r.json() as Record<string,any>};
  };
  const login=await call("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(login.status,200,JSON.stringify(login.body));
  const token=login.body.token as string;
  const make=(path:string,data:unknown,revision=0,key="tx-"+randomUUID())=>
    call(path,"POST",data,token,{"idempotency-key":key,"if-match":String(revision)});
  const product=await make("/v1/catalog/products",{
    branchId:b,code:"TX1",name:"Transfer test SKU",baseUnit:"cai"});
  assert.equal(product.status,201,JSON.stringify(product.body));
  const p=product.body.id as string;
  const opening=await make("/v1/inventory/openings",{
    branchId:b,warehouseId:w,productId:p,quantity:"5"});
  assert.equal(opening.status,201,JSON.stringify(opening.body));
  const scope={branchId:b,sourceWarehouseId:w,destinationWarehouseId:dest};
  const line={productId:p,quantity:"3"};
  const endpoint="/v1/inventory/transfers";
  const draft={...scope,note:"Transit audit",lines:[line]};
  assert.equal((await make(endpoint,draft)).status,403);
  await db.query(
   `INSERT INTO user_role_warehouse(installation_id,user_id,role_id,branch_id,warehouse_id)
   SELECT ur.installation_id,ur.user_id,ur.role_id,ur.branch_id,$4
   FROM user_role ur JOIN app_role r ON r.installation_id=ur.installation_id
     AND r.id=ur.role_id
   WHERE ur.installation_id=$1 AND ur.user_id=$2 AND ur.branch_id=$3
      AND r.code='PRIMARY_OWNER_MAIN' ON CONFLICT DO NOTHING`,
   [t,root.actorId,b,dest]);
  const k="create-"+randomUUID();
  const created=await make(endpoint,draft,0,k);
  assert.equal(created.status,201,JSON.stringify(created.body));
  const id=created.body.id as string;
  assert.deepEqual((await make(endpoint,draft,0,k)).body,created.body);
  assert.equal((await make(endpoint,{...draft,lines:[{...line,quantity:"4"}]},0,k)).status,409);
  const detailPath=endpoint+"/"+id+"?branchId="+b+
   "&sourceWarehouseId="+w+"&destinationWarehouseId="+dest+"&warehouseId="+w;
  const detail=await call(detailPath,"GET",undefined,token);
  assert.equal(detail.status,200,JSON.stringify(detail.body));
  assert.equal(detail.body.transfer.lines[0].dispatchedBase,"3.000000");
  assert.equal((await call(endpoint+"?branchId="+b+"&warehouseId="+w)).status,401);
  assert.equal((await call(endpoint+"?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token,{origin:"https://evil.example.test"})).status,403);
  const approve=await make(endpoint+"/"+id+"/approve",scope,0);
  assert.equal(approve.status,200,JSON.stringify(approve.body));
  assert.equal(approve.body.status,"APPROVED");
  const before=await call("/v1/inventory/balances?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(before.body.items[0].onHand,"5.000000");
  const dispatchKey="dispatch-"+randomUUID();
  const sent=await make(endpoint+"/"+id+"/dispatch",scope,1,dispatchKey);
  assert.equal(sent.status,200,JSON.stringify(sent.body));
  assert.equal(sent.body.status,"IN_TRANSIT");
  assert.deepEqual((await make(endpoint+"/"+id+"/dispatch",scope,1,dispatchKey)).body,sent.body);
  const sourceStock=await call("/v1/inventory/balances?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(sourceStock.body.items[0].onHand,"2.000000");
  const destinationBefore=await call("/v1/inventory/balances?branchId="+b+
    "&warehouseId="+dest,"GET",undefined,token);
  assert.equal(destinationBefore.body.items.length,0);
  const transit=await db.query<{in_transit_base:string}>(
    `SELECT in_transit_base::text FROM inventory_transfer_in_transit
     WHERE installation_id=$1 AND branch_id=$2 AND transfer_id=$3`,[t,b,id]);
  assert.equal(transit.rows[0]?.in_transit_base,"3.000000");
  assert.equal((await make(endpoint+"/"+id+"/cancel",scope,2)).status,409);
  const receivePath=endpoint+"/"+id+"/receipts";
  const firstPayload={...scope,lines:[{transferLineNo:1,quantity:"1"}]};
  const receiptKey="receipt-"+randomUUID();
  const first=await make(receivePath,firstPayload,2,receiptKey);
  assert.equal(first.status,201,JSON.stringify(first.body));
  assert.equal(first.body.transferStatus,"PARTIALLY_RECEIVED");
  assert.deepEqual((await make(receivePath,firstPayload,2,receiptKey)).body,first.body);
  const middle=await db.query<{in_transit_base:string}>(
    `SELECT in_transit_base::text FROM inventory_transfer_in_transit
     WHERE installation_id=$1 AND branch_id=$2 AND transfer_id=$3`,[t,b,id]);
  assert.equal(middle.rows[0]?.in_transit_base,"2.000000");
  const over=await make(receivePath,{...scope,
    lines:[{transferLineNo:1,quantity:"3"}]},3);
  assert.equal(over.status,409,JSON.stringify(over.body));
  const second={...scope,lines:[{transferLineNo:1,quantity:"2"}]};
  const raced=await Promise.all([make(receivePath,second,3),make(receivePath,second,3)]);
  assert.deepEqual(raced.map(x=>x.status).sort(),[201,409],JSON.stringify(raced));
  const completed=await call(endpoint+"/"+id+"?branchId="+b+
   "&sourceWarehouseId="+w+"&destinationWarehouseId="+dest+"&warehouseId="+dest,
   "GET",undefined,token);
  assert.equal(completed.body.transfer.status,"RECEIVED");
  assert.equal(completed.body.transfer.lines[0].receivedBase,"3.000000");
  assert.equal(completed.body.transfer.lines[0].inTransitBase,"0.000000");
  assert.equal(completed.body.transfer.receipts.length,2);
  const receivedStock=await call("/v1/inventory/balances?branchId="+b+
    "&warehouseId="+dest,"GET",undefined,token);
  assert.equal(receivedStock.body.items[0].onHand,"3.000000");
  const movements=await db.query<{kind:string;n:string}>(
    `SELECT kind,count(*)::text AS n FROM inventory_ledger WHERE
      installation_id=$1 AND branch_id=$2 AND kind IN ('TRANSFER_IN','TRANSFER_OUT')
     GROUP BY kind ORDER BY kind`,[t,b]);
  assert.deepEqual(movements.rows,[{kind:"TRANSFER_IN",n:"2"},
    {kind:"TRANSFER_OUT",n:"1"}]);
  await assert.rejects(db.query(
   "UPDATE inventory_transfer_receipt_line SET quantity_base=9 WHERE installation_id=$1",[t]),
   /immutable/i);
  assert.equal((await make(receivePath,second,4)).status,409);
  const unknownWh=randomUUID();
  assert.equal((await call(endpoint+"?branchId="+b+"&warehouseId="+unknownWh,
    "GET",undefined,token)).status,403);
 }finally{
  if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+name+'" WITH (FORCE)');
  await admin.end();
 }
});
