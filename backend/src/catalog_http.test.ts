import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";
import { resolve } from "node:path";
import { Pool } from "pg";
import { buildApp } from "./server.ts";
import { applyMigrations } from "./migrate.ts";
import { bootstrapInstallation } from "./bootstrap.ts";
import { isDatabaseReady } from "./db.ts";

const dbUrl=process.env.DATABASE_URL;
const ephemeral=(()=>{
  if(!dbUrl)return false;
  try{const u=new URL(dbUrl);return ["localhost","127.0.0.1"].includes(u.hostname)
    &&u.pathname==="/erp_ci";}catch{return false;}
})();

test("Issue #7: catalog HTTP uses real PostgreSQL with tenant/branch RBAC, decimal history, audit and replay",
  {skip:!ephemeral},async()=>{
  const admin=new Pool({connectionString:dbUrl,max:2});
  const dbName="erp_ci_cat_"+randomUUID().replaceAll("-","").slice(0,12);
  let pool:Pool|null=null;
  try{
    await admin.query('CREATE DATABASE "'+dbName+'"');
    const target=new URL(dbUrl!);target.pathname="/"+dbName;
    pool=new Pool({connectionString:target.toString(),max:5,query_timeout:12000});
    pool.on("error",()=>{});
    const applied=await applyMigrations(pool,resolve(process.cwd(),"db/migrations"));
    assert.equal(applied.applied.length,29);
    const ownerPassword="Owner-test-"+randomUUID();
    const root=await bootstrapInstallation(pool,{code:"catalog-ci",displayName:"Catalog Integration CI",
      adminLogin:"root",adminPassword:ownerPassword});
    const app=buildApp(()=>isDatabaseReady(pool!),async()=>true,{
      pool,installationId:root.installationId,
      allowedOrigin:"https://erp.example.test",
      throttleSecret:"test-secret-"+randomUUID(),
    });
    await new Promise<void>(ok=>app.listen(0,"127.0.0.1",ok));
    try{
      const base="http://127.0.0.1:"+(app.address() as AddressInfo).port;
      const call=async(route:string,method="GET",body?:unknown,token?:string,headers:Record<string,string>={})=>{
        const r=await fetch(base+route,{method,headers:{
          origin:"https://erp.example.test",...(body!==undefined?{"content-type":"application/json"}:{}),
          ...(token?{authorization:"Bearer "+token}:{}),...headers,
        },body:body===undefined?undefined:JSON.stringify(body)});
        return {status:r.status,body:await r.json() as Record<string,any>,
          cors:r.headers.get("access-control-allow-origin")};
      };
      const b=root.branchId;
      const create=(kind:string,payload:Record<string,unknown>,key:string,token:string)=>
        call("/v1/catalog/"+kind,"POST",{branchId:b,...payload},token,
          {"idempotency-key":key,"if-match":"0"});
      assert.equal((await call("/v1/catalog/customers?branchId="+b)).status,401,
        "anonymous cannot read catalog");
      const login=await call("/v1/auth/login","POST",{loginName:"root",password:ownerPassword});
      assert.equal(login.status,200);
      const token=login.body.token as string;
      const initial=await call("/v1/catalog/customers?branchId="+b,"GET",undefined,token);
      assert.equal(initial.status,200);
      assert.deepEqual(initial.body.items,[],"real empty table, no synthetic sales");
      assert.equal(initial.cors,"https://erp.example.test");
      assert.equal((await call("/v1/catalog/customers?branchId="+b,"GET",undefined,token,
        {origin:"https://unknown.example"})).status,403);
      const supplier=await create("suppliers",{code:"SUP-01",name:"Synthetic Supplier"},
        "supplier-"+randomUUID(),token);
      assert.equal(supplier.status,201);
      const group=await create("groups",{code:"GRP-01",name:"Synthetic Group"},
        "group-"+randomUUID(),token);
      assert.equal(group.status,201);
      const uom=await create("unit-definitions",{code:"CHAI",name:"Chai"},
        "unit-dictionary-"+randomUUID(),token);
      assert.equal(uom.status,201,JSON.stringify(uom.body));
      assert.equal(uom.body.code,"CHAI");
      const definitions=await call("/v1/catalog/unit-definitions?branchId="+b,
        "GET",undefined,token);
      assert.equal(definitions.status,200);
      assert.equal(definitions.body.items.find((x:{code:string})=>x.code==="CHAI")?.name,
        "Chai","unit code and human-readable label stay separate");
      const duplicate=await create("unit-definitions",{code:"CHAI",name:"Khác"},
        "unit-duplicate-"+randomUUID(),token);
      assert.equal(duplicate.status,409);
      const unitEdit=await call("/v1/catalog/unit-definitions/"+uom.body.id,
        "PATCH",{branchId:b,name:"Chai thủy tinh"},token,{
          "idempotency-key":"unit-edit-"+randomUUID(),"if-match":"0",
        });
      assert.equal(unitEdit.status,200);
      assert.equal(unitEdit.body.revision,1);
      const unitAfter=await call("/v1/catalog/unit-definitions?branchId="+b,
        "GET",undefined,token);
      assert.equal(unitAfter.body.items.find((x:{code:string})=>x.code==="CHAI")?.name,
        "Chai thủy tinh");
      const overlongName=await call("/v1/catalog/unit-definitions/"+uom.body.id,
        "PATCH",{branchId:b,name:"X".repeat(81)},token,{
          "idempotency-key":"unit-invalid-length-"+randomUUID(),"if-match":"1",
        });
      assert.equal(overlongName.status,400,"UOM name over 80 chars is rejected before SQL");
      const unitAfterReject=await call("/v1/catalog/unit-definitions?branchId="+b,
        "GET",undefined,token);
      const stillValid=unitAfterReject.body.items.find((x:{code:string})=>x.code==="CHAI");
      assert.equal(stillValid.name,"Chai thủy tinh");
      assert.equal(stillValid.revision,1);
      // Regression: >100 shared units must all remain selectable by branch.
      await pool.query(`INSERT INTO catalog_unit_definition
        (installation_id,branch_id,code,name)
        SELECT $1,$2,'U'||lpad(n::text,3,'0'),'Unit '||n
        FROM generate_series(1,120) AS n`,[root.installationId,b]);
      const firstPage=await call("/v1/catalog/unit-definitions?branchId="+b,
        "GET",undefined,token);
      assert.equal(firstPage.status,200);
      assert.equal(firstPage.body.items.length,100);
      assert.equal(typeof firstPage.body.nextAfter,"string");
      const secondPage=await call("/v1/catalog/unit-definitions?branchId="+b+
        "&after="+encodeURIComponent(firstPage.body.nextAfter),
        "GET",undefined,token);
      assert.equal(secondPage.status,200);
      assert.equal(secondPage.body.items.length,21);
      const allUnitCodes=[...firstPage.body.items,...secondPage.body.items]
        .map((item:{code:string})=>item.code);
      assert.equal(new Set(allUnitCodes).size,121,
        "each UOM returned exactly once across cursor boundary");
      assert.ok(allUnitCodes.includes("U120"),
        "last unit remains selectable even beyond initial page");
      // Existing UOMs imported from older installations may contain spaces
      // and Unicode; such codes must remain valid keyset cursor values.
      await pool.query(`INSERT INTO catalog_unit_definition
        (installation_id,branch_id,code,name)
        VALUES($1,$2,'Hộp 12','Hộp 12')`,[root.installationId,b]);
      const legacyCursor=await call("/v1/catalog/unit-definitions?branchId="+b+
        "&after="+encodeURIComponent("Hộp 12"),"GET",undefined,token);
      assert.equal(legacyCursor.status,200,
        "legacy Unicode/space UOM codes are valid pagination boundaries");
      assert.equal((await call("/v1/catalog/unit-definitions?branchId="+b+
        "&after="+encodeURIComponent("bad\ncode"),"GET",undefined,token)).status,400);
      const masterGroup=await create("customer-groups",
        {code:"KH_SI",name:"Khách bán sỉ"},"group-"+randomUUID(),token);
      const masterRegion=await create("customer-regions",
        {code:"KV_MT",name:"Khu vực Mỹ Tho"},"region-"+randomUUID(),token);
      assert.equal(masterGroup.status,201,JSON.stringify(masterGroup.body));
      assert.equal(masterRegion.status,201,JSON.stringify(masterRegion.body));
      assert.equal((await create("customers",{
        code:"KH-INVALID-REF",name:"Tham chiếu sai",
        customerRegionId:randomUUID(),
      },"invalid-ref-"+randomUUID(),token)).status,400,
        "customer cannot reference another installation/branch or unknown region");
      assert.equal((await create("customers",{
        code:"KH-TEXT-REF",name:"Không nhập nhóm text",customerGroup:"KH_SI",
      },"invalid-text-"+randomUUID(),token)).status,400,
        "customer group is selected by stable ID, not free text");
      const customerKey="customer-"+randomUUID();
      const customerBody={branchId:b,code:"CUSTOMER-01",name:"Synthetic Customer",
        customerGroupId:masterGroup.body.id,customerRegionId:masterRegion.body.id};
      const customer=await call("/v1/catalog/customers","POST",customerBody,token,
        {"idempotency-key":customerKey,"if-match":"0"});
      assert.equal(customer.status,201,JSON.stringify(customer.body));
      const replay=await Promise.all([call("/v1/catalog/customers","POST",customerBody,token,
        {"idempotency-key":customerKey,"if-match":"0"}),
        call("/v1/catalog/customers","POST",customerBody,token,
          {"idempotency-key":customerKey,"if-match":"0"})]);
      assert.equal(replay[0]!.body.id,customer.body.id);
      assert.equal(replay[1]!.body.id,customer.body.id);
      assert.equal((await call("/v1/catalog/customers","POST",
        {...customerBody,name:"Other Customer"},token,
        {"idempotency-key":customerKey,"if-match":"0"})).status,409);
      assert.equal((await create("customers",{code:"CUSTOMER-01",name:"Duplicate"},
        "duplicate-"+randomUUID(),token)).status,409);
      const customerList=await call("/v1/catalog/customers?branchId="+b+"&q=CUSTOMER-01",
        "GET",undefined,token);
      assert.equal(customerList.body.items.length,1);
      assert.equal(customerList.body.items[0].customerGroupCode,"KH_SI");
      assert.equal(customerList.body.items[0].customerRegionCode,"KV_MT");
      assert.equal(customerList.body.items[0].customerGroupId,masterGroup.body.id);
      const exactCustomer=await call("/v1/catalog/customers?branchId="+b+"&id="+customer.body.id+"&q=not-the-code","GET",undefined,token);
      assert.equal(exactCustomer.status,200);
      assert.deepEqual(exactCustomer.body.items.map((x:{id:string})=>x.id),[customer.body.id]);
      const missingCustomer=await call("/v1/catalog/customers?branchId="+b+"&id="+randomUUID(),"GET",undefined,token);
      assert.deepEqual(missingCustomer.body.items,[]);
      const productPayload={
        code:"SKU-0001",name:"Synthetic Product",groupId:group.body.id,baseUnit:"cai",
        barcode:"BASE-0001",
        units:[{unitCode:"thung",toBase:"12.000000",sku:"SKU-0001-T",barcode:"PACK-0001"},
          {unitCode:"lo",toBase:"6.000000",sku:"SKU-0001-L",barcode:"PACK-0002"}],
      };
      const productKey="product-"+randomUUID();
      const product=await create("products",productPayload,productKey,token);
      assert.equal(product.status,201,JSON.stringify(product.body));
      assert.equal(product.body.variants.length,3,"base and two sell units created atomically");
      const productReplay=await create("products",productPayload,productKey,token);
      assert.deepEqual(productReplay.body,product.body,"same idempotency key never duplicates variants");
      const skus=await call("/v1/catalog/r1/skus?branchId="+b,"GET",undefined,token);
      const productSkus=skus.body.items.filter((x:{productId:string})=>x.productId===product.body.id);
      assert.deepEqual(productSkus.map((x:{code:string})=>x.code).sort(),
        ["SKU-0001","SKU-0001-L","SKU-0001-T"]);
      assert.deepEqual(productSkus.map((x:{barcode:string})=>x.barcode).sort(),
        ["BASE-0001","PACK-0001","PACK-0002"]);
      const broken=await create("products",{
        code:"SKU-FAIL",name:"Should rollback",baseUnit:"cai",
        units:[{unitCode:"thung",toBase:"12.000000",sku:"SKU-FAIL-T",barcode:"PACK-0001"}],
      },"product-fail-"+randomUUID(),token);
      assert.equal(broken.status,409,"barcode already belongs to another sell SKU");
      const absent=await pool.query<{count:string}>(
        "SELECT count(*)::text AS count FROM catalog_product WHERE installation_id=$1 AND sku='SKU-FAIL'",
        [root.installationId]);
      assert.equal(absent.rows[0]?.count,"0","all product, unit and SKU inserts rollback");
      assert.equal((await create("products",{
        code:"SKU-DUP",name:"Invalid multiple units",baseUnit:"cai",
        units:[{unitCode:"thung",toBase:"12.000000",sku:"SKU-DUP-T"},
          {unitCode:"lo",toBase:"6.000000",sku:"SKU-DUP-T"}],
      },"duplicate-sku-"+randomUUID(),token)).status,400);
      assert.equal((await create("products",{
        code:"SKU-BAR",name:"Barcode without SKU",baseUnit:"cai",
        units:[{unitCode:"thung",toBase:"12.000000",barcode:"BAR-0009"}],
      },"barcode-no-sku-"+randomUUID(),token)).status,400);
      const unit=(await pool.query<{to_base:string}>(
        "SELECT to_base::text FROM catalog_unit WHERE installation_id=$1 AND branch_id=$2 AND product_id=$3 AND unit_code='thung'",
        [root.installationId,b,product.body.id])).rows[0]!.to_base;
      assert.equal(unit,"12.000000");
      assert.equal((await call("/v1/catalog/products?branchId="+b,
        "GET",undefined,token)).body.items[0].code,"SKU-0001");
      // A read request already holds one pool client. Requesting another
      // client to check R1 readiness deadlocks a saturated five-client pool.
      const parallel=await Promise.all(Array.from({length:8},()=>call(
        "/v1/catalog/products?branchId="+b,"GET",undefined,token)));
      for(const result of parallel){
        assert.equal(result.status,200,JSON.stringify(result.body));
        assert.equal(result.body.r1ProductReady,true,
          "concurrent catalog reads must not falsely hide product creation");
      }
      assert.equal((await create("products",{code:"SKU-BAD",name:"Bad",baseUnit:"cai",
        units:[{unitCode:"thung",toBase:1.5}]},
        "bad-unit-"+randomUUID(),token)).status,400,"float UOM forbidden");
      // The selector searches the server beyond its first 100 rows; large
      // assignments are one transaction, preserve unseen customers, and roll
      // back every row when any target conflicts.
      const many=(await pool.query<{id:string}>(`INSERT INTO catalog_customer(installation_id,branch_id,code,name)
        SELECT $1,$2,'UAT-KH-'||lpad(n::text,4,'0'),'UAT customer '||n
        FROM generate_series(1,1001) n RETURNING id`,[root.installationId,b])).rows.map(x=>x.id);
      const big=await create("price-lists",{code:"UAT-BIG",name:"Bảng giá nhiều khách",
        priority:8765,customerIds:many.slice(0,1000)},
        "price-list-big-"+randomUUID(),token);
      assert.equal(big.status,201,JSON.stringify(big.body));
      const bigPath="/v1/catalog/price-lists/assignments?branchId="+b+"&priceListId="+big.body.id;
      const bigFirstPage=await call(bigPath,"GET",undefined,token);
      assert.equal(bigFirstPage.body.items.length,100);
      assert.equal(bigFirstPage.body.hasMore,true);
      assert.ok(bigFirstPage.body.items.every((x:any)=>typeof x.customerName==="string"));
      const searchPage=await call("/v1/catalog/customers?branchId="+b+"&q=UAT-KH-1001","GET",undefined,token);
      assert.equal(searchPage.body.items.length,1);
      assert.equal(searchPage.body.items[0].id,many[1000]);
      const changed=[...many.slice(1,1000),many[1000]!];
      const changeBig=await call("/v1/catalog/price-lists/"+big.body.id,"PATCH",
        {branchId:b,customerIds:changed},token,{"if-match":"0","idempotency-key":"big-edit-"+randomUUID()});
      assert.equal(changeBig.status,200,JSON.stringify(changeBig.body));
      const count=await pool.query<{n:number}>(`SELECT count(*)::integer n FROM catalog_price_list_assignment
       WHERE installation_id=$1 AND branch_id=$2 AND price_list_id=$3 AND active`,[root.installationId,b,big.body.id]);
      assert.equal(count.rows[0]!.n,1000);
      const conflict=await create("price-lists",{code:"UAT-CONFLICT",name:"Conflict",
        priority:8765,customerIds:[many[0],many[1000]]},"big-conflict-"+randomUUID(),token);
      assert.equal(conflict.status,409,JSON.stringify(conflict.body));
      assert.equal((await pool.query("SELECT 1 FROM catalog_price_list WHERE installation_id=$1 AND branch_id=$2 AND code='UAT-CONFLICT'",[root.installationId,b])).rowCount,0);
      const priceList=await create("price-lists",{code:"RETAIL",name:"Giá bán lẻ"},
        "price-list-"+randomUUID(),token);
      assert.equal(priceList.status,201);
      const priceInput={priceListId:priceList.body.id,productId:product.body.id,
        amount:"12345.6789",discountRate:"12.50",effectiveAt:"2026-01-01T00:00:00.123456Z"};
      const price=await create("prices",priceInput,"price-"+randomUUID(),token);
      assert.equal(price.status,201,JSON.stringify(price.body));
      assert.equal(price.body.amount,"12345.6789");
      assert.equal(price.body.discountRate,"12.50");
      assert.equal(price.body.effectiveAt,"2026-01-01T00:00:00.123Z",
        "server normalizes microsecond Dart timestamp to millisecond precision");
      const priceNext=await create("prices",{...priceInput,amount:"13000.0000",
        effectiveAt:"2026-02-01T00:00:00Z"},"price-next-"+randomUUID(),token);
      assert.equal(priceNext.status,201);
      const quotePath="/v1/catalog/prices/quote?branchId="+b+
        "&priceListId="+priceList.body.id+"&productId="+product.body.id;
      const quote=await call(quotePath,"GET",undefined,token);
      assert.equal(quote.status,200);
      assert.equal(quote.body.quote.priceEntryId,priceNext.body.id);
      assert.equal(quote.body.quote.amount,"13000.0000");
      assert.equal(quote.body.stockStatus,"NOT_VERIFIED");
      assert.equal(quote.body.confirmationAllowed,false,
        "price checks never authorize stock or order posting");
      const priceCheck=(id:string)=>call("/v1/catalog/prices/check","POST",{
        branchId:b,priceListId:priceList.body.id,productId:product.body.id,
        expectedPriceEntryId:id,
      },token);
      assert.equal((await priceCheck(price.body.id)).status,409,
        "replaced historical price must fail stale check");
      assert.equal((await priceCheck(priceNext.body.id)).status,200);
      const update=(kind:string,id:string,rev:number,fields:Record<string,unknown>,key:string)=>
        call("/v1/catalog/"+kind+"/"+id,"PATCH",
          {branchId:b,...fields},token,{"idempotency-key":key,"if-match":String(rev)});
      const customerUpdateKey="update-customer-"+randomUUID();
      const cUpdate=await update("customers",customer.body.id,0,
        {name:"Đổi tên khách hàng",active:false},customerUpdateKey);
      assert.equal(cUpdate.status,200,JSON.stringify(cUpdate.body));
      assert.equal(cUpdate.body.revision,1);
      const repeated=await update("customers",customer.body.id,0,
        {name:"Đổi tên khách hàng",active:false},customerUpdateKey);
      assert.equal(repeated.status,200);
      assert.deepEqual(repeated.body,cUpdate.body,"idempotent PATCH returns same response");
      assert.equal((await update("customers",customer.body.id,0,
        {name:"Stale change"},"stale-"+randomUUID())).status,409,
        "stale revision rejects lost update");
      assert.equal((await update("customers",customer.body.id,1,
        {code:"CHANGED"},"immutable-code-"+randomUUID())).status,400,
        "canonical code immutable");
      assert.equal((await call("/v1/catalog/customers?branchId="+b+"&id="+customer.body.id,"GET",undefined,token))
        .body.items[0].active,false);
      const productUpdate=await update("products",product.body.id,0,
        {name:"Renamed Product"},"product-update-"+randomUUID());
      assert.equal(productUpdate.status,200);
      assert.equal(productUpdate.body.revision,1);
      const groupUpdate=await update("groups",group.body.id,0,
        {name:"Nhóm cập nhật"},"group-update-"+randomUUID());
      assert.equal(groupUpdate.status,200);
      assert.equal(groupUpdate.body.revision,1);
      const supplierUpdate=await update("suppliers",supplier.body.id,0,
        {active:false},"supplier-update-"+randomUUID());
      assert.equal(supplierUpdate.status,200);
      const disableList=await update("price-lists",priceList.body.id,0,
        {active:false},"list-disable-"+randomUUID());
      assert.equal(disableList.status,200);
      assert.equal((await call(quotePath,"GET",undefined,token)).body.quote,null,
        "inactive price list cannot provide a current sell price");
      const enableList=await update("price-lists",priceList.body.id,1,
        {active:true},"list-enable-"+randomUUID());
      assert.equal(enableList.status,200);
      assert.equal((await priceCheck(priceNext.body.id)).status,200);
      const allPrices=await call("/v1/catalog/prices?branchId="+b,"GET",undefined,token);
      assert.equal(allPrices.status,200);
      assert.equal(allPrices.body.items.length,2);
      assert.equal(allPrices.body.items[0].amount,"13000.0000");
      assert.equal((await create("prices",{...priceInput,amount:12345.6789},
        "float-price-"+randomUUID(),token)).status,400);
      await assert.rejects(pool.query(
        "UPDATE catalog_price_entry SET amount=1 WHERE installation_id=$1 AND id=$2",
        [root.installationId,price.body.id]),/append-only/);
      const warehouses=await call("/v1/catalog/warehouses?branchId="+b,"GET",undefined,token);
      assert.equal(warehouses.status,200);
      assert.equal(warehouses.body.items.length,1);
      assert.equal(warehouses.body.items[0].id,root.warehouseId);
      const otherBranch=(await pool.query<{id:string}>(
        "INSERT INTO branch(installation_id,code,name) VALUES($1,'OTHER','Other Branch') RETURNING id",
        [root.installationId])).rows[0]!.id;
      assert.equal((await call("/v1/catalog/products?branchId="+otherBranch,
        "GET",undefined,token)).status,403,"main branch grant does not expand");
      assert.equal((await call("/v1/catalog/customers/"+customer.body.id,"PATCH",
        {branchId:otherBranch,name:"Out of scope"},token,
        {"idempotency-key":"scope-"+randomUUID(),"if-match":"1"})).status,403);

      assert.equal((await call("/v1/catalog/products?branchId="+randomUUID(),
        "GET",undefined,token)).status,403);
      const noGrant=(await pool.query<{id:string}>(
        "INSERT INTO app_user(installation_id,login_name,password_hash) VALUES($1,'bare_user',$2) RETURNING id",
        [root.installationId,"x".repeat(64)])).rows[0]!.id;
      assert.ok(noGrant);
      const otherTenant=(await pool.query<{id:string}>(
        "INSERT INTO installation(code,display_name) VALUES($1,'Other Tenant') RETURNING id",
        ["other-"+randomUUID().slice(0,8)])).rows[0]!.id;
      assert.equal((await pool.query(
        "SELECT count(*)::integer AS total FROM catalog_customer WHERE installation_id=$1",
        [otherTenant])).rows[0]!.total,0);
      const audit=await pool.query<{total:string}>(
        "SELECT count(*)::text AS total FROM audit_event WHERE installation_id=$1 AND action_code LIKE 'catalog.%'",
        [root.installationId]);
      assert.equal(audit.rows[0]!.total,"19",
        "11 creations and 8 distinct PATCH mutations audited once, including the large assignment transaction; replay not double counted");
    }finally{await new Promise<void>((ok,fail)=>app.close(e=>e?fail(e):ok()));}
  }finally{
    if(pool)await pool.end();
    await admin.query('DROP DATABASE IF EXISTS "'+dbName+'"');
    await admin.end();
  }
});
