import {randomUUID} from "node:crypto";
import type {PoolClient} from "pg";
import {DeliveryTripFault} from "./delivery_trip.ts";
import {reconcileAttempt,type AttemptInput,type DispatchSource} from "./delivery_attempt_contract.ts";
import {requireRevision,type MutationContext} from "./mutation.ts";
import {stockDecimalUnits as units,stockUnitsDecimal as decimal} from "./inventory.ts";

type Scope={branchId:string;warehouseId:string;tripId:string};
type Issue={dispatchId:string;sourceLine:number;orderLineNo:number;productId:string;
 productName:string;baseUnit:string;issuedBase:string;locationId:string|null;lotId:string|null};
type Stop={orderId:string;version:number;revision:number;customerId:string;
 customerName:string;documentNo:string;deliveryAddress:string;sequenceNo:number};
type Trip={id:string;status:string;revision:number;driverId:string|null;
 driverUserId:string|null;driverActive:boolean;driverEmployeeActive:boolean;
 warehouseId:string;tripNo:string};
const error=(code:string,status=409):never=>{throw new DeliveryTripFault(status,code);};
async function trip(db:PoolClient,c:MutationContext,s:Scope,lock=false):Promise<Trip>{
 const h=await db.query<Trip>(`SELECT t.id,t.status,t.revision::integer,t.trip_no AS "tripNo",
 t.driver_id AS "driverId",e.account_user_id AS "driverUserId",
 coalesce(d.active,false) AS "driverActive",coalesce(e.active,false) AS "driverEmployeeActive",
 t.warehouse_id AS "warehouseId"
 FROM delivery_trip t LEFT JOIN delivery_driver d ON d.installation_id=t.installation_id
  AND d.branch_id=t.branch_id AND d.id=t.driver_id
 LEFT JOIN org_employee e ON e.installation_id=d.installation_id
  AND e.branch_id=d.branch_id AND e.id=d.employee_id
 WHERE t.installation_id=$1 AND t.branch_id=$2 AND t.warehouse_id=$3 AND t.id=$4
 ${lock?"FOR UPDATE OF t":""}`,
 [c.installationId,s.branchId,s.warehouseId,s.tripId]);
 if(!h.rows[0])error("TRIP_NOT_FOUND",404);
 return h.rows[0]!;
}
async function stops(db:PoolClient,c:MutationContext,s:Scope):Promise<Stop[]>{
 return (await db.query<Stop>(`SELECT st.order_id AS "orderId",st.order_version AS version,
 st.sequence_no AS "sequenceNo",st.customer_id AS "customerId",
 st.customer_name AS "customerName",st.delivery_address AS "deliveryAddress",
 o.document_no AS "documentNo",o.revision::integer
 FROM delivery_trip_stop st JOIN sales_order o
 ON o.installation_id=st.installation_id AND o.branch_id=st.branch_id AND o.id=st.order_id
 WHERE st.installation_id=$1 AND st.branch_id=$2 AND st.trip_id=$3
 ORDER BY st.sequence_no,st.order_id`,
 [c.installationId,s.branchId,s.tripId])).rows;
}
async function issueRows(db:PoolClient,c:MutationContext,s:Scope,stop:Stop):Promise<Issue[]>{
 return (await db.query<Issue>(`SELECT l.dispatch_id AS "dispatchId",l.source_line AS "sourceLine",
 l.order_line_no AS "orderLineNo",l.product_id AS "productId",p.name AS "productName",
 p.base_unit AS "baseUnit",l.quantity_base::text AS "issuedBase",
 l.location_id AS "locationId",l.lot_id AS "lotId"
 FROM sales_trip_dispatch h JOIN sales_trip_dispatch_line l
 ON l.installation_id=h.installation_id AND l.branch_id=h.branch_id AND l.dispatch_id=h.id
 JOIN catalog_product p ON p.installation_id=l.installation_id
  AND p.branch_id=l.branch_id AND p.id=l.product_id
 JOIN inventory_ledger m ON m.installation_id=l.installation_id AND m.branch_id=l.branch_id
  AND m.warehouse_id=h.warehouse_id AND m.source_type='FULFILLMENT'
  AND m.kind='ISSUE' AND m.source_id=l.dispatch_id AND m.source_line=l.source_line
  AND m.product_id=l.product_id AND m.delta_base=-l.quantity_base
 WHERE h.installation_id=$1 AND h.branch_id=$2 AND h.warehouse_id=$3
 AND h.order_id=$4 AND h.version_no=$5
 ORDER BY l.dispatch_id,l.source_line`,
 [c.installationId,s.branchId,s.warehouseId,stop.orderId,stop.version])).rows;
}
async function totals(db:PoolClient,c:MutationContext,s:Scope,stop:Stop){
 const posted=await db.query<{dispatchId:string;sourceLine:number;quantity:string}>(`
 SELECT l.dispatch_id AS "dispatchId",l.source_line AS "sourceLine",
 sum(l.quantity_base)::text AS quantity FROM delivery_trip_attempt_line l
 JOIN delivery_trip_attempt h ON h.installation_id=l.installation_id
 AND h.branch_id=l.branch_id AND h.id=l.attempt_id
 WHERE h.installation_id=$1 AND h.branch_id=$2 AND h.trip_id=$3 AND h.order_id=$4
 GROUP BY l.dispatch_id,l.source_line`,[c.installationId,s.branchId,s.tripId,stop.orderId]);
 const returns=await db.query<{dispatchId:string;sourceLine:number;quantity:string}>(`
 SELECT l.dispatch_id AS "dispatchId",l.dispatch_source_line AS "sourceLine",
 sum(l.quantity_base)::text AS quantity FROM delivery_trip_return_line l
 JOIN delivery_trip_return h ON h.installation_id=l.installation_id
 AND h.branch_id=l.branch_id AND h.id=l.return_id
 WHERE h.installation_id=$1 AND h.branch_id=$2 AND h.trip_id=$3 AND h.order_id=$4
 GROUP BY l.dispatch_id,l.dispatch_source_line`,[c.installationId,s.branchId,s.tripId,stop.orderId]);
 const map=(rows:{dispatchId:string;sourceLine:number;quantity:string}[])=>
  new Map(rows.map(x=>[x.dispatchId+":"+x.sourceLine,units(x.quantity)]));
 return {delivered:map(posted.rows),returned:map(returns.rows)};
}
const issueKey=(x:{dispatchId:string;sourceLine:number})=>x.dispatchId+":"+x.sourceLine;
async function ledgerBalance(db:PoolClient,c:MutationContext,stop:Stop){
 const r=await db.query<{due:string;paid:string}>(`SELECT
 coalesce(sum(CASE WHEN kind='SALE' THEN amount ELSE 0 END),0)::text AS due,
 coalesce(-sum(CASE WHEN kind='PAYMENT' THEN amount ELSE 0 END),0)::text AS paid
 FROM customer_receivable_ledger WHERE installation_id=$1 AND branch_id=$2
 AND order_id=$3`,[c.installationId,c.payload&&typeof c.payload==="object"&&"branchId" in c.payload?
  String((c.payload as {branchId:string}).branchId):"",stop.orderId]);
 return {due:BigInt(r.rows[0]?.due??"0"),paid:BigInt(r.rows[0]?.paid??"0")};
}
async function status(db:PoolClient,c:MutationContext,s:Scope,stop:Stop,
 sources:Issue[],amountIncrement:bigint=0n){
 const {delivered,returned}=await totals(db,c,s,stop);
 let out=0n,received=0n,back=0n;
 for(const source of sources){
  const q=units(source.issuedBase),k=issueKey(source);
  out+=q;received+=delivered.get(k)??0n;back+=returned.get(k)??0n;
 }
 if(received+back>out)error("DELIVERY_RECONCILIATION_REQUIRED");
 const bill=await db.query<{due:string;paid:string}>(`SELECT
 coalesce(sum(CASE WHEN kind='SALE' THEN amount ELSE 0 END),0)::text AS due,
 coalesce(-sum(CASE WHEN kind='PAYMENT' THEN amount ELSE 0 END),0)::text AS paid
 FROM customer_receivable_ledger WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3`,
 [c.installationId,s.branchId,stop.orderId]);
 const due=BigInt(bill.rows[0]?.due??"0"),paid=BigInt(bill.rows[0]?.paid??"0");
 if(paid>due||due<0n)error("RECEIVABLE_RECONCILIATION_REQUIRED");
 const orderLines=await db.query<{lineNo:number;ordered:string}>(`
 SELECT l.line_no AS "lineNo",CASE WHEN l.pricing_engine='R1'
 THEN l.price_snapshot->>'normalizedBaseQuantity'
 WHEN l.unit_code=p.base_unit THEN l.quantity::text ELSE NULL END AS ordered
 FROM sales_order_line l JOIN catalog_product p
 ON p.installation_id=l.installation_id AND p.branch_id=l.branch_id AND p.id=l.product_id
 WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3 AND l.version_no=$4`,
 [c.installationId,s.branchId,stop.orderId,stop.version]);
 const byLine=new Map<number,bigint>();
 for(const source of sources)byLine.set(source.orderLineNo,
  (byLine.get(source.orderLineNo)??0n)+(delivered.get(issueKey(source))??0n));
 const allOrdered=orderLines.rows.length>0&&orderLines.rows.every(x=>
  x.ordered!==null&&byLine.get(x.lineNo)===units(x.ordered));
 const delivery=received===0n?(back===out&&out>0n?"RETURNED":"NOT_DISPATCHED"):
  allOrdered?"DELIVERED":"PARTIAL";
 const payment=due===0n?(received>0n?"PAID":"NOT_DUE"):
  paid===due?"PAID":"PARTIAL";
 const upd=await db.query<{revision:string}>(`UPDATE sales_order SET
 delivery_status=$4,payment_status=$5,revision=revision+1,updated_at=now()
 WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,
 [c.installationId,s.branchId,stop.orderId,delivery,payment]);
 return {revision:Number(upd.rows[0]!.revision),deliveryStatus:delivery,
  paymentStatus:payment,issued:decimal(out),delivered:decimal(received),
  returned:decimal(back),onVehicle:decimal(out-received-back),
  due:due.toString(),paid:paid.toString(),remaining:(due-paid).toString(),
  amountIncrement:amountIncrement.toString()};
}
async function requireStop(db:PoolClient,c:MutationContext,s:Scope,orderId:string){
 const st=(await stops(db,c,s)).find(x=>x.orderId===orderId);
 if(!st)error("TRIP_STOP_NOT_FOUND",404);
 const locked=await db.query<{revision:string}>(`SELECT revision::text FROM sales_order
 WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE`,
 [c.installationId,s.branchId,orderId]);
 if(!locked.rows[0])error("TRIP_STOP_NOT_FOUND",404);
 requireRevision(c.expectedRevision,Number(locked.rows[0]!.revision));
 return st!;
}
async function requireDeparted(db:PoolClient,c:MutationContext,s:Scope){
 const tr=await trip(db,c,s);
 if(tr.status!=="LOCKED")error("TRIP_NOT_LOCKED");
 const dep=await db.query(`SELECT 1 FROM delivery_trip_departure
 WHERE installation_id=$1 AND branch_id=$2 AND trip_id=$3`,
 [c.installationId,s.branchId,s.tripId]);
 if(!dep.rowCount)error("TRIP_NOT_DEPARTED");
 return tr;
}
export async function executeStart(db:PoolClient,c:MutationContext,s:Scope){
 const tr=await trip(db,c,s,true);
 requireRevision(c.expectedRevision,tr.revision);
 if(tr.status!=="LOCKED"||!tr.driverId||!tr.driverActive||!tr.driverEmployeeActive)
  error("TRIP_NOT_READY_TO_DEPART");
 const all=await stops(db,c,s);
 if(!all.length)error("TRIP_EMPTY");
 // Same order row lock used by T3-C dispatch; lock in deterministic order.
 for(const st of [...all].sort((a,b)=>a.orderId.localeCompare(b.orderId))){
  await db.query(`SELECT id FROM sales_order WHERE installation_id=$1 AND branch_id=$2
   AND id=$3 FOR UPDATE`,[c.installationId,s.branchId,st.orderId]);
 }
 for(const st of all)if(!(await issueRows(db,c,s,st)).length)
  error("TRIP_STOP_STOCK_NOT_DISPATCHED");
 const r=await db.query<{trip_id:string}>(`INSERT INTO delivery_trip_departure
 (installation_id,branch_id,trip_id,actor_id,request_id) VALUES($1,$2,$3,$4,$5)
 RETURNING trip_id`,[c.installationId,s.branchId,s.tripId,c.actorId,c.requestId]);
 return {status:201,body:{tripId:r.rows[0]!.trip_id,status:"DEPARTED",stopCount:all.length}};
}
export async function executionRead(db:PoolClient,c:MutationContext,s:Scope){
 const tr=await trip(db,c,s);
 const departure=await db.query<{departedAt:string}>(`SELECT departed_at::text AS "departedAt"
 FROM delivery_trip_departure WHERE installation_id=$1 AND branch_id=$2 AND trip_id=$3`,
 [c.installationId,s.branchId,s.tripId]);
 const all=await stops(db,c,s);
 const out=[];
 for(const st of all){
  const sources=await issueRows(db,c,s,st),prev=await totals(db,c,s,st);
  const attempts=await db.query(`SELECT id,attempt_no AS "attemptNo",result,reason_code AS "reasonCode",
 rescheduled_for AS "rescheduledFor",occurred_at AS "occurredAt",
 amount::text FROM delivery_trip_attempt
 WHERE installation_id=$1 AND branch_id=$2 AND trip_id=$3 AND order_id=$4
 ORDER BY attempt_no`,[c.installationId,s.branchId,s.tripId,st.orderId]);
  const rows=sources.map(x=>{
   const d=prev.delivered.get(issueKey(x))??0n,r=prev.returned.get(issueKey(x))??0n;
   const q=units(x.issuedBase);
   return {...x,deliveredBase:decimal(d),returnedBase:decimal(r),
    onVehicleBase:decimal(q-d-r)};
  });
  const due=await db.query<{due:string;paid:string}>(`SELECT
   coalesce(sum(CASE WHEN kind='SALE' THEN amount ELSE 0 END),0)::text AS due,
   coalesce(-sum(CASE WHEN kind='PAYMENT' THEN amount ELSE 0 END),0)::text AS paid
   FROM customer_receivable_ledger WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3`,
   [c.installationId,s.branchId,st.orderId]);
  const balance=BigInt(due.rows[0]?.due??"0")-BigInt(due.rows[0]?.paid??"0");
  out.push({...st,lines:rows,attempts:attempts.rows,
   due:due.rows[0]?.due??"0",paid:due.rows[0]?.paid??"0",remaining:balance.toString()});
 }
 const money=await db.query(`SELECT c.id,c.order_id AS "orderId",c.amount::text,
 p.method,coalesce(sum(l.amount),0)::text AS handed
 FROM delivery_cod_collection c JOIN payment_receipt p
 ON p.installation_id=c.installation_id AND p.branch_id=c.branch_id AND p.id=c.receipt_id
 LEFT JOIN delivery_cod_handover_line l ON l.installation_id=c.installation_id
 AND l.branch_id=c.branch_id AND l.collection_id=c.id
 WHERE c.installation_id=$1 AND c.branch_id=$2 AND c.trip_id=$3
 GROUP BY c.id,c.order_id,c.amount,c.collected_at,p.method ORDER BY c.collected_at,c.id`,[c.installationId,s.branchId,s.tripId]);
 return {tripId:s.tripId,tripNo:tr.tripNo,revision:tr.revision,
  status:departure.rowCount?"DEPARTED":tr.status,driverId:tr.driverId,
  stops:out,collections:money.rows};
}
async function orderPriceIncrement(db:PoolClient,c:MutationContext,s:Scope,stop:Stop,
 sources:Issue[],fresh:Map<string,bigint>,prior:Map<string,bigint>){
 const lines=await db.query<{lineNo:number;ordered:string|null;total:string}>(`SELECT
 l.line_no AS "lineNo",CASE WHEN l.pricing_engine='R1'
 THEN l.price_snapshot->>'normalizedBaseQuantity'
 WHEN l.unit_code=p.base_unit THEN l.quantity::text ELSE NULL END AS ordered,
 l.line_total::text AS total FROM sales_order_line l JOIN catalog_product p
 ON p.installation_id=l.installation_id AND p.branch_id=l.branch_id AND p.id=l.product_id
 WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3 AND l.version_no=$4`,
 [c.installationId,s.branchId,stop.orderId,stop.version]);
 const agg=new Map<number,{prior:bigint;now:bigint}>();
 for(const source of sources){
  const entry=agg.get(source.orderLineNo)??{prior:0n,now:0n},k=issueKey(source);
  entry.prior+=prior.get(k)??0n;entry.now+=fresh.get(k)??0n;
  agg.set(source.orderLineNo,entry);
 }
 if(!lines.rows.length)error("ORDER_LINES_REQUIRED");
 let amount=0n;
 for(const line of lines.rows){
  if(!line.ordered)error("BASE_QUANTITY_SNAPSHOT_REQUIRED");
  const ordered=units(line.ordered!);if(ordered<=0n)error("BASE_QUANTITY_SNAPSHOT_REQUIRED");
  const nums=agg.get(line.lineNo)??{prior:0n,now:0n};
  if(nums.prior+nums.now>ordered)error("DELIVERY_EXCEEDS_ORDER");
  const total=BigInt(line.total);
  // Cumulative prorate prevents rounding drift over repeated partial deliveries.
  amount+=(total*(nums.prior+nums.now)+ordered/2n)/ordered-
   (total*nums.prior+ordered/2n)/ordered;
 }
 return amount;
}
export async function executeAttempt(db:PoolClient,c:MutationContext,s:Scope,
 orderId:string,input:AttemptInput){
 const tr=await requireDeparted(db,c,s);
 if(!tr.driverActive||!tr.driverEmployeeActive||tr.driverUserId!==c.actorId)
  error("DRIVER_ACCOUNT_NOT_ASSIGNED",403);
 const stop=await requireStop(db,c,s,orderId);
 const all=await issueRows(db,c,s,stop);
 const prev=await totals(db,c,s,stop);
 const source=all.filter(x=>units(x.issuedBase)-
  (prev.delivered.get(issueKey(x))??0n)-(prev.returned.get(issueKey(x))??0n)>0n)
  .map(x=>({dispatchId:x.dispatchId,sourceLine:x.sourceLine,
  issuedBase:decimal(units(x.issuedBase)-(prev.delivered.get(issueKey(x))??0n)-
   (prev.returned.get(issueKey(x))??0n)),
  baseUnitAllowsFractional:true} satisfies DispatchSource));
 const earlier=await db.query<{attemptNo:number;result:string;rescheduledFor:Date|null}>(`
 SELECT attempt_no AS "attemptNo",result,rescheduled_for AS "rescheduledFor"
 FROM delivery_trip_attempt WHERE installation_id=$1 AND branch_id=$2
 AND trip_id=$3 AND order_id=$4 ORDER BY attempt_no DESC LIMIT 1`,
 [c.installationId,s.branchId,s.tripId,orderId]);
 const latest=earlier.rows[0];
 if(latest?.result==="DELIVERED_FULL")error("TRIP_STOP_DELIVERED_ALREADY");
 if(latest?.result==="RESCHEDULED"&&latest.rescheduledFor&&
  latest.rescheduledFor.getTime()>Date.now())error("TRIP_STOP_RESCHEDULED_FOR_LATER");
 const result=reconcileAttempt(source,input,new Date().toISOString());
 const current=new Map(result.lines.map(x=>[issueKey(x),units(x.deliveredBase)]));
 const amount=await orderPriceIncrement(db,c,s,stop,all,current,prev.delivered);
 const attemptId=randomUUID(),no=(latest?.attemptNo??0)+1;
 await db.query(`INSERT INTO delivery_trip_attempt
 (installation_id,branch_id,id,trip_id,order_id,attempt_no,result,reason_code,
 rescheduled_for,amount,actor_id,request_id)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::numeric,$11,$12)`,
 [c.installationId,s.branchId,attemptId,s.tripId,orderId,no,result.result,
 result.reasonCode??null,result.rescheduledFor??null,amount.toString(),c.actorId,c.requestId]);
 for(const [i,line] of result.lines.entries()){
  await db.query(`INSERT INTO delivery_trip_attempt_line
 (installation_id,branch_id,attempt_id,dispatch_id,source_line,quantity_base)
 VALUES($1,$2,$3,$4,$5,$6::numeric)`,
 [c.installationId,s.branchId,attemptId,line.dispatchId,line.sourceLine,line.deliveredBase]);
 }
 if(result.hasDelivered){
  // Canonical shared fulfillment header; TRIP never creates a parallel AR ledger.
  await db.query(`INSERT INTO sales_fulfillment
 (installation_id,branch_id,order_id,version_no,warehouse_id,mode,actor_id,request_id)
 VALUES($1,$2,$3,$4,$5,'TRIP',$6,$7)
 ON CONFLICT (installation_id,branch_id,order_id) DO NOTHING`,
 [c.installationId,s.branchId,orderId,stop.version,s.warehouseId,c.actorId,c.requestId]);
 }
 if(amount>0n)await db.query(`INSERT INTO customer_receivable_ledger
 (installation_id,branch_id,customer_id,order_id,kind,source_id,amount,actor_id,request_id)
 VALUES($1,$2,$3,$4,'SALE',$5,$6::numeric,$7,$8)`,
 [c.installationId,s.branchId,stop.customerId,orderId,attemptId,amount.toString(),c.actorId,c.requestId]);
 const snapshot=await status(db,c,s,stop,all,amount);
 return {status:201,body:{id:attemptId,orderId,attemptNo:no,result:result.result,
  ...snapshot,lines:result.lines}};
}
export async function executeReturn(db:PoolClient,c:MutationContext,s:Scope,
 orderId:string,reason:string,input:{dispatchId:string;sourceLine:number;quantityBase:string}[]){
 await requireDeparted(db,c,s);
 const stop=await requireStop(db,c,s,orderId);
 if(!reason||reason.trim().length<3||reason.length>500)error("RETURN_REASON_REQUIRED",400);
 if(!input.length||input.length>1000)error("RETURN_LINES_REQUIRED",400);
 const sources=await issueRows(db,c,s,stop),prev=await totals(db,c,s,stop);
 const byKey=new Map(sources.map(x=>[issueKey(x),x]));
 const seen=new Set<string>();
 const retId=randomUUID();
 await db.query(`INSERT INTO delivery_trip_return
 (installation_id,branch_id,id,trip_id,order_id,reason,actor_id,request_id)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,
 [c.installationId,s.branchId,retId,s.tripId,orderId,reason.trim(),c.actorId,c.requestId]);
 for(const [i,line] of input.entries()){
  const k=issueKey(line),src=byKey.get(k);
  if(!src||seen.has(k))error("RETURN_SOURCE_INVALID",400);
  seen.add(k);
  const qty=units(line.quantityBase);
  if(qty<=0n||qty>units(src!.issuedBase)-
   (prev.delivered.get(k)??0n)-(prev.returned.get(k)??0n))
   error("RETURN_EXCEEDS_ON_VEHICLE");
  await db.query(`INSERT INTO delivery_trip_return_line
  (installation_id,branch_id,return_id,source_line,dispatch_id,dispatch_source_line,
  product_id,location_id,lot_id,quantity_base)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::numeric)`,
  [c.installationId,s.branchId,retId,i+1,src!.dispatchId,src!.sourceLine,
   src!.productId,src!.locationId,src!.lotId,line.quantityBase]);
  await db.query(`INSERT INTO inventory_ledger
  (installation_id,branch_id,warehouse_id,product_id,kind,source_type,source_id,
  source_line,delta_base,actor_id,request_id)
  VALUES($1,$2,$3,$4,'RETURN','FULFILLMENT',$5,$6,$7::numeric,$8,$9)`,
  [c.installationId,s.branchId,s.warehouseId,src!.productId,retId,i+1,
   line.quantityBase,c.actorId,c.requestId]);
 }
 const snap=await status(db,c,s,stop,sources);
 return {status:201,body:{id:retId,orderId,...snap,returnedLines:input}};
}
export async function executeCollect(db:PoolClient,c:MutationContext,s:Scope,
 orderId:string,amountText:string,method:"CASH"|"BANK_TRANSFER"){
 const tr=await requireDeparted(db,c,s);
 if(!tr.driverActive||!tr.driverEmployeeActive||tr.driverUserId!==c.actorId)
  error("DRIVER_ACCOUNT_NOT_ASSIGNED",403);
 const stop=await requireStop(db,c,s,orderId);
 const sources=await issueRows(db,c,s,stop);
 if(!/^(0|[1-9][0-9]{0,15})$/.test(amountText))error("INVALID_PAYMENT_AMOUNT",400);
 if(method!=="CASH"&&method!=="BANK_TRANSFER")error("INVALID_PAYMENT_METHOD",400);
 const amount=BigInt(amountText);
 const balance=await ledgerBalance(db,{...c,payload:{branchId:s.branchId}},stop);
 const remaining=balance.due-balance.paid;
 if(remaining<0n)error("RECEIVABLE_RECONCILIATION_REQUIRED");
 if(amount>remaining)error("PAYMENT_EXCEEDS_REMAINING");
 let receiptId:string|null=null,collectionId:string|null=null;
 if(amount>0n){
  const f=await db.query<{id:string}>(`SELECT id FROM sales_fulfillment
  WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND mode='TRIP'`,
  [c.installationId,s.branchId,orderId]);
  if(!f.rows[0])error("TRIP_DELIVERY_NOT_COMPLETED");
  const sales=await db.query<{id:string;due:string;paid:string}>(`
  SELECT l.id,l.amount::text AS due,coalesce(sum(a.allocated),0)::text AS paid
  FROM customer_receivable_ledger l LEFT JOIN payment_allocation a
  ON a.installation_id=l.installation_id AND a.branch_id=l.branch_id AND a.sale_ledger_id=l.id
  WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3 AND l.kind='SALE'
  GROUP BY l.id ORDER BY l.id FOR UPDATE OF l`,[c.installationId,s.branchId,orderId]);
  // PostgreSQL rejects FOR UPDATE on GROUP BY; source order row was already
  // locked, and receipt allocation guard locks individual SALE rows at COMMIT.
  const receipt=await db.query<{id:string}>(`INSERT INTO payment_receipt
  (installation_id,branch_id,checkout_id,fulfillment_id,order_id,method,amount,actor_id,request_id)
  VALUES($1,$2,NULL,$3,$4,$5,$6::numeric,$7,$8) RETURNING id`,
  [c.installationId,s.branchId,f.rows[0]!.id,orderId,method,amountText,c.actorId,c.requestId]);
  receiptId=receipt.rows[0]!.id;
  let allocate=amount;
  for(const row of sales.rows){
   const open=BigInt(row.due)-BigInt(row.paid);
   if(open<=0n)continue;
   const part=open<allocate?open:allocate;
   await db.query(`INSERT INTO payment_allocation
   (installation_id,branch_id,receipt_id,sale_ledger_id,allocated)
   VALUES($1,$2,$3,$4,$5::numeric)`,
   [c.installationId,s.branchId,receiptId,row.id,part.toString()]);
   allocate-=part;if(allocate===0n)break;
  }
  if(allocate!==0n)error("RECEIVABLE_RECONCILIATION_REQUIRED");
  await db.query(`INSERT INTO customer_receivable_ledger
   (installation_id,branch_id,customer_id,order_id,kind,source_id,amount,actor_id,request_id)
   VALUES($1,$2,$3,$4,'PAYMENT',$5,-$6::numeric,$7,$8)`,
   [c.installationId,s.branchId,stop.customerId,orderId,receiptId,amountText,c.actorId,c.requestId]);
  if(method==="CASH"){
   const coll=await db.query<{id:string}>(`INSERT INTO delivery_cod_collection
   (installation_id,branch_id,trip_id,order_id,receipt_id,driver_id,amount,actor_id,request_id)
   VALUES($1,$2,$3,$4,$5,$6,$7::numeric,$8,$9) RETURNING id`,
   [c.installationId,s.branchId,s.tripId,orderId,receiptId,tr.driverId,amountText,c.actorId,c.requestId]);
   collectionId=coll.rows[0]!.id;
  }
 }
 const snap=await status(db,c,s,stop,sources);
 return {status:amount===0n?200:201,body:{receiptId,collectionId,orderId,
  amount:amountText,recorded:amount>0n,debtRecorded:amount===0n,...snap}};
}
export async function executeHandover(db:PoolClient,c:MutationContext,s:Scope,
 input:{collectionId:string;amount:string}[]){
 const tr=await requireDeparted(db,c,s);
 if(!tr.driverId||!input.length||input.length>200)error("COD_HANDOVER_INVALID",400);
 const id=randomUUID(),seen=new Set<string>();
 await db.query(`INSERT INTO delivery_cod_handover
 (installation_id,branch_id,id,trip_id,driver_id,receiver_id,actor_id,request_id)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,
 [c.installationId,s.branchId,id,s.tripId,tr.driverId,c.actorId,c.actorId,c.requestId]);
 let sum=0n;
 for(const item of input){
  if(seen.has(item.collectionId)||!/^[0-9]+$/.test(item.amount)||BigInt(item.amount)<=0n)
   error("COD_HANDOVER_INVALID",400);
  seen.add(item.collectionId);sum+=BigInt(item.amount);
  const row=await db.query<{amount:string;handed:string}>(`
  SELECT c.amount::text,coalesce((SELECT sum(amount) FROM delivery_cod_handover_line h
  WHERE h.installation_id=c.installation_id AND h.branch_id=c.branch_id
  AND h.collection_id=c.id),0)::text AS handed
  FROM delivery_cod_collection c WHERE c.installation_id=$1 AND c.branch_id=$2
  AND c.trip_id=$3 AND c.driver_id=$4 AND c.id=$5 FOR UPDATE OF c`,
  [c.installationId,s.branchId,s.tripId,tr.driverId,item.collectionId]);
  if(!row.rows[0]||BigInt(row.rows[0]!.amount)-BigInt(row.rows[0]!.handed)<BigInt(item.amount))
   error("COD_HANDOVER_EXCEEDS_CUSTODY");
  await db.query(`INSERT INTO delivery_cod_handover_line
   (installation_id,branch_id,handover_id,collection_id,amount)
   VALUES($1,$2,$3,$4,$5::numeric)`,
   [c.installationId,s.branchId,id,item.collectionId,item.amount]);
 }
 return {status:201,body:{id,tripId:s.tripId,amount:sum.toString(),receivedBy:c.actorId}};
}
