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
import { validBaseQty } from "./inventory.ts";

test("R3 quantity contract accepts exact base-unit decimal strings only",()=>{
 for(const v of ["1","0.000001","25.500000","100000000000.123456"])
  assert.equal(validBaseQty(v),true,v);
 for(const v of [null,1,"0","0.000000","-2","1e3","1.1234567","01","1."])
  assert.equal(validBaseQty(v),false,String(v));
});
const source=process.env.DATABASE_URL;
const ci=(()=>{
 try{const u=new URL(source??"");return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";}
 catch{return false;}
})();
test("R3 real PostgreSQL: on-hand, hold, release, no oversell, exact replay, RBAC, immutable ledger",
 {skip:!ci},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const dbName="erp_ci_r3_"+randomUUID().replaceAll("-","").slice(0,12);
 let pool:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+dbName+'"');
  const u=new URL(source!);u.pathname="/"+dbName;
  pool=new Pool({connectionString:u.toString(),max:8,query_timeout:12000});
  pool.on("error",()=>{});
  const installed=await applyMigrations(pool,resolve(process.cwd(),"db/migrations"));
  assert.equal(installed.applied.length,14);
  assert.equal((await applyMigrations(pool,resolve(process.cwd(),"db/migrations"))).skipped.length,14);
  const password="R3-PG-Synthetic-"+randomUUID();
  const root=await bootstrapInstallation(pool,{code:"r3-test",displayName:"R3 stock integration",
   adminLogin:"owner",adminPassword:password});
  const t=root.installationId,b=root.branchId,w=root.warehouseId;
  server=buildApp(()=>isDatabaseReady(pool!),async()=>true,{
   pool,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"test-"+randomUUID(),
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
  const make=(path:string,data:unknown,expected=0,key="r3-"+randomUUID())=>
   call(path,"POST",data,token,{"idempotency-key":key,"if-match":String(expected)});
  const catalog=(name:string,value:Record<string,unknown>)=>
   make("/v1/catalog/"+name,{branchId:b,...value});
  const customer=await catalog("customers",{code:"C1",name:"R3 Test Customer"});
  assert.equal(customer.status,201,JSON.stringify(customer.body));
  const product=await catalog("products",{code:"P1",name:"Synthetic item",baseUnit:"cai"});
  assert.equal(product.status,201,JSON.stringify(product.body));
  const priceList=await catalog("price-lists",{code:"PL1",name:"Price list"});
  assert.equal(priceList.status,201,JSON.stringify(priceList.body));
  const price=await catalog("prices",{priceListId:priceList.body.id,
   productId:product.body.id,amount:"1000.0000",discountRate:"0",
   effectiveAt:"2026-01-01T00:00:00Z"});
  assert.equal(price.status,201,JSON.stringify(price.body));
  const productId=product.body.id as string;
  const opening={branchId:b,warehouseId:w,productId,quantity:"5.000000"};
  assert.equal((await call("/v1/inventory/balances?branchId="+b+"&warehouseId="+w)).status,401);
  assert.equal((await call("/v1/inventory/balances?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token,{origin:"https://evil.example.test"})).status,403);
  const openKey="open-"+randomUUID();
  const opened=await make("/v1/inventory/openings",opening,0,openKey);
  assert.equal(opened.status,201,JSON.stringify(opened.body));
  assert.equal(opened.body.deltaBase,"5.000000");
  assert.deepEqual((await make("/v1/inventory/openings",opening,0,openKey)).body,opened.body);
  assert.equal((await make("/v1/inventory/openings",{...opening,quantity:"6"},0,openKey)).status,409);
  assert.equal((await make("/v1/inventory/openings",opening)).status,409);
  assert.equal((await make("/v1/inventory/openings",{...opening,quantity:5})).status,400);
  const orderData={branchId:b,customerId:customer.body.id,priceListId:priceList.body.id,
   lines:[{productId,quantity:"3"}],note:""};
  const orders=[];
  for(let i=0;i<2;i++){
   const made=await make("/v1/sales/orders",orderData);
   assert.equal(made.status,201,JSON.stringify(made.body));
   const confirmed=await make("/v1/sales/orders/"+made.body.id+"/confirm",{branchId:b});
   assert.equal(confirmed.status,200,JSON.stringify(confirmed.body));
   orders.push(made.body.id as string);
  }
  const reservation=(id:string)=>({branchId:b,warehouseId:w,orderId:id,version:1,lineNo:1});
  const keys=["reserve-a-"+randomUUID(),"reserve-b-"+randomUUID()];
  const competing=await Promise.all([
   make("/v1/inventory/reservations",reservation(orders[0]!),0,keys[0]),
   make("/v1/inventory/reservations",reservation(orders[1]!),0,keys[1]),
  ]);
  assert.deepEqual(competing.map(x=>x.status).sort(),[201,409],
   JSON.stringify(competing.map(x=>x.body)));
  const winner=competing[0]!.status===201?0:1,loser=1-winner;
  const accepted=competing[winner]!;
  assert.equal(accepted.body.quantityBase,"3.000000");
  assert.deepEqual((await make("/v1/inventory/reservations",
   reservation(orders[winner]!),0,keys[winner]!)).body,accepted.body);
  assert.equal((await make("/v1/inventory/reservations",
   reservation(orders[loser]!),0,keys[winner]!)).status,409);
  assert.equal((await make("/v1/inventory/reservations",
   reservation(orders[winner]!))).status,409);
  const stock=await call("/v1/inventory/balances?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(stock.status,200,JSON.stringify(stock.body));
  assert.equal(stock.body.items[0].onHand,"5.000000");
  assert.equal(stock.body.items[0].reserved,"3.000000");
  assert.equal(stock.body.items[0].available,"2.000000");
  // Database-level guard protects against bypassing the HTTP posting service.
  await assert.rejects(pool.query(
   `INSERT INTO inventory_reservation (installation_id,branch_id,warehouse_id,
     product_id,order_id,version_no,line_no,quantity_base,actor_id,request_id)
     VALUES($1,$2,$3,$4,$5,1,1,3,$6,'direct-stock-test')`,
   [t,b,w,productId,orders[loser]!,root.actorId]),/exceeds available stock/i);
  await assert.rejects(pool.query(
   `INSERT INTO inventory_ledger (installation_id,branch_id,warehouse_id,product_id,
     kind,source_type,source_id,source_line,delta_base,actor_id,request_id)
     VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,1,-3,$6,'direct-issue-test')`,
   [t,b,w,productId,randomUUID(),root.actorId]),/insufficient available stock/i);
  const heldOrder=orders[winner]!;
  assert.equal((await make("/v1/sales/orders/"+heldOrder+"/amend",
   {branchId:b,reason:"Change planned order"},1)).status,409);
  assert.equal((await make("/v1/sales/orders/"+heldOrder+"/cancel",
   {branchId:b,reason:"Cancel test order"},1)).status,409);
  const held=await call("/v1/inventory/reservations?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(held.status,200);assert.equal(held.body.items.length,1);
  assert.equal(held.body.hasMore,false);
  assert.equal(held.body.items[0].state,"ACTIVE");
  // Regression for Codex P2: 105 newer RELEASED events must not conceal an old ACTIVE hold.
  const smallOrder=await make("/v1/sales/orders",{...orderData,
    lines:[{productId,quantity:"1"}]});
  assert.equal(smallOrder.status,201,JSON.stringify(smallOrder.body));
  assert.equal((await make("/v1/sales/orders/"+smallOrder.body.id+"/confirm",
    {branchId:b})).status,200);
  const setupInsert=`INSERT INTO inventory_reservation
   (installation_id,branch_id,warehouse_id,product_id,order_id,
    version_no,line_no,quantity_base,actor_id,request_id)
   VALUES($1,$2,$3,$4,$5,1,1,1,$6,'history-fixture')
   RETURNING id`;
  for(let i=0;i<105;i++){
    const id=(await pool.query<{id:string}>(setupInsert,
     [t,b,w,productId,smallOrder.body.id,root.actorId])).rows[0]!.id;
    await pool.query(
     "UPDATE inventory_reservation SET state='RELEASED',revision=1,released_at=now() WHERE installation_id=$1 AND branch_id=$2 AND id=$3",
     [t,b,id]);
  }
  const activePage=await call("/v1/inventory/reservations?branchId="+b+
    "&warehouseId="+w+"&state=ACTIVE","GET",undefined,token);
  assert.equal(activePage.status,200,JSON.stringify(activePage.body));
  assert.equal(activePage.body.items.length,1);
  assert.equal(activePage.body.items[0].id,accepted.body.id);
  assert.equal(activePage.body.hasMore,false);
  const historyPage=await call("/v1/inventory/reservations?branchId="+b+
    "&warehouseId="+w+"&state=RELEASED","GET",undefined,token);
  assert.equal(historyPage.status,200);
  assert.equal(historyPage.body.items.length,100);
  assert.equal(historyPage.body.hasMore,true);
  const lastHistory=await call("/v1/inventory/reservations?branchId="+b+
    "&warehouseId="+w+"&state=RELEASED&offset=100","GET",undefined,token);
  assert.equal(lastHistory.status,200);
  assert.equal(lastHistory.body.items.length,5);
  assert.equal(lastHistory.body.hasMore,false);
  const badPage=await call("/v1/inventory/reservations?branchId="+b+
    "&warehouseId="+w+"&state=RELEASED&offset=-1","GET",undefined,token);
  assert.equal(badPage.status,400);

  const releasePath="/v1/inventory/reservations/"+accepted.body.id+"/release";
  const releaseKey="release-"+randomUUID();
  const released=await make(releasePath,{branchId:b,warehouseId:w},0,releaseKey);
  assert.equal(released.status,200,JSON.stringify(released.body));
  assert.equal(released.body.stock.reserved,"0.000000");
  const releasedList=await call("/v1/inventory/reservations?branchId="+b+
    "&warehouseId="+w+"&state=RELEASED","GET",undefined,token);
  assert.equal(releasedList.status,200);
  assert.equal(releasedList.body.items.length,100);
  assert.equal(releasedList.body.hasMore,true);
  const releasedTail=await call("/v1/inventory/reservations?branchId="+b+
    "&warehouseId="+w+"&state=RELEASED&offset=100","GET",undefined,token);
  assert.equal(releasedTail.body.items.length,6);
  assert.equal(releasedTail.body.items.some(
    (x:Record<string,string>)=>x.id===accepted.body.id),true);

  assert.equal((await make(releasePath,{branchId:b,warehouseId:w},0,
   "different-release-"+randomUUID())).status,409);
  assert.deepEqual((await make(releasePath,{branchId:b,warehouseId:w},0,releaseKey)).body,
   released.body);
  // A released row is immutable audit history; the same sales line may be held again.
  const reheld=await make("/v1/inventory/reservations",reservation(heldOrder));
  assert.equal(reheld.status,201,JSON.stringify(reheld.body));
  assert.equal(reheld.body.state,"ACTIVE");
  assert.notEqual(reheld.body.id,accepted.body.id);
  const reRelease=await make("/v1/inventory/reservations/"+reheld.body.id+"/release",
   {branchId:b,warehouseId:w},0);
  assert.equal(reRelease.status,200,JSON.stringify(reRelease.body));
  assert.equal((await make("/v1/inventory/reservations",
   reservation(orders[loser]!))).status,201);
  assert.equal((await make("/v1/sales/orders/"+heldOrder+"/cancel",
   {branchId:b,reason:"Cancel test order"},1)).status,200);
  const ledger=await call("/v1/inventory/movements?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(ledger.status,200);assert.equal(ledger.body.items.length,1);
  assert.equal(ledger.body.items[0].kind,"OPENING");
  // Codex P1 regressions: reject numeric NaN and never credit a different SKU on reversal.
  const otherProduct=await catalog("products",{
    code:"P2",name:"Second synthetic SKU",baseUnit:"cai"});
  assert.equal(otherProduct.status,201,JSON.stringify(otherProduct.body));
  const otherId=otherProduct.body.id as string;
  const directLedger=`INSERT INTO inventory_ledger(
    installation_id,branch_id,warehouse_id,product_id,kind,source_type,
    source_id,source_line,delta_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,$5,$6,$7,1,$8::numeric,$9,$10)
    RETURNING id`;
  await assert.rejects(pool.query(directLedger,[
    t,b,w,otherId,"OPENING","OPENING",otherId,"NaN",root.actorId,"nan-rejected"
  ]),/check constraint/i);
  const otherAfterNan=await pool.query<{count:string}>(
    "SELECT count(*)::text AS count FROM inventory_ledger WHERE installation_id=$1 AND product_id=$2",
    [t,otherId]);
  assert.equal(otherAfterNan.rows[0]?.count,"0");
  const issueId=(await pool.query<{id:string}>(directLedger,[
    t,b,w,productId,"ISSUE","FULFILLMENT",randomUUID(),"-1",root.actorId,"issue-for-reversal"
  ])).rows[0]!.id;
  const readStock=(id:string)=>pool!.query<{onHand:string;available:string}>(
    `SELECT on_hand::text AS "onHand",available::text AS "available"
     FROM inventory_stock_balance WHERE installation_id=$1 AND branch_id=$2
       AND warehouse_id=$3 AND product_id=$4`,[t,b,w,id]);
  const afterIssue=(await readStock(productId)).rows[0]!;
  assert.equal(afterIssue.onHand,"4.000000");
  const otherBefore=(await readStock(otherId)).rows;
  assert.equal(otherBefore.length,0);
  await assert.rejects(pool.query(
    `INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,product_id,
       kind,source_type,source_id,source_line,delta_base,
       reversal_of,actor_id,request_id)
     VALUES($1,$2,$3,$4,'REVERSAL','REVERSAL',$5,1,1,$6,$7,'wrong-product-reversal')`,
    [t,b,w,otherId,randomUUID(),issueId,root.actorId]
  ),/Reversal product must match original movement/i);
  assert.equal((await readStock(productId)).rows[0]?.onHand,afterIssue.onHand);
  assert.equal((await readStock(otherId)).rows.length,0);
  await pool.query(
    `INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,product_id,
       kind,source_type,source_id,source_line,delta_base,
       reversal_of,actor_id,request_id)
     VALUES($1,$2,$3,$4,'REVERSAL','REVERSAL',$5,1,1,$6,$7,'valid-product-reversal')`,
    [t,b,w,productId,randomUUID(),issueId,root.actorId]);
  assert.equal((await readStock(productId)).rows[0]?.onHand,"5.000000");
  assert.equal((await readStock(otherId)).rows.length,0);
  await assert.rejects(pool.query(
   "UPDATE inventory_ledger SET delta_base=100 WHERE installation_id=$1",
   [t]),/immutable/i);
  await assert.rejects(pool.query("DELETE FROM inventory_ledger WHERE installation_id=$1",[t]),
   /immutable/i);
  // A new warehouse is not automatically granted to an existing branch role.
  const newWh=await pool.query<{id:string}>(
   "INSERT INTO warehouse(installation_id,branch_id,code,name) VALUES($1,$2,'OTHER','Other warehouse') RETURNING id",
   [t,b]);
  assert.equal((await make("/v1/inventory/openings",
   {...opening,warehouseId:newWh.rows[0]!.id})).status,403);
  assert.equal((await call("/v1/inventory/balances?branchId="+b+
   "&warehouseId="+newWh.rows[0]!.id,"GET",undefined,token)).status,403);
  // Codex P2: never permanently hide stocked SKUs or movement facts after page 1.
  const bulk=await pool.query<{id:string}>(`
    INSERT INTO catalog_product(installation_id,branch_id,sku,name,base_unit)
    SELECT $1,$2,'BULK'||g::text,'Bulk item '||g::text,'cai'
    FROM generate_series(1,105) AS g RETURNING id`,[t,b]);
  assert.equal(bulk.rows.length,105);
  await pool.query(`INSERT INTO inventory_ledger
    (installation_id,branch_id,warehouse_id,product_id,kind,source_type,
      source_id,source_line,delta_base,actor_id,request_id)
    SELECT $1,$2,$3,id,'OPENING','OPENING',id,1,1,$4,'bulk-inventory-fixture'
    FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 AND sku LIKE 'BULK%'`,
    [t,b,w,root.actorId]);
  const firstStock=await call("/v1/inventory/balances?branchId="+b+
    "&warehouseId="+w+"&offset=0","GET",undefined,token);
  assert.equal(firstStock.status,200);
  assert.equal(firstStock.body.items.length,100);
  assert.equal(firstStock.body.hasMore,true);
  const lastStock=await call("/v1/inventory/balances?branchId="+b+
    "&warehouseId="+w+"&offset=100","GET",undefined,token);
  assert.equal(lastStock.status,200);
  assert.equal(lastStock.body.items.length,6);
  assert.equal(lastStock.body.hasMore,false);
  const allSkus=[...firstStock.body.items,...lastStock.body.items]
    .map((x:Record<string,string>)=>x.sku);
  assert.equal(new Set(allSkus).size,106);
  const firstMovements=await call("/v1/inventory/movements?branchId="+b+
    "&warehouseId="+w+"&offset=0","GET",undefined,token);
  assert.equal(firstMovements.body.items.length,100);
  assert.equal(firstMovements.body.hasMore,true);
  const lastMovements=await call("/v1/inventory/movements?branchId="+b+
    "&warehouseId="+w+"&offset=100","GET",undefined,token);
  assert.equal(lastMovements.body.items.length,8);
  assert.equal(lastMovements.body.hasMore,false);
  assert.equal((await call("/v1/inventory/balances?branchId="+b+
    "&warehouseId="+w+"&offset=-1","GET",undefined,token)).status,400);
  // Simulate a production installation still on Sales 0010 while Inventory 0011 awaits approval.
  // Existing legitimate commercial actions must remain available without the new relation.
  await pool.query("DROP TABLE inventory_reservation CASCADE");
  const olderSale=await make("/v1/sales/orders",orderData);
  assert.equal(olderSale.status,201,JSON.stringify(olderSale.body));
  assert.equal((await make("/v1/sales/orders/"+olderSale.body.id+"/confirm",
    {branchId:b})).status,200);
  const amended=await make("/v1/sales/orders/"+olderSale.body.id+"/amend",
    {branchId:b,reason:"Regression for 0010-only sales"},1);
  assert.equal(amended.status,201,JSON.stringify(amended.body));
  const cancelled=await make("/v1/sales/orders/"+olderSale.body.id+"/cancel",
    {branchId:b,reason:"Regression for 0010-only sales"},2);
  assert.equal(cancelled.status,200,JSON.stringify(cancelled.body));
 } finally {
  if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
  if(pool)await pool.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)');
  await admin.end();
 }
});
