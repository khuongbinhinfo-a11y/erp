import test from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {resolve} from "node:path";
import {Pool} from "pg";
import type {AddressInfo} from "node:net";
import {applyMigrations} from "./migrate.ts";
import {bootstrapInstallation} from "./bootstrap.ts";
import {buildApp} from "./server.ts";
import {isDatabaseReady} from "./db.ts";

const connection=process.env.DATABASE_URL;
const isCi=(()=>{
 try{const u=new URL(connection??"");
  return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";
 }catch{return false;}
})();
test("T5-D: real PG dispatch, driver attempt, custody return, AR, COD and handover",{skip:!isCi},async()=>{
 const admin=new Pool({connectionString:connection,max:2});
 const name="erp_ci_t5d_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,app:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+name+'"');
  const dsn=new URL(connection!);dsn.pathname="/"+name;
  db=new Pool({connectionString:dsn.toString(),max:10,query_timeout:25000});
  db.on("error",()=>{});
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).applied.length,30);
  const password="t5d-"+randomUUID();
  const root=await bootstrapInstallation(db,{code:"t5d",displayName:"Delivery execution",
   adminLogin:"owner",adminPassword:password});
  const {installationId:t,branchId:b,warehouseId:w,actorId:owner}=root;
  app=buildApp(()=>isDatabaseReady(db!),async()=>true,{
   pool:db,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"test-"+randomUUID()});
  await new Promise<void>(done=>app!.listen(0,"127.0.0.1",done));
  const origin="http://127.0.0.1:"+(app.address() as AddressInfo).port;
  async function call(path:string,method="GET",body?:unknown,token?:string,
   headers:Record<string,string>={}){
   const r=await fetch(origin+path,{method,headers:{
    origin:"https://erp.example.test",...(body===undefined?{}:{"content-type":"application/json"}),
    ...(token?{authorization:"Bearer "+token}:{}),...headers},
    body:body===undefined?undefined:JSON.stringify(body)});
   return {status:r.status,data:r.status===204?{}:await r.json() as Record<string,any>};
  }
  const login=await call("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(login.status,200,JSON.stringify(login.data));
  const token=login.data.token as string;
  const write=(path:string,payload:unknown,revision=0,key="t5d-"+randomUUID())=>
   call(path,"POST",payload,token,{"if-match":String(revision),"idempotency-key":key});
  const cat=(name:string,payload:Record<string,unknown>)=>
   write("/v1/catalog/"+name,{branchId:b,...payload});
  const customer=await cat("customers",{code:"T5DC",name:"Khách giao chuyến"});
  const list=await cat("price-lists",{code:"T5DPL",name:"Bảng giá chuyến"});
  const product=await cat("products",{code:"T5DP",name:"Sản phẩm",baseUnit:"cai"});
  for(const x of [customer,list,product])assert.equal(x.status,201,JSON.stringify(x.data));
  assert.equal((await cat("prices",{priceListId:list.data.id,productId:product.data.id,
   amount:"1000",discountRate:"0",effectiveAt:"2026-01-01T00:00:00Z"})).status,201);
  assert.equal((await write("/v1/inventory/openings",{
   branchId:b,warehouseId:w,productId:product.data.id,quantity:"10"})).status,201);
  const order=await write("/v1/sales/orders",{
   branchId:b,customerId:customer.data.id,priceListId:list.data.id,
   shipping:{warehouseId:w,deliveryChoice:"TRIP",customerMode:"EXISTING",
    collectionPolicy:"CREDIT_TERMS",deliveryAddress:"Đường T5D, Cần Thơ, Việt Nam"},
   lines:[{productId:product.data.id,quantity:"4"}]});
  assert.equal(order.status,201,JSON.stringify(order.data));
  const orderId=order.data.id as string;
  assert.equal((await write("/v1/sales/orders/"+orderId+"/confirm",{branchId:b})).status,200);
  const s={branchId:b,warehouseId:w};
  const staff=await write("/v1/delivery/employees",{...s,code:"T5DSTAFF",
   fullName:"Tài xế kiểm thử"});
  assert.equal(staff.status,201,JSON.stringify(staff.data));
  await db.query(`UPDATE org_employee SET account_user_id=$4,revision=revision+1
   WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
   [t,b,staff.data.employee.id,owner]);
  const driver=await write("/v1/delivery/drivers",{...s,employeeId:staff.data.employee.id});
  const vehicle=await write("/v1/delivery/vehicles",{...s,code:"T5DVEH",
   name:"Xe kiểm thử",licensePlate:"65A-12345"});
  assert.equal(driver.status,201,JSON.stringify(driver.data));
  assert.equal(vehicle.status,201,JSON.stringify(vehicle.data));
  const trip=await write("/v1/delivery/trips",{...s,plannedDate:"2026-11-28"});
  assert.equal(trip.status,201,JSON.stringify(trip.data));
  const tripId=trip.data.id as string;
  const tp="/v1/delivery/trips/"+tripId;
  assert.equal((await write(tp+"/assign",{...s,orderIds:[orderId]},0)).status,200);
  assert.equal((await write(tp+"/plan",{...s,driverId:driver.data.resource.id,
   vehicleId:vehicle.data.resource.id,plannedDate:"2026-11-28"},1)).status,200);
  assert.equal((await write(tp+"/lock",s,2)).status,200);
  const orderScope={...s,orderId,version:1};
  const hold=await write("/v1/inventory/trip-holds",orderScope,1);
  assert.equal(hold.status,200,JSON.stringify(hold.data));
  const pre=await write("/v1/inventory/trips/prepare",{
   ...orderScope,lines:[{lineNo:1,pickedBase:"4",packedBase:"4"}]},2);
  assert.equal(pre.status,201,JSON.stringify(pre.data));
  const parts=pre.data.lines[0].preparations as Record<string,any>[];
  assert.ok(parts.length>0);
  const issued=await write("/v1/inventory/trips/dispatch",{
   ...orderScope,lines:parts.map(p=>({preparationId:p.preparationId,
    sourceLine:p.sourceLine,quantityBase:p.readyBase}))},3);
  assert.equal(issued.status,201,JSON.stringify(issued.data));
  const dispatchId=issued.data.id as string;
  const exec="/v1/delivery/execution/";
  const body={...s,tripId};
  const qs="?"+new URLSearchParams(body);
  assert.equal((await call(exec+"read"+qs)).status,401);
  const before=await call(exec+"read"+qs,"GET",undefined,token);
  assert.equal(before.status,200,JSON.stringify(before.data));
  assert.equal(before.data.execution.status,"LOCKED");
  const noDispatch=await write(exec+"attempt",{
   ...body,orderId,result:"DELIVERED_FULL"},issued.data.revision);
  assert.equal(noDispatch.status,409,"start required before attempt");
  const startKey="start-"+randomUUID();
  const start=await write(exec+"start",body,3,startKey);
  assert.equal(start.status,201,JSON.stringify(start.data));
  assert.deepEqual((await write(exec+"start",body,3,startKey)).data,start.data);
  assert.equal((await write(exec+"start",body,3)).status,409);
  const read=await call(exec+"read"+qs,"GET",undefined,token);
  assert.equal(read.status,200,JSON.stringify(read.data));
  assert.equal(read.data.execution.status,"DEPARTED");
  const stop=read.data.execution.stops[0];
  assert.equal(stop.lines.length,1);
  assert.equal(stop.lines[0].issuedBase,"4.000000");
  const src={dispatchId,sourceLine:1};
  const attemptBody={...body,orderId,result:"DELIVERED_PARTIAL",
   lines:[{...src,deliveredBase:"2"}]};
  const attemptKey="attempt-"+randomUUID();
  const partial=await write(exec+"attempt",attemptBody,stop.revision,attemptKey);
  assert.equal(partial.status,201,JSON.stringify(partial.data));
  assert.equal(partial.data.due,"2000");
  assert.equal(partial.data.onVehicle,"2.000000");
  assert.deepEqual((await write(exec+"attempt",attemptBody,stop.revision,attemptKey)).data,partial.data);
  const changed=await write(exec+"attempt",{...attemptBody,lines:[{...src,deliveredBase:"1"}]},
   stop.revision,attemptKey);
  assert.equal(changed.status,409);
  const bad=await write(exec+"attempt",{...body,orderId,result:"DELIVERED_FULL"},stop.revision);
  assert.equal(bad.status,409,"stale revision cannot double post");
  const wrong=await write(exec+"attempt",{...body,orderId:randomUUID(),result:"DELIVERED_FULL"},
   partial.data.revision);
  assert.equal(wrong.status,404);
  const retBody={...body,orderId,reason:"Hàng khách chưa nhận",
   lines:[{...src,quantityBase:"1"}]};
  const retKey="return-"+randomUUID();
  const returned=await write(exec+"return",retBody,partial.data.revision,retKey);
  assert.equal(returned.status,201,JSON.stringify(returned.data));
  assert.deepEqual((await write(exec+"return",retBody,partial.data.revision,retKey)).data,returned.data);
  assert.equal(returned.data.returned,"1.000000");
  assert.equal(returned.data.onVehicle,"1.000000");
  assert.equal(returned.data.due,"2000");
  assert.equal((await write(exec+"return",{
   ...retBody,lines:[{...src,quantityBase:"2"}]},returned.data.revision)).status,409,
   "must reject a return larger than actual goods still on the truck");
  const failAttempt=await write(exec+"attempt",{
   ...body,orderId,result:"FAILED",reasonCode:"CUSTOMER_ABSENT"},returned.data.revision);
  assert.equal(failAttempt.status,201,JSON.stringify(failAttempt.data));
  assert.equal(failAttempt.data.due,"2000");
  const finish=await write(exec+"attempt",{
   ...body,orderId,result:"DELIVERED_FULL"},failAttempt.data.revision);
  assert.equal(finish.status,201,JSON.stringify(finish.data));
  assert.equal(finish.data.due,"3000");
  assert.equal(finish.data.onVehicle,"0.000000");
  assert.equal(finish.data.deliveryStatus,"PARTIAL");
  const paymentBody={...body,orderId,amount:"1000",method:"CASH"};
  const payKey="cod-"+randomUUID();
  const paid=await write(exec+"collect",paymentBody,finish.data.revision,payKey);
  assert.equal(paid.status,201,JSON.stringify(paid.data));
  assert.equal(paid.data.remaining,"2000");
  assert.ok(paid.data.collectionId);
  assert.deepEqual((await write(exec+"collect",paymentBody,finish.data.revision,payKey)).data,paid.data);
  const zero=await write(exec+"collect",{...paymentBody,amount:"0"},paid.data.revision);
  assert.equal(zero.status,200,JSON.stringify(zero.data));
  assert.equal(zero.data.recorded,false);
  assert.equal((await write(exec+"collect",{...paymentBody,amount:"4000"},paid.data.revision)).status,409);
  const handBody={...body,collectionLines:[{
   collectionId:paid.data.collectionId,amount:"1000"}]};
  const handKey="handover-"+randomUUID();
  const hand=await write(exec+"handover",handBody,3,handKey);
  assert.equal(hand.status,201,JSON.stringify(hand.data));
  assert.deepEqual((await write(exec+"handover",handBody,3,handKey)).data,hand.data);
  assert.equal((await write(exec+"handover",handBody,3)).status,409);
  const onHand=await db.query<{qty:string}>(`SELECT coalesce(sum(delta_base),0)::text AS qty
   FROM inventory_ledger WHERE installation_id=$1 AND branch_id=$2 AND
   warehouse_id=$3 AND product_id=$4`,[t,b,w,product.data.id]);
  assert.equal(onHand.rows[0]!.qty,"7.000000","one real RETURN restores warehouse stock");
  const financial=await db.query<{sales:string;payments:string}>(`SELECT
   coalesce(sum(CASE WHEN kind='SALE' THEN amount ELSE 0 END),0)::text AS sales,
   coalesce(-sum(CASE WHEN kind='PAYMENT' THEN amount ELSE 0 END),0)::text AS payments
   FROM customer_receivable_ledger WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3`,
   [t,b,orderId]);
  assert.deepEqual(financial.rows[0],{sales:"3000",payments:"1000"});
  await assert.rejects(db.query(`UPDATE delivery_trip_attempt SET amount=0
   WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
   [t,b,partial.data.id]),/immutable/i);
  // The committed receipt read is authoritative after a lost transport ACK.
  const recovery=await write(exec+"recovery",{action:"attempt",body:attemptBody},
   stop.revision,attemptKey);
  assert.equal(recovery.status,200,JSON.stringify(recovery.data));
  assert.equal(recovery.data.receipt.id,partial.data.id);
 }finally{
  if(app)await new Promise<void>(done=>app!.close(()=>done()));
  if(db)await db.end().catch(()=>undefined);
  await admin.query('DROP DATABASE IF EXISTS "'+name+'" WITH (FORCE)').catch(()=>undefined);
  await admin.end();
 }
});
