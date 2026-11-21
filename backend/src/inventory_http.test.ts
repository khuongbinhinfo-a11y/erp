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
  assert.equal(installed.applied.length,11);
  assert.equal((await applyMigrations(pool,resolve(process.cwd(),"db/migrations"))).skipped.length,11);
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
  const heldOrder=orders[winner]!;
  assert.equal((await make("/v1/sales/orders/"+heldOrder+"/amend",
   {branchId:b,reason:"Change planned order"},1)).status,409);
  assert.equal((await make("/v1/sales/orders/"+heldOrder+"/cancel",
   {branchId:b,reason:"Cancel test order"},1)).status,409);
  const held=await call("/v1/inventory/reservations?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(held.status,200);assert.equal(held.body.items.length,1);
  const releasePath="/v1/inventory/reservations/"+accepted.body.id+"/release";
  const releaseKey="release-"+randomUUID();
  const released=await make(releasePath,{branchId:b,warehouseId:w},0,releaseKey);
  assert.equal(released.status,200,JSON.stringify(released.body));
  assert.equal(released.body.stock.reserved,"0");
  assert.equal((await make(releasePath,{branchId:b,warehouseId:w},0,
   "different-release-"+randomUUID())).status,409);
  assert.deepEqual((await make(releasePath,{branchId:b,warehouseId:w},0,releaseKey)).body,
   released.body);
  assert.equal((await make("/v1/inventory/reservations",
   reservation(orders[loser]!)).status,201);
  assert.equal((await make("/v1/sales/orders/"+heldOrder+"/cancel",
   {branchId:b,reason:"Cancel test order"},1)).status,200);
  const ledger=await call("/v1/inventory/movements?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(ledger.status,200);assert.equal(ledger.body.items.length,1);
  assert.equal(ledger.body.items[0].kind,"OPENING");
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
 } finally {
  if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
  if(pool)await pool.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)');
  await admin.end();
 }
});
