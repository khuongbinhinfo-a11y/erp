import test from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import type {AddressInfo} from "node:net";
import {resolve} from "node:path";
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
test("T3-B PostgreSQL: partial MANUAL issue, lot/location, scoped stock, negative policy, concurrency, replay",
 {skip:!ci},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const name="erp_ci_t3b_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+name+'"');
  const u=new URL(source!);u.pathname="/"+name;
  db=new Pool({connectionString:u.toString(),max:8,query_timeout:12000});
  db.on("error",()=>{});
  const migrations=await applyMigrations(db,resolve(process.cwd(),"db/migrations"));
  assert.equal(migrations.applied.length,24);
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).skipped.length,24);
  const pass="T3B-Test-"+randomUUID();
  const root=await bootstrapInstallation(db,{code:"t3b",displayName:"T3-B test",
   adminLogin:"owner",adminPassword:pass});
  const t=root.installationId,b=root.branchId,w=root.warehouseId;
  server=buildApp(()=>isDatabaseReady(db!),async()=>true,{
   pool:db,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"test-"+randomUUID(),
  });
  await new Promise<void>(ok=>server!.listen(0,"127.0.0.1",ok));
  const host="http://127.0.0.1:"+(server.address() as AddressInfo).port;
  const call=async(path:string,method="GET",body?:unknown,token?:string,
   extra:Record<string,string>={})=>{
   const r=await fetch(host+path,{method,headers:{
    origin:"https://erp.example.test",
    ...(body===undefined?{}:{"content-type":"application/json"}),
    ...(token?{authorization:"Bearer "+token}:{}),...extra,
   },body:body===undefined?undefined:JSON.stringify(body)});
   return {status:r.status,body:r.status===204?{}:await r.json() as Record<string,any>};
  };
  const login=await call("/v1/auth/login","POST",{loginName:"owner",password:pass});
  assert.equal(login.status,200,JSON.stringify(login.body));
  const token=login.body.token as string;
  const write=(path:string,body:unknown,rev=0,key="t3b-"+randomUUID())=>
   call(path,"POST",body,token,{"idempotency-key":key,"if-match":String(rev)});
  const catalog=(kind:string,x:Record<string,unknown>)=>
   write("/v1/catalog/"+kind,{branchId:b,...x});
  const cust=await catalog("customers",{code:"T3BC",name:"Synthetic buyer"});
  assert.equal(cust.status,201,JSON.stringify(cust.body));
  const list=await catalog("price-lists",{code:"T3BP",name:"Distribution price"});
  assert.equal(list.status,201,JSON.stringify(list.body));
  const products:string[]=[];
  for(const code of ["T3B1","T3B2","T3B3"]){
   const p=await catalog("products",{code,name:code,baseUnit:"cai"});
   assert.equal(p.status,201,JSON.stringify(p.body));products.push(p.body.id as string);
   const price=await catalog("prices",{priceListId:list.body.id,productId:p.body.id,
    amount:"1000.0000",discountRate:"0",effectiveAt:"2026-01-01T00:00:00Z"});
   assert.equal(price.status,201,JSON.stringify(price.body));
  }
  const shipping={warehouseId:w,deliveryChoice:"MANUAL",
   collectionPolicy:"CREDIT_TERMS",customerMode:"EXISTING"};
  const makeOrder=async(p:string,qty:string,mode="MANUAL")=>{
   const created=await write("/v1/sales/orders",{
    branchId:b,customerId:cust.body.id,priceListId:list.body.id,
    shipping:{...shipping,deliveryChoice:mode},lines:[{productId:p,quantity:qty}]});
   assert.equal(created.status,201,JSON.stringify(created.body));
   const confirmed=await write("/v1/sales/orders/"+created.body.id+"/confirm",{branchId:b},0);
   assert.equal(confirmed.status,200,JSON.stringify(confirmed.body));
   return created.body.id as string;
  };
  const opening=async(p:string,qty:string)=>write("/v1/inventory/openings",{
   branchId:b,warehouseId:w,productId:p,quantity:qty});
  assert.equal((await opening(products[0]!,"5.000000")).status,201);
  assert.equal((await opening(products[1]!,"6.000000")).status,201);
  assert.equal((await opening(products[2]!,"1.000000")).status,201);
  const first=await makeOrder(products[0]!,"5");
  const payload={branchId:b,warehouseId:w,orderId:first,version:1,
   lines:[{lineNo:1,quantityBase:"2.000000"}]};
  assert.equal((await call("/v1/inventory/direct-issues","POST",payload)).status,401);
  const key="direct-first-"+randomUUID();
  const issued=await write("/v1/inventory/direct-issues",payload,1,key);
  assert.equal(issued.status,201,JSON.stringify(issued.body));
  assert.equal(issued.body.fulfillmentStatus,"PARTIAL");
  assert.equal(issued.body.revision,2);
  assert.equal(issued.body.deliveryStatus,"NOT_DISPATCHED");
  assert.equal(issued.body.receivablePosted,false);
  assert.equal(issued.body.paymentPosted,false);
  assert.equal(issued.body.remaining[0].remainingBase,"3.000000");
  assert.deepEqual((await write("/v1/inventory/direct-issues",payload,1,key)).body,issued.body);
  assert.equal((await write("/v1/inventory/direct-issues",
   {...payload,lines:[{lineNo:1,quantityBase:"3.000000"}]},1,key)).status,409);
  const second=await write("/v1/inventory/direct-issues",
   {...payload,lines:[{lineNo:1,quantityBase:"3.000000"}]},2);
  assert.equal(second.status,201,JSON.stringify(second.body));
  assert.equal(second.body.fulfillmentStatus,"COMPLETED");
  assert.equal(second.body.remaining[0].remainingBase,"0.000000");
  assert.equal((await write("/v1/inventory/direct-issues",payload,3)).status,409);
  const count=await db.query<{n:string}>(`
   SELECT count(*)::text AS n FROM inventory_ledger WHERE installation_id=$1
    AND branch_id=$2 AND warehouse_id=$3 AND kind='ISSUE'
    AND source_id IN ($4,$5)`,[t,b,w,issued.body.id,second.body.id]);
  assert.equal(count.rows[0]!.n,"2");
  const stock=await call("/v1/inventory/balances?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(stock.status,200);
  assert.equal(stock.body.items.find((x:any)=>x.productId===products[0]).onHand,"0.000000");
  const ar=await db.query<{n:string}>("SELECT count(*)::text AS n FROM customer_receivable_ledger WHERE installation_id=$1 AND order_id=$2",[t,first]);
  assert.equal(ar.rows[0]!.n,"0");
  const pick=await makeOrder(products[1]!,"1","PICKUP");
  assert.equal((await write("/v1/inventory/direct-issues",
   {...payload,orderId:pick},1)).status,409);

  const loc=await write("/v1/inventory/locations",
   {branchId:b,warehouseId:w,code:"A-01",name:"Kệ A"});
  assert.equal(loc.status,201,JSON.stringify(loc.body));
  const lot=await write("/v1/inventory/lots",
   {branchId:b,warehouseId:w,productId:products[1],lotCode:"LOT-A",
    expiryDate:"2099-12-31"});
  assert.equal(lot.status,201,JSON.stringify(lot.body));
  const track=await write("/v1/inventory/tracking-policy",
   {branchId:b,warehouseId:w,productId:products[1],
    requireLocation:true,requireLot:true});
  assert.equal(track.status,200,JSON.stringify(track.body));
  const assign=await write("/v1/inventory/stock-scopes/assign",
   {branchId:b,warehouseId:w,productId:products[1],
    locationId:loc.body.id,lotId:lot.body.id,quantityBase:"4.000000"});
  assert.equal(assign.status,201,JSON.stringify(assign.body));
  const scoped=await call("/v1/inventory/stock-scopes?branchId="+b+
   "&warehouseId="+w+"&productId="+products[1],"GET",undefined,token);
  assert.equal(scoped.status,200,JSON.stringify(scoped.body));
  assert.equal(scoped.body.scopes[0].quantityBase,"4.000000");
  assert.equal((await write("/v1/inventory/stock-scopes/assign",
   {branchId:b,warehouseId:w,productId:products[1],locationId:loc.body.id,
    lotId:lot.body.id,quantityBase:"3.000000"})).status,409);
  const tracked=await makeOrder(products[1]!,"6");
  const trackedPayload={...payload,orderId:tracked,
   lines:[{lineNo:1,quantityBase:"2.000000",locationId:loc.body.id,lotId:lot.body.id}]};
  const trackedIssue=await write("/v1/inventory/direct-issues",trackedPayload,1);
  assert.equal(trackedIssue.status,201,JSON.stringify(trackedIssue.body));
  const scopeAfter=await call("/v1/inventory/stock-scopes?branchId="+b+
    "&warehouseId="+w+"&productId="+products[1],"GET",undefined,token);
  assert.equal(scopeAfter.body.scopes[0].quantityBase,"2.000000");
  const missingScope=await write("/v1/inventory/direct-issues",
   {...trackedPayload,lines:[{lineNo:1,quantityBase:"1.000000"}]},2);
  assert.equal(missingScope.status,409,JSON.stringify(missingScope.body));
  const wrongLot=await write("/v1/inventory/direct-issues",
   {...trackedPayload,lines:[{lineNo:1,quantityBase:"3.000000",
    locationId:loc.body.id,lotId:lot.body.id}]},2);
  assert.equal(wrongLot.status,409,JSON.stringify(wrongLot.body));
  const once=await db.query<{n:string}>(`SELECT count(*)::text AS n FROM inventory_ledger
   WHERE installation_id=$1 AND source_id=$2`,[t,trackedIssue.body.id]);
  assert.equal(once.rows[0]!.n,"1");
  await assert.rejects(db.query(`UPDATE sales_direct_issue_line SET quantity_base=4
    WHERE installation_id=$1 AND issue_id=$2`,[t,trackedIssue.body.id]),/immutable/i);

  // Concurrent writes on one confirmed order must serialize by warehouse/order.
  const race=await makeOrder(products[1]!,"1");
  const races=await Promise.all([1,2].map(()=>write("/v1/inventory/direct-issues",
    {...trackedPayload,orderId:race,lines:[{lineNo:1,quantityBase:"1.000000",
     locationId:loc.body.id,lotId:lot.body.id}]},1)));
  assert.deepEqual(races.map(x=>x.status).sort(),[201,409],JSON.stringify(races));

  const negOrder=await makeOrder(products[2]!,"4");
  const negPayload={...payload,orderId:negOrder,
    lines:[{lineNo:1,quantityBase:"4.000000"}],allowNegative:true};
  assert.equal((await write("/v1/inventory/direct-issues",negPayload,1)).status,409);
  const policy=await call("/v1/inventory/guard-policy?branchId="+b+
   "&warehouseId="+w,"GET",undefined,token);
  assert.equal(policy.body.policy.negativeIssueMode,"BLOCK");
  const updated=await write("/v1/inventory/guard-policy",{
    branchId:b,warehouseId:w,reserveShortageMode:"WARN",negativeIssueMode:"ALLOW"},
    policy.body.policy.revision);
  assert.equal(updated.status,200,JSON.stringify(updated.body));
  assert.equal(updated.body.negativeIssueMode,"ALLOW");
  const negative=await write("/v1/inventory/direct-issues",negPayload,1);
  assert.equal(negative.status,201,JSON.stringify(negative.body));
  assert.equal(negative.body.negativeIssued,true);
  const negativeBalance=await db.query<{n:string}>(`SELECT on_hand::text AS n
    FROM inventory_stock_balance WHERE installation_id=$1 AND branch_id=$2
    AND warehouse_id=$3 AND product_id=$4`,[t,b,w,products[2]]);
  assert.equal(negativeBalance.rows[0]!.n,"-3.000000");
  await assert.rejects(db.query(`INSERT INTO inventory_ledger
    (installation_id,branch_id,warehouse_id,product_id,kind,source_type,
     source_id,source_line,delta_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,1,-1,$6,'fake-neg')`,
    [t,b,w,products[2],randomUUID(),root.actorId]),/insufficient available stock/i);
 }finally{
  if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+name+'" WITH (FORCE)').catch(()=>undefined);
  await admin.end();
 }
});
