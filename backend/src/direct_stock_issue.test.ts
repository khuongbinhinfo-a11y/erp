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
  // Codex P2: a forged movement posted before a matching source header must
  // be rejected at COMMIT even if a separate legitimate line is posted later.
  const forgedId=randomUUID(),forger=await db.connect();
  try{
   await forger.query("BEGIN");
   await forger.query(`INSERT INTO inventory_ledger
    (installation_id,branch_id,warehouse_id,product_id,kind,source_type,
      source_id,source_line,delta_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,99,-1,$6,'forged-preheader')`,
    [t,b,w,products[0],forgedId,root.actorId]);
   await forger.query(`INSERT INTO sales_direct_issue
    (installation_id,branch_id,id,order_id,version_no,warehouse_id,actor_id,request_id)
    VALUES($1,$2,$3,$4,1,$5,$6,'forged-header')`,
    [t,b,forgedId,first,w,root.actorId]);
   await forger.query(`INSERT INTO sales_direct_issue_line
    (installation_id,branch_id,issue_id,source_line,order_line_no,
      product_id,quantity_base)
    VALUES($1,$2,$3,1,1,$4,1)`,[t,b,forgedId,products[0]]);
   await forger.query(`INSERT INTO inventory_ledger
    (installation_id,branch_id,warehouse_id,product_id,kind,source_type,
      source_id,source_line,delta_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,1,-1,$6,'forged-valid-line')`,
    [t,b,w,products[0],forgedId,root.actorId]);
   await assert.rejects(forger.query("COMMIT"),
     /Direct issue ledger movement has no matching source line/i);
  }finally{
   await forger.query("ROLLBACK").catch(()=>undefined);
   forger.release();
  }
  assert.equal((await db.query<{n:string}>(
   "SELECT count(*)::text AS n FROM inventory_ledger WHERE installation_id=$1 AND source_id=$2",
   [t,forgedId])).rows[0]!.n,"0");
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
  const totals=await call("/v1/inventory/direct-issues/totals?"+
    new URLSearchParams({branchId:b,warehouseId:w,orderId:first}).toString(),
    "GET",undefined,token);
  assert.equal(totals.status,200,JSON.stringify(totals.body));
  assert.equal(totals.body.items.length,1);
  assert.equal(totals.body.items[0].issuedBase,"5.000000");
  assert.equal(totals.body.items[0].baseUnit,"cai");

  const reconciliation=await call("/v1/inventory/direct-issues/reconcile?"+
   new URLSearchParams({branchId:b,warehouseId:w,orderId:first}).toString(),
   "GET",undefined,token);
  assert.equal(reconciliation.status,200,JSON.stringify(reconciliation.body));
  assert.equal(reconciliation.body.reconciled,true);
  assert.equal(reconciliation.body.lines.length,2);
  assert.equal(reconciliation.body.lines.every((x:any)=>
    x.quantityBase===x.postedBase&&x.movementCount===1),true);
  assert.equal(reconciliation.body.stock[0].onHand,
    reconciliation.body.stock[0].ledgerTotal);
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
  // Codex P2: a movement inserted before its source must not borrow
  // unassigned warehouse stock by naming an empty physical location.
  const emptyLoc=await write("/v1/inventory/locations",
   {branchId:b,warehouseId:w,code:"EMPTY",name:"Kệ chưa phân hàng"});
  assert.equal(emptyLoc.status,201,JSON.stringify(emptyLoc.body));
  const scopedOrder=await makeOrder(products[1]!,"1");
  const spoofId=randomUUID(),scopeForger=await db.connect();
  try{
   await scopeForger.query("BEGIN");
   await scopeForger.query(`INSERT INTO inventory_ledger
    (installation_id,branch_id,warehouse_id,product_id,kind,source_type,
     source_id,source_line,delta_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,1,-1,$6,'scoped-rogue-ledger')`,
    [t,b,w,products[1],spoofId,root.actorId]);
   await scopeForger.query(`INSERT INTO sales_direct_issue
    (installation_id,branch_id,id,order_id,version_no,warehouse_id,actor_id,request_id)
    VALUES($1,$2,$3,$4,1,$5,$6,'scoped-rogue-header')`,
    [t,b,spoofId,scopedOrder,w,root.actorId]);
   await assert.rejects(scopeForger.query(`INSERT INTO sales_direct_issue_line
    (installation_id,branch_id,issue_id,source_line,order_line_no,
     product_id,quantity_base,location_id)
    VALUES($1,$2,$3,1,1,$4,1,$5)`,
    [t,b,spoofId,products[1],emptyLoc.body.id]),
     /Direct issue exceeds allocated stock at lot\/location/i);
  }finally{
   await scopeForger.query("ROLLBACK").catch(()=>undefined);
   scopeForger.release();
  }
  // An orphan ISSUE committed before the header exists must not become a
  // valid direct stock source by creating that header in a later transaction.
  const delayedHeaderId=randomUUID();
  const legacyOrphan=await db.query<{id:string}>(`INSERT INTO inventory_ledger
   (installation_id,branch_id,warehouse_id,product_id,kind,source_type,
    source_id,source_line,delta_base,actor_id,request_id)
   VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,99,-1,$6,'precommitted-orphan')
   RETURNING id`,[t,b,w,products[1],delayedHeaderId,root.actorId]);
  const late=await db.connect();
  try{
   await late.query("BEGIN");
   await late.query(`INSERT INTO sales_direct_issue
     (installation_id,branch_id,id,order_id,version_no,warehouse_id,actor_id,request_id)
     VALUES($1,$2,$3,$4,1,$5,$6,'late-header')`,
     [t,b,delayedHeaderId,scopedOrder,w,root.actorId]);
   await late.query(`INSERT INTO sales_direct_issue_line
     (installation_id,branch_id,issue_id,source_line,order_line_no,product_id,quantity_base)
     VALUES($1,$2,$3,1,1,$4,1)`,[t,b,delayedHeaderId,products[1]]);
   await late.query(`INSERT INTO inventory_ledger
     (installation_id,branch_id,warehouse_id,product_id,kind,source_type,
      source_id,source_line,delta_base,actor_id,request_id)
     VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,1,-1,$6,'late-matched-line')`,
     [t,b,w,products[1],delayedHeaderId,root.actorId]);
   await assert.rejects(late.query("COMMIT"),
     /Direct issue header has unmatched historic ledger movement/i);
  }finally{
   await late.query("ROLLBACK").catch(()=>undefined);
   late.release();
  }
  // Correct synthetic starting stock by REVERSAL; never rewrite a posted row.
  await db.query(`INSERT INTO inventory_ledger
   (installation_id,branch_id,warehouse_id,product_id,kind,source_type,source_id,
    source_line,delta_base,reversal_of,actor_id,request_id)
   VALUES($1,$2,$3,$4,'REVERSAL','REVERSAL',$5,1,1,$6,$7,'orphan-test-correction')`,
   [t,b,w,products[1],randomUUID(),legacyOrphan.rows[0]!.id,root.actorId]);
  assert.equal((await db.query<{n:string}>(`SELECT count(*)::text AS n
    FROM sales_direct_issue WHERE installation_id=$1 AND id=$2`,
    [t,delayedHeaderId])).rows[0]!.n,"0");
  // Codex P2: in one transaction, a scoped issue line decreases the scope
  // projection before its inventory movement decreases warehouse on-hand.
  // A later scope assignment must not double-classify that interim quantity.
  const coverageProduct=await catalog("products",{
   code:"T3BCOVER",name:"Scope coverage product",baseUnit:"cai"});
  assert.equal(coverageProduct.status,201,JSON.stringify(coverageProduct.body));
  assert.equal((await catalog("prices",{
   priceListId:list.body.id,productId:coverageProduct.body.id,
   amount:"1000.0000",discountRate:"0",effectiveAt:"2026-01-01T00:00:00Z"})).status,201);
  assert.equal((await opening(coverageProduct.body.id,"10.000000")).status,201);
  const originalCoverage=await write("/v1/inventory/stock-scopes/assign",{
   branchId:b,warehouseId:w,productId:coverageProduct.body.id,
   locationId:loc.body.id,quantityBase:"10.000000"});
  assert.equal(originalCoverage.status,201,JSON.stringify(originalCoverage.body));
  const coverageOrder=await makeOrder(coverageProduct.body.id,"5");
  const coverageId=randomUUID(),concurrent=await db.connect();
  try{
   await concurrent.query("BEGIN");
   await concurrent.query(`INSERT INTO sales_direct_issue
    (installation_id,branch_id,id,order_id,version_no,warehouse_id,actor_id,request_id)
    VALUES($1,$2,$3,$4,1,$5,$6,'coverage-header')`,
    [t,b,coverageId,coverageOrder,w,root.actorId]);
   await concurrent.query(`INSERT INTO sales_direct_issue_line
    (installation_id,branch_id,issue_id,source_line,order_line_no,
     product_id,quantity_base,location_id)
    VALUES($1,$2,$3,1,1,$4,5,$5)`,
    [t,b,coverageId,coverageProduct.body.id,loc.body.id]);
   await concurrent.query(`INSERT INTO inventory_scope_assignment
    (installation_id,branch_id,warehouse_id,product_id,location_id,
     quantity_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,$5,5,$6,'coverage-fake-reassignment')`,
    [t,b,w,coverageProduct.body.id,emptyLoc.body.id,root.actorId]);
   await concurrent.query(`INSERT INTO inventory_ledger
    (installation_id,branch_id,warehouse_id,product_id,kind,source_type,source_id,
     source_line,delta_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,1,-5,$6,'coverage-ledger')`,
    [t,b,w,coverageProduct.body.id,coverageId,root.actorId]);
   await assert.rejects(concurrent.query("COMMIT"),
    /Scoped stock classification exceeds final on-hand balance/i);
  }finally{
   await concurrent.query("ROLLBACK").catch(()=>undefined);
   concurrent.release();
  }
  const coverageRead=await call("/v1/inventory/stock-scopes?branchId="+b+
    "&warehouseId="+w+"&productId="+coverageProduct.body.id,"GET",undefined,token);
  assert.equal(coverageRead.status,200,JSON.stringify(coverageRead.body));
  assert.equal(coverageRead.body.scopes.length,1);
  assert.equal(coverageRead.body.scopes[0].quantityBase,"10.000000");
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
  // Codex P2: >100 older empty lot/bin entries must never hide a later
  // stock-bearing lot (expiry 2099) or its selected warehouse location.
  await db.query(`INSERT INTO inventory_product_lot
   (installation_id,branch_id,product_id,lot_code,expiry_date,created_by)
   SELECT $1,$2,$3,'FILL-'||lpad(g::text,4,'0'),'2090-12-31'::date,$4
   FROM generate_series(1,105) g`,[t,b,products[1],root.actorId]);
  await db.query(`INSERT INTO inventory_storage_location
   (installation_id,branch_id,warehouse_id,code,name,created_by)
   SELECT $1,$2,$3,'ZONE-'||lpad(g::text,4,'0'),'Kệ phụ '||g::text,$4
   FROM generate_series(1,105) g`,[t,b,w,root.actorId]);
  const scoped=await call("/v1/inventory/stock-scopes?branchId="+b+
   "&warehouseId="+w+"&productId="+products[1],"GET",undefined,token);
  assert.equal(scoped.status,200,JSON.stringify(scoped.body));
  assert.equal(scoped.body.lots.length,106,"No silent 100-lot limit");
  assert.equal(scoped.body.locations.length,107,"No silent 100-bin limit");
  assert.equal(scoped.body.lots.at(-1).id,lot.body.id,
    "The stocked lot must remain selectable after 105 older empty lots");
  assert.equal(scoped.body.lots.some((x:any)=>x.id===lot.body.id),true);
  assert.equal(scoped.body.locations.some((x:any)=>x.id===loc.body.id),true);
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
