import test from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {resolve} from "node:path";
import type {AddressInfo} from "node:net";
import {Pool} from "pg";
import {applyMigrations} from "./migrate.ts";
import {bootstrapInstallation} from "./bootstrap.ts";
import {buildApp} from "./server.ts";
import {isDatabaseReady} from "./db.ts";
const source=process.env.DATABASE_URL;
const ci=(()=>{try{const u=new URL(source??"");
 return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";
}catch{return false;}})();
test("T5-B trip planner: two orders, driver/vehicle, sequencing, idempotency, lock and no stock/AR",{skip:!ci},async()=>{
 const admin=new Pool({connectionString:source,max:2});
 const dbName="erp_ci_t5b_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,app:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+dbName+'"');
  const url=new URL(source!);url.pathname="/"+dbName;
  db=new Pool({connectionString:url.toString(),max:10,query_timeout:25000});
  db.on("error",()=>{});
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).applied.length,28);
  assert.equal((await applyMigrations(db,resolve(process.cwd(),"db/migrations"))).skipped.length,28);
  const password="t5b-"+randomUUID();
  const scope=await bootstrapInstallation(db,{code:"t5b",displayName:"Delivery trip test",
    adminLogin:"owner",adminPassword:password});
  const {installationId:t,branchId:b,warehouseId:w}=scope;
  app=buildApp(()=>isDatabaseReady(db!),async()=>true,{
   pool:db,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"test-"+randomUUID()});
  await new Promise<void>(done=>app!.listen(0,"127.0.0.1",done));
  const host="http://127.0.0.1:"+(app.address() as AddressInfo).port;
  const call=async(path:string,method="GET",body?:unknown,token?:string,
    headers:Record<string,string>={})=>{
   const r=await fetch(host+path,{method,headers:{
    origin:"https://erp.example.test",
    ...(body===undefined?{}:{"content-type":"application/json"}),
    ...(token?{authorization:"Bearer "+token}:{}),...headers
   },body:body===undefined?undefined:JSON.stringify(body)});
   return {status:r.status,data:r.status===204?{}:await r.json() as Record<string,any>};
  };
  const auth=await call("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(auth.status,200,JSON.stringify(auth.data));
  const token=auth.data.token as string;
  const post=(path:string,body:unknown,rev=0,key="t5b-"+randomUUID())=>
   call(path,"POST",body,token,{"idempotency-key":key,"if-match":String(rev)});
  const cat=(type:string,body:Record<string,unknown>)=>post("/v1/catalog/"+type,{branchId:b,...body});
  const customer=await cat("customers",{code:"B01",name:"Khách giao tuyến"});
  const prices=await cat("price-lists",{code:"PL01",name:"Giá giao"});
  const product=await cat("products",{code:"P01",name:"Hàng giao",baseUnit:"cai"});
  for(const result of [customer,prices,product])assert.equal(result.status,201,JSON.stringify(result.data));
  assert.equal((await cat("prices",{priceListId:prices.data.id,productId:product.data.id,
    amount:"1000",discountRate:"0",effectiveAt:"2026-01-01T00:00:00Z"})).status,201);
  const make=async(address:string)=>{
   const c=await post("/v1/sales/orders",{
    branchId:b,customerId:customer.data.id,priceListId:prices.data.id,
    shipping:{warehouseId:w,deliveryChoice:"TRIP",customerMode:"EXISTING",
      collectionPolicy:"CREDIT_TERMS",deliveryAddress:address},
    lines:[{productId:product.data.id,quantity:"1"}]});
   assert.equal(c.status,201,JSON.stringify(c.data));
   const confirm=await post("/v1/sales/orders/"+c.data.id+"/confirm",{branchId:b});
   assert.equal(confirm.status,200,JSON.stringify(confirm.data));
   return c.data.id as string;
  };
  const a=await make("Đường A, Mỹ Tho, Việt Nam");
  const b2=await make("Đường B, Mỹ Tho, Việt Nam");
  const s={branchId:b,warehouseId:w},qs="?"+new URLSearchParams(s);
  assert.equal((await call("/v1/delivery/trips"+qs)).status,401);
  const elig=await call("/v1/delivery/trips/eligible"+qs,"GET",undefined,token);
  assert.equal(elig.status,200,JSON.stringify(elig.data));
  assert.deepEqual(new Set(elig.data.items.map((x:any)=>x.id)),new Set([a,b2]));
  // Search and pagination never leak outside the active installation/warehouse.
  const searched=await call("/v1/delivery/trips/eligible"+qs+
    "&q="+encodeURIComponent("Đường B"),"GET",undefined,token);
  assert.equal(searched.status,200,JSON.stringify(searched.data));
  assert.deepEqual(searched.data.items.map((x:any)=>x.id),[b2]);
  const emptySearch=await call("/v1/delivery/trips/eligible"+qs+"&q=ZZZZNO",
    "GET",undefined,token);
  assert.equal(emptySearch.status,200,JSON.stringify(emptySearch.data));
  assert.deepEqual(emptySearch.data.items,[]);
  const page200=await call("/v1/delivery/trips/eligible"+qs+"&offset=200",
    "GET",undefined,token);
  assert.equal(page200.status,200,JSON.stringify(page200.data));
  assert.deepEqual(page200.data.items,[]);
  assert.equal((await call("/v1/delivery/trips/eligible"+qs+"&offset=1",
    "GET",undefined,token)).status,400);
  assert.equal((await call("/v1/delivery/trips/eligible"+qs+"&q="+
    "a".repeat(81),"GET",undefined,token)).status,400);
  // Canonical employee exists separately from app_user/login and is scoped.
  assert.equal((await call("/v1/delivery/employees"+qs)).status,401);
  const staff=await post("/v1/delivery/employees",{
    ...s,code:"NV01",fullName:"Tài xế Một",phone:"0912345678",jobTitle:"Lái xe"});
  assert.equal(staff.status,201,JSON.stringify(staff.data));
  assert.equal(staff.data.employee.active,true);
  assert.equal((await post("/v1/delivery/employees",{
    ...s,code:"NV01",fullName:"Nhân viên trùng"})).status,409);
  const staffRows=await call("/v1/delivery/employees"+qs,"GET",undefined,token);
  assert.equal(staffRows.status,200,JSON.stringify(staffRows.data));
  assert.equal(staffRows.data.items[0].id,staff.data.employee.id);
  assert.equal(staffRows.data.items[0].linkedDriver,false);
  assert.equal((await post("/v1/delivery/drivers",
    {...s,code:"D01",name:"Tài xế Một"})).status,400,
    "Detached driver creation must be rejected");
  assert.equal((await post("/v1/delivery/drivers",
    {...s,employeeId:randomUUID()})).status,409);
  const dr=await post("/v1/delivery/drivers",
    {...s,employeeId:staff.data.employee.id});
  assert.equal((await post("/v1/delivery/drivers",
    {...s,employeeId:staff.data.employee.id})).status,409,
    "Exactly one active driver profile per canonical employee");
  assert.equal((await call("/v1/delivery/drivers"+qs,"GET",undefined,token))
    .data.items[0].employeeId,staff.data.employee.id);
  const inactive=await post("/v1/delivery/employees",{
    ...s,code:"NV02",fullName:"Nhân viên nghỉ"});
  assert.equal(inactive.status,201,JSON.stringify(inactive.data));
  assert.equal((await post("/v1/delivery/employees/"+inactive.data.employee.id+"/update",{
    ...s,fullName:"Nhân viên nghỉ",active:false},0)).status,200);
  assert.equal((await post("/v1/delivery/drivers",{
    ...s,employeeId:inactive.data.employee.id})).status,409);
  const car=await post("/v1/delivery/vehicles",{...s,code:"C01",name:"Xe tải",licensePlate:"63A-12345"});
  assert.equal(dr.status,201,JSON.stringify(dr.data));
  assert.equal(car.status,201,JSON.stringify(car.data));
  const body={...s,plannedDate:"2026-11-28",note:"Chuyến buổi sáng"};
  const key="create-"+randomUUID();
  const created=await post("/v1/delivery/trips",body,0,key);
  assert.equal(created.status,201,JSON.stringify(created.data));
  assert.deepEqual((await post("/v1/delivery/trips",body,0,key)).data,created.data);
  assert.equal((await post("/v1/delivery/trips",{...body,note:"Changed"},0,key)).status,409);
  const tid=created.data.id as string,path="/v1/delivery/trips/"+tid;
  const bulk={...s,orderIds:[a,b2]},ak="assign-"+randomUUID();
  const assigned=await post(path+"/assign",bulk,0,ak);
  assert.equal(assigned.status,200,JSON.stringify(assigned.data));
  assert.equal(assigned.data.revision,1);
  assert.deepEqual((await post(path+"/assign",bulk,0,ak)).data,assigned.data);
  assert.equal((await post(path+"/assign",bulk,0)).status,409);
  let trip=await call(path+qs,"GET",undefined,token);
  assert.equal(trip.status,200,JSON.stringify(trip.data));
  assert.equal(trip.data.trip.stops.length,2);
  const removed=await post(path+"/unassign",{...s,orderIds:[a]},1);
  assert.equal(removed.status,200,JSON.stringify(removed.data));
  assert.equal(removed.data.revision,2);
  const reassigned=await post(path+"/assign",{...s,orderIds:[a]},2);
  assert.equal(reassigned.status,200,JSON.stringify(reassigned.data));
  assert.equal(reassigned.data.revision,3);
  trip=await call(path+qs,"GET",undefined,token);
  const reversed=trip.data.trip.stops.map((x:any)=>x.orderId).reverse();
  assert.equal((await post(path+"/reorder",{...s,orderIds:reversed},3)).status,200);
  trip=await call(path+qs,"GET",undefined,token);
  assert.deepEqual(trip.data.trip.stops.map((x:any)=>x.orderId),reversed);
  const plan=await post(path+"/plan",{...s,driverId:dr.data.resource.id,
    vehicleId:car.data.resource.id,plannedDate:"2026-11-28",note:"Đã kiểm tuyến"},4);
  assert.equal(plan.status,200,JSON.stringify(plan.data));
  assert.equal(plan.data.status,"PLANNED");
  const lock=await post(path+"/lock",s,5);
  assert.equal(lock.status,200,JSON.stringify(lock.data));
  assert.equal(lock.data.status,"LOCKED");
  assert.equal((await post("/v1/delivery/employees/"+staff.data.employee.id+"/update",{
    ...s,fullName:"Tài xế Một",active:false},0)).status,409,
    "Cannot disable employee while a locked delivery trip is outstanding");
  assert.equal((await post(path+"/reorder",{...s,orderIds:reversed},6)).status,409);
  const another=await post("/v1/delivery/trips",body);
  assert.equal(another.status,201);
  assert.equal((await post("/v1/delivery/trips/"+another.data.id+"/assign",
    {...s,orderIds:[a]},0)).status,409);
  // 100+ routes must remain accessible, including older PLANNED/DRAFT trips.
  // Seed additional trip fixtures only in this isolated ephemeral CI DB.
  await db.query(`INSERT INTO delivery_trip
    (installation_id,branch_id,warehouse_id,trip_no,planned_date,created_by)
    SELECT $1,$2,$3,'TG-20261129-'||lpad(n::text,6,'0'),
      DATE '2026-11-29',$4 FROM generate_series(1,101) AS g(n)`,
    [t,b,w,scope.actorId]);
  const firstPage=await call("/v1/delivery/trips"+qs,"GET",undefined,token);
  const nextPage=await call("/v1/delivery/trips"+qs+"&offset=100","GET",undefined,token);
  assert.equal(firstPage.status,200,JSON.stringify(firstPage.data));
  assert.equal(nextPage.status,200,JSON.stringify(nextPage.data));
  assert.equal(firstPage.data.items.length,100);
  assert.equal(nextPage.data.items.length,3);
  assert.equal(new Set([...firstPage.data.items,...nextPage.data.items]
    .map((x:any)=>x.id)).size,103);
  assert.equal((await call("/v1/delivery/trips"+qs+"&offset=1",
    "GET",undefined,token)).status,400);
  assert.equal((await call("/v1/delivery/trips"+qs+"&offset=-100",
    "GET",undefined,token)).status,400);
  assert.equal((await call(path+qs,"GET",undefined,token)).status,200);
  const ledger=await db.query<{n:string}>(`SELECT count(*)::text AS n FROM inventory_ledger
    WHERE installation_id=$1 AND branch_id=$2`,[t,b]);
  assert.equal(ledger.rows[0]?.n,"0");
  const ar=await db.query<{n:string}>(`SELECT count(*)::text AS n FROM customer_receivable_ledger
    WHERE installation_id=$1 AND branch_id=$2`,[t,b]);
  assert.equal(ar.rows[0]?.n,"0");
  const events=await db.query<{n:string}>(`SELECT count(*)::text AS n FROM delivery_trip_event
    WHERE installation_id=$1 AND branch_id=$2 AND trip_id=$3`,[t,b,tid]);
  assert.equal(events.rows[0]?.n,"7");
  await assert.rejects(db.query(`UPDATE delivery_trip_event SET detail='{}'
    WHERE installation_id=$1 AND branch_id=$2 AND trip_id=$3`,[t,b,tid]));
 }finally{
  if(app)await new Promise<void>(ok=>app!.close(()=>ok()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)').catch(()=>{});
  await admin.end();
 }
});
