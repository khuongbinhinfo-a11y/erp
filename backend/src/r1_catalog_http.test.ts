import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
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
  assert.equal(applied.applied.length,16);
  assert.equal((await applyMigrations(pool,resolve(process.cwd(),"db/migrations"))).skipped.length,16);
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

  const c1=await legacy("customers",{
   code:"KH-01",name:"Khách thử A",customerGroup:"VIP",
   phone:"+84900000001",deliveryAddress:"Địa chỉ kiểm thử",paymentTermsDays:15,
  });
  assert.equal(c1.status,201,JSON.stringify(c1.body));
  assert.equal((await legacy("customers",{code:"KH-02",name:"Khách trùng",
   phone:"+84900000001"})).status,409,"phone unique within installation/branch");
  const customers=await request("/v1/catalog/customers?branchId="+b,"GET",undefined,token);
  assert.equal(customers.body.items[0].phone,"+84900000001");
  assert.equal(customers.body.items[0].paymentTermsDays,15);
  const c2=await legacy("customers",{code:"KH-02",name:"Khách thử B",
   customerGroup:"STANDARD",phone:"+84900000002"});
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
