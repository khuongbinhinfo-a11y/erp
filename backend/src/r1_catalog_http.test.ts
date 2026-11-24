import test from "node:test";
import assert from "node:assert/strict";
import { createHash,randomUUID } from "node:crypto";
import { r1QuoteSignature } from "./r1_pricing.ts";
import { spawnSync } from "node:child_process";
import type { AddressInfo } from "node:net";
import { resolve } from "node:path";
import { Pool } from "pg";
import { applyMigrations } from "./migrate.ts";
import { bootstrapInstallation } from "./bootstrap.ts";
import { buildApp } from "./server.ts";
import { isDatabaseReady } from "./db.ts";

const url=process.env.DATABASE_URL;
const local=(()=>{
 try{const u=new URL(url??"");return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";}
 catch{return false;}
})();

test("R1-C: presentation-only explanation does not change historical price receipt",()=>{
 const historical={
  sellSkuId:"s",productId:"p",sku:"SP",unitCode:"CAI",
  conversionToBase:"1.000000",quantity:"1.000",
  normalizedBaseQuantity:"1.000000",
  customerId:null,channelId:null,priceListId:"l",
  basePrice:"12000.0000",unitPrice:"12000.0000",lineTotal:"12000",
  trace:[{ruleId:"r",scope:"BASE_RULE",adjustment:"FIXED_PRICE",
    amount:"12000.0000",result:"12000.0000"}],
 };
 const oldFingerprint={
  sellSkuId:"s",productId:"p",sku:"SP",unitCode:"CAI",
  conversionToBase:"1.000000",quantity:"1",
  normalizedBaseQuantity:"1.000000",customerId:null,channelId:null,
  priceListId:"l",basePrice:"12000.0000",
  unitPrice:"12000.0000",lineTotal:"12000",trace:historical.trace,
 };
 const expected=createHash("sha256").update(JSON.stringify(oldFingerprint)).digest("hex");
 type Quote=Parameters<typeof r1QuoteSignature>[0];
 assert.equal(r1QuoteSignature(historical as unknown as Quote),expected);
 const decorated={...historical,trace:[{...historical.trace[0]!,
  reason:"Giá cơ sở của SKU",priority:100,minQuantity:"1",
  effectiveFrom:"2026-11-23T00:00:00Z",stacking:"STACKABLE"}]};
 assert.equal(r1QuoteSignature(decorated as unknown as Quote),expected);
});

test("R1 never allows a retired B1 operator to run a newer migration",()=>{
 for(const script of ["scripts/b1-production-migration.mjs","scripts/b1-resume-preflight.mjs"]){
  const r=spawnSync(process.execPath,[script],{
   cwd:process.cwd(),encoding:"utf8",timeout:10000,
   env:{...process.env,GITHUB_ACTIONS:"false"},
  });
  assert.notEqual(r.status,0,script);
  assert.match(r.stderr??" ",/B1_OPERATOR_RETIRED_NEWER_SCHEMA/,script);
 }
});

test("R1: real PostgreSQL exact SKU price precedence, barcode, customer profile, tenant RBAC and replay",
 {skip:!local},async()=>{
 const admin=new Pool({connectionString:url,max:2});
 const name="erp_ci_r1_"+randomUUID().replaceAll("-","").slice(0,12);
 let pool:Pool|null=null,app:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+name+'"');
  const target=new URL(url!);target.pathname="/"+name;
  pool=new Pool({connectionString:target.toString(),max:7,query_timeout:15000});
  pool.on("error",()=>{});
  const applied=await applyMigrations(pool,resolve(process.cwd(),"db/migrations"));
  assert.equal(applied.applied.length,21);
  assert.equal((await applyMigrations(pool,resolve(process.cwd(),"db/migrations"))).skipped.length,21);
  const password="R1-test-"+randomUUID();
  const root=await bootstrapInstallation(pool,{
   code:"r1-test",displayName:"Synthetic R1 integration",
   adminLogin:"owner",adminPassword:password,
  });
  app=buildApp(()=>isDatabaseReady(pool!),async()=>true,{
   pool,installationId:root.installationId,
   allowedOrigin:"https://erp.example.test",throttleSecret:"test-"+randomUUID(),
  });
  await new Promise<void>(ok=>app!.listen(0,"127.0.0.1",ok));
  const base="http://127.0.0.1:"+(app.address() as AddressInfo).port;
  const request=async(path:string,method="GET",data?:unknown,token?:string,h:Record<string,string>={})=>{
   const r=await fetch(base+path,{
    method,headers:{origin:"https://erp.example.test",
      ...(data===undefined?{}:{"content-type":"application/json"}),
      ...(token?{authorization:"Bearer "+token}:{}),...h},
    body:data===undefined?undefined:JSON.stringify(data),
   });
   return {status:r.status,body:await r.json() as Record<string,any>,
    cors:r.headers.get("access-control-allow-origin")};
  };
  const b=root.branchId;
  const auth=await request("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(auth.status,200,JSON.stringify(auth.body));
  const token=auth.body.token as string;
  const write=(path:string,data:Record<string,unknown>,key="r1-"+randomUUID())=>
   request(path,"POST",{branchId:b,...data},token,
    {"idempotency-key":key,"if-match":"0"});
  const legacy=(resource:string,data:Record<string,unknown>,key?:string)=>
   write("/v1/catalog/"+resource,data,key);
  const r1=(resource:string,data:Record<string,unknown>,key?:string)=>
   write("/v1/catalog/r1/"+resource,data,key);
  const read=(resource:string,q="")=>
   request("/v1/catalog/r1/"+resource+"?branchId="+b+(q?"&q="+encodeURIComponent(q):""),
    "GET",undefined,token);
  const resolvePrice=(data:Record<string,unknown>)=>request(
   "/v1/catalog/r1/resolve","POST",{branchId:b,...data},token);
  assert.equal((await request("/v1/catalog/r1/skus?branchId="+b)).status,401);
  assert.equal((await request("/v1/catalog/r1/skus?branchId="+b,"GET",undefined,token,
   {origin:"https://evil.example"})).status,403);
  assert.equal((await read("skus")).status,200);

  const vipGroup=await legacy("customer-groups",{code:"VIP",name:"Khách VIP"});
  const standardGroup=await legacy("customer-groups",{code:"STANDARD",name:"Khách phổ thông"});
  assert.equal(vipGroup.status,201);
  assert.equal(standardGroup.status,201);
  const c1=await legacy("customers",{
   code:"KH-01",name:"Khách thử A",customerGroupId:vipGroup.body.id,
   phone:"+84900000001",deliveryAddress:"Địa chỉ kiểm thử",paymentTermsDays:15,
  });
  assert.equal(c1.status,201,JSON.stringify(c1.body));
  assert.equal((await legacy("customers",{code:"KH-02",name:"Khách trùng",
   phone:"+84900000001"})).status,409,"phone unique within installation/branch");
  const customers=await request("/v1/catalog/customers?branchId="+b,"GET",undefined,token);
  assert.equal(customers.body.items[0].phone,"+84900000001");
  assert.equal(customers.body.items[0].paymentTermsDays,15);
  const c2=await legacy("customers",{code:"KH-02",name:"Khách thử B",
   customerGroupId:standardGroup.body.id,phone:"+84900000002"});
  assert.equal(c2.status,201);

  const product=await legacy("products",{
   code:"SP-01",name:"Sản phẩm thử",baseUnit:"cai",
   units:[{unitCode:"thung",toBase:"12.000000"}],
  });
  assert.equal(product.status,201,JSON.stringify(product.body));
  const skus=await read("skus");
  assert.equal(skus.body.items.length,1,"product creates one base SKU, never guesses carton SKU");
  const baseSku=skus.body.items[0].id as string;
  assert.equal(skus.body.items[0].code,"SP-01");
  const cartonKey="carton-"+randomUUID();
  const cartonPayload={productId:product.body.id,sku:"SP-01-T",unitCode:"thung",toBase:"12.000000"};
  const carton=await r1("skus",cartonPayload,cartonKey);
  assert.equal(carton.status,201,JSON.stringify(carton.body));
  const replay=await Promise.all([r1("skus",cartonPayload,cartonKey),
    r1("skus",cartonPayload,cartonKey)]);
  assert.equal(replay[0]!.body.id,carton.body.id);
  assert.equal(replay[1]!.body.id,carton.body.id);
  assert.equal((await r1("skus",{...cartonPayload,sku:"DIFF"},cartonKey)).status,409);
  assert.equal((await r1("skus",{...cartonPayload,sku:"SP-OTHER",
    toBase:"11.000000"})).status,409,"conversion must match canonical product unit");
  assert.equal((await r1("skus",cartonPayload)).status,409,"one active SKU per product unit");
  const skuId=carton.body.id as string;
  const code=await r1("barcodes",{sellSkuId:skuId,barcode:"BC-0001",isPrimary:true});
  assert.equal(code.status,201,JSON.stringify(code.body));
  assert.equal((await r1("barcodes",{sellSkuId:baseSku,barcode:"BC-0001"})).status,409);
  const found=await read("skus","BC-0001");
  assert.equal(found.body.items.length,1);
  assert.equal(found.body.items[0].code,"SP-01-T");
  // T1: exact product filter precedes the LIMIT, while the cursor stays
  // stable for products with many selling units.
  const exact=await request("/v1/catalog/r1/skus?branchId="+b+
    "&productId="+product.body.id,"GET",undefined,token);
  assert.equal(exact.status,200,JSON.stringify(exact.body));
  assert.deepEqual(new Set(exact.body.items.map((x:{id:string})=>x.id)),
    new Set([baseSku,skuId]));
  const sorted=[baseSku,skuId].sort();
  const later=await request("/v1/catalog/r1/skus?branchId="+b+
    "&productId="+product.body.id+"&after="+sorted[0],"GET",undefined,token);
  assert.equal(later.status,200);
  assert.deepEqual(later.body.items.map((x:{id:string})=>x.id),[sorted[1]]);
  const foreign=await request("/v1/catalog/r1/skus?branchId="+b+
    "&productId="+randomUUID(),"GET",undefined,token);
  assert.equal(foreign.status,200);
  assert.equal(foreign.body.items.length,0);
  assert.equal((await request("/v1/catalog/r1/skus?branchId="+b+
    "&productId=invalid","GET",undefined,token)).status,400);
  const list=await legacy("price-lists",{code:"SELL",name:"Giá bán"});
  assert.equal(list.status,201);
  const channel=await r1("channels",{code:"MCP",name:"Kênh nhân viên thị trường"});
  assert.equal(channel.status,201);
  const now="2026-11-21T00:00:00Z",priceAt="2026-11-21T08:00:00Z";
  const basic={priceListId:list.body.id,effectiveFrom:now,minQuantity:"1"};
  const fixed=await r1("rules",{...basic,sellSkuId:baseSku,scopeKind:"BASE",
   adjustment:"FIXED_PRICE",amount:"12000.0000"});
  assert.equal(fixed.status,201,JSON.stringify(fixed.body));
  assert.equal((await resolvePrice({priceListId:list.body.id,sellSkuId:skuId,
   quantity:"1",priceAt})).status,409,"carton price is NOT retail times conversion");
  const cartonRule=await r1("rules",{...basic,sellSkuId:skuId,
   scopeKind:"BASE",adjustment:"FIXED_PRICE",amount:"130000.0000"});
  assert.equal(cartonRule.status,201,JSON.stringify(cartonRule.body));
  const channelRule=await r1("rules",{...basic,sellSkuId:skuId,
   scopeKind:"CHANNEL",channelId:channel.body.id,
   adjustment:"PERCENT_DISCOUNT",amount:"10.0000",
   priority:30,stacking:"EXCLUSIVE"});
  assert.equal(channelRule.status,201);
  const vipRule=await r1("rules",{...basic,sellSkuId:skuId,
   scopeKind:"CUSTOMER_GROUP",customerGroup:"VIP",
   adjustment:"PERCENT_DISCOUNT",amount:"5.0000",
   priority:20,stacking:"STACKABLE"});
  assert.equal(vipRule.status,201);
  // A lost ACK followed by accidental recreation under a different key may
  // produce an immutable duplicate; the pricing engine must not stack the
  // exact same commercial policy twice.
  const identicalVip=await r1("rules",{...basic,sellSkuId:skuId,
   scopeKind:"CUSTOMER_GROUP",customerGroup:"VIP",
   adjustment:"PERCENT_DISCOUNT",amount:"5.0000",
   priority:20,stacking:"STACKABLE"});
  assert.equal(identicalVip.status,201);
  const overlap=await r1("rules",{...basic,sellSkuId:skuId,
   scopeKind:"CUSTOMER_GROUP",customerGroup:"VIP",
   adjustment:"PERCENT_DISCOUNT",amount:"7.0000",
   priority:20,stacking:"STACKABLE"});
  assert.equal(overlap.status,409,"overlapping conflicting policy must be rejected");
  assert.equal(overlap.body.error?.code,"PRICE_RULE_OVERLAP");
  const customerRule=await r1("rules",{...basic,sellSkuId:skuId,
   scopeKind:"CUSTOMER",customerId:c2.body.id,
   adjustment:"FIXED_PRICE",amount:"100000.0000",
   priority:40,stacking:"EXCLUSIVE"});
  assert.equal(customerRule.status,201);
  const noContext=await resolvePrice({priceListId:list.body.id,sellSkuId:skuId,
   quantity:"2",priceAt});
  assert.equal(noContext.status,200,JSON.stringify(noContext.body));
  assert.equal(noContext.body.quote.unitPrice,"130000.0000");
  assert.equal(noContext.body.quote.lineTotal,"260000");
  assert.equal(noContext.body.quote.normalizedBaseQuantity,"24.000000");
  assert.equal(noContext.body.quote.trace.length,1);
  const vip=await resolvePrice({priceListId:list.body.id,sellSkuId:skuId,
   quantity:"2",customerId:c1.body.id,channelId:channel.body.id,priceAt});
  assert.equal(vip.status,200,JSON.stringify(vip.body));
  assert.equal(vip.body.quote.unitPrice,"111150");
  assert.equal(vip.body.quote.lineTotal,"222300");
  assert.equal(vip.body.quote.trace.length,3);
  const sameUpper=await resolvePrice({
   priceListId:list.body.id.toUpperCase(),sellSkuId:skuId.toUpperCase(),
   quantity:"2",customerId:c1.body.id.toUpperCase(),
   channelId:channel.body.id.toUpperCase(),priceAt,
  });
  assert.equal(sameUpper.status,200,JSON.stringify(sameUpper.body));
  assert.equal(sameUpper.body.quote.unitPrice,vip.body.quote.unitPrice);
  assert.equal(sameUpper.body.quote.priceSignature,vip.body.quote.priceSignature);
  const customerB=await resolvePrice({priceListId:list.body.id,sellSkuId:skuId,
   quantity:"1.333",customerId:c2.body.id,channelId:channel.body.id,priceAt});
  assert.equal(customerB.status,200,JSON.stringify(customerB.body));
  assert.equal(customerB.body.quote.unitPrice,"100000.0000");
  assert.equal(customerB.body.quote.lineTotal,"133300");
  assert.equal(customerB.body.quote.normalizedBaseQuantity,"15.996000");
  assert.equal((await resolvePrice({priceListId:list.body.id,sellSkuId:skuId,
   quantity:1.333,customerId:c2.body.id,priceAt})).status,400,
   "JS floating quantity rejected");
  const tooLate=await resolvePrice({priceListId:list.body.id,sellSkuId:skuId,
   quantity:"1",priceAt:"2025-11-21T00:00:00Z"});
  assert.equal(tooLate.status,409);
  assert.equal((await r1("rules",{...basic,sellSkuId:skuId,
   scopeKind:"BASE",adjustment:"PERCENT_DISCOUNT",amount:"10"})).status,400);
  // P0 regression: history import and SKU editing must not disagree on the
  // effective base price. Use a separate list and synthetic product fixture.
  const recoveryList=await legacy("price-lists",{code:"P0-RECOVERY",name:"Kiểm thử giá đồng nhất"});
  assert.equal(recoveryList.status,201,JSON.stringify(recoveryList.body));
  const recoveryListId=recoveryList.body.id;
  const recoveryContext={priceListId:recoveryListId,sellSkuId:baseSku,quantity:"1"};
  const staleBase=await r1("rules",{priceListId:recoveryListId,sellSkuId:baseSku,
   minQuantity:"1",scopeKind:"BASE",adjustment:"FIXED_PRICE",amount:"1.0000",
   effectiveFrom:"2026-11-20T00:00:00Z"});
  assert.equal(staleBase.status,201,JSON.stringify(staleBase.body));
  const imported=await legacy("prices",{priceListId:recoveryListId,
   productId:product.body.id,amount:"9800.0000",discountRate:"0",
   effectiveAt:"2026-11-21T00:00:00Z"});
  assert.equal(imported.status,201,JSON.stringify(imported.body));
  const beforeImport=await resolvePrice({...recoveryContext,priceAt:"2026-11-20T12:00:00Z"});
  assert.equal(beforeImport.status,200,JSON.stringify(beforeImport.body));
  assert.equal(Number(beforeImport.body.quote.unitPrice),1);
  const afterImport=await resolvePrice({...recoveryContext,priceAt:"2026-11-21T12:00:00Z"});
  assert.equal(afterImport.status,200,JSON.stringify(afterImport.body));
  assert.equal(Number(afterImport.body.quote.unitPrice),9800,
   "later effective base-unit price from history must not be masked by a stale BASE rule");
  const corrected=await r1("rules",{priceListId:recoveryListId,sellSkuId:baseSku,
   minQuantity:"1",scopeKind:"BASE",adjustment:"FIXED_PRICE",amount:"10500.0000",
   effectiveFrom:"2026-11-22T00:00:00Z"});
  assert.equal(corrected.status,201,JSON.stringify(corrected.body));
  const afterCorrection=await resolvePrice({...recoveryContext,priceAt:"2026-11-22T12:00:00Z"});
  assert.equal(afterCorrection.status,200,JSON.stringify(afterCorrection.body));
  assert.equal(Number(afterCorrection.body.quote.unitPrice),10500);
  const clonedRecovery=await write(
    "/v1/catalog/price-lists/"+recoveryListId+"/clone",
    {code:"P0-PRICE-CLONE",name:"Sao chép nguyên giá hiệu lực",sourceRevision:0},
    "p0-price-clone-"+randomUUID());
  assert.equal(clonedRecovery.status,201,JSON.stringify(clonedRecovery.body));
  const copiedRecovery=await resolvePrice({...recoveryContext,
    priceListId:clonedRecovery.body.id,priceAt:"2026-11-24T12:00:00Z"});
  assert.equal(copiedRecovery.status,200,JSON.stringify(copiedRecovery.body));
  assert.equal(Number(copiedRecovery.body.quote.unitPrice),10500,
    "clone cannot resurrect an older 9,800 product price over a newer 10,500 SKU rule");

  assert.equal((await resolvePrice({...recoveryContext,sellSkuId:skuId,
   priceAt:"2026-11-22T12:00:00Z"})).status,409,
   "product-level price history must not leak into a carton SKU");

  // Combined channel/group scope: OR inside a dimension, AND across them.
  const combined=await legacy("price-lists",{code:"P0-COMBINED",name:"Kênh và nhóm",
   effectiveFrom:"2026-11-18T00:00:00Z",effectiveTo:"2026-11-19T00:00:00Z"});
  assert.equal(combined.status,201,JSON.stringify(combined.body));
  const anotherChannel=await r1("channels",{code:"P0-OTHER",name:"Kênh thứ hai"});
  assert.equal(anotherChannel.status,201);
  assert.equal((await r1("rules",{priceListId:combined.body.id,sellSkuId:baseSku,
   scopeKind:"BASE",adjustment:"FIXED_PRICE",amount:"9800.0000",
   effectiveFrom:"2026-11-17T00:00:00Z"})).status,201);
  for(const target of [
    {scopeKind:"CHANNEL",channelId:channel.body.id},
    {scopeKind:"CHANNEL",channelId:anotherChannel.body.id},
    {scopeKind:"CUSTOMER_GROUP",customerGroupId:vipGroup.body.id},
    {scopeKind:"CUSTOMER_GROUP",customerGroupId:standardGroup.body.id},
  ]){
   const result=await write("/v1/catalog/price-lists/assignments",{
    priceListId:combined.body.id,priority:77,...target,
   });
   assert.equal(result.status,201,JSON.stringify(result.body));
  }
  const combinedQuote={sellSkuId:baseSku,quantity:"1",priceAt:"2026-11-18T12:00:00Z"};
  for(const customerId of [c1.body.id,c2.body.id]){
   for(const channelId of [channel.body.id,anotherChannel.body.id]){
    const result=await resolvePrice({...combinedQuote,customerId,channelId});
    assert.equal(result.status,200,JSON.stringify(result.body));
    assert.equal(result.body.quote.priceListId,combined.body.id);
    assert.equal(result.body.quote.unitPrice,"9800.0000");
   }
  }
  assert.equal((await resolvePrice({...combinedQuote,customerId:c1.body.id})).status,409);
  assert.equal((await resolvePrice({...combinedQuote,channelId:channel.body.id})).status,409);
  assert.equal((await resolvePrice({...combinedQuote,priceListId:combined.body.id,
    customerId:c1.body.id})).status,409);

  // P0 manual price: a SKU without configured price can still be sold
  // with an authorized explicit price, discount, VAT and split line.
  const manualList=await legacy("price-lists",{code:"P0-MANUAL",name:"Giá nhập trực tiếp"});
  assert.equal(manualList.status,201);
  const manualInput={
   customerId:c1.body.id,priceListId:manualList.body.id,
   lines:[{sellSkuId:baseSku,quantity:"1",unitPrice:"10500",
    discountRate:"10",taxRate:"8"},
    {sellSkuId:baseSku,quantity:"1",unitPrice:"10500",
    discountRate:"10",taxRate:"8"}],
  };
  const manualQuote=await request("/v1/sales/quote","POST",{
   branchId:b,...manualInput},token);
  assert.equal(manualQuote.status,200,JSON.stringify(manualQuote.body));
  assert.equal(manualQuote.body.quote.lines[0].normalizedBaseQuantity,"1.000000",
    "manual price must never become reserved stock quantity");
  assert.equal(manualQuote.body.quote.subtotal,"21000");
  assert.equal(manualQuote.body.quote.discountTotal,"2100");
  assert.equal(manualQuote.body.quote.taxTotal,"1512");
  assert.equal(manualQuote.body.quote.grandTotal,"20412");
  const manualQtyQuote=await request("/v1/sales/quote","POST",{
    branchId:b,customerId:c1.body.id,priceListId:manualList.body.id,
    lines:[{sellSkuId:baseSku,quantity:"2.5",unitPrice:"9800",
      discountRate:"0",taxRate:"0"}]},token);
  assert.equal(manualQtyQuote.status,200,JSON.stringify(manualQtyQuote.body));
  assert.equal(manualQtyQuote.body.quote.lines[0].normalizedBaseQuantity,"2.500000",
    "stock normalization is sold quantity times conversion, not unit price");
  const manualOrder=await write("/v1/sales/orders",{
   ...manualInput,note:"Hai dòng cùng SKU",
   lines:manualInput.lines.map((line,i)=>({...line,
    expectedPriceSignature:manualQuote.body.quote.lines[i].priceSignature})),
  });
  assert.equal(manualOrder.status,201,JSON.stringify(manualOrder.body));
  assert.equal(Number(manualOrder.body.total),20412);
  const manualLines=await pool.query<{n:string}>(`SELECT count(*)::text AS n
   FROM sales_order_line WHERE installation_id=$1 AND branch_id=$2
    AND order_id=$3 AND pricing_engine='R1'`,
   [root.installationId,b,manualOrder.body.id]);
  assert.equal(manualLines.rows[0]!.n,"2");
  const manualConfirmed=await write(
   "/v1/sales/orders/"+manualOrder.body.id+"/confirm",
   {branchId:b},"p0-manual-confirm-"+randomUUID());
  assert.equal(manualConfirmed.status,200,JSON.stringify(manualConfirmed.body));

  // P0: create/edit multi-scope arrays in ONE audited price-list mutation.
  const atomicList=await legacy("price-lists",{
    code:"P0-ATOMIC",name:"Bảng phạm vi kết hợp",
    effectiveFrom:"2026-11-18T00:00:00Z",
    effectiveTo:"2026-11-19T00:00:00Z",priority:5,
    channelIds:[channel.body.id,anotherChannel.body.id],
    customerGroupIds:[vipGroup.body.id,standardGroup.body.id],
    customerIds:[c1.body.id],stackingMode:"STACKABLE",stopProcessing:false,
  });
  assert.equal(atomicList.status,201,JSON.stringify(atomicList.body));
  const scopeRead=()=>request("/v1/catalog/price-lists/assignments?branchId="+b+
    "&priceListId="+atomicList.body.id,"GET",undefined,token);
  const scopeRows=(await scopeRead()).body.items;
  assert.equal(scopeRows.filter((x:any)=>x.active).length,5,
    "one form creates all channel/group/customer assignments atomically");
  assert.equal((await r1("rules",{priceListId:atomicList.body.id,sellSkuId:baseSku,
    scopeKind:"BASE",adjustment:"FIXED_PRICE",amount:"9800",
    effectiveFrom:"2026-11-17T00:00:00Z"})).status,201);
  const promoList=await legacy("price-lists",{code:"P0-PROMO",
    name:"Giảm giá thêm",stackingMode:"STACKABLE"});
  assert.equal(promoList.status,201,JSON.stringify(promoList.body));
  for(const target of [
    {scopeKind:"CHANNEL",channelId:channel.body.id},
    {scopeKind:"CUSTOMER_GROUP",customerGroupId:vipGroup.body.id},
  ]){
    const assign=await write("/v1/catalog/price-lists/assignments",{
      priceListId:promoList.body.id,priority:1,...target});
    assert.equal(assign.status,201,JSON.stringify(assign.body));
  }
  const promotion=await r1("rules",{priceListId:promoList.body.id,
    sellSkuId:baseSku,scopeKind:"CUSTOMER_GROUP",customerGroup:"VIP",
    adjustment:"PERCENT_DISCOUNT",amount:"5",
    priority:15,stacking:"STACKABLE",effectiveFrom:"2026-11-17T00:00:00Z"});
  assert.equal(promotion.status,201,JSON.stringify(promotion.body));
  const quoteAtomic=(customerId:string,channelId:string)=>resolvePrice({
    priceListId:atomicList.body.id,sellSkuId:baseSku,
    quantity:"1",customerId,channelId,priceAt:"2026-11-18T12:00:00Z"});
  const stacked=await quoteAtomic(c1.body.id,channel.body.id);
  assert.equal(stacked.status,200,JSON.stringify(stacked.body));
  assert.equal(Number(stacked.body.quote.unitPrice),9310,
    "matching stackable discount on a different list is applied exactly once");
  const secondPromotion=await r1("rules",{priceListId:promoList.body.id,
    sellSkuId:baseSku,scopeKind:"PROMOTION",
    adjustment:"PERCENT_DISCOUNT",amount:"10",
    priority:10,stacking:"STACKABLE",effectiveFrom:"2026-11-17T00:00:00Z",
    effectiveTo:"2026-11-19T00:00:00Z"});
  assert.equal(secondPromotion.status,201,JSON.stringify(secondPromotion.body));
  const promoStop=await request("/v1/catalog/price-lists/"+promoList.body.id,"PATCH",{
    branchId:b,stopProcessing:true},token,{
    "if-match":"0","idempotency-key":"p0-promo-stop-"+randomUUID()});
  assert.equal(promoStop.status,200,JSON.stringify(promoStop.body));
  const bothDiscounts=await quoteAtomic(c1.body.id,channel.body.id);
  assert.equal(bothDiscounts.status,200,JSON.stringify(bothDiscounts.body));
  assert.equal(Number(bothDiscounts.body.quote.unitPrice),8379,
    "list-level stop must preserve both 5% and 10% rules from its own list");
  assert.equal(Number((await quoteAtomic(c1.body.id,anotherChannel.body.id))
    .body.quote.unitPrice),9800,"nonmatching channel cannot borrow channel-scoped discount");
  const stop=await request("/v1/catalog/price-lists/"+atomicList.body.id,"PATCH",{
    branchId:b,stopProcessing:true},token,{
    "if-match":"0","idempotency-key":"p0-stop-"+randomUUID()});
  assert.equal(stop.status,200,JSON.stringify(stop.body));
  assert.equal(Number((await quoteAtomic(c1.body.id,channel.body.id))
    .body.quote.unitPrice),9800,"stop processing prevents cross-list discount");
  const narrowed=await request("/v1/catalog/price-lists/"+atomicList.body.id,"PATCH",{
    branchId:b,stopProcessing:false,
    channelIds:[channel.body.id],customerGroupIds:[vipGroup.body.id],
    customerIds:[],defaultAssignment:false},token,{
    "if-match":"1","idempotency-key":"p0-narrow-"+randomUUID()});
  assert.equal(narrowed.status,200,JSON.stringify(narrowed.body));
  assert.equal((await scopeRead()).body.items.filter((x:any)=>x.active).length,2,
    "scope edit leaves retired assignment history instead of deleting");
  assert.equal((await quoteAtomic(c2.body.id,channel.body.id)).status,409,
    "both scoped dimensions must match after scope correction");

  // R1-C.1: selection stays on the existing SKU pricing engine, with
  // strict list windows, scoped priority, concurrency, RBAC, and replay.
  assert.equal((await legacy("price-lists",{code:"BAD-WINDOW",name:"Sai thời hạn",
    effectiveFrom:"2026-11-24T00:00:00Z",
    effectiveTo:"2026-11-23T00:00:00Z"})).status,400);
  const periods=[
    {code:"DEF",amount:"10000.0000",priority:4},
    {code:"K-MCP",amount:"20000.0000",priority:8},
    {code:"G-VIP",amount:"30000.0000",priority:2},
    {code:"C-01",amount:"40000.0000",priority:1},
  ];
  const scopedLists=[] as string[];
  for(const p of periods){
    const created=await legacy("price-lists",{
      code:p.code,name:"Bảng "+p.code,priority:p.priority,
      effectiveFrom:"2026-11-20T00:00:00Z",
      effectiveTo:"2026-11-25T00:00:00Z",
    });
    assert.equal(created.status,201,JSON.stringify(created.body));
    scopedLists.push(created.body.id as string);
    const rule=await r1("rules",{
      priceListId:created.body.id,sellSkuId:baseSku,
      effectiveFrom:now,scopeKind:"BASE",adjustment:"FIXED_PRICE",
      amount:p.amount,minQuantity:"1",
    });
    assert.equal(rule.status,201,JSON.stringify(rule.body));
  }
  const assignments=[
    {scopeKind:"DEFAULT",priceListId:scopedLists[0]},
    {scopeKind:"CHANNEL",priceListId:scopedLists[1],channelId:channel.body.id},
    {scopeKind:"CUSTOMER_GROUP",priceListId:scopedLists[2],customerGroupId:vipGroup.body.id},
    {scopeKind:"CUSTOMER",priceListId:scopedLists[3],customerId:c1.body.id},
  ];
  const assigned=[] as Array<Record<string,any>>;
  for(const input of assignments){
    const saved=await write("/v1/catalog/price-lists/assignments",input);
    assert.equal(saved.status,201,JSON.stringify(saved.body));
    assigned.push(saved.body);
  }
  const auto=(context:Record<string,unknown>)=>resolvePrice({
    sellSkuId:baseSku,quantity:"2",priceAt,...context,
  });
  const effectiveDefault=await auto({});
  assert.equal(effectiveDefault.status,200,JSON.stringify(effectiveDefault.body));
  assert.equal(effectiveDefault.body.quote.unitPrice,"10000.0000");
  assert.equal(effectiveDefault.body.quote.priceListId,scopedLists[0]);
  assert.match(effectiveDefault.body.quote.priceListSelectionReason,/mặc định/);
  assert.equal((await auto({channelId:channel.body.id})).body.quote.unitPrice,"20000.0000");
  assert.equal((await auto({customerId:c1.body.id})).body.quote.unitPrice,"40000.0000");
  assert.equal((await auto({customerId:c2.body.id,channelId:channel.body.id})).body.quote.unitPrice,
    "20000.0000","standard group falls back to channel");
  const grouped=await auto({customerId:c1.body.id,channelId:channel.body.id});
  assert.equal(grouped.body.quote.unitPrice,"40000.0000",
    "specific customer takes precedence over group/channel irrespective of numeric priority");
  const disable=await request("/v1/catalog/price-lists/assignments/"+assigned[3]!.id,
    "PATCH",{branchId:b,active:false},token,
    {"if-match":"0","idempotency-key":"disable-"+randomUUID()});
  assert.equal(disable.status,200,JSON.stringify(disable.body));
  assert.equal((await auto({customerId:c1.body.id,channelId:channel.body.id}))
    .body.quote.unitPrice,"30000.0000","customer group now wins");
  assert.equal((await auto({customerId:c1.body.id}))
    .body.quote.unitPrice,"30000.0000");
  assert.equal((await auto({customerId:c2.body.id}))
    .body.quote.unitPrice,"10000.0000");
  const assignmentHistory=await request("/v1/catalog/price-lists/assignments?branchId="+b,
    "GET",undefined,token);
  assert.equal(assignmentHistory.status,200);
  assert.ok(assignmentHistory.body.items.some((x:any)=>x.id===assigned[3]!.id&&x.active===false));
  assert.equal((await request("/v1/catalog/price-lists/assignments?branchId="+b))
    .status,401,"assignments are never public");
  const overlapPayload={scopeKind:"DEFAULT",priceListId:scopedLists[1],priority:0};
  assert.equal((await write("/v1/catalog/price-lists/assignments",overlapPayload)).status,409);
  const colliding=await Promise.all([1,2].map(()=>write(
    "/v1/catalog/price-lists/assignments",
    {...overlapPayload,priority:5},"r1c-concurrent-"+randomUUID())));
  assert.deepEqual(colliding.map(x=>x.status).sort(),[201,409],
    "two concurrent matching assignments cannot both win");
  const explicitExpired=await resolvePrice({priceListId:scopedLists[0],
    sellSkuId:baseSku,quantity:"1",priceAt:"2026-11-26T00:00:00Z"});
  assert.equal(explicitExpired.status,409,"explicit list expiry must be enforced");
  const noActive=await auto({priceAt:"2026-11-26T00:00:00Z"});
  assert.equal(noActive.status,409,"no automatic list survives its end day");
  assert.equal((await resolvePrice({sellSkuId:baseSku,quantity:"1",
    priceAt:"2026-11-26T00:00:00Z"})).status,409);
  const inherit=await write("/v1/catalog/price-lists/"+scopedLists[0]+"/clone",
    {code:"DEF-COPY",name:"Bảng sao chép thời hạn",sourceRevision:0});
  assert.equal(inherit.status,201,JSON.stringify(inherit.body));
  const withWindows=await request("/v1/catalog/price-lists?branchId="+b,"GET",undefined,token);
  const cloned=withWindows.body.items.find((x:any)=>x.id===inherit.body.id);
  assert.equal(cloned.priority,4);
  assert.equal(cloned.effectiveFrom,"2026-11-20T00:00:00.000Z");
  assert.equal(cloned.effectiveTo,"2026-11-25T00:00:00.000Z");
  assert.equal((await resolvePrice({priceListId:inherit.body.id,sellSkuId:baseSku,
    quantity:"1",priceAt})).status,200);
  // R1-C: a list copy is a new independent identity, copying only current
  // effective prices and unretired current/future SKU rules.
  const originalPrice=await legacy("prices",{
   priceListId:list.body.id,productId:product.body.id,
   amount:"9999.0000",discountRate:"0",
   effectiveAt:"2026-11-21T00:00:00Z",
  });
  assert.equal(originalPrice.status,201,JSON.stringify(originalPrice.body));
  const cloneKey="r1c-clone-"+randomUUID();
  const clonePayload={code:"SELL-COPY",name:"Giá bán sao chép",sourceRevision:0};
  const clone=await write("/v1/catalog/price-lists/"+list.body.id+"/clone",
    clonePayload,cloneKey);
  assert.equal(clone.status,201,JSON.stringify(clone.body));
  assert.equal(clone.body.sourceId,list.body.id);
  assert.equal(clone.body.copiedPrices,1);
  assert.equal(clone.body.copiedRules,6,"base, channel, group, duplicate group and customer");
  const replayClone=await Promise.all([
   write("/v1/catalog/price-lists/"+list.body.id+"/clone",clonePayload,cloneKey),
   write("/v1/catalog/price-lists/"+list.body.id+"/clone",clonePayload,cloneKey),
  ]);
  assert.deepEqual(replayClone[0]!.body,clone.body);
  assert.deepEqual(replayClone[1]!.body,clone.body);
  assert.equal((await write("/v1/catalog/price-lists/"+list.body.id+"/clone",
   {...clonePayload,name:"Khác"},cloneKey)).status,409);
  assert.equal((await write("/v1/catalog/price-lists/"+list.body.id+"/clone",
   {...clonePayload,code:"SELL-COPY-2",sourceRevision:1})).status,409,
   "stale source revision must fail without copying anything");
  const cloneQuote=await resolvePrice({
    priceListId:clone.body.id,sellSkuId:skuId,quantity:"2",
    customerId:c1.body.id,channelId:channel.body.id,
    priceAt:new Date(Date.now()+5000).toISOString(),
  });
  assert.equal(cloneQuote.status,200,JSON.stringify(cloneQuote.body));
  assert.equal(cloneQuote.body.quote.unitPrice,"111150");
  assert.match(cloneQuote.body.quote.trace[1].reason,/ưu tiên/);
  const copiedHistory=await request(
   "/v1/catalog/prices?branchId="+b+"&q=SP-01","GET",undefined,token);
  assert.equal(copiedHistory.status,200);
  assert.ok(copiedHistory.body.items.some((x:any)=>
    x.priceListId===clone.body.id&&x.productCode==="SP-01"));
  const readOriginalList=await request(
    "/v1/catalog/price-lists?branchId="+b,"GET",undefined,token);
  assert.equal(readOriginalList.body.items.find((x:any)=>
    x.id===list.body.id)?.code,"SELL","cloning must not edit source identity");

  // Regression: two active BASE policies of equal priority and a shared
  // effective timestamp must resolve in the same order after cloning.
  // Direct inserts represent legitimate pre-R1-C immutable legacy history.
  const precedenceList=await legacy("price-lists",{
   code:"PRIO",name:"Nguồn kiểm thử thứ tự chính sách"});
  assert.equal(precedenceList.status,201);
  await pool.query(`INSERT INTO catalog_sku_price_rule
   (installation_id,branch_id,price_list_id,sell_sku_id,scope_kind,
    adjustment,amount,priority,effective_from)
   VALUES ($1,$2,$3,$4,'BASE','FIXED_PRICE',21000,90,
     transaction_timestamp()-interval '2 days'),
    ($1,$2,$3,$4,'BASE','FIXED_PRICE',22000,90,
     transaction_timestamp()-interval '1 day'),
    ($1,$2,$3,$4,'BASE','FIXED_PRICE',23000,90,
     transaction_timestamp()-interval '1 day')`,
   [root.installationId,b,precedenceList.body.id,baseSku]);
  const sameClock=new Date().toISOString();
  const priorityBefore=await resolvePrice({
   priceListId:precedenceList.body.id,sellSkuId:baseSku,quantity:"1",
   priceAt:sameClock});
  assert.equal(priorityBefore.status,200,JSON.stringify(priorityBefore.body));
  const copiedPriority=await write("/v1/catalog/price-lists/"+
   precedenceList.body.id+"/clone",{
    code:"PRIO-COPY",name:"Bản sao thứ tự",sourceRevision:0,
   });
  assert.equal(copiedPriority.status,201,JSON.stringify(copiedPriority.body));
  assert.equal(copiedPriority.body.copiedRules,3);
  const priorityAfter=await resolvePrice({
   priceListId:copiedPriority.body.id,sellSkuId:baseSku,quantity:"1",
   priceAt:sameClock});
  assert.equal(priorityAfter.status,200,JSON.stringify(priorityAfter.body));
  assert.equal(priorityAfter.body.quote.unitPrice,
    priorityBefore.body.quote.unitPrice,
    "cloned equal-priority rule order must match source");
  // Distinct spelling of the SAME decimal quantity must take a single
  // advisory lock; concurrent conflicting prices cannot both commit.
  const decimalLockList=await legacy("price-lists",{
   code:"LOCK-TEST",name:"Kiểm thử khóa chính sách"});
  assert.equal(decimalLockList.status,201);
  const lockBase={
   priceListId:decimalLockList.body.id,sellSkuId:baseSku,
   scopeKind:"BASE",adjustment:"FIXED_PRICE",priority:51,
   effectiveFrom:"2026-11-21T00:00:00Z",
  };
  const decimalRace=await Promise.all([
   r1("rules",{...lockBase,amount:"23000.0000",minQuantity:"1"}),
   r1("rules",{...lockBase,amount:"24000.0000",minQuantity:"1.000"}),
  ]);
  assert.deepEqual(decimalRace.map(x=>x.status).sort((a,b)=>a-b),[201,409],
   "same numeric threshold with different strings must serialize");
  assert.equal(decimalRace.find(x=>x.status===409)?.body.error?.code,
    "PRICE_RULE_OVERLAP");
  const laterBase=await r1("rules",{...lockBase,
   amount:"25000.0000",minQuantity:"1.000",
   effectiveFrom:"2026-11-22T00:00:00Z"});
  assert.equal(laterBase.status,201,JSON.stringify(laterBase.body));
  const latestBase=await resolvePrice({
   priceListId:decimalLockList.body.id,sellSkuId:baseSku,
   quantity:"1",priceAt:new Date().toISOString(),
  });
  assert.equal(latestBase.status,200,JSON.stringify(latestBase.body));
  assert.equal(latestBase.body.quote.unitPrice,"25000.0000",
   "later immutable BASE rule supersedes older price without retirement");


  // Order API must use the same R1 resolver as the visible customer/channel quote.
  // Two distinct sell units of one product are permitted on the same commercial order.
  const orderPayload={
   branchId:b,customerId:c1.body.id,priceListId:list.body.id,channelId:channel.body.id,
   note:"Hai đơn vị bán",lines:[
    {sellSkuId:baseSku,quantity:"1"},{sellSkuId:skuId,quantity:"2"},
   ],
  };
  const withReceipts=async()=>({
   ...orderPayload,
   lines:await Promise.all(orderPayload.lines.map(async line=>{
    const response=await resolvePrice({
     priceListId:list.body.id,sellSkuId:line.sellSkuId,quantity:line.quantity,
     customerId:c1.body.id,channelId:channel.body.id,
    });
    assert.equal(response.status,200,JSON.stringify(response.body));
    const signature=response.body.quote.priceSignature as string;
    assert.match(signature,/^[0-9a-f]{64}$/);
    return {...line,expectedPriceSignature:signature};
   })),
  });
  const orderWrite=(path:string,data:Record<string,unknown>,revision:number,
   key:string,method="POST")=>request(path,method,data,token,{
    "idempotency-key":key,"if-match":String(revision),
   });
  const orderKey="r1-order-"+randomUUID();
  const firstPayload=await withReceipts();
  const created=await orderWrite("/v1/sales/orders",firstPayload,0,orderKey);
  assert.equal(created.status,201,JSON.stringify(created.body));
  assert.equal(created.body.total,"234300");
  const orderId=created.body.id as string;
  const lostAckReplay=await orderWrite("/v1/sales/orders",firstPayload,0,orderKey);
  assert.deepEqual(lostAckReplay.body,created.body);
  const stored=await request("/v1/sales/orders/"+orderId+"?branchId="+b,
   "GET",undefined,token);
  assert.equal(stored.status,200,JSON.stringify(stored.body));
  assert.equal(stored.body.order.channelId,channel.body.id);
  assert.equal(stored.body.order.lines.length,2);
  assert.equal(stored.body.order.lines[1].sellSkuId,skuId);
  assert.equal(stored.body.order.lines[1].pricingEngine,"R1");
  assert.equal(stored.body.order.lines[1].priceSnapshot.normalizedBaseQuantity,"24.000000");
  assert.equal(stored.body.order.lines[1].priceSnapshot.trace.length,3);
  assert.equal((await orderWrite("/v1/sales/orders",
   {...orderPayload,lines:[{sellSkuId:skuId,quantity:2}]},0,
   "float-r1-"+randomUUID())).status,400);
  assert.equal((await orderWrite("/v1/sales/orders",
   {...orderPayload,lines:[{sellSkuId:skuId,quantity:"1"},
     {sellSkuId:skuId,quantity:"1"}]},0,"dupe-r1-"+randomUUID())).status,400);

  // Insert a newly effective rule *after* draft creation: confirming cannot
  // post the earlier price or silently ignore the now-changed precedence.
  const newer=await r1("rules",{...basic,sellSkuId:skuId,
   scopeKind:"BASE",adjustment:"FIXED_PRICE",amount:"140000.0000",priority:100,
   effectiveFrom:"2026-11-21T00:00:02Z"});
  assert.equal(newer.status,201,JSON.stringify(newer.body));
  const oldQuote=await orderWrite("/v1/sales/orders",firstPayload,0,
   "stale-preview-"+randomUUID());
  assert.equal(oldQuote.status,409,JSON.stringify(oldQuote.body));
  assert.equal(oldQuote.body.error?.code,"PRICE_STALE",
   "price changes between preview and save must not silently reprice");
  const stale=await orderWrite("/v1/sales/orders/"+orderId+"/confirm",
   {branchId:b},0,"stale-r1-"+randomUUID());
  assert.equal(stale.status,409,JSON.stringify(stale.body));
  const currentPayload=await withReceipts();
  const refreshed=await orderWrite("/v1/sales/orders/"+orderId,currentPayload,0,
   "refresh-r1-"+randomUUID(),"PATCH");
  assert.equal(refreshed.status,200,JSON.stringify(refreshed.body));
  assert.notEqual(refreshed.body.total,created.body.total);
  const confirmed=await orderWrite("/v1/sales/orders/"+orderId+"/confirm",
   {branchId:b},1,"confirm-r1-"+randomUUID());
  assert.equal(confirmed.status,200,JSON.stringify(confirmed.body));
  assert.equal((await orderWrite("/v1/sales/orders/"+orderId,currentPayload,2,
   "post-r1-"+randomUUID(),"PATCH")).status,409,
   "confirmed commercial versions cannot be rewritten");
  const history=await request("/v1/sales/orders/"+orderId+"?branchId="+b,
   "GET",undefined,token);
  assert.equal(history.body.order.versionStatus,"CONFIRMED");
  assert.equal(history.body.order.lines[1].priceSnapshot.unitPrice,"119700");
  const openPromotion={...basic,sellSkuId:baseSku,scopeKind:"PROMOTION",
   adjustment:"PERCENT_DISCOUNT",amount:"10.0000",priority:10,
   stacking:"EXCLUSIVE"};
  assert.equal((await r1("rules",openPromotion)).status,400,
   "promotions must declare their end time");
  // A live retirement is stamped at database NOW(); keep the test promotion
  // active at that instant, regardless of when the CI run is executed.
  const promoEnd=new Date(Date.now()+30*24*60*60*1000).toISOString();
  const timeBound=await r1("rules",{
   ...openPromotion,effectiveTo:promoEnd,
  });
  assert.equal(timeBound.status,201,JSON.stringify(timeBound.body));
  const during=await resolvePrice({
   priceListId:list.body.id,sellSkuId:baseSku,quantity:"1",
   priceAt:"2026-11-21T08:00:00Z",
  });
  const after=await resolvePrice({
   priceListId:list.body.id,sellSkuId:baseSku,quantity:"1",
   priceAt:new Date(Date.parse(promoEnd)+24*60*60*1000).toISOString(),
  });
  assert.equal(during.body.quote.unitPrice,"10800");
  assert.equal(after.body.quote.unitPrice,"12000.0000");
  const retireKey="retire-"+randomUUID();
  const retirement=await write("/v1/catalog/r1/rules/"+timeBound.body.id+"/retire",
   {reason:"Kết thúc ưu đãi theo kế hoạch"},retireKey);
  assert.equal(retirement.status,200,JSON.stringify(retirement.body));
  assert.deepEqual((await write("/v1/catalog/r1/rules/"+timeBound.body.id+"/retire",
   {reason:"Kết thúc ưu đãi theo kế hoạch"},retireKey)).body,retirement.body,
   "lost ACK must replay same immutable retirement event");
  assert.equal((await write("/v1/catalog/r1/rules/"+timeBound.body.id+"/retire",
   {reason:"Yêu cầu thay đổi"},retireKey)).status,409);
  assert.equal((await write("/v1/catalog/r1/rules/"+timeBound.body.id+"/retire",
   {reason:"Yêu cầu khác sau khi kết thúc"})).status,409);
  const retiredAt=Date.parse(retirement.body.retiredAt);
  const previousPrice=await resolvePrice({
   priceListId:list.body.id,sellSkuId:baseSku,quantity:"1",
   priceAt:new Date(retiredAt-1000).toISOString(),
  });
  const currentPrice=await resolvePrice({
   priceListId:list.body.id,sellSkuId:baseSku,quantity:"1",
   priceAt:new Date(retiredAt+1000).toISOString(),
  });
  assert.equal(previousPrice.body.quote.unitPrice,"10800");
  assert.equal(currentPrice.body.quote.unitPrice,"12000.0000");
  const rules=await read("rules");
  assert.equal(rules.body.items.find((x:any)=>x.id===timeBound.body.id)?.retiredAt!=null,true);
  await assert.rejects(pool.query(
   "DELETE FROM catalog_sku_price_retirement WHERE rule_id=$1",[timeBound.body.id]),
   /immutable/i);
  const patchR1=(kind:string,targetId:string,revision:number,
    fields:Record<string,unknown>,key="update-r1-"+randomUUID())=>
    request("/v1/catalog/r1/"+kind+"/"+targetId,"PATCH",
      {branchId:b,...fields},token,
      {"idempotency-key":key,"if-match":String(revision)});
  const channelKey="channel-edit-"+randomUUID();
  const updatedChannel=await patchR1("channels",channel.body.id,0,
    {name:"Kênh bán thị trường",active:true},channelKey);
  assert.equal(updatedChannel.status,200,JSON.stringify(updatedChannel.body));
  assert.equal(updatedChannel.body.revision,1);
  assert.deepEqual((await patchR1("channels",channel.body.id,0,
    {name:"Kênh bán thị trường",active:true},channelKey)).body,
    updatedChannel.body,"channel update must be idempotent");
  assert.equal((await patchR1("channels",channel.body.id,0,
    {name:"Stale edit"})).status,409);
  assert.equal((await patchR1("channels",channel.body.id,1,
    {code:"MCP_NEW"})).status,400,"channel identity is immutable");
  assert.equal((await patchR1("skus",baseSku,0,{active:false})).status,400,
    "SKU deactivation always requires an auditable reason");
  const retiredBase=await patchR1("skus",baseSku,0,
    {active:false,reason:"Nhập sai SKU đơn vị gốc"});
  assert.equal(retiredBase.status,200,JSON.stringify(retiredBase.body));
  assert.equal((await patchR1("skus",baseSku,0,
    {active:true})).status,409,"stale base SKU revision must conflict");
  const liveParent=(await pool.query<{active:boolean}>(`SELECT p.active FROM catalog_product p
    JOIN catalog_sell_sku s ON s.installation_id=p.installation_id
      AND s.branch_id=p.branch_id AND s.product_id=p.id
    WHERE s.installation_id=$1 AND s.branch_id=$2 AND s.id=$3`,
    [root.installationId,b,baseSku])).rows[0]!;
  assert.equal(liveParent.active,true,
    "other active sellable variants allow the product to remain active");
  const otherBarcode=await r1("barcodes",
    {sellSkuId:skuId,barcode:"BC-0002",isPrimary:false});
  assert.equal(otherBarcode.status,201);
  // Historic Unicode labels and new directory codes must resolve the
  // SAME customer group. Neither policy may silently disappear or double stack.
  // Synthetic migrated dictionary row includes a frozen legacy alias,
  // which is intentionally unavailable to ordinary POST/PATCH APIs.
  const unicodeGroupId=(await pool.query<{id:string}>(`INSERT INTO catalog_customer_group
    (installation_id,branch_id,code,name,legacy_label)
    VALUES($1,$2,'LEGACY-7e736d8317f82900ab34d1f5d56e3ed2',
      'Bán sỉ','Bán sỉ') RETURNING id`,
    [root.installationId,b])).rows[0]!.id;
  const unicodeCustomer=await legacy("customers",{
    code:"KH-UNICODE",name:"Khách nhập theo nhóm cũ",
    customerGroupId:unicodeGroupId});
  assert.equal(unicodeCustomer.status,201);
  const newGroupRule=await r1("rules",{
    ...basic,sellSkuId:skuId,scopeKind:"CUSTOMER_GROUP",
    customerGroup:"LEGACY-7e736d8317f82900ab34d1f5d56e3ed2",
    adjustment:"PERCENT_DISCOUNT",amount:"3.0000",priority:-1,
    stacking:"STACKABLE"});
  assert.equal(newGroupRule.status,201,JSON.stringify(newGroupRule.body));
  const legacyRule=(await pool.query<{id:string}>(`INSERT INTO catalog_sku_price_rule
    (installation_id,branch_id,price_list_id,sell_sku_id,scope_kind,
      customer_group,adjustment,amount,priority,stacking,min_quantity,effective_from)
    VALUES ($1,$2,$3,$4,'CUSTOMER_GROUP','Bán sỉ','PERCENT_DISCOUNT',
      3.0000,-1,'STACKABLE',1,$5::timestamptz) RETURNING id`,
    [root.installationId,b,list.body.id,skuId,now])).rows[0]!.id;
  const renamed=await request("/v1/catalog/customer-groups/"+unicodeGroupId,"PATCH",
    {branchId:b,name:"Tên nhóm đổi sau migration",active:true},token,
    {"idempotency-key":"rename-group-"+randomUUID(),"if-match":"0"});
  assert.equal(renamed.status,200,JSON.stringify(renamed.body));
  const unicodeQuote=await resolvePrice({
    priceListId:list.body.id,sellSkuId:skuId,
    quantity:"1",customerId:unicodeCustomer.body.id,priceAt});
  assert.equal(unicodeQuote.status,200,JSON.stringify(unicodeQuote.body));
  const equivalent=[newGroupRule.body.id,legacyRule];
  assert.equal(unicodeQuote.body.quote.trace.filter(
    (x:{ruleId:string})=>equivalent.includes(x.ruleId)).length,1,
    "old label and new code are equivalent; the discount must apply exactly once");
  const disabledSku=await patchR1("skus",skuId,0,
    {active:false,reason:"Sai quy cách nhập thử"});
  assert.equal(disabledSku.status,200,JSON.stringify(disabledSku.body));
  assert.equal(disabledSku.body.revision,1);
  assert.equal((await patchR1("skus",skuId,0,{active:true})).status,409);
  assert.equal((await patchR1("skus",skuId,1,{toBase:"24"})).status,400,
    "an immutable conversion must not become editable");
  const promote=await patchR1("barcodes",otherBarcode.body.id,0,
    {active:true,isPrimary:true});
  assert.equal(promote.status,200,JSON.stringify(promote.body));
  const barcodes=await read("barcodes");
  assert.equal(barcodes.body.items.find((x:any)=>x.id===otherBarcode.body.id)?.isPrimary,true);
  assert.equal(barcodes.body.items.find((x:any)=>x.id===code.body.id)?.isPrimary,false);
  assert.equal((await patchR1("barcodes",otherBarcode.body.id,0,
    {active:false})).status,409,"barcode revision guards other-device stale edits");
  assert.equal((await patchR1("barcodes",otherBarcode.body.id,1,
    {barcode:"CHANGED"})).status,400,"barcode identity is immutable");
  const onlyBaseProduct=await legacy("products",{
    code:"SP-WRONG-BASE",name:"Sản phẩm nhập sai mã gốc",baseUnit:"cai",
  });
  assert.equal(onlyBaseProduct.status,201,JSON.stringify(onlyBaseProduct.body));
  const onlyBaseSku=(await read("skus","SP-WRONG-BASE")).body.items[0];
  const retiredLast=await patchR1("skus",onlyBaseSku.id,0,
    {active:false,reason:"Ngừng SKU được nhập sai khi tạo"});
  assert.equal(retiredLast.status,200,JSON.stringify(retiredLast.body));
  assert.equal((await pool.query<{active:boolean}>(`SELECT active FROM catalog_product
     WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [root.installationId,b,onlyBaseProduct.body.id])).rows[0]!.active,false,
    "retiring last active SKU must deactivate parent product atomically");
  assert.equal((await patchR1("skus",onlyBaseSku.id,1,{active:true})).status,409,
    "re-enabling last SKU requires product reactivation first");
  assert.equal((await read("skus","SP-WRONG-BASE")).body.items[0].active,false);
  const inactive=await pool.query<{id:string}>(
   "INSERT INTO branch(installation_id,code,name) VALUES($1,'OTHER','Other') RETURNING id",
   [root.installationId]);
  assert.equal((await request("/v1/catalog/r1/skus?branchId="+inactive.rows[0]!.id,
    "GET",undefined,token)).status,403);
  const oldRule=await pool.query<{id:string}>(
   "SELECT id FROM catalog_sku_price_rule WHERE installation_id=$1 LIMIT 1",[root.installationId]);
  await assert.rejects(pool.query("UPDATE catalog_sku_price_rule SET amount=1 WHERE id=$1",
   [oldRule.rows[0]!.id]),/immutable/i);
  await assert.rejects(pool.query("UPDATE catalog_sell_sku SET sku='REBRAND' WHERE id=$1",
   [skuId]),/immutable/i);
  const receipts=await pool.query<{total:string}>(
   "SELECT count(*)::text AS total FROM audit_event WHERE installation_id=$1 AND action_code LIKE 'r1.catalog.%'",
   [root.installationId]);
  assert.equal(Number(receipts.rows[0]?.total)>=7,true);
 }finally{
  if(app)await new Promise<void>(ok=>app!.close(()=>ok()));
  if(pool)await pool.end();
  await admin.query('DROP DATABASE IF EXISTS "'+name+'" WITH (FORCE)').catch(()=>undefined);
  await admin.end();
 }
});
