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
 }finally{
  if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)');
  await admin.end();
 }
});
