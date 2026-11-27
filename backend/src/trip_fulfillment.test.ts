import test from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {resolve} from "node:path";
import type {AddressInfo} from "node:net";
import {Pool} from "pg";
import {applyMigrations} from "./migrate.ts";
import {bootstrapInstallation} from "./bootstrap.ts";
import {buildApp} from "./server.ts";
import {isDatabaseReady} from "./db.ts";

const source=process.env.DATABASE_URL;
const ci=(()=>{
 try{const u=new URL(source??"");
  return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";
 }catch{return false;}
})();
test("T3-C PostgreSQL: whole hold, partial pick/pack, physical dispatch, ledger, retry and RBAC",
 {skip:!ci},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const dbName="erp_ci_t3c_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+dbName+'"');
  const u=new URL(source!);u.pathname="/"+dbName;
  db=new Pool({connectionString:u.toString(),max:8,query_timeout:20000});
  db.on("error",()=>{});
  const installed=await applyMigrations(db,resolve(process.cwd(),"db/migrations"));
  assert.equal(installed.applied.length,25);
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).skipped.length,25);
  const password="trip-secret-"+randomUUID();
  const root=await bootstrapInstallation(db,{code:"trip-ci",displayName:"Trip CI",
   adminLogin:"owner",adminPassword:password});
  const t=root.installationId,b=root.branchId,w=root.warehouseId;
  server=buildApp(()=>isDatabaseReady(db!),async()=>true,{
   pool:db,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"test-"+randomUUID(),
  });
  await new Promise<void>(ok=>server!.listen(0,"127.0.0.1",ok));
  const host="http://127.0.0.1:"+(server.address() as AddressInfo).port;
  const call=async(path:string,method="GET",data?:unknown,token?:string,
   extras:Record<string,string>={})=>{
    const response=await fetch(host+path,{method,headers:{
     origin:"https://erp.example.test",
     ...(data===undefined?{}:{"content-type":"application/json"}),
     ...(token?{authorization:"Bearer "+token}:{}),...extras,
    },body:data===undefined?undefined:JSON.stringify(data)});
    return {status:response.status,body:response.status===204?{}:
      await response.json() as Record<string,any>};
  };
  const login=await call("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(login.status,200,JSON.stringify(login.body));
  const token=login.body.token as string;
  const write=(path:string,data:unknown,revision=0,key="t3c-"+randomUUID())=>
    call(path,"POST",data,token,{"idempotency-key":key,"if-match":String(revision)});
  const catalog=(kind:string,data:Record<string,unknown>)=>
    write("/v1/catalog/"+kind,{branchId:b,...data});
  const customer=await catalog("customers",{code:"TRIPC",name:"Trip buyer"});
  assert.equal(customer.status,201,JSON.stringify(customer.body));
  const list=await catalog("price-lists",{code:"TRIPPL",name:"Trip prices"});
  assert.equal(list.status,201,JSON.stringify(list.body));
  const product=await catalog("products",{code:"TRIPP",name:"Trip item",baseUnit:"cai"});
  assert.equal(product.status,201,JSON.stringify(product.body));
  assert.equal((await catalog("prices",{priceListId:list.body.id,productId:product.body.id,
   amount:"1000.0000",discountRate:"0",effectiveAt:"2026-01-01T00:00:00Z"})).status,201);
  const p=product.body.id as string;
  assert.equal((await write("/v1/inventory/openings",{branchId:b,warehouseId:w,
   productId:p,quantity:"5.000000"})).status,201);
  const made=await write("/v1/sales/orders",{
   branchId:b,customerId:customer.body.id,priceListId:list.body.id,
   shipping:{warehouseId:w,deliveryChoice:"TRIP",
    collectionPolicy:"CREDIT_TERMS",customerMode:"EXISTING"},
   lines:[{productId:p,quantity:"4"}]});
  assert.equal(made.status,201,JSON.stringify(made.body));
  const id=made.body.id as string;
  assert.equal((await write("/v1/sales/orders/"+id+"/confirm",{branchId:b})).status,200);
  const qstr="?"+new URLSearchParams({branchId:b,warehouseId:w,orderId:id,version:"1"});
  const pre=await call("/v1/inventory/trips/work"+qstr,"GET",undefined,token);
  assert.equal(pre.status,200,JSON.stringify(pre.body));
  assert.equal(pre.body.lines[0].reservedBase,"0.000000");
  assert.equal((await write("/v1/inventory/trips/prepare",{
   branchId:b,warehouseId:w,orderId:id,version:1,lines:[
    {lineNo:1,pickedBase:"1",packedBase:"1"}]},1)).status,409);
  const held=await write("/v1/inventory/trip-holds",{
   branchId:b,warehouseId:w,orderId:id,version:1},1);
  assert.equal(held.status,200,JSON.stringify(held.body));
  assert.equal(held.body.revision,2);
  assert.equal(held.body.lines[0].quantityBase,"4.000000");
  const holdId=held.body.lines[0].reservationId as string;
  const firstPayload={branchId:b,warehouseId:w,orderId:id,version:1,lines:[
    {lineNo:1,pickedBase:"3.000000",packedBase:"2.000000"}]};
  const prepKey="t3c-prep-"+randomUUID();
  const first=await write("/v1/inventory/trips/prepare",firstPayload,2,prepKey);
  assert.equal(first.status,201,JSON.stringify(first.body));
  assert.equal(first.body.revision,3);
  assert.equal(first.body.inventoryPosted,false);
  assert.equal(first.body.lines[0].pickedBase,"3.000000");
  assert.equal(first.body.lines[0].packedBase,"2.000000");
  assert.equal(first.body.lines[0].readyBase,"2.000000");
  assert.deepEqual((await write("/v1/inventory/trips/prepare",
   firstPayload,2,prepKey)).body,first.body);
  assert.equal((await write("/v1/inventory/trips/prepare",
   {...firstPayload,lines:[{lineNo:1,pickedBase:"2",packedBase:"2"}]},2,prepKey)).status,409);
  assert.equal((await write("/v1/inventory/reservations/"+holdId+"/release",
   {branchId:b,warehouseId:w},0)).status,409);
  const next=await write("/v1/inventory/trips/prepare",{
   branchId:b,warehouseId:w,orderId:id,version:1,lines:[
    {lineNo:1,pickedBase:"1",packedBase:"2"}]},3);
  assert.equal(next.status,201,JSON.stringify(next.body));
  assert.equal(next.body.lines[0].pickedBase,"4.000000");
  assert.equal(next.body.lines[0].packedBase,"4.000000");
  const parts=next.body.lines[0].preparations as Record<string,any>[];
  assert.equal(parts.length,2);
  const before=await call("/v1/inventory/balances?"+
   new URLSearchParams({branchId:b,warehouseId:w}).toString(),"GET",undefined,token);
  assert.equal(before.body.items[0].onHand,"5.000000");
  const initialDispatch={branchId:b,warehouseId:w,orderId:id,version:1,
   lines:[{preparationId:parts[0]!.preparationId,
     sourceLine:parts[0]!.sourceLine,quantityBase:"2.000000"}]};
  const issueKey="t3c-dispatch-"+randomUUID();
  const issued=await write("/v1/inventory/trips/dispatch",initialDispatch,4,issueKey);
  assert.equal(issued.status,201,JSON.stringify(issued.body));
  assert.equal(issued.body.inventoryPosted,true);
  assert.equal(issued.body.deliveryPosted,false);
  assert.equal(issued.body.receivablePosted,false);
  assert.equal(issued.body.paymentPosted,false);
  assert.equal(issued.body.fulfillmentStatus,"PARTIAL");
  assert.equal(issued.body.revision,5);
  assert.deepEqual((await write("/v1/inventory/trips/dispatch",
   initialDispatch,4,issueKey)).body,issued.body);
  assert.equal((await write("/v1/inventory/trips/dispatch",initialDispatch,4)).status,409);
  const stockMid=await call("/v1/inventory/balances?"+
   new URLSearchParams({branchId:b,warehouseId:w}).toString(),"GET",undefined,token);
  assert.equal(stockMid.body.items[0].onHand,"3.000000");
  assert.equal(stockMid.body.items[0].reserved,"2.000000");
  assert.equal(stockMid.body.items[0].available,"1.000000");
  const secondPayload={...initialDispatch,lines:[
    {preparationId:parts[1]!.preparationId,
      sourceLine:parts[1]!.sourceLine,quantityBase:"2.000000"}]};
  const dup=await Promise.all([
   write("/v1/inventory/trips/dispatch",secondPayload,5,"dispatch-race-a-"+randomUUID()),
   write("/v1/inventory/trips/dispatch",secondPayload,5,"dispatch-race-b-"+randomUUID()),
  ]);
  assert.deepEqual(dup.map(x=>x.status).sort(),[201,409],
   JSON.stringify(dup.map(x=>x.body)));
  const winner=dup.find(x=>x.status===201)!;
  assert.equal(winner.body.fulfillmentStatus,"COMPLETED");
  assert.equal(winner.body.revision,6);
  const finalStock=await call("/v1/inventory/balances?"+
   new URLSearchParams({branchId:b,warehouseId:w}).toString(),"GET",undefined,token);
  assert.equal(finalStock.body.items[0].onHand,"1.000000");
  assert.equal(finalStock.body.items[0].reserved,"0.000000");
  assert.equal(finalStock.body.items[0].available,"1.000000");
  const posted=await db.query<{qty:string;n:string}>(`
   SELECT coalesce(sum(-delta_base),0)::text AS qty,count(*)::text AS n
   FROM inventory_ledger WHERE installation_id=$1 AND branch_id=$2
    AND warehouse_id=$3 AND source_id=ANY($4::uuid[])
  `,[t,b,w,[issued.body.id,winner.body.id]]);
  assert.deepEqual(posted.rows[0],{qty:"4.000000",n:"2"});
  const fact=await db.query(`SELECT fulfillment_status,delivery_status,payment_status
    FROM sales_order WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,[t,b,id]);
  assert.deepEqual(fact.rows[0],{fulfillment_status:"COMPLETED",
    delivery_status:"NOT_DISPATCHED",payment_status:"NOT_DUE"});
  await assert.rejects(db.query(`UPDATE sales_trip_dispatch_line SET quantity_base=1
    WHERE installation_id=$1 AND branch_id=$2 AND dispatch_id=$3`,
    [t,b,issued.body.id]),/immutable/i);
  // No fabricated customer delivery, receivable, or payment rows.
  assert.equal((await db.query<{n:string}>(`SELECT count(*)::text AS n
    FROM inventory_reservation WHERE installation_id=$1 AND order_id=$2
      AND state='ACTIVE'`,[t,id])).rows[0]!.n,"1");

  // P1 regression: an already prepared partial hold must not prevent later
  // replenishment. Both the old and new immutable reservation facts remain ACTIVE.
  const extraProduct=await catalog("products",{
   code:"TRIP-LATE",name:"Deferred truck item",baseUnit:"cai"});
  assert.equal(extraProduct.status,201,JSON.stringify(extraProduct.body));
  const extraId=extraProduct.body.id as string;
  assert.equal((await catalog("prices",{priceListId:list.body.id,productId:extraId,
   amount:"1000",discountRate:"0",effectiveAt:"2026-01-01T00:00:00Z"})).status,201);
  assert.equal((await write("/v1/inventory/openings",{
   branchId:b,warehouseId:w,productId:extraId,quantity:"5"})).status,201);
  const makeTrip=async(quantity:string)=>{
   const created=await write("/v1/sales/orders",{
    branchId:b,customerId:customer.body.id,priceListId:list.body.id,
    shipping:{warehouseId:w,deliveryChoice:"TRIP",
     collectionPolicy:"CREDIT_TERMS",customerMode:"EXISTING"},
    lines:[{productId:extraId,quantity}]});
   assert.equal(created.status,201,JSON.stringify(created.body));
   const oid=created.body.id as string;
   assert.equal((await write("/v1/sales/orders/"+oid+"/confirm",{branchId:b})).status,200);
   return oid;
  };
  const competitor=await makeTrip("3");
  const competitorHold=await write("/v1/inventory/trip-holds",{
   branchId:b,warehouseId:w,orderId:competitor,version:1},1);
  assert.equal(competitorHold.status,200,JSON.stringify(competitorHold.body));
  const late=await makeTrip("4");
  const lateScope={branchId:b,warehouseId:w,orderId:late,version:1};
  const lateHold=await write("/v1/inventory/trip-holds",lateScope,1);
  assert.equal(lateHold.status,200,JSON.stringify(lateHold.body));
  assert.equal(lateHold.body.lines[0].quantityBase,"2.000000");
  assert.equal(lateHold.body.lines[0].backorderedBase,"2.000000");
  const latePrep=await write("/v1/inventory/trips/prepare",{
   ...lateScope,lines:[{lineNo:1,pickedBase:"2",packedBase:"2"}]},2);
  assert.equal(latePrep.status,201,JSON.stringify(latePrep.body));
  assert.equal(latePrep.body.revision,3);
  const cancelled=await write("/v1/sales/orders/"+competitor+"/cancel",
   {branchId:b,reason:"Release shipment capacity"},2);
  assert.equal(cancelled.status,200,JSON.stringify(cancelled.body));
  const replenished=await write("/v1/inventory/trip-holds",lateScope,3);
  assert.equal(replenished.status,200,JSON.stringify(replenished.body));
  assert.equal(replenished.body.changedLines,1);
  assert.equal(replenished.body.revision,4);
  assert.equal(replenished.body.lines[0].quantityBase,"4.000000");
  assert.equal(replenished.body.lines[0].backorderedBase,"0.000000");
  const read=await call("/v1/inventory/trips/work?"+
   new URLSearchParams({...lateScope,version:"1"}).toString(),"GET",undefined,token);
  assert.equal(read.status,200,JSON.stringify(read.body));
  assert.equal(read.body.lines[0].reservedBase,"4.000000");
  assert.equal(read.body.lines[0].backorderedBase,"0.000000");
  assert.equal(read.body.lines[0].reservations.length,2);
  const supplemental=read.body.lines[0].reservations.find((x:Record<string,string>)=>
   x.reservationId!==lateHold.body.lines[0].reservationId);
  assert.ok(supplemental?.reservationId);
  const preparedExtra=await write("/v1/inventory/trips/prepare",{
   ...lateScope,lines:[{lineNo:1,reservationId:supplemental.reservationId,
    pickedBase:"2",packedBase:"2"}]},4);
  assert.equal(preparedExtra.status,201,JSON.stringify(preparedExtra.body));
  assert.equal(preparedExtra.body.revision,5);
  assert.equal(preparedExtra.body.lines[0].pickedBase,"4.000000");
  const laterParts=preparedExtra.body.lines[0].preparations;
  assert.equal(laterParts.length,2);
  const both=await write("/v1/inventory/trips/dispatch",{
   ...lateScope,lines:laterParts.map((x:Record<string,any>)=>({
    preparationId:x.preparationId,sourceLine:x.sourceLine,
    quantityBase:x.readyBase
   }))},5);
  assert.equal(both.status,201,JSON.stringify(both.body));
  assert.equal(both.body.fulfillmentStatus,"COMPLETED");
  assert.equal(both.body.deliveryPosted,false);
  const heldHistory=await db.query<{state:string;quantity:string}>(`
   SELECT state,quantity_base::text AS quantity FROM inventory_reservation
   WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3
   ORDER BY created_at,id`,[t,b,late]);
  assert.deepEqual(heldHistory.rows,[{state:"ACTIVE",quantity:"2.000000"},
   {state:"ACTIVE",quantity:"2.000000"}]);
  const afterLate=await db.query<{onhand:string;reserved:string}>(`
   SELECT on_hand::text AS onhand,reserved::text AS reserved
   FROM inventory_stock_balance WHERE installation_id=$1 AND branch_id=$2
    AND warehouse_id=$3 AND product_id=$4`,[t,b,w,extraId]);
  assert.deepEqual(afterLate.rows[0],{onhand:"1.000000",reserved:"0.000000"});

  // P2 regressions: exact location packing and MANUAL stock withdrawals may
  // not consume another confirmed trip's picked physical stock.
  const scopedProduct=await catalog("products",{
   code:"TRIP-SCOPE",name:"Scoped truck cargo",baseUnit:"cai"});
  assert.equal(scopedProduct.status,201,JSON.stringify(scopedProduct.body));
  const scopedId=scopedProduct.body.id as string;
  assert.equal((await catalog("prices",{priceListId:list.body.id,productId:scopedId,
   amount:"1000",discountRate:"0",effectiveAt:"2026-01-01T00:00:00Z"})).status,201);
  assert.equal((await write("/v1/inventory/openings",{
   branchId:b,warehouseId:w,productId:scopedId,quantity:"6"})).status,201);
  const locA=await write("/v1/inventory/locations",{
   branchId:b,warehouseId:w,code:"TRIP-A",name:"Trip Rack A"});
  const locB=await write("/v1/inventory/locations",{
   branchId:b,warehouseId:w,code:"TRIP-B",name:"Trip Rack B"});
  assert.equal(locA.status,201,JSON.stringify(locA.body));
  assert.equal(locB.status,201,JSON.stringify(locB.body));
  for(const locationId of [locA.body.id,locB.body.id]){
   const assignment=await write("/v1/inventory/stock-scopes/assign",{
    branchId:b,warehouseId:w,productId:scopedId,locationId,quantityBase:"3"});
   assert.equal(assignment.status,201,JSON.stringify(assignment.body));
  }
  const scopedTrip=await write("/v1/sales/orders",{
   branchId:b,customerId:customer.body.id,priceListId:list.body.id,
   shipping:{warehouseId:w,deliveryChoice:"TRIP",
    collectionPolicy:"CREDIT_TERMS",customerMode:"EXISTING"},
   lines:[{productId:scopedId,quantity:"3"}]});
  assert.equal(scopedTrip.status,201,JSON.stringify(scopedTrip.body));
  const tId=scopedTrip.body.id as string;
  assert.equal((await write("/v1/sales/orders/"+tId+"/confirm",{branchId:b})).status,200);
  const tScope={branchId:b,warehouseId:w,orderId:tId,version:1};
  const th=await write("/v1/inventory/trip-holds",tScope,1);
  assert.equal(th.status,200,JSON.stringify(th.body));
  const pp=await write("/v1/inventory/trips/prepare",{
   ...tScope,lines:[{lineNo:1,locationId:locA.body.id,
    pickedBase:"3",packedBase:"3"}]},2);
  assert.equal(pp.status,201,JSON.stringify(pp.body));
  assert.equal((await write("/v1/inventory/trips/prepare",{
   ...tScope,lines:[{lineNo:1,locationId:locB.body.id,
    pickedBase:"0",packedBase:"1"}]},3)).status,409);
  const assignedHold=th.body.lines[0].reservationId as string;
  // Reordering a valid dispatch-line insert, a classification assignment,
  // and the matching OUT cannot evade the final deferred scope reconciliation.
  const forgedId=randomUUID(),dbForger=await db.connect();
  try{
   await dbForger.query("BEGIN");
   await dbForger.query(`INSERT INTO sales_trip_dispatch
    (installation_id,branch_id,id,order_id,version_no,warehouse_id,actor_id,request_id)
    VALUES($1,$2,$3,$4,1,$5,$6,'t3c-scoped-forgery')`,
    [t,b,forgedId,tId,w,root.actorId]);
   await dbForger.query(`INSERT INTO sales_trip_dispatch_line
    (installation_id,branch_id,dispatch_id,source_line,preparation_id,
     preparation_line_no,order_line_no,reservation_id,product_id,quantity_base,location_id)
    VALUES($1,$2,$3,1,$4,1,1,$5,$6,3,$7)`,
    [t,b,forgedId,pp.body.id,assignedHold,scopedId,locA.body.id]);
   await dbForger.query(`INSERT INTO inventory_scope_assignment
    (installation_id,branch_id,warehouse_id,product_id,location_id,
     quantity_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,$5,3,$6,'t3c-fake-classification')`,
    [t,b,w,scopedId,locB.body.id,root.actorId]);
   await dbForger.query(`INSERT INTO inventory_ledger
    (installation_id,branch_id,warehouse_id,product_id,kind,source_type,
     source_id,source_line,delta_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,1,-3,$6,'t3c-fake-out')`,
    [t,b,w,scopedId,forgedId,root.actorId]);
   await assert.rejects(dbForger.query("COMMIT"),
     /Trip dispatch leaves invalid final physical scope coverage/i);
  }finally{
   await dbForger.query("ROLLBACK").catch(()=>undefined);
   dbForger.release();
  }
  const manual=await write("/v1/sales/orders",{
   branchId:b,customerId:customer.body.id,priceListId:list.body.id,
   shipping:{warehouseId:w,deliveryChoice:"MANUAL",
    collectionPolicy:"CREDIT_TERMS",customerMode:"EXISTING"},
   lines:[{productId:scopedId,quantity:"3"}]});
  assert.equal(manual.status,201,JSON.stringify(manual.body));
  const manualId=manual.body.id as string;
  assert.equal((await write("/v1/sales/orders/"+manualId+"/confirm",{branchId:b})).status,200);
  const stolen=await write("/v1/inventory/direct-issues",{
   branchId:b,warehouseId:w,orderId:manualId,version:1,
   lines:[{lineNo:1,quantityBase:"3",locationId:locA.body.id}]},1);
  assert.equal(stolen.status,409,JSON.stringify(stolen.body));
  const legal=await write("/v1/inventory/direct-issues",{
   branchId:b,warehouseId:w,orderId:manualId,version:1,
   lines:[{lineNo:1,quantityBase:"3",locationId:locB.body.id}]},1);
  assert.equal(legal.status,201,JSON.stringify(legal.body));
  const correctDispatch=await write("/v1/inventory/trips/dispatch",{
   ...tScope,lines:[{preparationId:pp.body.id,sourceLine:1,quantityBase:"3"}]},3);
  assert.equal(correctDispatch.status,201,JSON.stringify(correctDispatch.body));
  assert.equal(correctDispatch.body.fulfillmentStatus,"COMPLETED");
  const finalScoped=await db.query<{onhand:string;reserved:string}>(`
   SELECT on_hand::text AS onhand,reserved::text AS reserved
   FROM inventory_stock_balance WHERE installation_id=$1 AND branch_id=$2
    AND warehouse_id=$3 AND product_id=$4`,[t,b,w,scopedId]);
  assert.deepEqual(finalScoped.rows[0],{onhand:"0.000000",reserved:"0.000000"});


 }finally{
  if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)');
  await admin.end();
 }
});
