import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";
import { resolve } from "node:path";
import { Pool } from "pg";
import { applyMigrations } from "./migrate.ts";
import { bootstrapInstallation } from "./bootstrap.ts";
import { buildApp } from "./server.ts";
import { isDatabaseReady } from "./db.ts";

const source=process.env.DATABASE_URL;
const local=(()=>{
 try{const u=new URL(source??"");return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";}
 catch{return false;}
})();

test("R1-B: real PG CSV mapping, revision-bound preview, all-or-nothing COMMIT and SKU/price history",
 {skip:!local},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const dbName="erp_ci_bulk_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,app:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+dbName+'"');
  const u=new URL(source!);u.pathname="/"+dbName;
  db=new Pool({connectionString:u.toString(),max:9,query_timeout:20000});
  db.on("error",()=>{});
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).applied.length,17);
  const password="Bulk-"+randomUUID();
  const root=await bootstrapInstallation(db,{
   code:"bulk-"+randomUUID().slice(0,8),displayName:"R1-B synthetic bulk test",
   adminLogin:"owner",adminPassword:password,
  });
  app=buildApp(()=>isDatabaseReady(db!),async()=>true,{
   pool:db,installationId:root.installationId,
   allowedOrigin:"https://erp.example.test",throttleSecret:"test-"+randomUUID(),
  });
  await new Promise<void>(ok=>app!.listen(0,"127.0.0.1",ok));
  const host="http://127.0.0.1:"+(app.address() as AddressInfo).port;
  const request=async(path:string,method="GET",data?:unknown,token?:string,
    headers:Record<string,string>={})=>{
   const res=await fetch(host+path,{
    method,headers:{origin:"https://erp.example.test",
      ...(data?{"content-type":"application/json"}:{}),
      ...(token?{authorization:"Bearer "+token}:{}),...headers},
    body:data===undefined?undefined:JSON.stringify(data),
   });
   return {status:res.status,body:await res.json() as Record<string,any>};
  };
  const branchId=root.branchId;
  const login=await request("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(login.status,200);
  const token=login.body.token as string;
  const create=(kind:string,input:Record<string,unknown>)=>
   request("/v1/catalog/"+kind,"POST",{branchId,...input},token,{
    "idempotency-key":"bulk-setup-"+randomUUID(),"if-match":"0"});
  const file=(text:string)=>
   {const fileName="r1b.csv";return {branchId,resource:"customers",
    mode:"UPSERT",fileName,contentBase64:Buffer.from(text).toString("base64"),
    hasHeader:true,mapping:{
      code:"Mã KH",name:"Tên khách",customerGroupCode:"Mã nhóm",
      customerRegionCode:"Mã khu vực",phone:"Điện thoại",
      paymentTermsDays:"Hạn nợ",
    }};
   };
  const preview=(input:Record<string,unknown>)=>
   request("/v1/catalog/bulk/preview","POST",input,token);
  const inspect=(input:Record<string,unknown>)=>
   request("/v1/catalog/bulk/inspect","POST",input,token);
  const apply=(input:Record<string,unknown>,hash:string,key="bulk-"+randomUUID())=>
   request("/v1/catalog/bulk/apply","POST",{...input,previewHash:hash},token,
     {"idempotency-key":key,"if-match":"0"});

  const group=await create("customer-groups",{code:"KH_SI",name:"Khách sỉ"});
  const region=await create("customer-regions",{code:"KV_MT",name:"Mỹ Tho"});
  assert.equal(group.status,201);assert.equal(region.status,201);
  const customerInput=file("Mã KH,Tên khách,Mã nhóm,Mã khu vực,Điện thoại,Hạn nợ\n"+
   "KH01,Khách A,KH_SI,KV_MT,+84900000001,15\n"+
   "KH02,Khách B,KH_SI,KV_MT,+84900000002,30\n");
  const inspected=await inspect(customerInput);
  assert.equal(inspected.status,200,JSON.stringify(inspected.body));
  assert.equal(inspected.body.rowCount,2);
  assert.equal(inspected.body.suggestedMapping.code,"Mã KH");
  const p=await preview(customerInput);
  assert.equal(p.status,200,JSON.stringify(p.body));
  assert.equal(p.body.summary.create,2);
  assert.equal(p.body.summary.error,0);
  assert.equal(p.body.rows[0].before,null);
  assert.equal(p.body.rows[0].after.customerGroupId,group.body.id);
  const key="customers-"+randomUUID();
  const result=await apply(customerInput,p.body.hash,key);
  assert.equal(result.status,200,JSON.stringify(result.body));
  assert.equal(result.body.applied.length,2);
  const repeat=await apply(customerInput,p.body.hash,key);
  assert.equal(repeat.status,200);
  assert.equal(repeat.body.replayed,true,"retry after lost ACK must replay receipt");
  assert.equal((await db.query<{n:string}>('SELECT count(*)::text AS n FROM catalog_customer '+
    'WHERE installation_id=$1 AND branch_id=$2',
    [root.installationId,branchId])).rows[0]!.n,"2");
  const again=await preview(customerInput);
  assert.equal(again.body.summary.unchanged,2,JSON.stringify(again.body));
  const bad=file("Mã KH,Tên khách,Mã nhóm,Mã khu vực,Điện thoại,Hạn nợ\n"+
    "KH03,Khách C,KH_SI,KV_NOT_FOUND,+84900000003,20\n");
  const invalid=await preview(bad);
  assert.equal(invalid.status,200);
  assert.equal(invalid.body.summary.error,1);
  assert.equal((await apply(bad,invalid.body.hash)).status,409,
    "an error row blocks the complete batch");
  const duplicate=file("Mã KH,Tên khách,Mã nhóm,Mã khu vực,Điện thoại,Hạn nợ\n"+
    "KH04,Dup A,KH_SI,KV_MT,+84900000004,0\n"+
    "KH04,Dup B,KH_SI,KV_MT,+84900000005,0\n");
  assert.equal((await preview(duplicate)).body.summary.error,1);
  const changed=file("Mã KH,Tên khách,Mã nhóm,Mã khu vực,Điện thoại,Hạn nợ\n"+
    "KH01,Khách A mới,KH_SI,KV_MT,+84900000001,15\n");
  const oldPreview=await preview(changed);
  const patch=await request("/v1/catalog/customers/"+result.body.applied[0].id,
    "PATCH",{branchId,name:"Khách A thay từ thiết bị khác"},token,
    {"idempotency-key":"concurrent-"+randomUUID(),"if-match":"0"});
  assert.equal(patch.status,200,JSON.stringify(patch.body));
  const stale=await apply(changed,oldPreview.body.hash);
  assert.equal(stale.status,409,"stale preview cannot overwrite another device");
  const fresh=await preview(changed);
  assert.equal(fresh.body.summary.update,1);
  assert.equal((await apply(changed,fresh.body.hash)).status,200);
  const exportCsv=await request("/v1/catalog/bulk/export?branchId="+branchId+
    "&resource=customers","GET",undefined,token);
  assert.equal(exportCsv.status,200);
  assert.match(exportCsv.body.content,/KH01/);
  assert.equal(exportCsv.body.content.includes("customer_group_id"),false);

  for(const unit of ["CHAI","THUNG"]){
   assert.equal((await create("unit-definitions",{code:unit,name:unit})).status,201);
  }
  const productGroup=await create("groups",{code:"NONGSAN",name:"Nông sản"});
  assert.equal(productGroup.status,201);
  const productInput={branchId,resource:"products",mode:"UPSERT",
   fileName:"products.csv",
   contentBase64:Buffer.from("Mã SP,Tên SP,ĐVT,Nhóm\nSP01,Sản phẩm A,CHAI,NONGSAN\n").toString("base64"),
   hasHeader:true,mapping:{code:"Mã SP",name:"Tên SP",baseUnit:"ĐVT",groupCode:"Nhóm"}};
  const productPreview=await preview(productInput);
  assert.equal(productPreview.status,200,JSON.stringify(productPreview.body));
  assert.equal(productPreview.body.summary.create,1);
  const createdProduct=await apply(productInput,productPreview.body.hash);
  assert.equal(createdProduct.status,200,JSON.stringify(createdProduct.body));
  const productId=createdProduct.body.applied[0].id;
  const productReimport=await preview(productInput);
  assert.equal(productReimport.body.summary.unchanged,1,
    "exported unchanged product base UOM must not be rewritten");
  const priceList=await create("price-lists",{code:"BANLE",name:"Giá bán lẻ"});
  assert.equal(priceList.status,201);
  const pricing=(amount:string,date:string)=>({
   branchId,resource:"prices",mode:"UPSERT",fileName:"prices.csv",
   contentBase64:Buffer.from(
    "Mã bảng giá,Mã SP,Giá,CK,Hiệu lực\n"+
    "BANLE,SP01,"+amount+",5.00,"+date+"\n").toString("base64"),
   hasHeader:true,mapping:{priceListCode:"Mã bảng giá",productCode:"Mã SP",
    amount:"Giá",discountRate:"CK",effectiveAt:"Hiệu lực"},
  });
  const firstPrice=pricing("15000.0000","2026-11-23T00:00:00Z");
  const firstPricePreview=await preview(firstPrice);
  assert.equal(firstPricePreview.status,200,JSON.stringify(firstPricePreview.body));
  assert.equal((await apply(firstPrice,firstPricePreview.body.hash)).status,200);
  const laterPrice=pricing("17000.0000","2026-11-24T00:00:00Z");
  const laterPricePreview=await preview(laterPrice);
  assert.equal(laterPricePreview.body.summary.update,1);
  assert.equal((await apply(laterPrice,laterPricePreview.body.hash)).status,200);
  const priceReimport=await preview(laterPrice);
  assert.equal(priceReimport.body.summary.unchanged,1,
    "same amount and effective timestamp is unchanged, not a duplicate ledger entry");
  const conflict=await preview(pricing("99999.0000","2026-11-24T00:00:00Z"));
  assert.equal(conflict.body.summary.error,1);
  assert.equal(conflict.body.rows[0].error,"PRICE_EFFECTIVE_TIME_CONFLICT");
  assert.equal((await db.query<{n:string}>(
    'SELECT count(*)::text AS n FROM catalog_price_entry '+
    'WHERE installation_id=$1 AND branch_id=$2 AND product_id=$3',
    [root.installationId,branchId,productId])).rows[0]!.n,"2",
    "bulk price update appends new effective record without rewriting history");

  const skuFile=(code:string,active:string,reason:string)=>({
   branchId,resource:"skus",mode:"UPSERT",fileName:"skus.csv",
   contentBase64:Buffer.from("Mã SKU,Mã SP,Đơn vị,Quy đổi,Trạng thái,Lý do\n"+
    code+",SP01,THUNG,24.000000,"+active+","+reason+"\n").toString("base64"),
   hasHeader:true,mapping:{code:"Mã SKU",productCode:"Mã SP",
    unitCode:"Đơn vị",toBase:"Quy đổi",active:"Trạng thái",reason:"Lý do"},
  });
  const skuCreate=skuFile("SP01-T","1","");
  const skuPreview=await preview(skuCreate);
  assert.equal(skuPreview.body.summary.create,1,JSON.stringify(skuPreview.body));
  const skuAdded=await apply(skuCreate,skuPreview.body.hash);
  assert.equal(skuAdded.status,200,JSON.stringify(skuAdded.body));
  const skuId=skuAdded.body.applied[0].id;
  const skuStop=skuFile("SP01-T","Ngừng","Sai mã SKU");
  const skuStopPreview=await preview(skuStop);
  assert.equal(skuStopPreview.body.summary.update,1,JSON.stringify(skuStopPreview.body));
  const stopped=await apply(skuStop,skuStopPreview.body.hash);
  assert.equal(stopped.status,200,JSON.stringify(stopped.body));
  assert.equal((await db.query<{active:boolean}>(
    'SELECT active FROM catalog_sell_sku WHERE id=$1',[skuId])).rows[0]!.active,false);
  assert.equal((await db.query<{active:boolean}>(
    'SELECT active FROM catalog_product WHERE id=$1',[productId])).rows[0]!.active,true,
    "base sellable SKU remains active after retiring mistaken pack SKU");
  const otherBranch=(await db.query<{id:string}>(
   "INSERT INTO branch(installation_id,code,name) VALUES($1,'OTHER','Other') RETURNING id",
   [root.installationId])).rows[0]!.id;
  assert.equal((await preview({...customerInput,branchId:otherBranch})).status,403,
    "bulk inspection cannot leak data for unauthorized branches");
 }finally{
  if(app)await new Promise<void>(ok=>app!.close(()=>ok()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)').catch(()=>{});
  await admin.end();
 }
});
