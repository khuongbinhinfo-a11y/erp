import {randomUUID} from "node:crypto";
import type {PoolClient} from "pg";
import {stockDecimalUnits,stockUnitsDecimal} from "./inventory.ts";
import {requireRevision,type MutationContext} from "./mutation.ts";

export class ExecutionFault extends Error {
 readonly httpStatus:number;
 readonly code:string;
 constructor(httpStatus:number,code:string){super(code);this.httpStatus=httpStatus;this.code=code;}
}
export type ExecutionScope={branchId:string;warehouseId:string;orderId:string;version:number};
export type ReturnLine={issueId:string;sourceLine:number;quantityBase:string};
export type ManualReturnInput=ExecutionScope&{reason:string;lines:ReturnLine[]};
export type ManualPaymentInput=Omit<ExecutionScope,"version">&{amount:string;method:"CASH"|"BANK_TRANSFER"};
type RawOrder={
 status:string;source_type:string;current_version:number;revision:string;
 delivery_choice:string;warehouse_id:string;delivery_status:string;customer_id:string;
};
type RawLine={line_no:number;product_id:string;pricing_engine:string;
 price_snapshot:{normalizedBaseQuantity?:unknown}|null;
 quantity:string;unit_code:string;base_unit:string;line_total:string;};
type LineFact={lineNo:number;productId:string;orderedBase:string;issuedBase:string;
 returnedBase:string;deliverableBase:string;lineTotal:string;deliveryAmount:string};
const units=(v:string)=>stockDecimalUnits(v);
const decimal=(n:bigint)=>stockUnitsDecimal(n);

export async function requireT5a(db:PoolClient){
 const r=await db.query<{ok:boolean}>(`SELECT EXISTS(SELECT 1 FROM schema_migrations
  WHERE version='0026_t5a_sales_execution.sql') AS ok`);
 if(!r.rows[0]?.ok)throw new ExecutionFault(503,"T5A_MIGRATION_REQUIRED");
}
async function warehouseLock(db:PoolClient,c:MutationContext,scope:ExecutionScope){
 const r=await db.query(`SELECT id FROM warehouse
  WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE`,
  [c.installationId,scope.branchId,scope.warehouseId]);
 if(!r.rowCount)throw new ExecutionFault(404,"WAREHOUSE_NOT_FOUND");
}
async function manualOrder(db:PoolClient,c:MutationContext,s:ExecutionScope,mutate:boolean){
 const t=c.installationId,b=s.branchId;
 const result=await db.query<RawOrder>(`SELECT o.status,o.source_type,o.current_version,
  o.revision::text,o.delivery_status,o.customer_id,
  v.delivery_choice,v.warehouse_id
  FROM sales_order o JOIN sales_order_version_context v
   ON v.installation_id=o.installation_id AND v.branch_id=o.branch_id
   AND v.order_id=o.id AND v.version_no=o.current_version
  WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$3
  ${mutate?"FOR UPDATE OF o":""}`,[t,b,s.orderId]);
 const o=result.rows[0];
 if(!o||o.status!=="CONFIRMED"||o.source_type==="RETAIL"||
  o.delivery_choice!=="MANUAL"||o.warehouse_id!==s.warehouseId||
  (s.version>0&&o.current_version!==s.version))
  throw new ExecutionFault(409,"CONFIRMED_MANUAL_ORDER_REQUIRED");
 if(mutate)requireRevision(c.expectedRevision,Number(o.revision));
 return o;
}
async function baseFacts(db:PoolClient,t:string,b:string,s:ExecutionScope){
 const rows=await db.query<RawLine>(`SELECT l.line_no,l.product_id,l.pricing_engine,
  l.price_snapshot,l.quantity::text,l.unit_code,p.base_unit,l.line_total::text
  FROM sales_order_line l JOIN catalog_product p
   ON p.installation_id=l.installation_id AND p.branch_id=l.branch_id
   AND p.id=l.product_id
  WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3
   AND l.version_no=$4 ORDER BY l.line_no`,[t,b,s.orderId,s.version]);
 const issues=await db.query<{line_no:number;quantity:string}>(`
  SELECT l.order_line_no AS line_no,sum(l.quantity_base)::text AS quantity
  FROM sales_direct_issue d JOIN sales_direct_issue_line l
   ON l.installation_id=d.installation_id AND l.branch_id=d.branch_id
   AND l.issue_id=d.id
  WHERE d.installation_id=$1 AND d.branch_id=$2 AND d.order_id=$3
   AND d.version_no=$4 AND d.warehouse_id=$5
  GROUP BY l.order_line_no`,[t,b,s.orderId,s.version,s.warehouseId]);
 const returns=await db.query<{line_no:number;quantity:string}>(`
  SELECT l.order_line_no AS line_no,sum(l.quantity_base)::text AS quantity
  FROM sales_manual_return h JOIN sales_manual_return_line l
   ON l.installation_id=h.installation_id AND l.branch_id=h.branch_id
   AND l.return_id=h.id
  WHERE h.installation_id=$1 AND h.branch_id=$2 AND h.order_id=$3
   AND h.version_no=$4 AND h.warehouse_id=$5
  GROUP BY l.order_line_no`,[t,b,s.orderId,s.version,s.warehouseId]);
 const issued=new Map(issues.rows.map(x=>[x.line_no,units(x.quantity)]));
 const returned=new Map(returns.rows.map(x=>[x.line_no,units(x.quantity)]));
 const lines:LineFact[]=[];
 let total=0n,full=0n,delivered=0n;
 for(const l of rows.rows){
  const raw=l.pricing_engine==="R1"?l.price_snapshot?.normalizedBaseQuantity:
   l.unit_code===l.base_unit?l.quantity:null;
  if(typeof raw!=="string"||!raw||!/^(0|[1-9][0-9]*)(?:\.[0-9]{1,6})?$/.test(raw))
   throw new ExecutionFault(409,"BASE_QUANTITY_SNAPSHOT_REQUIRED");
  const ordered=units(raw),out=issued.get(l.line_no)??0n,back=returned.get(l.line_no)??0n;
  if(ordered<=0n||out<back||out>ordered)
   throw new ExecutionFault(409,"ISSUE_RETURN_RECONCILIATION_REQUIRED");
  const net=out-back,value=BigInt(l.line_total);
  const allocated=net===ordered?value:(value*net+ordered/2n)/ordered;
  total+=allocated;full+=value;delivered+=net;
  lines.push({lineNo:l.line_no,productId:l.product_id,orderedBase:decimal(ordered),
   issuedBase:decimal(out),returnedBase:decimal(back),deliverableBase:decimal(net),
   lineTotal:value.toString(),deliveryAmount:allocated.toString()});
 }
 return {lines,total:total.toString(),full:full.toString(),hasDelivery:delivered>0n,
  isFull:lines.length>0&&lines.every(x=>units(x.deliverableBase)===units(x.orderedBase))};
}
export async function executionRead(db:PoolClient,c:MutationContext,s:ExecutionScope){
 await requireT5a(db);
 const o=await manualOrder(db,c,s,false);
 const scope={...s,version:o.current_version};
 const facts=await baseFacts(db,c.installationId,s.branchId,scope);
 const sale=await db.query<{id:string;amount:string}>(`
  SELECT id,amount::text FROM customer_receivable_ledger
  WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3
   AND kind='SALE' ORDER BY posted_at,id`,
  [c.installationId,s.branchId,s.orderId]);
 const payment=await db.query<{paid:string}>(`
  SELECT coalesce(-sum(amount),0)::text AS paid FROM customer_receivable_ledger
  WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND kind='PAYMENT'`,
  [c.installationId,s.branchId,s.orderId]);
 const total=sale.rows.reduce((a,x)=>a+BigInt(x.amount),0n);
 const paid=BigInt(payment.rows[0]?.paid??"0");
 const deliver=await db.query<{id:string;completed_at:Date}>(`
  SELECT id,completed_at FROM sales_fulfillment
  WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND mode='MANUAL'`,
  [c.installationId,s.branchId,s.orderId]);
 const sources=await db.query(`SELECT d.id AS "issueId",l.source_line AS "sourceLine",
  l.order_line_no AS "lineNo",l.product_id AS "productId",
  l.quantity_base::text AS "quantityBase",l.location_id AS "locationId",
  l.lot_id AS "lotId",
  (l.quantity_base-coalesce((
   SELECT sum(r.quantity_base) FROM sales_manual_return_line r
   WHERE r.installation_id=l.installation_id AND r.branch_id=l.branch_id
    AND r.issue_id=l.issue_id AND r.issue_source_line=l.source_line
  ),0))::text AS "returnableBase"
  FROM sales_direct_issue d JOIN sales_direct_issue_line l
   ON l.installation_id=d.installation_id AND l.branch_id=d.branch_id AND l.issue_id=d.id
  WHERE d.installation_id=$1 AND d.branch_id=$2 AND d.order_id=$3
   AND d.version_no=$4 AND d.warehouse_id=$5
  ORDER BY d.issued_at,l.source_line LIMIT 500`,
  [c.installationId,s.branchId,s.orderId,scope.version,s.warehouseId]);
 return {orderId:s.orderId,version:scope.version,revision:Number(o.revision),
  deliveryStatus:o.delivery_status,completed:deliver.rowCount!==0,
  fulfillmentId:deliver.rows[0]?.id??null,lines:facts.lines,
  expectedDeliveryTotal:facts.total,fullOrderLineTotal:facts.full,
  hasIssuedDelivery:facts.hasDelivery,isFullDelivery:facts.isFull,
  grandTotal:total.toString(),paid:paid.toString(),
  remaining:(total-paid).toString(),sources:sources.rows};
}
export async function returnManual(db:PoolClient,c:MutationContext,s:ManualReturnInput){
 await requireT5a(db);await warehouseLock(db,c,s);
 const o=await manualOrder(db,c,s,true);
 if(o.delivery_status!=="NOT_DISPATCHED"||
  (await db.query(`SELECT 1 FROM sales_fulfillment WHERE
   installation_id=$1 AND branch_id=$2 AND order_id=$3`,
   [c.installationId,s.branchId,s.orderId])).rowCount)
  throw new ExecutionFault(409,"DELIVERY_ALREADY_COMPLETED");
 const rid=randomUUID();
 await db.query(`INSERT INTO sales_manual_return
  (installation_id,branch_id,id,order_id,version_no,warehouse_id,reason,actor_id,request_id)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
  [c.installationId,s.branchId,rid,s.orderId,s.version,s.warehouseId,
   s.reason,c.actorId,c.requestId]);
 let seq=0;
 for(const line of s.lines){
  seq++;
  const q=units(line.quantityBase);
  if(q<=0n)throw new ExecutionFault(400,"INVALID_RETURN_QUANTITY");
  const issued=await db.query<{order_line_no:number;product_id:string;
   location_id:string|null;lot_id:string|null}>(`SELECT l.order_line_no,l.product_id,
   l.location_id,l.lot_id FROM sales_direct_issue_line l
   JOIN sales_direct_issue h ON h.installation_id=l.installation_id
    AND h.branch_id=l.branch_id AND h.id=l.issue_id
   WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.issue_id=$3
    AND l.source_line=$4 AND h.order_id=$5 AND h.version_no=$6
    AND h.warehouse_id=$7`,
   [c.installationId,s.branchId,line.issueId,line.sourceLine,
    s.orderId,s.version,s.warehouseId]);
  const src=issued.rows[0];
  if(!src)throw new ExecutionFault(409,"ISSUE_LINE_NOT_FOUND");
  await db.query(`INSERT INTO sales_manual_return_line
   (installation_id,branch_id,return_id,source_line,issue_id,issue_source_line,
    order_line_no,product_id,quantity_base,location_id,lot_id)
   VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::numeric,$10,$11)`,
   [c.installationId,s.branchId,rid,seq,line.issueId,line.sourceLine,
    src.order_line_no,src.product_id,line.quantityBase,src.location_id,src.lot_id]);
  await db.query(`INSERT INTO inventory_ledger
   (installation_id,branch_id,warehouse_id,product_id,kind,source_type,source_id,
    source_line,delta_base,actor_id,request_id)
   VALUES($1,$2,$3,$4,'RETURN','FULFILLMENT',$5,$6,$7::numeric,$8,$9)`,
   [c.installationId,s.branchId,s.warehouseId,src.product_id,rid,seq,
    line.quantityBase,c.actorId,c.requestId]);
 }
 const update=await db.query<{revision:string}>(`
  UPDATE sales_order SET fulfillment_status='PARTIAL',revision=revision+1,
   updated_at=now() WHERE installation_id=$1 AND branch_id=$2 AND id=$3
  RETURNING revision::text`,[c.installationId,s.branchId,s.orderId]);
 const facts=await baseFacts(db,c.installationId,s.branchId,s);
 return {status:201,body:{id:rid,orderId:s.orderId,revision:Number(update.rows[0]!.revision),
  returnedLines:s.lines.length,remainingIssued:facts.lines,inventoryPosted:true,
  receivablePosted:false,deliveryCompleted:false}};
}
export async function completeManual(db:PoolClient,c:MutationContext,s:ExecutionScope){
 await requireT5a(db);
 const o=await manualOrder(db,c,s,true);
 if(o.delivery_status!=="NOT_DISPATCHED")throw new ExecutionFault(409,"DELIVERY_ALREADY_COMPLETED");
 const prior=await db.query(`SELECT 1 FROM sales_fulfillment WHERE
  installation_id=$1 AND branch_id=$2 AND order_id=$3`,
  [c.installationId,s.branchId,s.orderId]);
 if(prior.rowCount)throw new ExecutionFault(409,"DELIVERY_ALREADY_COMPLETED");
 const facts=await baseFacts(db,c.installationId,s.branchId,s);
 if(!facts.hasDelivery)throw new ExecutionFault(409,"NO_ISSUED_GOODS_TO_DELIVER");
 const id=randomUUID(),t=c.installationId,b=s.branchId;
 await db.query(`INSERT INTO sales_fulfillment
  (installation_id,branch_id,id,order_id,version_no,warehouse_id,mode,
   actor_id,request_id)
  VALUES($1,$2,$3,$4,$5,$6,'MANUAL',$7,$8)`,
  [t,b,id,s.orderId,s.version,s.warehouseId,c.actorId,c.requestId]);
 for(const l of facts.lines){
  await db.query(`INSERT INTO sales_manual_delivery_line
   (installation_id,branch_id,fulfillment_id,order_line_no,product_id,
    ordered_base,issued_base,returned_base,delivered_base,amount)
   VALUES($1,$2,$3,$4,$5,$6::numeric,$7::numeric,$8::numeric,$9::numeric,$10::numeric)`,
   [t,b,id,l.lineNo,l.productId,l.orderedBase,l.issuedBase,
    l.returnedBase,l.deliverableBase,l.deliveryAmount]);
 }
 if(BigInt(facts.total)>0n){
  await db.query(`INSERT INTO customer_receivable_ledger
   (installation_id,branch_id,customer_id,order_id,kind,source_id,amount,actor_id,request_id)
   VALUES($1,$2,$3,$4,'SALE',$5,$6::numeric,$7,$8)`,
   [t,b,o.customer_id,s.orderId,id,facts.total,c.actorId,c.requestId]);
 }
 const update=await db.query<{revision:string}>(`UPDATE sales_order SET
  fulfillment_status='COMPLETED',delivery_status=$4,payment_status=$5,
  revision=revision+1,updated_at=now() WHERE installation_id=$1 AND branch_id=$2 AND id=$3
  RETURNING revision::text`,
  [t,b,s.orderId,facts.isFull?"DELIVERED":"PARTIAL",
   BigInt(facts.total)===0n?"PAID":"PARTIAL"]);
 return {status:201,body:{id,orderId:s.orderId,revision:Number(update.rows[0]!.revision),
  grandTotal:facts.total,paid:"0",remaining:facts.total,
  deliveryStatus:facts.isFull?"DELIVERED":"PARTIAL",
  fulfillmentStatus:"COMPLETED",paymentStatus:BigInt(facts.total)===0n?"PAID":"PARTIAL",
  inventoryPosted:false,receivablePosted:BigInt(facts.total)>0n,
  deliveredLines:facts.lines}};
}
export async function payManual(db:PoolClient,c:MutationContext,s:ManualPaymentInput){
 await requireT5a(db);
 const queryScope={...s,version:0};
 const o=await manualOrder(db,c,queryScope,true);
 const t=c.installationId,b=s.branchId,orderId=s.orderId;
 const sale=await db.query<{id:string;amount:string}>(`
  SELECT l.id,l.amount::text FROM customer_receivable_ledger l
  JOIN sales_fulfillment f ON f.installation_id=l.installation_id
   AND f.branch_id=l.branch_id AND f.id=l.source_id AND f.mode='MANUAL'
  WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3
   AND l.kind='SALE' FOR UPDATE OF l`,[t,b,orderId]);
 const fulfillment=await db.query<{id:string}>(`
  SELECT id FROM sales_fulfillment WHERE installation_id=$1
   AND branch_id=$2 AND order_id=$3 AND mode='MANUAL'`,[t,b,orderId]);
 if(!fulfillment.rows[0])throw new ExecutionFault(409,"MANUAL_DELIVERY_NOT_COMPLETED");
 const due=BigInt(sale.rows[0]?.amount??"0");
 const paidRow=await db.query<{paid:string}>(`
  SELECT coalesce(-sum(amount),0)::text AS paid FROM customer_receivable_ledger
  WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND kind='PAYMENT'`,
  [t,b,orderId]);
 const paid=BigInt(paidRow.rows[0]?.paid??"0"),balance=due-paid;
 const amount=BigInt(s.amount);
 if(balance<0n)throw new ExecutionFault(409,"RECEIVABLE_RECONCILIATION_REQUIRED");
 if(amount>balance)throw new ExecutionFault(409,"PAYMENT_EXCEEDS_REMAINING");
 let receiptId:string|null=null;
 if(amount>0n){
  const saleRow=sale.rows[0];
  if(!saleRow)throw new ExecutionFault(409,"SALE_LEDGER_MISSING");
  const receipt=await db.query<{id:string}>(`INSERT INTO payment_receipt
   (installation_id,branch_id,checkout_id,fulfillment_id,order_id,method,amount,actor_id,request_id)
   VALUES($1,$2,NULL,$3,$4,$5,$6::numeric,$7,$8) RETURNING id`,
   [t,b,fulfillment.rows[0]!.id,orderId,s.method,s.amount,c.actorId,c.requestId]);
  receiptId=receipt.rows[0]!.id;
  await db.query(`INSERT INTO payment_allocation
   (installation_id,branch_id,receipt_id,sale_ledger_id,allocated)
   VALUES($1,$2,$3,$4,$5::numeric)`,
   [t,b,receiptId,saleRow.id,s.amount]);
  await db.query(`INSERT INTO customer_receivable_ledger
   (installation_id,branch_id,customer_id,order_id,kind,source_id,amount,actor_id,request_id)
   VALUES($1,$2,$3,$4,'PAYMENT',$5,-$6::numeric,$7,$8)`,
   [t,b,o.customer_id,orderId,receiptId,s.amount,c.actorId,c.requestId]);
 }
 const newPaid=paid+amount,remaining=due-newPaid;
 const update=await db.query<{revision:string}>(`UPDATE sales_order SET
  payment_status=$4,revision=revision+1,updated_at=now()
  WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,
  [t,b,orderId,remaining===0n?"PAID":"PARTIAL"]);
 return {status:amount>0n?201:200,body:{id:receiptId,orderId,
  amount:s.amount,method:s.method,grandTotal:due.toString(),paid:newPaid.toString(),
  remaining:remaining.toString(),revision:Number(update.rows[0]!.revision),
  paymentStatus:remaining===0n?"PAID":"PARTIAL",recorded:amount>0n,
  debtRecorded:amount===0n}};
}
