import test from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import type {AddressInfo} from "node:net";
import {resolve} from "node:path";
import {Pool} from "pg";
import {applyMigrations} from "./migrate.ts";
import {buildApp} from "./server.ts";
import {bootstrapInstallation} from "./bootstrap.ts";
import {isDatabaseReady} from "./db.ts";

const source=process.env.DATABASE_URL;
const ephemeral=(()=>{
 try{const u=new URL(source??"");
  return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";
 }catch{return false;}
})();
test("T6 POS posts exactly once: PICKUP, inventory, AR, mixed payment and return",
 {skip:!ephemeral},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const dbName="erp_ci_pos_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+dbName+'"');
  const target=new URL(source!);target.pathname="/"+dbName;
  db=new Pool({connectionString:target.toString(),max:8,query_timeout:12000});
  db.on("error",()=>{});
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).applied.length,26);
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).skipped.length,26);
  const password="Pos-Testing-"+randomUUID();
  const root=await bootstrapInstallation(db,{code:"pos-test",displayName:"POS integration",
   adminLogin:"owner",adminPassword:password});
  const t=root.installationId,b=root.branchId,w=root.warehouseId;
  server=buildApp(()=>isDatabaseReady(db!),async()=>true,{
   pool:db,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"test-"+randomUUID(),
  });
  await new Promise<void>(ok=>server!.listen(0,"127.0.0.1",ok));
  const base="http://127.0.0.1:"+(server.address() as AddressInfo).port;
  const call=async(path:string,method="GET",data?:unknown,token?:string,
   extra:Record<string,string>={})=>{
   const r=await fetch(base+path,{method,headers:{
     origin:"https://erp.example.test",
     ...(data===undefined?{}:{"content-type":"application/json"}),
     ...(token?{authorization:"Bearer "+token}:{}),...extra,
    },body:data===undefined?undefined:JSON.stringify(data)});
   return {status:r.status,body:r.status===204?{}:await r.json() as Record<string,any>};
  };
  const login=await call("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(login.status,200,JSON.stringify(login.body));
  const token=login.body.token as string;
  const make=(path:string,data:unknown,key="pos-"+randomUUID())=>
   call(path,"POST",data,token,{"idempotency-key":key,"if-match":"0"});
  const catalog=(name:string,fields:Record<string,unknown>)=>
    make("/v1/catalog/"+name,{branchId:b,...fields});
  const product=await catalog("products",{code:"POS01",name:"Product A",baseUnit:"cai"});
  assert.equal(product.status,201,JSON.stringify(product.body));
  const list=await catalog("price-lists",{code:"RETAIL",name:"Retail price"});
  assert.equal(list.status,201,JSON.stringify(list.body));
  const price=await catalog("prices",{
   priceListId:list.body.id,productId:product.body.id,
   amount:"1000.0000",discountRate:"0",effectiveAt:"2026-01-01T00:00:00Z",
  });
  assert.equal(price.status,201,JSON.stringify(price.body));
  const open=await make("/v1/inventory/openings",{
   branchId:b,warehouseId:w,productId:product.body.id,quantity:"5.000000",
  });
  assert.equal(open.status,201,JSON.stringify(open.body));
  const walk=await make("/v1/sales/walk-in",{branchId:b});
  assert.equal(walk.status,200,JSON.stringify(walk.body));
  const skus=await call("/v1/catalog/r1/skus?branchId="+b+"&q=POS01","GET",undefined,token);
  assert.equal(skus.status,200);
  const sellSkuId=skus.body.items[0].id as string;
  const quote=await call("/v1/sales/quote","POST",{
   branchId:b,customerId:walk.body.customer.id,priceListId:list.body.id,
   lines:[{sellSkuId,quantity:"2"}],
  },token);
  assert.equal(quote.status,200,JSON.stringify(quote.body));
  assert.equal(quote.body.quote.grandTotal,"2000");
  const openShift=await make("/v1/pos/shifts/open",{
   branchId:b,warehouseId:w,counterName:"Quầy 1",openingCash:"100",
  });
  assert.equal(openShift.status,201,JSON.stringify(openShift.body));
  const current=await call("/v1/pos/shifts/current?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(current.body.shift.id,openShift.body.id);
  const payload={
   branchId:b,warehouseId:w,shiftId:openShift.body.id,
   customerId:walk.body.customer.id,priceListId:list.body.id,
   cashReceived:"2000",bankAmount:"500",
   lines:[{sellSkuId,quantity:"2",expectedPriceSignature:
     quote.body.quote.lines[0].priceSignature}],
  };
  assert.equal((await call("/v1/pos/checkouts","POST",payload)).status,401);
  const key="checkout-"+randomUUID();
  const settle=await make("/v1/pos/checkouts",payload,key);
  assert.equal(settle.status,201,JSON.stringify(settle.body));
  assert.equal(settle.body.paymentStatus,"PAID");
  assert.equal(settle.body.deliveryStatus,"DELIVERED");
  assert.equal(settle.body.fulfillmentStatus,"COMPLETED");
  assert.equal(settle.body.changeDue,"500");
  const replay=await make("/v1/pos/checkouts",payload,key);
  assert.equal(replay.status,201);
  assert.deepEqual(replay.body,settle.body);
  assert.equal((await make("/v1/pos/checkouts",{...payload,bankAmount:"1000"},key)).status,409);
  const receipt=await call("/v1/pos/checkouts/"+settle.body.id+
   "?branchId="+b+"&warehouseId="+w,"GET",undefined,token);
  assert.equal(receipt.status,200,JSON.stringify(receipt.body));
  assert.equal(receipt.body.receipt.lines[0].quantity,"2.000");
  const lost=await make("/v1/pos/recovery",{checkout:payload},key);
  assert.equal(lost.status,200,JSON.stringify(lost.body));
  assert.equal(lost.body.receipt.id,settle.body.id);
  // A cancellation arriving after COMMIT must replay the paid receipt.
  const cancelPaid=await make("/v1/pos/checkouts/cancel",{checkout:payload},key);
  assert.equal(cancelPaid.status,201);
  assert.deepEqual(cancelPaid.body,settle.body);
  const stock=await db.query<{on_hand:string}>(`SELECT on_hand::text FROM inventory_stock_balance
   WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND product_id=$4`,
   [t,b,w,product.body.id]);
  assert.equal(stock.rows[0]!.on_hand,"3.000000");
  const payment=await db.query<{n:string;sum:string}>(`SELECT count(*)::text AS n,
   sum(amount)::text AS sum FROM customer_receivable_ledger
   WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3`,
   [t,b,settle.body.orderId]);
  assert.equal(payment.rows[0]!.n,"3");
  assert.equal(payment.rows[0]!.sum,"0");
  const posts=await db.query<{n:string}>(`SELECT count(*)::text AS n FROM inventory_ledger
   WHERE installation_id=$1 AND branch_id=$2 AND source_type='FULFILLMENT' AND source_id=$3`,
   [t,b,(await db.query<{fulfillment_id:string}>(`SELECT fulfillment_id FROM retail_checkout
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [t,b,settle.body.id])).rows[0]!.fulfillment_id]);
  assert.equal(posts.rows[0]!.n,"1");
  const ret=await make("/v1/pos/returns",{
   branchId:b,warehouseId:w,shiftId:openShift.body.id,
   checkoutId:settle.body.id,refundMethod:"BANK_TRANSFER",
  },"return-"+randomUUID());
  assert.equal(ret.status,201,JSON.stringify(ret.body));
  assert.equal((await make("/v1/pos/returns",{
   branchId:b,warehouseId:w,shiftId:openShift.body.id,
   checkoutId:settle.body.id,refundMethod:"BANK_TRANSFER",
  })).status,409);
  const restored=await db.query<{on_hand:string}>(`SELECT on_hand::text FROM inventory_stock_balance
   WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND product_id=$4`,
   [t,b,w,product.body.id]);
  assert.equal(restored.rows[0]!.on_hand,"5.000000");
  await assert.rejects(db.query(`UPDATE customer_receivable_ledger SET amount=123
   WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3`,
   [t,b,settle.body.orderId]),/immutable/i);
  const closed=await make("/v1/pos/shifts/"+openShift.body.id+"/close",{
    branchId:b,warehouseId:w,closingCash:"1600",
  });
  assert.equal(closed.status,200,JSON.stringify(closed.body));
  assert.equal(closed.body.expectedCash,"1600");
  assert.equal(closed.body.variance,"0");
  // Two cashiers/devices racing for the same 5 physical units cannot both
  // issue 4. The failed checkout rolls its order and payment back atomically.
  const nextShift=await make("/v1/pos/shifts/open",{
    branchId:b,warehouseId:w,counterName:"Quầy sau kiểm ca",openingCash:"0",
  });
  assert.equal(nextShift.status,201,JSON.stringify(nextShift.body));
  const quoteFour=await call("/v1/sales/quote","POST",{
    branchId:b,customerId:walk.body.customer.id,priceListId:list.body.id,
    lines:[{sellSkuId,quantity:"4"}],
  },token);
  assert.equal(quoteFour.status,200,JSON.stringify(quoteFour.body));
  const raced={...payload,shiftId:nextShift.body.id,
    cashReceived:"4000",bankAmount:"0",
    lines:[{sellSkuId,quantity:"4",
      expectedPriceSignature:quoteFour.body.quote.lines[0].priceSignature}]};
  const competing=await Promise.all([
    make("/v1/pos/checkouts",raced,"race-a-"+randomUUID()),
    make("/v1/pos/checkouts",raced,"race-b-"+randomUUID()),
  ]);
  assert.deepEqual(competing.map(x=>x.status).sort(),[201,409],
    JSON.stringify(competing.map(x=>x.body)));
  const afterRace=await db.query<{on_hand:string}>(`SELECT on_hand::text
   FROM inventory_stock_balance WHERE installation_id=$1 AND branch_id=$2
   AND warehouse_id=$3 AND product_id=$4`,[t,b,w,product.body.id]);
  assert.equal(afterRace.rows[0]!.on_hand,"1.000000");

  // Codex P1: terminal stock rejection must not trap the cashier forever.
  // Cancellation commits a terminal receipt with the SAME original key and
  // fingerprint, so a late/retried request cannot create a ghost sale.
  const rejected={...payload,shiftId:nextShift.body.id};
  const rejectedKey="stock-rejected-"+randomUUID();
  const noStock=await make("/v1/pos/checkouts",rejected,rejectedKey);
  assert.equal(noStock.status,409,JSON.stringify(noStock.body));
  const release=await make("/v1/pos/checkouts/cancel",{checkout:rejected},rejectedKey);
  assert.equal(release.status,200,JSON.stringify(release.body));
  assert.equal(release.body.status,"CANCELED");
  const recovered=await make("/v1/pos/recovery",{checkout:rejected},rejectedKey);
  assert.equal(recovered.body.receipt.status,"CANCELED");
  const retryDenied=await make("/v1/pos/checkouts",rejected,rejectedKey);
  assert.equal(retryDenied.status,200);
  assert.equal(retryDenied.body.status,"CANCELED");
  assert.equal((await make("/v1/pos/checkouts",
    {...rejected,cashReceived:"3000"},rejectedKey)).status,409);
  const stillOne=await db.query<{on_hand:string}>(`SELECT on_hand::text
   FROM inventory_stock_balance WHERE installation_id=$1 AND branch_id=$2
    AND warehouse_id=$3 AND product_id=$4`,[t,b,w,product.body.id]);
  assert.equal(stillOne.rows[0]!.on_hand,"1.000000");

  // Next cashier intent with a fresh key/quote can now sell the last unit.
  const quoteOne=await call("/v1/sales/quote","POST",{
   branchId:b,customerId:walk.body.customer.id,priceListId:list.body.id,
   lines:[{sellSkuId,quantity:"1"}],
  },token);
  assert.equal(quoteOne.status,200);
  const replacement={...rejected,cashReceived:"1000",bankAmount:"0",
   lines:[{sellSkuId,quantity:"1",
    expectedPriceSignature:quoteOne.body.quote.lines[0].priceSignature}]};
  const resumed=await make("/v1/pos/checkouts",replacement,"resumed-"+randomUUID());
  assert.equal(resumed.status,201,JSON.stringify(resumed.body));
  assert.equal(resumed.body.total,"1000");
  const gone=await db.query<{on_hand:string}>(`SELECT on_hand::text
   FROM inventory_stock_balance WHERE installation_id=$1 AND branch_id=$2
    AND warehouse_id=$3 AND product_id=$4`,[t,b,w,product.body.id]);
  assert.equal(gone.rows[0]!.on_hand,"0.000000");


 }finally{
  if(server)await new Promise<void>(done=>server!.close(()=>done()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)').catch(()=>undefined);
  await admin.end();
 }
});
