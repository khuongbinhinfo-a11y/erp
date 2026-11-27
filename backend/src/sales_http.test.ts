import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";
import { resolve } from "node:path";
import { Pool } from "pg";
import { applyMigrations } from "./migrate.ts";
import { buildApp } from "./server.ts";
import { bootstrapInstallation } from "./bootstrap.ts";
import { isDatabaseReady } from "./db.ts";

const source=process.env.DATABASE_URL;
const ephemeral=(()=>{
  try{
    const u=new URL(source??"");
    return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";
  }catch{return false;}
})();

test("B1: real PostgreSQL order lifecycle, immutable versions, RBAC, replay and exact prices",
  {skip:!ephemeral},async()=>{
  const admin=new Pool({connectionString:source,max:2});
  const dbName="erp_ci_sales_"+randomUUID().replaceAll("-","").slice(0,12);
  let pool:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
  try{
    await admin.query('CREATE DATABASE "'+dbName+'"');
    const u=new URL(source!);u.pathname="/"+dbName;
    pool=new Pool({connectionString:u.toString(),max:8,query_timeout:12000});
    pool.on("error",()=>{});
    const installed=await applyMigrations(pool,resolve(process.cwd(),"db/migrations"));
    assert.equal(installed.applied.length,26);
    assert.equal((await applyMigrations(pool,resolve(process.cwd(),"db/migrations"))).skipped.length,26);
    const password="Sales-Testing-"+randomUUID();
    const root=await bootstrapInstallation(pool,{
      code:"sales-test",displayName:"Order integration test",
      adminLogin:"owner",adminPassword:password,
    });
    server=buildApp(()=>isDatabaseReady(pool!),async()=>true,{
      pool,installationId:root.installationId,allowedOrigin:"https://erp.example.test",
      throttleSecret:"test-"+randomUUID(),
    });
    await new Promise<void>(ok=>server!.listen(0,"127.0.0.1",ok));
    const base="http://127.0.0.1:"+(server.address() as AddressInfo).port;
    const call=async(path:string,method="GET",body?:unknown,token?:string,extra:Record<string,string>={})=>{
      const r=await fetch(base+path,{method,headers:{
        origin:"https://erp.example.test",
        ...(body===undefined?{}:{"content-type":"application/json"}),
        ...(token?{authorization:"Bearer "+token}:{}),...extra,
      },body:body===undefined?undefined:JSON.stringify(body)});
      return {status:r.status,
        body:r.status===204?{}:await r.json() as Record<string,any>,
        origin:r.headers.get("access-control-allow-origin")};
    };
    const b=root.branchId;
    const login=await call("/v1/auth/login","POST",{loginName:"owner",password});
    assert.equal(login.status,200,JSON.stringify(login.body));
    const token=login.body.token as string;
    assert.equal((await call("/v1/sales/orders?branchId="+b)).status,401);
    assert.equal((await call("/v1/sales/orders?branchId="+b,"GET",undefined,token,
      {origin:"https://untrusted.invalid"})).status,403);
    const catalog=(resource:string,fields:Record<string,unknown>)=>call(
      "/v1/catalog/"+resource,"POST",{branchId:b,...fields},token,
      {"idempotency-key":"catalog-"+randomUUID(),"if-match":"0"});
    const customer=await catalog("customers",{code:"C-001",name:"Khách thử nghiệm"});
    assert.equal(customer.status,201,JSON.stringify(customer.body));
    const product=await catalog("products",{code:"P-001",name:"Sản phẩm thử",baseUnit:"cai"});
    assert.equal(product.status,201,JSON.stringify(product.body));
    const list=await catalog("price-lists",{code:"MAIN",name:"Giá bán"});
    assert.equal(list.status,201,JSON.stringify(list.body));
    const price=await catalog("prices",{
      priceListId:list.body.id,productId:product.body.id,
      amount:"12345.0000",discountRate:"10.00",effectiveAt:"2026-01-01T00:00:00Z",
    });
    assert.equal(price.status,201,JSON.stringify(price.body));
    // R2: whole-basket quote is one scoped, exact NUMERIC server operation.
    // A new product automatically exposes its canonical base sell SKU.
    const skus=await call("/v1/catalog/r1/skus?branchId="+b+"&q=P-001",
      "GET",undefined,token);
    assert.equal(skus.status,200,JSON.stringify(skus.body));
    const sellSkuId=skus.body.items[0]?.id as string;
    assert.ok(sellSkuId,"A new product must expose its canonical base SKU");
    const r2QuotePayload={branchId:b,customerId:customer.body.id,
      priceListId:list.body.id,lines:[{sellSkuId,quantity:"2"}]};
    assert.equal((await call("/v1/sales/quote","POST",r2QuotePayload)).status,401);
    const r2Quote=await call("/v1/sales/quote","POST",r2QuotePayload,token);
    assert.equal(r2Quote.status,200,JSON.stringify(r2Quote.body));
    assert.equal(r2Quote.body.quote.lines.length,1);
    assert.equal(r2Quote.body.quote.lines[0].sellSkuId,sellSkuId);
    assert.match(r2Quote.body.quote.lines[0].priceSignature,/^[a-f0-9]{64}$/);
    assert.equal(r2Quote.body.quote.grandTotal,r2Quote.body.quote.lines[0].lineTotal);
    assert.equal(r2Quote.body.quote.subtotal,r2Quote.body.quote.grandTotal);
    assert.equal(r2Quote.body.quote.taxTotal,"0");
    assert.equal(r2Quote.body.quote.taxPolicy,"NOT_CONFIGURED");
    const duplicate=await call("/v1/sales/quote","POST",{
      ...r2QuotePayload,lines:[...r2QuotePayload.lines,...r2QuotePayload.lines],
    },token);
    assert.equal(duplicate.status,200);
    assert.equal(duplicate.body.quote.lines.length,2,"same SKU can be split into two commercial lines");
    assert.equal((await call("/v1/sales/quote","POST",{
      ...r2QuotePayload,lines:[{sellSkuId,quantity:2}],
    },token)).status,400);
    const payload={branchId:b,customerId:customer.body.id,priceListId:list.body.id,
      note:"Giao tại quầy",lines:[{productId:product.body.id,quantity:"2.000"}]};
    const write=(path:string,data:unknown,rev:number,key:string,method="POST")=>
      call(path,method,data,token,{"idempotency-key":key,"if-match":String(rev)});
    assert.equal((await write("/v1/sales/orders",{...payload,lines:[]},0,"invalid-"+randomUUID())).status,400);
    assert.equal((await write("/v1/sales/orders",{...payload,
      lines:[{productId:product.body.id,quantity:2}]},0,"float-"+randomUUID())).status,400);
    const createKey="create-"+randomUUID();
    const made=await write("/v1/sales/orders",payload,0,createKey);
    assert.equal(made.status,201,JSON.stringify(made.body));
    assert.equal(made.body.documentNo,null);
    assert.equal(made.body.total,"22221");
    const id=made.body.id as string;
    const repeated=await Promise.all([
      write("/v1/sales/orders",payload,0,createKey),
      write("/v1/sales/orders",payload,0,createKey),
    ]);
    assert.equal(repeated[0]!.status,201);
    assert.deepEqual(repeated[0]!.body,made.body);
    assert.deepEqual(repeated[1]!.body,made.body);
    assert.equal((await write("/v1/sales/orders",{...payload,note:"different"},0,createKey)).status,409);
    const listRead=await call("/v1/sales/orders?branchId="+b,"GET",undefined,token);
    assert.equal(listRead.status,200);
    assert.equal(listRead.body.items.length,1);
    assert.equal(listRead.origin,"https://erp.example.test");

    const newPrice=await catalog("prices",{
      priceListId:list.body.id,productId:product.body.id,
      amount:"12000.0000",discountRate:"10.00",effectiveAt:"2026-02-01T00:00:00Z",
    });
    assert.equal(newPrice.status,201,JSON.stringify(newPrice.body));
    assert.equal((await write("/v1/sales/orders/"+id+"/confirm",{branchId:b},0,
      "stale-"+randomUUID())).status,409);
    const editKey="edit-"+randomUUID();
    const edited=await write("/v1/sales/orders/"+id,payload,0,editKey,"PATCH");
    assert.equal(edited.status,200,JSON.stringify(edited.body));
    assert.equal(edited.body.total,"21600");
    assert.equal(edited.body.revision,1);
    assert.equal((await write("/v1/sales/orders/"+id,payload,0,
      "old-"+randomUUID(),"PATCH")).status,409);
    assert.deepEqual((await write("/v1/sales/orders/"+id,payload,0,editKey,"PATCH")).body,edited.body);

    const keyA="confirmA-"+randomUUID(),keyB="confirmB-"+randomUUID();
    const pair=await Promise.all([
      write("/v1/sales/orders/"+id+"/confirm",{branchId:b},1,keyA),
      write("/v1/sales/orders/"+id+"/confirm",{branchId:b},1,keyB),
    ]);
    assert.deepEqual(pair.map(x=>x.status).sort(),[200,409]);
    const approved=pair.find(x=>x.status===200)!;
    assert.match(approved.body.documentNo,/^SO-\d{8}-\d{6}$/);
    assert.equal(approved.body.fulfillmentStatus,"NOT_ALLOCATED");
    assert.equal(approved.body.deliveryStatus,"NOT_DISPATCHED");
    assert.equal(approved.body.paymentStatus,"NOT_DUE");
    const winningKey=pair[0]!.status===200?keyA:keyB;
    const replay=await write("/v1/sales/orders/"+id+"/confirm",{branchId:b},1,winningKey);
    assert.equal(replay.status,200);
    assert.deepEqual(replay.body,approved.body);
    const detail=await call("/v1/sales/orders/"+id+"?branchId="+b,"GET",undefined,token);
    assert.equal(detail.status,200);
    assert.equal(detail.body.order.total,"21600");
    assert.equal(detail.body.order.lines[0].unitPrice,"12000.0000");
    assert.equal(detail.body.order.history.length,1);
    await assert.rejects(pool.query(
      "UPDATE sales_order_line SET quantity=99 WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3",
      [root.installationId,b,id]),/immutable/i);

    // A confirmed commercial snapshot must also reject an INSERT that
    // appends a new line after posting. Prior guard covered UPDATE/DELETE only.
    await assert.rejects(pool.query(
      `INSERT INTO sales_order_line
       (installation_id,branch_id,order_id,version_no,line_no,product_id,price_entry_id,
        sku,product_name,unit_code,quantity,unit_price,discount_rate,tax_rate,subtotal,
        discount_amount,tax_amount,line_total)
       SELECT installation_id,branch_id,order_id,version_no,line_no+10,product_id,
         price_entry_id,sku,product_name,unit_code,quantity,unit_price,discount_rate,
         tax_rate,subtotal,discount_amount,tax_amount,line_total
       FROM sales_order_line WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=1`,
      [root.installationId,b,id]),/immutable/i);

    const amend=await write("/v1/sales/orders/"+id+"/amend",
      {branchId:b,reason:"Điều chỉnh số lượng"},2,"amend-"+randomUUID());
    assert.equal(amend.status,201,JSON.stringify(amend.body));
    assert.equal(amend.body.version,2);
    await assert.rejects(pool.query(
      "UPDATE sales_order_line SET version_no=1 WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=2",
      [root.installationId,b,id]),/immutable/i,
      "a pending amendment may not be moved into a confirmed version");
    const updated=await write("/v1/sales/orders/"+id,{
      ...payload,lines:[{productId:product.body.id,quantity:"3"}]},3,
      "edit2-"+randomUUID(),"PATCH");
    assert.equal(updated.status,200,JSON.stringify(updated.body));
    assert.equal(updated.body.total,"32400");
    const reconfirm=await write("/v1/sales/orders/"+id+"/confirm",{branchId:b},4,
      "confirm2-"+randomUUID());
    assert.equal(reconfirm.status,200,JSON.stringify(reconfirm.body));
    assert.equal(reconfirm.body.documentNo,approved.body.documentNo);
    const details=await call("/v1/sales/orders/"+id+"?branchId="+b,"GET",undefined,token);
    assert.deepEqual(details.body.order.history.map((v:any)=>v.version),[2,1]);
    const cancelled=await write("/v1/sales/orders/"+id+"/cancel",
      {branchId:b,reason:"Khách thay đổi kế hoạch"},5,"cancel-"+randomUUID());
    assert.equal(cancelled.status,200,JSON.stringify(cancelled.body));
    assert.equal((await write("/v1/sales/orders/"+id+"/confirm",{branchId:b},6,
      "post-cancel-"+randomUUID())).status,409);
    const other=await pool.query<{id:string}>(
      "INSERT INTO branch(installation_id,code,name) VALUES($1,'OTHER','Chi nhánh khác') RETURNING id",
      [root.installationId]);
    const branch2=other.rows[0]!.id;
    assert.equal((await call("/v1/sales/orders?branchId="+branch2,"GET",undefined,token)).status,403);
    assert.equal((await write("/v1/sales/orders",{...payload,branchId:branch2},0,
      "cross-"+randomUUID())).status,403);
    const orderCount=await pool.query<{count:string}>(
      "SELECT count(*)::text AS count FROM sales_order WHERE installation_id=$1",
      [root.installationId]);
    assert.equal(orderCount.rows[0]?.count,"1");
    const facts=await pool.query<{count:string}>(
      "SELECT count(*)::text AS count FROM information_schema.tables WHERE table_schema='public'"+
      " AND table_name IN ('receivable_ledger','delivery_order','payment_ledger')");
    assert.equal(facts.rows[0]?.count,"0");
    // Sales confirmation alone never posts a movement; R3 owns inventory facts.
    const stockFacts=await pool.query<{count:string}>(
      "SELECT count(*)::text AS count FROM inventory_ledger WHERE installation_id=$1",
      [root.installationId]);
    assert.equal(stockFacts.rows[0]?.count,"0");
    const audit=await pool.query<{count:string}>(
      "SELECT count(*)::text AS count FROM audit_event WHERE installation_id=$1 AND action_code LIKE 'sales.order.%'",
      [root.installationId]);
    assert.equal(audit.rows[0]?.count,"7");
    // T1: scoped commercial delivery context is an immutable version snapshot.
    const settings=await call("/v1/sales/entry-settings?branchId="+b,"GET",undefined,token);
    assert.equal(settings.status,200,JSON.stringify(settings.body));
    assert.equal(settings.body.settings.deliveryChoice,null);
    const shipping={warehouseId:root.warehouseId,deliveryChoice:"MANUAL",
      collectionPolicy:"CREDIT_TERMS",customerMode:"EXISTING",
      deliveryAddress:"Địa chỉ kiểm thử",requestedDeliveryDate:"2026-12-01",
      rememberDeliveryChoice:true};
    const t1Payload={...payload,shipping};
    const t1Key="t1-create-"+randomUUID();
    const t1=await write("/v1/sales/orders",t1Payload,0,t1Key);
    assert.equal(t1.status,201,JSON.stringify(t1.body));
    assert.deepEqual((await write("/v1/sales/orders",t1Payload,0,t1Key)).body,t1.body);
    const t1id=t1.body.id;
    const readT1=()=>call("/v1/sales/orders/"+t1id+"?branchId="+b,"GET",undefined,token);
    const t1Detail=await readT1();
    assert.equal(t1Detail.body.order.shipping.warehouseId,root.warehouseId);
    assert.equal(t1Detail.body.order.shipping.deliveryChoice,"MANUAL");
    assert.equal(t1Detail.body.order.shipping.requestedDeliveryDate,"2026-12-01");
    assert.equal(t1Detail.body.order.shipping.deliveryAddress,"Địa chỉ kiểm thử");
    assert.equal((await call("/v1/sales/entry-settings?branchId="+b,"GET",undefined,token)).body.settings.deliveryChoice,"MANUAL");
    assert.equal((await write("/v1/sales/orders",{...t1Payload,
      shipping:{...shipping,warehouseId:randomUUID()}},0,"t1-badwarehouse-"+randomUUID())).status,403);
    assert.equal((await write("/v1/sales/orders",{...t1Payload,
      shipping:{...shipping,requestedDeliveryDate:"2026-02-30"}},0,"t1-baddate-"+randomUUID())).status,400);
    assert.equal((await write("/v1/sales/orders/"+t1id+"/confirm",{branchId:b},0,"t1-confirm-"+randomUUID())).status,200);
    assert.equal((await readT1()).body.order.paymentStatus,"NOT_DUE");
    // T3-A: MANUAL is a direct-issue lane, never a trip stock hold.
    const reserveInput={branchId:b,warehouseId:root.warehouseId,
      orderId:t1id,version:1,lineNo:1};
    const manualHold=await write("/v1/inventory/reservations",reserveInput,0,
      "t3a-manual-reserve-"+randomUUID());
    assert.equal(manualHold.status,409,JSON.stringify(manualHold.body));
    assert.equal(manualHold.body.error.code,"ORDER_DIRECT_ISSUE_ONLY");
    assert.equal((await pool.query(
      "SELECT count(*)::integer AS n FROM inventory_reservation WHERE installation_id=$1 AND order_id=$2",
      [root.installationId,t1id])).rows[0]!.n,0);
    const tripInput={...t1Payload,shipping:{...shipping,deliveryChoice:"TRIP",
      rememberDeliveryChoice:false}};
    const tripOrder=await write("/v1/sales/orders",tripInput,0,
      "t3a-trip-create-"+randomUUID());
    assert.equal(tripOrder.status,201,JSON.stringify(tripOrder.body));
    const tripConfirm=await write("/v1/sales/orders/"+tripOrder.body.id+"/confirm",
      {branchId:b},0,"t3a-trip-confirm-"+randomUUID());
    assert.equal(tripConfirm.status,200,JSON.stringify(tripConfirm.body));
    const tripHold=await write("/v1/inventory/reservations",
      {...reserveInput,orderId:tripOrder.body.id},0,"t3a-trip-reserve-"+randomUUID());
    assert.equal(tripHold.status,201,JSON.stringify(tripHold.body));
    assert.equal(tripHold.body.quantityBase,"0.000000");
    assert.equal(tripHold.body.backorderedBase,"2.000000");
    const tripDetail=await call("/v1/sales/orders/"+tripOrder.body.id+
      "?branchId="+b,"GET",undefined,token);
    assert.equal(tripDetail.body.order.shipping.deliveryChoice,"TRIP");
    await assert.rejects(pool.query("UPDATE sales_order_version_context SET delivery_choice='TRIP' WHERE installation_id=$1 AND order_id=$2",
      [root.installationId,t1id]),/immutable/i);
    const t1Amend=await write("/v1/sales/orders/"+t1id+"/amend",{branchId:b,reason:"Sửa giao hàng"},1,"t1-amend-"+randomUUID());
    assert.equal(t1Amend.status,201,JSON.stringify(t1Amend.body));
    assert.equal((await readT1()).body.order.shipping.deliveryChoice,"MANUAL");
    // Mode can change only by creating and editing a new draft version.
    const changedLane=await write("/v1/sales/orders/"+t1id,{
      ...t1Payload,shipping:{...shipping,deliveryChoice:"TRIP",
        rememberDeliveryChoice:false}},2,"t3a-mode-edit-"+randomUUID(),"PATCH");
    assert.equal(changedLane.status,200,JSON.stringify(changedLane.body));
    assert.equal((await readT1()).body.order.shipping.deliveryChoice,"TRIP");
    const changedConfirm=await write("/v1/sales/orders/"+t1id+"/confirm",
      {branchId:b},3,"t3a-mode-confirm-"+randomUUID());
    assert.equal(changedConfirm.status,200,JSON.stringify(changedConfirm.body));
    assert.equal((await readT1()).body.order.shipping.deliveryChoice,"TRIP");
    await assert.rejects(pool.query(
      "UPDATE sales_order_version_context SET delivery_choice='MANUAL' WHERE installation_id=$1 AND order_id=$2 AND version_no=2",
      [root.installationId,t1id]),/immutable/i);
    const walk=await Promise.all([1,2].map(()=>write("/v1/sales/walk-in",{branchId:b},0,"t1-walk-"+randomUUID())));
    assert.equal(walk[0]!.status,200,JSON.stringify(walk[0]!.body));
    assert.equal(walk[1]!.status,200,JSON.stringify(walk[1]!.body));
    const walkId=walk[0]!.body.customer.id;
    assert.equal(walk[1]!.body.customer.id,walkId);
    const customerList=await call("/v1/catalog/customers?branchId="+b,"GET",undefined,token);
    assert.ok(!customerList.body.items.some((x:any)=>x.id===walkId));
    const walkPayload={...payload,customerId:walkId,shipping:{warehouseId:root.warehouseId,
      customerMode:"WALK_IN",deliveryChoice:"PICKUP",collectionPolicy:"COLLECT_ON_DELIVERY",walkInName:"Khách thử"}};
    assert.equal((await write("/v1/sales/orders",{...walkPayload,
      shipping:{...walkPayload.shipping,collectionPolicy:"CREDIT_TERMS"}},0,"t1-walk-credit-"+randomUUID())).status,400);
    const walkOrder=await write("/v1/sales/orders",walkPayload,0,"t1-walk-order-"+randomUUID());
    assert.equal(walkOrder.status,201,JSON.stringify(walkOrder.body));
    const walkDetail=await call("/v1/sales/orders/"+walkOrder.body.id+"?branchId="+b,"GET",undefined,token);
    assert.equal(walkDetail.body.order.shipping.customerMode,"WALK_IN");
    assert.equal(walkDetail.body.order.shipping.paymentTermsDays,0);
    assert.equal(walkDetail.body.order.paymentStatus,"NOT_DUE");
    assert.equal((await call("/v1/sales/last-purchase?branchId="+b+"&customerId="+walkId+"&sellSkuId="+sellSkuId,"GET",undefined,token)).body.price,null);
    assert.equal((await write("/v1/sales/orders/"+walkOrder.body.id+"/confirm",{branchId:b},0,"t1-walk-confirm-"+randomUUID())).status,200);
    const pickupHold=await write("/v1/inventory/reservations",
      {...reserveInput,orderId:walkOrder.body.id},0,"t3a-pickup-hold-"+randomUUID());
    assert.equal(pickupHold.status,409,JSON.stringify(pickupHold.body));
    assert.equal(pickupHold.body.error.code,"ORDER_DIRECT_ISSUE_ONLY");
    assert.equal((await call("/v1/sales/last-purchase?branchId="+b+"&customerId="+walkId+"&sellSkuId="+sellSkuId,"GET",undefined,token)).body.price,null);
    assert.equal((await call("/v1/sales/entry-settings?branchId="+b,"GET",undefined,token)).body.settings.deliveryChoice,"MANUAL");
    // T1 document discount uses the same server quote and save allocation;
    // all money is integer VND, including rounding residuals.
    const docDiscount={mode:"TOTAL_AMOUNT",value:"1001",reason:"Ưu đãi toàn đơn"};
    const docQuoteInput={...r2QuotePayload,lines:[
      {sellSkuId,quantity:"1",unitPrice:"10000",discountRate:"0",taxRate:"10"},
      {sellSkuId,quantity:"2",unitPrice:"10000",discountRate:"0",taxRate:"10"}],
      documentDiscount:docDiscount};
    const docQuote=await call("/v1/sales/quote","POST",docQuoteInput,token);
    assert.equal(docQuote.status,200,JSON.stringify(docQuote.body));
    assert.equal(docQuote.body.quote.discountTotal,"1001");
    assert.equal(docQuote.body.quote.grandTotal,"31899");
    assert.deepEqual(docQuote.body.quote.lines.map((x:any)=>x.discountAmount),["334","667"]);
    const docPayload={...docQuoteInput,shipping:{warehouseId:root.warehouseId,deliveryChoice:"PICKUP",
      customerMode:"EXISTING",collectionPolicy:"PREPAID"},note:"",
      lines:docQuoteInput.lines.map((l,i)=>({...l,overrideReason:"Giá được duyệt",
        expectedPriceSignature:docQuote.body.quote.lines[i].priceSignature}))};
    const docOrder=await write("/v1/sales/orders",docPayload,0,"t1-discount-"+randomUUID());
    assert.equal(docOrder.status,201,JSON.stringify(docOrder.body));
    assert.equal(docOrder.body.total,"31899");
    const docDetail=await call("/v1/sales/orders/"+docOrder.body.id+"?branchId="+b,"GET",undefined,token);
    assert.equal(docDetail.body.order.lines[0].priceSnapshot.documentDiscount.allocatedAmount,"334");
    assert.equal(docDetail.body.order.lines[0].priceSnapshot.overrideReason,"Giá được duyệt");
    assert.equal((await write("/v1/sales/orders/"+docOrder.body.id+"/confirm",{branchId:b},0,"t1-doc-confirm-"+randomUUID())).status,200);
    assert.equal((await call("/v1/sales/quote","POST",{...docQuoteInput,
      lines:[{...docQuoteInput.lines[0],discountRate:"10"}]},token)).status,400);
    assert.equal((await write("/v1/sales/orders",{...docPayload,documentDiscount:{...docDiscount,reason:""}},0,"t1-doc-reason-"+randomUUID())).status,400);
    // T1 legacy commercial modes: no price override required to apply a line discount.
    const quoteMode=async(line:Record<string,unknown>)=>call("/v1/sales/quote","POST",
      {...r2QuotePayload,lines:[{sellSkuId,quantity:"2",...line}]},token);
    const fixed=await quoteMode({unitPrice:"10000",discountMode:"PER_UNIT",discountValue:"1000",
      taxRate:"10",taxMode:"INCLUSIVE"});
    assert.equal(fixed.status,200,JSON.stringify(fixed.body));
    assert.equal(fixed.body.quote.grandTotal,"18000");
    assert.equal(fixed.body.quote.taxTotal,"1636");
    assert.equal(fixed.body.quote.lines[0].rawDiscount,"2000");
    const modeOrder=await write("/v1/sales/orders",{...r2QuotePayload,note:"",
      lines:[{sellSkuId,quantity:"2",unitPrice:"10000",discountMode:"PER_UNIT",discountValue:"1000",
        taxRate:"10",taxMode:"INCLUSIVE",expectedPriceSignature:fixed.body.quote.lines[0].priceSignature}]},
      0,"t1-mode-"+randomUUID());
    assert.equal(modeOrder.status,201,JSON.stringify(modeOrder.body));
    assert.equal(modeOrder.body.total,"18000");
    assert.equal((await write("/v1/sales/orders/"+modeOrder.body.id+"/confirm",{branchId:b},0,"t1-mode-confirm-"+randomUUID())).status,200);
    const history=await call("/v1/sales/last-purchase?branchId="+b+"&customerId="+customer.body.id+"&sellSkuId="+sellSkuId,"GET",undefined,token);
    assert.equal(history.status,200);
    assert.equal(history.body.price.taxMode,"INCLUSIVE");
    assert.equal(history.body.price.discountMode,"PER_UNIT");
    assert.equal(history.body.price.discountValue,"1000");
    const restored=await quoteMode({unitPrice:history.body.price.unitPrice,
      taxRate:history.body.price.taxRate,taxMode:history.body.price.taxMode,
      discountMode:history.body.price.discountMode,discountValue:history.body.price.discountValue});
    assert.equal(restored.body.quote.grandTotal,"18000");
    const lineFixed=await quoteMode({unitPrice:"10000",discountMode:"TOTAL_AMOUNT",discountValue:"1001"});
    assert.equal(lineFixed.status,200,JSON.stringify(lineFixed.body));
    assert.equal(lineFixed.body.quote.grandTotal,"18999");
    const discountOnly=await quoteMode({discountRate:"10"});
    assert.equal(discountOnly.status,200,JSON.stringify(discountOnly.body));
    assert.equal(discountOnly.body.quote.lines[0].manualPriceOverride,false);
    const zero=await quoteMode({unitPrice:"0"});
    assert.equal(zero.status,200,JSON.stringify(zero.body));
    assert.equal(zero.body.quote.grandTotal,"0");
    assert.equal((await quoteMode({unitPrice:"10000",discountMode:"TOTAL_AMOUNT",discountValue:"20001"})).status,400);
    // Removal of one override grant must not remove the unrelated discount grant.
    await pool.query("DELETE FROM role_permission WHERE installation_id=$1 AND permission_code='orders.price.override'",[root.installationId]);
    assert.equal((await quoteMode({unitPrice:"10000"})).status,403);
    assert.equal((await quoteMode({discountRate:"10"})).status,200);
    await pool.query("INSERT INTO role_permission(installation_id,role_id,permission_code) SELECT installation_id,id,'orders.price.override' FROM app_role WHERE installation_id=$1 AND code='PRIMARY_OWNER_MAIN'",[root.installationId]);
    // R1-C: the legacy productId path must enforce the same list window
    // at both create and confirmation; existing posted documents stay intact.
    const pendingExpiry=await write("/v1/sales/orders",payload,0,
      "r1c-expiry-pending-"+randomUUID());
    assert.equal(pendingExpiry.status,201,JSON.stringify(pendingExpiry.body));
    await pool.query(`UPDATE catalog_price_list SET effective_to=now()-interval '1 second',
      revision=revision+1 WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
      [root.installationId,b,list.body.id]);
    const blockedConfirm=await write(
      "/v1/sales/orders/"+pendingExpiry.body.id+"/confirm",{branchId:b},
      0,"r1c-expired-confirm-"+randomUUID());
    assert.equal(blockedConfirm.status,409,
      "legacy order cannot confirm after price-list expiry");
    assert.equal((await write("/v1/sales/orders",payload,0,
      "r1c-expired-create-"+randomUUID())).status,409);
    assert.equal((await call("/v1/sales/quote","POST",r2QuotePayload,
      token)).status,409,"SKU quote rejects the same expired list");
    const oldConfirmed=await call("/v1/sales/orders/"+id+"?branchId="+b,
      "GET",undefined,token);
    assert.equal(oldConfirmed.status,200);
    assert.equal(oldConfirmed.body.order.status,"CANCELLED");
  }finally{
    if(server)await new Promise<void>(ok=>server!.close(()=>ok()));
    if(pool)await pool.end();
    await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)').catch(()=>undefined);
    await admin.end();
  }
});
