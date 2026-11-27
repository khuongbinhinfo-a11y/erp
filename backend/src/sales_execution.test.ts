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

const url=process.env.DATABASE_URL;
const ci=(()=>{try{const u=new URL(url??"");
 return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";
}catch{return false;}})();
test("T5-A manual delivery, source-matched return, 0-debt and repeat AR payment",{
 skip:!ci},async()=>{
 const admin=new Pool({connectionString:url,max:2});
 const name="erp_ci_t5a_"+randomUUID().replaceAll("-","").slice(0,12);
 let pool:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+name+'"');
  const uri=new URL(url!);uri.pathname="/"+name;
  pool=new Pool({connectionString:uri.toString(),max:10,query_timeout:15000});
  pool.on("error",()=>{});
  const applied=await applyMigrations(pool,resolve(process.cwd(),"db/migrations"));
  assert.equal(applied.applied.length,26);
  assert.equal((await applyMigrations(pool,resolve(process.cwd(),"db/migrations"))).skipped.length,26);
  const password="T5A-"+randomUUID();
  const root=await bootstrapInstallation(pool,{code:"t5a",displayName:"T5-A integration",
    adminLogin:"owner",adminPassword:password});
  const {installationId:t,branchId:b,warehouseId:w,actorId}=root;
  server=buildApp(()=>isDatabaseReady(pool!),async()=>true,{
    pool,installationId:t,allowedOrigin:"https://erp.example.test",
    throttleSecret:"t5a-"+randomUUID()});
  await new Promise<void>(done=>server!.listen(0,"127.0.0.1",done));
  const host="http://127.0.0.1:"+(server.address() as AddressInfo).port;
  const call=async(path:string,method="GET",data?:unknown,token?:string,
     headers:Record<string,string>={})=>{
    const res=await fetch(host+path,{method,headers:{
      origin:"https://erp.example.test",
      ...(data===undefined?{}:{"content-type":"application/json"}),
      ...(token?{authorization:"Bearer "+token}:{}),...headers},
     body:data===undefined?undefined:JSON.stringify(data)});
    return {status:res.status,body:res.status===204?{}:
      await res.json() as Record<string,any>};
  };
  const auth=await call("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(auth.status,200,JSON.stringify(auth.body));
  const token=auth.body.token as string;
  const post=(path:string,data:unknown,revision=0,key="t5a-"+randomUUID())=>
    call(path,"POST",data,token,{"if-match":String(revision),"idempotency-key":key});
  const catalog=(kind:string,data:Record<string,unknown>)=>
    post("/v1/catalog/"+kind,{branchId:b,...data});
  const cust=await catalog("customers",{code:"T5AC",name:"Buyer T5A"});
  const list=await catalog("price-lists",{code:"T5AP",name:"Test distribution price"});
  const product=await catalog("products",{code:"T5AS",name:"Test product",baseUnit:"cai"});
  for(const r of [cust,list,product])assert.equal(r.status,201,JSON.stringify(r.body));
  assert.equal((await catalog("prices",{priceListId:list.body.id,productId:product.body.id,
    amount:"1000.0000",discountRate:"0",effectiveAt:"2026-01-01T00:00:00Z"})).status,201);
  assert.equal((await post("/v1/inventory/openings",{
    branchId:b,warehouseId:w,productId:product.body.id,quantity:"5.000000"})).status,201);
  const created=await post("/v1/sales/orders",{branchId:b,
    customerId:cust.body.id,priceListId:list.body.id,
    shipping:{warehouseId:w,deliveryChoice:"MANUAL",
      collectionPolicy:"CREDIT_TERMS",customerMode:"EXISTING"},
    lines:[{productId:product.body.id,quantity:"5"}]});
  assert.equal(created.status,201,JSON.stringify(created.body));
  const orderId=created.body.id as string;
  assert.equal((await post("/v1/sales/orders/"+orderId+"/confirm",
    {branchId:b},0)).status,200);
  const scope={branchId:b,warehouseId:w,orderId,version:1};
  const issue=await post("/v1/inventory/direct-issues",
    {...scope,lines:[{lineNo:1,quantityBase:"5.000000"}]},1);
  assert.equal(issue.status,201,JSON.stringify(issue.body));
  const query=new URLSearchParams({branchId:b,warehouseId:w,orderId});
  const read=()=>call("/v1/sales/execution/read?"+query,"GET",undefined,token);
  assert.equal((await call("/v1/sales/execution/read?"+query)).status,401);
  let state=await read();
  assert.equal(state.status,200,JSON.stringify(state.body));
  assert.equal(state.body.execution.sources[0].returnableBase,"5.000000");
  const initialRev=state.body.execution.revision as number;
  const payload={...scope,reason:"Khách không nhận đủ hàng",
    lines:[{issueId:issue.body.id,sourceLine:1,quantityBase:"2.000000"}]};
  const key="t5a-return-"+randomUUID();
  const returned=await post("/v1/sales/execution/returns",payload,initialRev,key);
  assert.equal(returned.status,201,JSON.stringify(returned.body));
  assert.deepEqual((await post("/v1/sales/execution/returns",payload,initialRev,key)).body,returned.body);
  assert.equal((await post("/v1/sales/execution/returns",
    {...payload,reason:"Khác"},initialRev,key)).status,409);
  assert.equal((await post("/v1/sales/execution/returns",
    {...payload,lines:[{issueId:issue.body.id,sourceLine:1,
      quantityBase:"4.000000"}]},returned.body.revision)).status,409);
  const stock=await pool.query<{on_hand:string}>(`SELECT on_hand::text
    FROM inventory_stock_balance WHERE installation_id=$1 AND branch_id=$2
     AND warehouse_id=$3 AND product_id=$4`,[t,b,w,product.body.id]);
  assert.equal(stock.rows[0]?.on_hand,"2.000000");
  // A malicious SQL client cannot invent a fulfilled invoice without the
  // underlying physical delivery and matching SALE ledger, even on COMMIT.
  const fakeFulfillment=await pool.connect();
  try{
   await fakeFulfillment.query("BEGIN");
   await fakeFulfillment.query(`INSERT INTO sales_fulfillment
    (installation_id,branch_id,order_id,version_no,warehouse_id,mode,actor_id,request_id)
    VALUES($1,$2,$3,1,$4,'MANUAL',$5,'forged-delivery')`,[t,b,orderId,w,actorId]);
   await assert.rejects(fakeFulfillment.query("COMMIT"),
      /Manual fulfillment requires all actual delivery lines/i);
  }finally{
   await fakeFulfillment.query("ROLLBACK").catch(()=>undefined);fakeFulfillment.release();
  }
  const forged=await pool.connect();
  try{
   await forged.query("BEGIN");
   await assert.rejects(forged.query(`INSERT INTO inventory_ledger
      (installation_id,branch_id,warehouse_id,product_id,kind,source_type,
       source_id,source_line,delta_base,actor_id,request_id)
      VALUES($1,$2,$3,$4,'RETURN','FULFILLMENT',$5,99,1,$6,'forged-return')`,
      [t,b,w,product.body.id,randomUUID(),actorId]),/Return ledger must match/);
  }finally{await forged.query("ROLLBACK").catch(()=>undefined);forged.release();}
  state=await read();
  assert.equal(state.body.execution.lines[0].deliverableBase,"3.000000");
  const doneKey="t5a-complete-"+randomUUID();
  const complete=await post("/v1/sales/execution/complete",scope,
    state.body.execution.revision,doneKey);
  assert.equal(complete.status,201,JSON.stringify(complete.body));
  assert.equal(complete.body.grandTotal,"3000");
  assert.equal(complete.body.deliveryStatus,"PARTIAL");
  assert.equal(complete.body.remaining,"3000");
  assert.deepEqual((await post("/v1/sales/execution/complete",scope,
    state.body.execution.revision,doneKey)).body,complete.body);
  state=await read();
  assert.equal(state.body.execution.grandTotal,"3000");
  assert.equal(state.body.execution.paid,"0");
  assert.equal(state.body.execution.remaining,"3000");
  assert.equal(state.body.execution.completed,true);
  // No orphan receipt may be recorded after COMMIT without its matching
  // canonical allocation and negative AR PAYMENT entry.
  const orphan=await pool.connect();
  try{
   await orphan.query("BEGIN");
   await orphan.query(`INSERT INTO payment_receipt
    (installation_id,branch_id,fulfillment_id,order_id,method,amount,actor_id,request_id)
    VALUES($1,$2,$3,$4,'CASH',100,$5,'forged-money')`,
    [t,b,complete.body.id,orderId,actorId]);
   await assert.rejects(orphan.query("COMMIT"),
     /MANUAL receipt must match one posted payment and allocation/i);
  }finally{await orphan.query("ROLLBACK").catch(()=>undefined);orphan.release();}

  assert.equal((await post("/v1/sales/execution/returns",payload,
    state.body.execution.revision)).status,409);
  const zero={branchId:b,warehouseId:w,orderId,amount:"0",method:"CASH"};
  const debt=await post("/v1/sales/execution/payments",zero,state.body.execution.revision);
  assert.equal(debt.status,200,JSON.stringify(debt.body));
  assert.equal(debt.body.debtRecorded,true);
  assert.equal((await pool.query<{n:string}>(`SELECT count(*)::text AS n
    FROM payment_receipt WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3`,
    [t,b,orderId])).rows[0]?.n,"0");
  const part={branchId:b,warehouseId:w,orderId,amount:"1000",method:"CASH"};
  const partKey="t5a-part-"+randomUUID();
  const partial=await post("/v1/sales/execution/payments",part,debt.body.revision,partKey);
  assert.equal(partial.status,201,JSON.stringify(partial.body));
  assert.equal(partial.body.paid,"1000");assert.equal(partial.body.remaining,"2000");
  assert.deepEqual((await post("/v1/sales/execution/payments",part,
    debt.body.revision,partKey)).body,partial.body);
  const recovered=await post("/v1/sales/execution/recovery",
    {action:"payment",body:part},debt.body.revision,partKey);
  assert.equal(recovered.status,200,JSON.stringify(recovered.body));
  assert.deepEqual(recovered.body.receipt,partial.body);
  assert.equal((await post("/v1/sales/execution/payments",
    {...part,amount:"3000"},partial.body.revision)).status,409);
  // Two devices attempting to collect the same remaining debt MUST serialize:
  // one wins the order row lock, the stale revision loses without double posting.
  const finalPay={...part,amount:"2000",method:"BANK_TRANSFER"};
  const attempts=await Promise.all([
    post("/v1/sales/execution/payments",finalPay,partial.body.revision),
    post("/v1/sales/execution/payments",finalPay,partial.body.revision),
  ]);
  assert.deepEqual(attempts.map(x=>x.status).sort(),[201,409]);
  const last=attempts.find(x=>x.status===201)!;
  assert.equal(last.body.paid,"3000");assert.equal(last.body.remaining,"0");
  assert.equal(last.body.paymentStatus,"PAID");
  const ledger=await pool.query<{kind:string;sum:string;n:string}>(`
   SELECT kind,sum(amount)::text AS sum,count(*)::text AS n
   FROM customer_receivable_ledger WHERE installation_id=$1 AND branch_id=$2
   AND order_id=$3 GROUP BY kind`,[t,b,orderId]);
  assert.deepEqual(ledger.rows.map(x=>[x.kind,x.sum,x.n]).sort(),
   [["PAYMENT","-3000","2"],["SALE","3000","1"]]);
  assert.equal((await pool.query<{n:string}>(`
   SELECT count(*)::text AS n FROM payment_receipt
   WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3`,
   [t,b,orderId])).rows[0]?.n,"2");
  assert.equal((await read()).body.execution.remaining,"0");

  // All issued goods returned: close with no fictitious sale, cash or delivery.
  const refused=await post("/v1/sales/orders",{branchId:b,
    customerId:cust.body.id,priceListId:list.body.id,
    shipping:{warehouseId:w,deliveryChoice:"MANUAL",
      collectionPolicy:"CREDIT_TERMS",customerMode:"EXISTING"},
    lines:[{productId:product.body.id,quantity:"2"}]});
  assert.equal(refused.status,201,JSON.stringify(refused.body));
  const refusedId=refused.body.id as string;
  assert.equal((await post("/v1/sales/orders/"+refusedId+"/confirm",
    {branchId:b},0)).status,200);
  const refusedScope={branchId:b,warehouseId:w,orderId:refusedId,version:1};
  const refusedIssue=await post("/v1/inventory/direct-issues",{
    ...refusedScope,lines:[{lineNo:1,quantityBase:"2.000000"}]},1);
  assert.equal(refusedIssue.status,201,JSON.stringify(refusedIssue.body));
  const refusedQuery=new URLSearchParams({branchId:b,warehouseId:w,
    orderId:refusedId});
  const refusedRead=()=>call("/v1/sales/execution/read?"+
     refusedQuery,"GET",undefined,token);
  const beforeReturn=await refusedRead();
  assert.equal(beforeReturn.status,200,JSON.stringify(beforeReturn.body));
  const allBack=await post("/v1/sales/execution/returns",{
    ...refusedScope,reason:"Khách hoàn trả toàn bộ hàng",
    lines:[{issueId:refusedIssue.body.id,sourceLine:1,
      quantityBase:"2.000000"}]},beforeReturn.body.execution.revision);
  assert.equal(allBack.status,201,JSON.stringify(allBack.body));
  const fullyReturned=await refusedRead();
  assert.equal(fullyReturned.body.execution.hasIssuedHistory,true);
  assert.equal(fullyReturned.body.execution.hasIssuedDelivery,false);
  assert.equal(fullyReturned.body.execution.expectedDeliveryTotal,"0");
  const closed=await post("/v1/sales/execution/complete",refusedScope,
    fullyReturned.body.execution.revision);
  assert.equal(closed.status,201,JSON.stringify(closed.body));
  assert.equal(closed.body.deliveryStatus,"RETURNED");
  assert.equal(closed.body.grandTotal,"0");
  assert.equal(closed.body.remaining,"0");
  const finalState=await refusedRead();
  assert.equal(finalState.body.execution.completed,true);
  assert.equal(finalState.body.execution.grandTotal,"0");
  assert.equal(finalState.body.execution.paid,"0");
  assert.equal(finalState.body.execution.remaining,"0");
  assert.equal((await pool.query<{n:string}>(`
     SELECT count(*)::text AS n FROM customer_receivable_ledger
     WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3`,
     [t,b,refusedId])).rows[0]?.n,"0");
  assert.equal((await pool.query<{n:string}>(`
     SELECT count(*)::text AS n FROM payment_receipt
     WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3`,
     [t,b,refusedId])).rows[0]?.n,"0");

  // The direct SQL route must be unable to issue the outstanding unshipped
  // quantity after MANUAL completion. Gross issued is deliberately < ordered.
  const lateOrder=await post("/v1/sales/orders",{branchId:b,
    customerId:cust.body.id,priceListId:list.body.id,
    shipping:{warehouseId:w,deliveryChoice:"MANUAL",
      collectionPolicy:"CREDIT_TERMS",customerMode:"EXISTING"},
    lines:[{productId:product.body.id,quantity:"5"}]});
  assert.equal(lateOrder.status,201,JSON.stringify(lateOrder.body));
  const lateId=lateOrder.body.id as string;
  assert.equal((await post("/v1/sales/orders/"+lateId+"/confirm",
    {branchId:b},0)).status,200);
  const partialIssue=await post("/v1/inventory/direct-issues",{
     branchId:b,warehouseId:w,orderId:lateId,version:1,
     lines:[{lineNo:1,quantityBase:"1.000000"}]},1);
  assert.equal(partialIssue.status,201,JSON.stringify(partialIssue.body));
  const lateQ=new URLSearchParams({branchId:b,warehouseId:w,orderId:lateId});
  const lateState=await call("/v1/sales/execution/read?"+lateQ,"GET",undefined,token);
  assert.equal(lateState.status,200);
  const lastComplete=await post("/v1/sales/execution/complete",{
     branchId:b,warehouseId:w,orderId:lateId,version:1},
     lateState.body.execution.revision);
  assert.equal(lastComplete.status,201,JSON.stringify(lastComplete.body));
  const sqlClient=await pool.connect();
  try{
    await sqlClient.query("BEGIN");
    const newIssue=await sqlClient.query<{id:string}>(`INSERT INTO sales_direct_issue
      (installation_id,branch_id,order_id,version_no,warehouse_id,
       actor_id,request_id) VALUES($1,$2,$3,1,$4,$5,'forged-late-issue')
       RETURNING id`,[t,b,lateId,w,actorId]);
    await assert.rejects(sqlClient.query(`INSERT INTO sales_direct_issue_line
      (installation_id,branch_id,issue_id,source_line,order_line_no,
       product_id,quantity_base)
      VALUES($1,$2,$3,1,1,$4,1)`,
      [t,b,newIssue.rows[0]!.id,product.body.id]),/Cannot issue after completed MANUAL delivery/);
  }finally{
    await sqlClient.query("ROLLBACK").catch(()=>undefined);sqlClient.release();
  }


 }finally{
  if(server)await new Promise<void>(done=>server!.close(()=>done()));
  if(pool)await pool.end();
  await admin.query('DROP DATABASE IF EXISTS "'+name+'" WITH (FORCE)').catch(()=>undefined);
  await admin.end();
 }
});
