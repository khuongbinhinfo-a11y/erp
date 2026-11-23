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
  const duplicatePhone=file("Mã KH,Tên khách,Mã nhóm,Mã khu vực,Điện thoại,Hạn nợ\n"+
    "KH05,Khách E,KH_SI,KV_MT,+84900000006,0\n"+
    "KH06,Khách F,KH_SI,KV_MT,+84900000006,0\n");
  const duplicatePhonePreview=await preview(duplicatePhone);
  assert.equal(duplicatePhonePreview.status,200);
  assert.equal(duplicatePhonePreview.body.summary.error,2,
    "duplicate active phones within the CSV must be identified before apply");
  assert.equal(duplicatePhonePreview.body.rows[0].error,"DUPLICATE_CUSTOMER_PHONE");
  assert.equal((await apply(duplicatePhone,duplicatePhonePreview.body.hash)).status,409);
  const occupiedPhone=file("Mã KH,Tên khách,Mã nhóm,Mã khu vực,Điện thoại,Hạn nợ\n"+
    "KH07,Khách G,KH_SI,KV_MT,+84900000001,0\n");
  const occupiedPhonePreview=await preview(occupiedPhone);
  assert.equal(occupiedPhonePreview.body.summary.error,1,
    "phone owned by an existing active code outside the file is an error");
  assert.equal(occupiedPhonePreview.body.rows[0].error,"DUPLICATE_CUSTOMER_PHONE");
  const phoneHandoff=file("Mã KH,Tên khách,Mã nhóm,Mã khu vực,Điện thoại,Hạn nợ\n"+
    "KH01,Khách A,KH_SI,KV_MT,+84900000007,15\n"+
    "KH08,Khách H,KH_SI,KV_MT,+84900000001,0\n");
  const handoffPreview=await preview(phoneHandoff);
  assert.equal(handoffPreview.body.summary.error,0,
    "changing an existing phone and assigning its old number in one batch is valid");
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
  assert.match(exportCsv.body.content,/\'\+84900000001/,
    "international phone values are CSV formula-neutralized");
  const exportedCustomerReimport={
    ...customerInput,
    fileName:"export-customers.csv",
    contentBase64:Buffer.from(exportCsv.body.content).toString("base64"),
    mapping:{
      code:"code",name:"name",customerGroupCode:"customerGroupCode",
      customerRegionCode:"customerRegionCode",phone:"phone",
      deliveryAddress:"deliveryAddress",paymentTermsDays:"paymentTermsDays",
      active:"active",
    },
  };
  const roundtrip=await preview(exportedCustomerReimport);
  assert.equal(roundtrip.body.summary.unchanged,2,JSON.stringify(roundtrip.body));
  const decoratedCustomer={
   branchId,resource:"customers",mode:"UPSERT",fileName:"text-customer.csv",
   contentBase64:Buffer.from("Mã KH,Tên khách,Địa chỉ giao\n"+
    "KHFORM,@Home,-Kho hàng\n").toString("base64"),
   hasHeader:true,mapping:{code:"Mã KH",name:"Tên khách",
    deliveryAddress:"Địa chỉ giao"},
  };
  const decoratedPreview=await preview(decoratedCustomer);
  assert.equal(decoratedPreview.body.summary.error,0);
  assert.equal((await apply(decoratedCustomer,decoratedPreview.body.hash)).status,200);
  const exportDecorated=await request("/v1/catalog/bulk/export?branchId="+branchId+
    "&resource=customers","GET",undefined,token);
  assert.equal(exportDecorated.status,200);
  assert.match(exportDecorated.body.content,/'@Home/);
  assert.match(exportDecorated.body.content,/'-Kho hàng/);
  const decoratedRoundtrip=await preview({
   ...exportedCustomerReimport,
   contentBase64:Buffer.from(exportDecorated.body.content).toString("base64"),
  });
  const decoratedRow=decoratedRoundtrip.body.rows.find((row:{key:string})=>row.key==="KHFORM");
  assert.equal(decoratedRow?.action,"UNCHANGED",
   "formula-safe exported customer name/address must reimport unchanged");
  const inactiveCustomer=await create("customers",{
   code:"KH_IN",name:"Khách đã ngừng",customerGroupId:group.body.id,
   customerRegionId:region.body.id,phone:"+84900000031"});
  assert.equal(inactiveCustomer.status,201,JSON.stringify(inactiveCustomer.body));
  await db.query('UPDATE catalog_customer SET active=false,phone=$4 '+
    'WHERE installation_id=$1 AND branch_id=$2 AND id=$3',
    [root.installationId,branchId,inactiveCustomer.body.id,"+84900000001"]);
  const reactivateOnly={
   ...customerInput,fileName:"reactivate.csv",
   contentBase64:Buffer.from("Mã KH,Trạng thái\nKH_IN,1\n").toString("base64"),
   mapping:{code:"Mã KH",active:"Trạng thái"},
  };
  const reactivatePreview=await preview(reactivateOnly);
  assert.equal(reactivatePreview.status,200);
  assert.equal(reactivatePreview.body.rows[0].error,"DUPLICATE_CUSTOMER_PHONE",
    "reactivating a customer retaining a phone owned by another active code is invalid");


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
  const decoratedProduct=await request("/v1/catalog/products/"+productId,
    "PATCH",{branchId,name:"@Product"},token,
    {"idempotency-key":"product-formula-"+randomUUID(),"if-match":"0"});
  assert.equal(decoratedProduct.status,200,JSON.stringify(decoratedProduct.body));
  const exportedProduct=await request("/v1/catalog/bulk/export?branchId="+branchId+
    "&resource=products","GET",undefined,token);
  assert.equal(exportedProduct.status,200);
  assert.match(exportedProduct.body.content,/'@Product/);
  const importedProduct=await preview({
   ...productInput,fileName:"export-products.csv",
   contentBase64:Buffer.from(exportedProduct.body.content).toString("base64"),
   mapping:{code:"code",name:"name",baseUnit:"baseUnit",
    groupCode:"groupCode",barcode:"barcode",active:"active"},
  });
  assert.equal(importedProduct.body.rows[0].action,"UNCHANGED",
    "formula-safe product names must round-trip unchanged");
  const barcodeOwner=await create("products",{
   code:"SPBC",name:"Sản phẩm có barcode",baseUnit:"CHAI",
   groupId:productGroup.body.id,barcode:"BARCODE777"});
  assert.equal(barcodeOwner.status,201,JSON.stringify(barcodeOwner.body));
  await db.query('UPDATE catalog_sku_barcode SET active=false '+
   'WHERE installation_id=$1 AND branch_id=$2 AND barcode=$3',
   [root.installationId,branchId,"BARCODE777"]);
  const withBarcode=(lines:string)=>({
   ...productInput,fileName:"products-barcodes.csv",
   contentBase64:Buffer.from("Mã SP,Tên SP,ĐVT,Nhóm,Barcode\n"+lines).toString("base64"),
   mapping:{...productInput.mapping,barcode:"Barcode"},
  });
  const alreadyUsedBarcode=await preview(withBarcode(
   "SPBCNEW,Trùng mã vạch,CHAI,NONGSAN,BARCODE777\n"));
  assert.equal(alreadyUsedBarcode.status,200);
  assert.equal(alreadyUsedBarcode.body.rows[0].error,"BARCODE_ALREADY_ASSIGNED",
   "inactive barcode records still reserve their identity");
  const fileBarcodeConflict=await preview(withBarcode(
   "SPBC1,Đơn vị A,CHAI,NONGSAN,BARCODE888\n"+
   "SPBC2,Đơn vị B,CHAI,NONGSAN,BARCODE888\n"));
  assert.equal(fileBarcodeConflict.body.summary.error,2);
  assert.deepEqual(fileBarcodeConflict.body.rows.map((row:{error:string})=>row.error),
   ["DUPLICATE_FILE_BARCODE","DUPLICATE_FILE_BARCODE"]);


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
  const impossibleDate=await preview(pricing("15000.0000","2026-02-30T00:00:00Z"));
  assert.equal(impossibleDate.status,200,"invalid date is a row error, not HTTP 503");
  assert.equal(impossibleDate.body.summary.error,1);
  assert.equal(impossibleDate.body.rows[0].error,"INVALID_EFFECTIVE_AT");
  const impossibleLeap=await preview(pricing("15000.0000","2025-02-29T00:00:00Z"));
  assert.equal(impossibleLeap.status,200);
  assert.equal(impossibleLeap.body.rows[0].error,"INVALID_EFFECTIVE_AT");
  assert.equal((await preview(pricing("15000.0000","2028-02-29T00:00:00Z"))).body.summary.error,0);
  // An immutable timestamp with microseconds must round-trip via exported
  // CSV without generating another price entry.
  const laterPrice=pricing("17000.0000","2026-11-24T00:00:00Z");
  const laterPricePreview=await preview(laterPrice);
  assert.equal(laterPricePreview.body.summary.update,1);
  assert.equal((await apply(laterPrice,laterPricePreview.body.hash)).status,200);
  const priceReimport=await preview(laterPrice);
  assert.equal(priceReimport.body.summary.unchanged,1,
    "same amount and effective timestamp is unchanged, not a duplicate ledger entry");
  const historicalUnchanged=await preview(firstPrice);
  assert.equal(historicalUnchanged.body.summary.unchanged,1,
    "historical exact timestamp is matched, not only most recent price");
  const historicalConflict=await preview(pricing("15555.0000","2026-11-23T00:00:00Z"));
  assert.equal(historicalConflict.body.summary.error,1,
    "a conflicting historical timestamp is rejected during preview");
  const conflict=await preview(pricing("99999.0000","2026-11-24T00:00:00Z"));
  assert.equal(conflict.body.summary.error,1);
  assert.equal(conflict.body.rows[0].error,"PRICE_EFFECTIVE_TIME_CONFLICT");
  const concurrentPreview=await preview(pricing("18000.0000","2026-11-25T00:00:00Z"));
  assert.equal(concurrentPreview.body.summary.update,1);
  const concurrentPrice=await create("prices",{
    priceListId:priceList.body.id,productId,
    amount:"19000.0000",discountRate:"0",
    effectiveAt:"2026-11-26T00:00:00Z"});
  assert.equal(concurrentPrice.status,201,JSON.stringify(concurrentPrice.body));
  const stalePrice=await apply(pricing("18000.0000","2026-11-25T00:00:00Z"),
    concurrentPreview.body.hash);
  assert.equal(stalePrice.status,409,
    "single-price append after preview must conflict before bulk COMMIT");
  assert.equal((await db.query<{n:string}>(
    'SELECT count(*)::text AS n FROM catalog_price_entry '+
    'WHERE installation_id=$1 AND branch_id=$2 AND product_id=$3',
    [root.installationId,branchId,productId])).rows[0]!.n,"3",
    "two bulk versions plus one concurrent single-price version are all preserved");

  // Existing historical PostgreSQL prices can have microsecond precision.
  // The classic catalog single-entry API intentionally canonicalizes new
  // timestamps to milliseconds; verify export NEVER drops stored precision.
  await db.query(`INSERT INTO catalog_price_entry
    (installation_id,branch_id,price_list_id,product_id,amount,
     discount_rate,effective_at)
    VALUES ($1,$2,$3,$4,21000.0000,5.00,$5::timestamptz)`,
    [root.installationId,branchId,priceList.body.id,productId,
      "2026-11-27T00:00:00.123456Z"]);
  const pricesExport=await request("/v1/catalog/bulk/export?branchId="+branchId+
    "&resource=prices","GET",undefined,token);
  assert.equal(pricesExport.status,200,JSON.stringify(pricesExport.body));
  assert.match(pricesExport.body.content,/2026-11-27T00:00:00\.123456Z/,
    "price CSV must preserve all six fractional digits");
  const priceRoundtrip={
    branchId,resource:"prices",mode:"UPSERT",fileName:"export-prices.csv",
    contentBase64:Buffer.from(pricesExport.body.content).toString("base64"),
    hasHeader:true,mapping:{priceListCode:"priceListCode",productCode:"productCode",
      amount:"amount",discountRate:"discountRate",effectiveAt:"effectiveAt"},
  };
  assert.equal((await preview(priceRoundtrip)).body.summary.unchanged,1,
    "reimporting a microsecond timestamp must not append a rounded version");
  const microBatch=pricing("25000.0000","2026-11-28T00:00:00.123456Z");
  const microPreview=await preview(microBatch);
  assert.equal(microPreview.status,200,JSON.stringify(microPreview.body));
  assert.equal(microPreview.body.summary.error,0);
  assert.equal((await apply(microBatch,microPreview.body.hash)).status,200,
    "bulk apply must preserve a newly entered microsecond timestamp");
  assert.equal((await preview(microBatch)).body.summary.unchanged,1,
    "microsecond bulk price reimport must be unchanged");
  const microStored=await db.query<{at:string}>(`
   SELECT to_char(effective_at AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS at
   FROM catalog_price_entry WHERE installation_id=$1 AND branch_id=$2
   AND price_list_id=$3 AND product_id=$4
   AND effective_at='2026-11-28T00:00:00.123456Z'::timestamptz`,
   [root.installationId,branchId,priceList.body.id,productId]);
  assert.equal(microStored.rows[0]?.at,"2026-11-28T00:00:00.123456Z");
  const offsetBatch=pricing("26000.0000","2026-11-29T07:00:00+07:00");
  const offsetPreview=await preview(offsetBatch);
  assert.equal(offsetPreview.status,200);
  assert.equal(offsetPreview.body.summary.error,0);
  assert.equal((await apply(offsetBatch,offsetPreview.body.hash)).status,200,
    "bulk apply must accept timezone offsets approved by preview");
  assert.equal((await preview(offsetBatch)).body.summary.unchanged,1,
    "offset must resolve to the same immutable PostgreSQL instant");


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
  const productSkuCollision=await preview({
   ...productInput,fileName:"occupied-sku-product.csv",
   contentBase64:Buffer.from("Mã SP,Tên SP,ĐVT,Nhóm\n"+
    "SP01-T,Trùng mã SKU bán,CHAI,NONGSAN\n").toString("base64"),
  });
  assert.equal(productSkuCollision.status,200);
  assert.equal(productSkuCollision.body.rows[0].error,
   "PRODUCT_CODE_OCCUPIED_BY_SELL_SKU",
   "a non-base sell SKU, including inactive, reserves the product base code");

  const occupiedSku=await preview(skuFile("SP01-OTHER","1",""));
  assert.equal(occupiedSku.body.summary.error,1,
    "a different code cannot take over an existing product/unit pair");
  assert.equal(occupiedSku.body.rows[0].error,
    "PRODUCT_UNIT_ALREADY_ASSIGNED_TO_SKU");
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
  const enabled=await request("/v1/catalog/r1/skus/"+skuId,"PATCH",
    {branchId,active:true},token,{
      "idempotency-key":"reenable-"+randomUUID(),"if-match":"1",
    });
  assert.equal(enabled.status,200,JSON.stringify(enabled.body));
  assert.equal((await create("unit-definitions",{code:"HOP",name:"Hộp"})).status,201);
  const replacement={
    branchId,resource:"skus",mode:"UPSERT",fileName:"replacement.csv",
    contentBase64:Buffer.from(
      "Mã SKU,Mã SP,Đơn vị,Quy đổi,Trạng thái,Lý do\n"+
      "SP01-T,SP01,THUNG,24.000000,Ngừng,Nhập nhầm mã đóng gói\n"+
      "SP01-H,SP01,HOP,12.000000,1,\n").toString("base64"),
    hasHeader:true,mapping:{code:"Mã SKU",productCode:"Mã SP",
      unitCode:"Đơn vị",toBase:"Quy đổi",active:"Trạng thái",reason:"Lý do"},
  };
  const previewReplace=await preview(replacement);
  assert.equal(previewReplace.body.summary.update,1,JSON.stringify(previewReplace.body));
  assert.equal(previewReplace.body.summary.create,1);
  const appliedReplace=await apply(replacement,previewReplace.body.hash);
  assert.equal(appliedReplace.status,200,JSON.stringify(appliedReplace.body));
  assert.equal((await db.query<{active:boolean}>(
    "SELECT active FROM catalog_product WHERE id=$1",[productId])).rows[0]!.active,true,
    "replacing the last variant must not inadvertently retire its parent");
  assert.equal((await db.query<{n:string}>(`SELECT count(*)::text AS n
    FROM catalog_sell_sku WHERE installation_id=$1 AND branch_id=$2
    AND product_id=$3 AND active`,
    [root.installationId,branchId,productId])).rows[0]!.n,"2",
    "base and replacement pack SKU active; original pack is stopped");
  const makePhoneTransfer=(csv:string)=>file(
   "Mã KH,Tên khách,Mã nhóm,Mã khu vực,Điện thoại,Hạn nợ\n"+csv);
  const phoneSeed=makePhoneTransfer(
   "KH09,Khách I,KH_SI,KV_MT,+84900000021,0\n"+
   "KH10,Khách J,KH_SI,KV_MT,+84900000022,0\n");
  const seedPreview=await preview(phoneSeed);
  assert.equal(seedPreview.body.summary.error,0,JSON.stringify(seedPreview.body));
  assert.equal((await apply(phoneSeed,seedPreview.body.hash)).status,200);
  const phoneSwap=makePhoneTransfer(
   "KH09,Khách I,KH_SI,KV_MT,+84900000022,0\n"+
   "KH10,Khách J,KH_SI,KV_MT,+84900000021,0\n");
  const swapPreview=await preview(phoneSwap);
  assert.equal(swapPreview.body.summary.error,0,JSON.stringify(swapPreview.body));
  const swapApplied=await apply(phoneSwap,swapPreview.body.hash);
  assert.equal(swapApplied.status,200,"active customer phone swap must commit atomically");
  const swapped=(await db.query<{code:string;phone:string}>(
   'SELECT code,phone FROM catalog_customer WHERE installation_id=$1 AND branch_id=$2 '+
   "AND code IN ('KH09','KH10') ORDER BY code",[root.installationId,branchId])).rows;
  assert.deepEqual(swapped.map(x=>x.phone),["+84900000022","+84900000021"]);
  const oneWay=makePhoneTransfer(
   "KH11,Khách K,KH_SI,KV_MT,+84900000022,0\n"+
   "KH09,Khách I,KH_SI,KV_MT,+84900000023,0\n");
  const oneWayPreview=await preview(oneWay);
  assert.equal(oneWayPreview.body.summary.error,0,JSON.stringify(oneWayPreview.body));
  assert.equal((await apply(oneWay,oneWayPreview.body.hash)).status,200,
   "phone recipient can appear before the owner releasing the number");
  const oneWayRows=(await db.query<{code:string;phone:string}>(
   'SELECT code,phone FROM catalog_customer WHERE installation_id=$1 AND branch_id=$2 '+
   "AND code IN ('KH09','KH11') ORDER BY code",[root.installationId,branchId])).rows;
  assert.deepEqual(oneWayRows.map(x=>x.phone),["+84900000023","+84900000022"]);
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
