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
import { validCost } from "./purchasing.ts";
test("R3.2 unit cost is exact numeric string, not binary floating point",()=>{
 for(const x of ["0","1","25.1234","1000000.0001"])assert.equal(validCost(x),true,x);
 for(const x of [0,1,null,"NaN","Infinity","-1","01.00","1.12345","1e5"])
   assert.equal(validCost(x),false,String(x));
});
const source=process.env.DATABASE_URL;
const ci=(()=>{
 try{const u=new URL(source??"");return ["localhost","127.0.0.1"].includes(u.hostname)
  &&u.pathname==="/erp_ci"&&u.username==="erp_ci";}
 catch{return false;}
})();
test("R3.2 PostgreSQL: multi-receipt, concurrent arrivals, exact replay, RBAC, rollback and ledger",
 {skip:!ci},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const dbName="erp_ci_purchase_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+dbName+'"');
  const uri=new URL(source!);uri.pathname="/"+dbName;
  db=new Pool({connectionString:uri.toString(),max:8,query_timeout:12000});
  db.on("error",()=>{});
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).applied.length,13);
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).skipped.length,13);
  const password="Synthetic-PO-"+randomUUID();
  const root=await bootstrapInstallation(db,{code:"purchase-r3",displayName:"R3 Purchase tests",
   adminLogin:"owner",adminPassword:password});
  const t=root.installationId,b=root.branchId,w=root.warehouseId;
  server=buildApp(()=>isDatabaseReady(db!),async()=>true,{
   pool:db,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"synthetic-"+randomUUID(),
  });
  await new Promise<void>(resolve=>server!.listen(0,"127.0.0.1",resolve));
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
  const make=(path:string,data:unknown,revision=0,key="po-"+randomUUID())=>
    call(path,"POST",data,token,{"if-match":String(revision),"idempotency-key":key});
  const catalog=(kind:string,data:Record<string,unknown>)=>
    make("/v1/catalog/"+kind,{branchId:b,...data});
  const supplier=await catalog("suppliers",{code:"SUP1",name:"Supplier one"});
  assert.equal(supplier.status,201,JSON.stringify(supplier.body));
  const p1=await catalog("products",{code:"PO1",name:"Rice one",baseUnit:"cai"});
  const p2=await catalog("products",{code:"PO2",name:"Rice two",baseUnit:"cai"});
  assert.equal(p1.status,201,JSON.stringify(p1.body));
  assert.equal(p2.status,201,JSON.stringify(p2.body));
  const lines=[
    {productId:p1.body.id,quantity:"5.000000",unitCost:"1020.5000"},
    {productId:p2.body.id,quantity:"2",unitCost:"0"},
  ];
  const payload={branchId:b,warehouseId:w,supplierId:supplier.body.id,
    note:"Receipt by several deliveries",lines};
  assert.equal((await call("/v1/purchasing/orders?branchId="+b+"&warehouseId="+w)).status,401);
  assert.equal((await call("/v1/purchasing/orders?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token,{origin:"https://evil.example.test"})).status,403);
  const poKey="create-"+randomUUID();
  const created=await make("/v1/purchasing/orders",payload,0,poKey);
  assert.equal(created.status,201,JSON.stringify(created.body));
  const id=created.body.id as string;
  assert.deepEqual((await make("/v1/purchasing/orders",payload,0,poKey)).body,created.body);
  assert.equal((await make("/v1/purchasing/orders",
   {...payload,lines:lines.slice(0,1)},0,poKey)).status,409);
  const listing=await call("/v1/purchasing/orders?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(listing.status,200,JSON.stringify(listing.body));
  assert.equal(listing.body.items[0].id,id);
  const confirm=await make("/v1/purchasing/orders/"+id+"/confirm",
    {branchId:b,warehouseId:w},0);
  assert.equal(confirm.status,200,JSON.stringify(confirm.body));
  assert.match(confirm.body.documentNo,/^PO-[0-9]{8}$/);
  assert.equal(confirm.body.revision,1);
  const detail=await call("/v1/purchasing/orders/"+id+"?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(detail.status,200);
  assert.equal(detail.body.order.lines.length,2);
  assert.equal(detail.body.order.lines[0].orderedBase,"5.000000");
  // Codex P2: 105 newer drafts must not hide an older confirmed PO awaiting goods.
  await db.query(
   `INSERT INTO purchase_order(installation_id,branch_id,supplier_id,warehouse_id,
      created_by,request_id)
    SELECT $1,$2,$3,$4,$5,('ci-seed-'||g::text)
      FROM generate_series(1,105) AS g`,
   [t,b,supplier.body.id,w,root.actorId]);
  const pendingPage=await call("/v1/purchasing/orders?branchId="+b+
    "&warehouseId="+w+"&offset=0","GET",undefined,token);
  assert.equal(pendingPage.status,200);
  assert.equal(pendingPage.body.items.length,100);
  assert.equal(pendingPage.body.items[0].id,id);
  assert.equal(pendingPage.body.hasMore,true);
  const nextPage=await call("/v1/purchasing/orders?branchId="+b+
    "&warehouseId="+w+"&offset=100","GET",undefined,token);
  assert.equal(nextPage.status,200);
  assert.equal(nextPage.body.items.length,6);
  assert.equal(nextPage.body.hasMore,false);
  assert.equal((await call("/v1/purchasing/orders?branchId="+b+
    "&warehouseId="+w+"&offset=101","GET",undefined,token)).status,400);
  const receiptPath="/v1/purchasing/orders/"+id+"/receipts";
  const receipt1={branchId:b,warehouseId:w,lines:[{orderLineNo:1,quantity:"2"}]};
  const receiveKey="receipt-"+randomUUID();
  const first=await make(receiptPath,receipt1,1,receiveKey);
  assert.equal(first.status,201,JSON.stringify(first.body));
  assert.equal(first.body.purchaseStatus,"PARTIALLY_RECEIVED");
  assert.equal(first.body.purchaseRevision,2);
  assert.deepEqual((await make(receiptPath,receipt1,1,receiveKey)).body,first.body);
  const stock=await call("/v1/inventory/balances?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(stock.status,200);
  assert.equal(stock.body.items.find((x:Record<string,string>)=>x.productId===p1.body.id)?.onHand,
    "2.000000");
  const over=await make(receiptPath,{branchId:b,warehouseId:w,
   lines:[{orderLineNo:1,quantity:"4"}]},2);
  assert.equal(over.status,409,JSON.stringify(over.body));
  const second={branchId:b,warehouseId:w,lines:[{orderLineNo:1,quantity:"3"}]};
  const race=await Promise.all([make(receiptPath,second,2),make(receiptPath,second,2)]);
  assert.deepEqual(race.map(x=>x.status).sort(),[201,409],JSON.stringify(race));
  const afterRace=await call("/v1/purchasing/orders/"+id+"?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(afterRace.body.order.status,"PARTIALLY_RECEIVED");
  assert.equal(afterRace.body.order.lines[0].receivedBase,"5.000000");
  assert.equal(afterRace.body.order.lines[1].receivedBase,"0.000000");
  const completed=await make(receiptPath,{branchId:b,warehouseId:w,
    lines:[{orderLineNo:2,quantity:"2"}]},3);
  assert.equal(completed.status,201,JSON.stringify(completed.body));
  assert.equal(completed.body.purchaseStatus,"RECEIVED");
  assert.equal(completed.body.purchaseRevision,4);
  const final=await call("/v1/purchasing/orders/"+id+"?branchId="+b+"&warehouseId="+w,
    "GET",undefined,token);
  assert.equal(final.body.order.lines[0].receivedBase,"5.000000");
  assert.equal(final.body.order.lines[1].receivedBase,"2.000000");
  assert.equal(final.body.order.receipts.length,3);
  assert.equal((await make(receiptPath,{branchId:b,warehouseId:w,
   lines:[{orderLineNo:1,quantity:"1"}]},4)).status,409);
  assert.equal((await make("/v1/purchasing/orders/"+id+"/cancel",
   {branchId:b,warehouseId:w},4)).status,409);
  const ledger=await call("/v1/inventory/movements?branchId="+b+"&warehouseId="+w,
   "GET",undefined,token);
  assert.equal(ledger.body.items.length,3);
  assert.ok(ledger.body.items.every((x:Record<string,string>)=>x.kind==="RECEIPT"));
  const dbReceipts=await db.query<{n:string}>(
    "SELECT count(*)::text AS n FROM purchase_receipt WHERE installation_id=$1",
    [t]);
  assert.equal(dbReceipts.rows[0]?.n,"3");
  await assert.rejects(db.query(
    "UPDATE purchase_receipt_line SET quantity_base=1 WHERE installation_id=$1",[t]),
    /immutable/i);
  await assert.rejects(db.query(
    `INSERT INTO purchase_order_line
     (installation_id,branch_id,order_id,line_no,product_id,quantity_base,unit_cost)
     VALUES($1,$2,$3,3,$4,1,0)`,[t,b,id,p1.body.id]),
    /unconfirmed/i);
  const otherWh=await db.query<{id:string}>(
    "INSERT INTO warehouse(installation_id,branch_id,code,name) VALUES($1,$2,'OTHER_PO','Other warehouse') RETURNING id",
    [t,b]);
  assert.equal((await make("/v1/purchasing/orders",{...payload,
    warehouseId:otherWh.rows[0]!.id})).status,403);
  assert.equal((await call("/v1/purchasing/orders?branchId="+b+
    "&warehouseId="+otherWh.rows[0]!.id,"GET",undefined,token)).status,403);
 }finally{
  if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)');
  await admin.end();
 }
});
