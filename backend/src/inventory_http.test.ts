import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { join, resolve } from "node:path";
import { mkdtempSync, copyFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import type { AddressInfo } from "node:net";
import { Pool } from "pg";
import { applyMigrations } from "./migrate.ts";
import { bootstrapInstallation } from "./bootstrap.ts";
import { buildApp } from "./server.ts";
import { isDatabaseReady } from "./db.ts";
import { validBaseQty, allocateWarehouseDemand, stockDecimalUnits, stockUnitsDecimal } from "./inventory.ts";

// Characterization: legacy sales-order-fulfillment-demand.test.js, d39e8a87.
// ERP uses six fractional digits, not the legacy twelve. No float conversion.
test("T0 legacy demand: deterministic full, partial and zero hold",()=>{
 const lines=[{lineNo:1,ordered:6000000n},{lineNo:2,ordered:6000000n}];
 const partial=allocateWarehouseDemand(lines,8000000n,true);
 assert.deepEqual(partial,{ok:true,allocations:[
  {...lines[0],reserved:6000000n,backordered:0n},
  {...lines[1],reserved:2000000n,backordered:4000000n},
 ]});
 assert.deepEqual(allocateWarehouseDemand(lines,8000000n,false),{
  ok:false,code:"SALES_ORDER_INSUFFICIENT_STOCK",required:12000000n,available:8000000n,
 });
 assert.deepEqual(allocateWarehouseDemand(lines,12000000n,true),{
  ok:true,allocations:lines.map(line=>({...line,reserved:line.ordered,backordered:0n})),
 });
 for(const available of [0n,-1000000n]){
  assert.deepEqual(allocateWarehouseDemand(lines,available,true),{
   ok:true,allocations:lines.map(line=>({...line,reserved:0n,backordered:line.ordered})),
  });
  assert.deepEqual(allocateWarehouseDemand(lines,available,false),{
   ok:false,code:"SALES_ORDER_INSUFFICIENT_STOCK",required:12000000n,available:0n,
  });
 }
 assert.deepEqual(lines,[{lineNo:1,ordered:6000000n},{lineNo:2,ordered:6000000n}]);
});
test("T0 legacy allocator rejects invalid demand, retains smallest exact unit",()=>{
 for(const ordered of [0n,-1n])
  assert.throws(()=>allocateWarehouseDemand([{ordered}],1n,true),/INVALID_QUANTITY/);
 const ordered=999999999999999999n;
 assert.deepEqual(allocateWarehouseDemand([{ordered}],ordered-1n,true),{
  ok:true,allocations:[{ordered,reserved:ordered-1n,backordered:1n}],
 });
});


test("R3 quantity contract accepts exact base-unit decimal strings only",()=>{
 assert.equal(stockDecimalUnits("9800.00125"),9800001250n);
 assert.equal(stockDecimalUnits("-0.000001"),-1n);
 assert.equal(stockUnitsDecimal(9800001250n),"9800.001250");
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
  assert.equal(installed.applied.length,22);
  assert.equal((await applyMigrations(pool,resolve(process.cwd(),"db/migrations"))).skipped.length,22);
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
  // Preserve the original strict R3 regression with explicit warehouse BLOCK.
  const pScope={branchId:b,warehouseId:w};
  const policy0=await call("/v1/inventory/guard-policy?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(policy0.status,200);
  assert.equal(policy0.body.policy.reserveShortageMode,"WARN");
  assert.equal(policy0.body.policy.negativeIssueMode,"BLOCK");
  const policyKey="stock-policy-"+randomUUID();
  const strict=await make("/v1/inventory/guard-policy",
    {...pScope,reserveShortageMode:"BLOCK"},0,policyKey);
  assert.equal(strict.status,200,JSON.stringify(strict.body));
  assert.equal(strict.body.reserveShortageMode,"BLOCK");
  assert.deepEqual((await make("/v1/inventory/guard-policy",
    {...pScope,reserveShortageMode:"BLOCK"},0,policyKey)).body,strict.body);
  assert.equal((await make("/v1/inventory/guard-policy",
    {...pScope,reserveShortageMode:"ALLOW"},0,policyKey)).status,409);

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
  // No mutation yet: late lifecycle regression checks safe hold release.
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
  // T0: switching policy affects future reservations, never rewrites old holds.
  assert.equal((await make("/v1/inventory/guard-policy",
   {...pScope,reserveShortageMode:"WARN"},0)).status,409);
  const warnedPolicy=await make("/v1/inventory/guard-policy",
   {...pScope,reserveShortageMode:"WARN"},1);
  assert.equal(warnedPolicy.status,200,JSON.stringify(warnedPolicy.body));
  assert.equal(warnedPolicy.body.revision,2);
  const largeOrder=await make("/v1/sales/orders",{
   ...orderData,lines:[{productId,quantity:"7"}]});
  assert.equal(largeOrder.status,201,JSON.stringify(largeOrder.body));
  assert.equal((await make("/v1/sales/orders/"+largeOrder.body.id+"/confirm",
   {branchId:b})).status,200);
  const heldLarge=await make("/v1/inventory/reservations",reservation(largeOrder.body.id));
  assert.equal(heldLarge.status,201,JSON.stringify(heldLarge.body));
  assert.equal(heldLarge.body.quantityBase,"2.000000");
  assert.equal(heldLarge.body.backorderedBase,"5.000000");
  assert.equal(heldLarge.body.warnings[0]?.severity,"WARN");
  const zeroOrder=await make("/v1/sales/orders",{
   ...orderData,lines:[{productId,quantity:"1"}]});
  assert.equal(zeroOrder.status,201);
  assert.equal((await make("/v1/sales/orders/"+zeroOrder.body.id+"/confirm",
   {branchId:b})).status,200);
  const zeroHold=await make("/v1/inventory/reservations",reservation(zeroOrder.body.id));
  assert.equal(zeroHold.status,201,JSON.stringify(zeroHold.body));
  assert.equal(zeroHold.body.quantityBase,"0.000000");
  assert.equal(zeroHold.body.backorderedBase,"1.000000");
  // Read the exact product: list pagination can place this SKU on page two.
  const nowHeld=await pool.query<{onHand:string;reserved:string;available:string}>(`
   SELECT on_hand::text AS "onHand",reserved::text AS reserved,
     available::text AS available FROM inventory_stock_balance
   WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND product_id=$4`,
   [t,b,w,productId]);
  assert.equal(nowHeld.rows[0]?.onHand,"5.000000");
  assert.equal(nowHeld.rows[0]?.reserved,"5.000000");
  assert.equal(nowHeld.rows[0]?.available,"0.000000");
  await assert.rejects(pool.query(
   `INSERT INTO inventory_reservation(installation_id,branch_id,warehouse_id,
     product_id,order_id,version_no,line_no,quantity_base,backordered_base,
     actor_id,request_id) VALUES($1,$2,$3,$4,$5,1,1,0,0,$6,'invalid-shortage')`,
   [t,b,w,productId,zeroOrder.body.id,root.actorId]),/check constraint|base quantity differs/i);
  assert.equal((await make("/v1/inventory/guard-policy",
   {...pScope,reserveShortageMode:"ALLOW"},2)).status,200);
  const readPolicy=await call("/v1/inventory/guard-policy?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(readPolicy.body.policy.reserveShortageMode,"ALLOW");
  assert.equal(readPolicy.body.policy.negativeIssueMode,"BLOCK");
  assert.equal((await make("/v1/inventory/guard-policy",
   {...pScope,reserveShortageMode:"UNSAFE"},3)).status,400);
  // Negative stock remains a hard ledger gate pending a trusted T3 posting source.
  await assert.rejects(pool.query(
   `INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,
     product_id,kind,source_type,source_id,source_line,delta_base,actor_id,request_id)
     VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,1,-1,$6,'negative-denied')`,
   [t,b,w,productId,randomUUID(),root.actorId]),/insufficient available stock/i);
  // Order edits/cancellation before physical posting must release unexecuted
  // holds/backorders atomically instead of trapping the operator.
  const amendedLarge=await make("/v1/sales/orders/"+largeOrder.body.id+"/amend",
    {branchId:b,reason:"Change planned order"},1);
  assert.equal(amendedLarge.status,201,JSON.stringify(amendedLarge.body));
  assert.equal(amendedLarge.body.version,2);
  const largeHoldAfter=await pool.query<{state:string;quantity:string;backordered:string}>(`
   SELECT state,quantity_base::text AS quantity,backordered_base::text AS backordered
   FROM inventory_reservation WHERE installation_id=$1 AND branch_id=$2
     AND order_id=$3 ORDER BY created_at DESC LIMIT 1`,
    [t,b,largeOrder.body.id]);
  assert.deepEqual(largeHoldAfter.rows[0],{state:"RELEASED",quantity:"2.000000",backordered:"5.000000"});
  const cancelledZero=await make("/v1/sales/orders/"+zeroOrder.body.id+"/cancel",
    {branchId:b,reason:"Waiting for stock"},1);
  assert.equal(cancelledZero.status,200,JSON.stringify(cancelledZero.body));
  const zeroHoldAfter=await pool.query<{state:string}>(`
   SELECT state FROM inventory_reservation WHERE installation_id=$1
     AND branch_id=$2 AND order_id=$3 ORDER BY created_at DESC LIMIT 1`,
    [t,b,zeroOrder.body.id]);
  assert.equal(zeroHoldAfter.rows[0]?.state,"RELEASED");
  // Same order mutation/command receipt must replay without releasing twice.
  const closeKey="cancel-replay-"+randomUUID();
  const cancelledWithReceipt=await make("/v1/sales/orders/"+orders[loser]+"/cancel",
    {branchId:b,reason:"No longer required"},1,closeKey);
  assert.equal(cancelledWithReceipt.status,200,JSON.stringify(cancelledWithReceipt.body));
  assert.deepEqual((await make("/v1/sales/orders/"+orders[loser]+"/cancel",
    {branchId:b,reason:"No longer required"},1,closeKey)).body,cancelledWithReceipt.body);
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


test("T0 populated 0020 -> 0021 preserves legacy reserve/read and owner grants",
 {skip:!ci},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const name="erp_ci_t0_upgrade_"+randomUUID().replaceAll("-","").slice(0,12);
 const tmp=mkdtempSync(join(tmpdir(),"erp-t0-old-schema-"));
 let pool:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  const dir=resolve(process.cwd(),"db/migrations");
  const sqlFiles=readdirSync(dir).filter(x=>/^\d{4}_[a-z0-9_]+\.sql$/.test(x)&&x.slice(0,4)<="0021");
  assert.equal(sqlFiles.length,21);
  for(const file of sqlFiles.filter(x=>!x.startsWith("0021_")))
   copyFileSync(join(dir,file),join(tmp,file));
  await admin.query('CREATE DATABASE "'+name+'"');
  const u=new URL(source!);u.pathname="/"+name;
  pool=new Pool({connectionString:u.toString(),max:8,query_timeout:12000});
  pool.on("error",()=>{});
  assert.equal((await applyMigrations(pool,tmp)).applied.length,20);
  const password="T0-Upgrade-"+randomUUID();
  const root=await bootstrapInstallation(pool,{
   code:"t0-old",displayName:"T0 baseline upgrade",adminLogin:"owner",adminPassword:password,
  });
  const t=root.installationId,b=root.branchId,w=root.warehouseId;
  // Emulate an installation bootstrapped with the old ERP permission catalog.
  // This test uses the new bootstrap helper, whose owner grants already include
  // inventory.policy.manage; that permission did not exist on the old release.
  await pool.query("DELETE FROM role_permission WHERE installation_id=$1 AND permission_code=$2",
   [t,"inventory.policy.manage"]);
  const pre=await pool.query<{role_id:string;permission_code:string}>(`
   SELECT role_id::text,permission_code FROM role_permission
   WHERE installation_id=$1 ORDER BY role_id,permission_code`,[t]);
  assert.ok(pre.rows.length>0);
  assert.ok(pre.rows.every(x=>x.permission_code!=="inventory.policy.manage"));
  server=buildApp(()=>isDatabaseReady(pool!),async()=>true,{
   pool,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"test-"+randomUUID(),
  });
  await new Promise<void>(ok=>server!.listen(0,"127.0.0.1",ok));
  const host="http://127.0.0.1:"+(server.address() as AddressInfo).port;
  const request=async(path:string,method="GET",data?:unknown,token?:string)=>{
   const key="t0-"+randomUUID();
   const response=await fetch(host+path,{method,headers:{
    origin:"https://erp.example.test",
    ...(data===undefined?{}:{"content-type":"application/json"}),
    ...(token?{authorization:"Bearer "+token}:{}),
    ...(method==="POST"?{"idempotency-key":key,"if-match":"0"}:{}),
   },body:data===undefined?undefined:JSON.stringify(data)});
   return {status:response.status,body:await response.json() as Record<string,any>};
  };
  const auth=await request("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(auth.status,200,JSON.stringify(auth.body));
  const token=auth.body.token as string;
  const oldPolicy=await request("/v1/inventory/guard-policy?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(oldPolicy.status,200,JSON.stringify(oldPolicy.body));
  assert.equal(oldPolicy.body.policy.reserveShortageMode,"BLOCK");
  assert.equal(oldPolicy.body.policy.migrationRequired,true);
  const oldList=await request("/v1/inventory/reservations?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(oldList.status,200,JSON.stringify(oldList.body));
  assert.deepEqual(oldList.body.items,[]);
  const catalog=async(path:string,values:Record<string,unknown>)=>request(
    "/v1/catalog/"+path,"POST",{branchId:b,...values},token);
  const cust=await catalog("customers",{code:"OLD-C",name:"Old customer"});
  const prod=await catalog("products",{code:"OLD-P",name:"Old product",baseUnit:"cai"});
  const list=await catalog("price-lists",{code:"OLD-PL",name:"Old price list"});
  for(const x of [cust,prod,list])assert.equal(x.status,201,JSON.stringify(x.body));
  const price=await catalog("prices",{priceListId:list.body.id,
    productId:prod.body.id,amount:"1000.0000",discountRate:"0",
    effectiveAt:"2026-01-01T00:00:00Z"});
  assert.equal(price.status,201,JSON.stringify(price.body));
  const order=await request("/v1/sales/orders","POST",{
   branchId:b,customerId:cust.body.id,priceListId:list.body.id,
   lines:[{productId:prod.body.id,quantity:"2"}],note:""},token);
  assert.equal(order.status,201,JSON.stringify(order.body));
  const confirmed=await request("/v1/sales/orders/"+order.body.id+"/confirm",
   "POST",{branchId:b},token);
  assert.equal(confirmed.status,200,JSON.stringify(confirmed.body));
  const opening=await request("/v1/inventory/openings","POST",
   {branchId:b,warehouseId:w,productId:prod.body.id,quantity:"3"},token);
  assert.equal(opening.status,201,JSON.stringify(opening.body));
  const reserved=await request("/v1/inventory/reservations","POST",
   {branchId:b,warehouseId:w,orderId:order.body.id,version:1,lineNo:1},token);
  assert.equal(reserved.status,201,JSON.stringify(reserved.body));
  assert.equal(reserved.body.quantityBase,"2.000000");
  assert.equal(reserved.body.backorderedBase,"0.000000");
  const listing=await request("/v1/inventory/reservations?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(listing.status,200,JSON.stringify(listing.body));
  assert.equal(listing.body.items[0].backorderedBase,"0.000000");
  const beforeRows=await pool.query(`
   SELECT id::text,quantity_base::text,state FROM inventory_reservation
    WHERE installation_id=$1 ORDER BY id`,[t]);
  copyFileSync(join(dir,'0021_t0_partial_reservation_policy.sql'),join(tmp,'0021_t0_partial_reservation_policy.sql'));
  const upgrade=await applyMigrations(pool,tmp);
  assert.deepEqual(upgrade.applied,["0021_t0_partial_reservation_policy.sql"]);
  assert.equal(upgrade.skipped.length,20);
  const after=await pool.query<{role_id:string;permission_code:string}>(`
   SELECT role_id::text,permission_code FROM role_permission
   WHERE installation_id=$1 ORDER BY role_id,permission_code`,[t]);
  for(const row of pre.rows)assert.ok(after.rows.some(x=>
    x.role_id===row.role_id&&x.permission_code===row.permission_code));
  const newGrant=after.rows.filter(x=>x.permission_code==="inventory.policy.manage");
  assert.equal(newGrant.length,1);
  assert.equal(after.rows.length,pre.rows.length+1);
  const afterRows=await pool.query(`
   SELECT id::text,quantity_base::text,state FROM inventory_reservation
    WHERE installation_id=$1 ORDER BY id`,[t]);
  assert.deepEqual(afterRows.rows,beforeRows.rows);
  const migrated=await request("/v1/inventory/guard-policy?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(migrated.status,200,JSON.stringify(migrated.body));
  assert.equal(migrated.body.policy.reserveShortageMode,"WARN");
 }finally{
  if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
  if(pool)await pool.end();
  await admin.query('DROP DATABASE IF EXISTS "'+name+'" WITH (FORCE)');
  await admin.end();
  rmSync(tmp,{recursive:true,force:true});
 }
});
