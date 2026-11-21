import type { PoolClient } from "pg";
import type { MutationContext } from "./mutation.ts";
import { requireRevision } from "./mutation.ts";
import { validBaseQty } from "./inventory.ts";

export class PurchaseFault extends Error {
 readonly status:number;readonly code:string;
 constructor(status:number,code:string){super(code);this.status=status;this.code=code;}
}
export type PurchaseScope={branchId:string;warehouseId:string};
export type PurchaseLine={productId:string;quantity:string;unitCost:string};
export type PurchaseCreate=PurchaseScope&{supplierId:string;note:string;lines:PurchaseLine[]};
export type PurchaseReceiptLine={orderLineNo:number;quantity:string};
export type PurchaseReceipt=PurchaseScope&{orderId:string;lines:PurchaseReceiptLine[]};
const COST=/^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,4})?$/;
export const validCost=(x:unknown):x is string=>typeof x==="string"&&COST.test(x);
async function scopedWarehouse(db:PoolClient,t:string,scope:PurchaseScope,lock=false){
 const r=await db.query(
  `SELECT id FROM warehouse WHERE installation_id=$1 AND branch_id=$2 AND id=$3
   ${lock?"FOR UPDATE":"FOR SHARE"}`,[t,scope.branchId,scope.warehouseId]);
 if(r.rowCount!==1)throw new PurchaseFault(404,"WAREHOUSE_NOT_FOUND");
}
export async function listOrders(db:PoolClient,t:string,b:string,warehouseIds:string[],offset=0){
 if(warehouseIds.length===0)return {items:[],hasMore:false};
 const r=await db.query(
  `SELECT o.id,o.document_no AS "documentNo",o.revision::integer,
    o.status,o.warehouse_id AS "warehouseId",w.name AS "warehouseName",
    s.name AS "supplierName",o.supplier_id AS "supplierId",
    o.created_at AS "createdAt",o.confirmed_at AS "confirmedAt",
    (SELECT count(*)::integer FROM purchase_order_line l
      WHERE l.installation_id=o.installation_id AND l.branch_id=o.branch_id
        AND l.order_id=o.id) AS "lineCount",
    (SELECT count(*)::integer FROM purchase_receipt r
      WHERE r.installation_id=o.installation_id AND r.branch_id=o.branch_id
        AND r.order_id=o.id) AS "receiptCount"
    FROM purchase_order o
    JOIN catalog_supplier s ON s.installation_id=o.installation_id
      AND s.branch_id=o.branch_id AND s.id=o.supplier_id
    JOIN warehouse w ON w.installation_id=o.installation_id
      AND w.branch_id=o.branch_id AND w.id=o.warehouse_id
    WHERE o.installation_id=$1 AND o.branch_id=$2
      AND o.warehouse_id=ANY($3::uuid[])
    ORDER BY CASE WHEN o.status IN ('CONFIRMED','PARTIALLY_RECEIVED') THEN 0
                  WHEN o.status='DRAFT' THEN 1 ELSE 2 END,
             o.created_at DESC,o.id DESC LIMIT 101 OFFSET $4`,
  [t,b,warehouseIds,offset]);
 return {items:r.rows.slice(0,100),hasMore:r.rows.length>100};
}
export async function orderDetail(db:PoolClient,t:string,scope:PurchaseScope,id:string){
 const q=await db.query(
  `SELECT o.id,o.status,o.revision::integer,o.document_no AS "documentNo",
     o.supplier_id AS "supplierId",s.name AS "supplierName",
     o.warehouse_id AS "warehouseId",w.name AS "warehouseName",o.note,
     o.created_at AS "createdAt",o.confirmed_at AS "confirmedAt"
   FROM purchase_order o
   JOIN catalog_supplier s ON s.installation_id=o.installation_id
     AND s.branch_id=o.branch_id AND s.id=o.supplier_id
   JOIN warehouse w ON w.installation_id=o.installation_id
     AND w.branch_id=o.branch_id AND w.id=o.warehouse_id
   WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$3
     AND o.warehouse_id=$4`,[t,scope.branchId,id,scope.warehouseId]);
 if(!q.rows[0])throw new PurchaseFault(404,"PURCHASE_NOT_FOUND");
 const lines=await db.query(
  `SELECT l.line_no AS "lineNo",l.product_id AS "productId",p.sku,p.name,
   p.base_unit AS "baseUnit",l.quantity_base::text AS "orderedBase",
   l.unit_cost::text AS "unitCost",
   COALESCE((SELECT sum(x.quantity_base) FROM purchase_receipt_line x
     WHERE x.installation_id=l.installation_id AND x.branch_id=l.branch_id
       AND x.order_id=l.order_id AND x.order_line_no=l.line_no),0)::numeric(24,6)::text
        AS "receivedBase"
   FROM purchase_order_line l JOIN catalog_product p
     ON p.installation_id=l.installation_id AND p.branch_id=l.branch_id
       AND p.id=l.product_id
   WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3
   ORDER BY l.line_no`,[t,scope.branchId,id]);
 const receipts=await db.query(
  `SELECT r.id,r.posted_at AS "postedAt",r.posted_by AS "postedBy",
    count(l.line_no)::integer AS "lineCount"
   FROM purchase_receipt r LEFT JOIN purchase_receipt_line l
    ON l.installation_id=r.installation_id AND l.branch_id=r.branch_id AND l.receipt_id=r.id
   WHERE r.installation_id=$1 AND r.branch_id=$2 AND r.order_id=$3
   GROUP BY r.installation_id,r.branch_id,r.id
   ORDER BY r.posted_at DESC,r.id DESC`,[t,scope.branchId,id]);
 return {...q.rows[0] as object,lines:lines.rows,receipts:receipts.rows};
}
export async function createPurchase(db:PoolClient,ctx:MutationContext,input:PurchaseCreate){
 const t=ctx.installationId,b=input.branchId,w=input.warehouseId;
 if(input.lines.length<1||input.lines.length>40)throw new PurchaseFault(400,"PURCHASE_LINES_REQUIRED");
 if(input.note.length>500)throw new PurchaseFault(400,"NOTE_TOO_LONG");
 await scopedWarehouse(db,t,input);
 const sup=await db.query(
  "SELECT id FROM catalog_supplier WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active FOR SHARE",
  [t,b,input.supplierId]);
 if(sup.rowCount!==1)throw new PurchaseFault(409,"SUPPLIER_UNAVAILABLE");
 const products=input.lines.map(x=>x.productId);
 if(new Set(products).size!==products.length)throw new PurchaseFault(400,"DUPLICATE_PRODUCT_LINE");
 const ps=await db.query<{id:string}>(
  "SELECT id FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 AND id=ANY($3::uuid[]) AND active FOR SHARE",
  [t,b,products]);
 if(ps.rowCount!==input.lines.length)throw new PurchaseFault(409,"PRODUCT_UNAVAILABLE");
 for(const row of input.lines){
  if(!validBaseQty(row.quantity)||!validCost(row.unitCost))
   throw new PurchaseFault(400,"PURCHASE_DECIMAL_INVALID");
 }
 const q=await db.query<{id:string}>(
  `INSERT INTO purchase_order(installation_id,branch_id,supplier_id,warehouse_id,note,created_by,request_id)
   VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
  [t,b,input.supplierId,w,input.note,ctx.actorId,ctx.requestId]);
 const id=q.rows[0]!.id;
 for(let i=0;i<input.lines.length;i++){
  const row=input.lines[i]!;
  await db.query(`INSERT INTO purchase_order_line
   (installation_id,branch_id,order_id,line_no,product_id,quantity_base,unit_cost)
   VALUES($1,$2,$3,$4,$5,$6::numeric,$7::numeric)`,
    [t,b,id,i+1,row.productId,row.quantity,row.unitCost]);
 }
 return {status:201,body:{id,warehouseId:w,supplierId:input.supplierId,
   status:"DRAFT",revision:0,lineCount:input.lines.length}};
}
async function lockedOrder(db:PoolClient,t:string,s:PurchaseScope,id:string){
 const q=await db.query<{status:string;revision:string;warehouse_id:string;document_no:string|null}>(
  `SELECT status,revision::text,warehouse_id,document_no FROM purchase_order
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE`,[t,s.branchId,id]);
 const o=q.rows[0];
 if(!o||o.warehouse_id!==s.warehouseId)throw new PurchaseFault(404,"PURCHASE_NOT_FOUND");
 return o;
}
export async function confirmPurchase(db:PoolClient,ctx:MutationContext,s:PurchaseScope,id:string){
 const t=ctx.installationId,b=s.branchId;
 await scopedWarehouse(db,t,s);
 const o=await lockedOrder(db,t,s,id);
 requireRevision(ctx.expectedRevision,Number(o.revision));
 if(o.status!=="DRAFT")throw new PurchaseFault(409,"PURCHASE_NOT_DRAFT");
 const count=await db.query<{n:string}>(
  "SELECT count(*)::text AS n FROM purchase_order_line WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3",
  [t,b,id]);
 if(count.rows[0]?.n==="0")throw new PurchaseFault(409,"PURCHASE_EMPTY");
 const seq=await db.query<{seq:string}>(
  `INSERT INTO purchase_order_sequence(installation_id,branch_id,next_no)
   VALUES($1,$2,2) ON CONFLICT(installation_id,branch_id) DO UPDATE
   SET next_no=purchase_order_sequence.next_no+1
   RETURNING (next_no-1)::text AS seq`,[t,b]);
 const documentNo="PO-"+seq.rows[0]!.seq.padStart(8,"0");
 const updated=await db.query<{revision:number}>(
  `UPDATE purchase_order SET status='CONFIRMED',document_no=$4,confirmed_by=$5,
   confirmed_at=now(),revision=revision+1,updated_at=now()
   WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::integer`,
  [t,b,id,documentNo,ctx.actorId]);
 return {status:200,body:{id,documentNo,status:"CONFIRMED",revision:updated.rows[0]!.revision}};
}
export async function cancelPurchase(db:PoolClient,ctx:MutationContext,s:PurchaseScope,id:string){
 const t=ctx.installationId,b=s.branchId;
 const o=await lockedOrder(db,t,s,id);
 requireRevision(ctx.expectedRevision,Number(o.revision));
 if(!["DRAFT","CONFIRMED"].includes(o.status))
  throw new PurchaseFault(409,"PURCHASE_CANNOT_CANCEL");
 const exists=await db.query(
  "SELECT 1 FROM purchase_receipt WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 LIMIT 1",
  [t,b,id]);
 if(exists.rowCount)throw new PurchaseFault(409,"RECEIPTS_ALREADY_POSTED");
 const r=await db.query<{revision:number}>(
  `UPDATE purchase_order SET status='CANCELLED',revision=revision+1,updated_at=now()
   WHERE installation_id=$1 AND branch_id=$2 AND id=$3
   RETURNING revision::integer`,[t,b,id]);
 return {status:200,body:{id,status:"CANCELLED",revision:r.rows[0]!.revision}};
}
export async function postReceipt(db:PoolClient,ctx:MutationContext,input:PurchaseReceipt){
 const t=ctx.installationId,b=input.branchId,w=input.warehouseId;
 if(input.lines.length<1||input.lines.length>40)
  throw new PurchaseFault(400,"RECEIPT_LINES_REQUIRED");
 if(new Set(input.lines.map(x=>x.orderLineNo)).size!==input.lines.length)
  throw new PurchaseFault(400,"DUPLICATE_RECEIPT_LINE");
 // First lock warehouse, then order: same sequence as other inventory writers.
 await scopedWarehouse(db,t,input,true);
 const order=await lockedOrder(db,t,input,input.orderId);
 requireRevision(ctx.expectedRevision,Number(order.revision));
 if(!["CONFIRMED","PARTIALLY_RECEIVED"].includes(order.status))
  throw new PurchaseFault(409,"PURCHASE_NOT_RECEIVABLE");
 const all=await db.query<{line_no:number;product_id:string;quantity_base:string;unit_cost:string}>(
  `SELECT line_no,product_id,quantity_base::text,unit_cost::text
   FROM purchase_order_line WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3
   ORDER BY line_no FOR SHARE`,[t,b,input.orderId]);
 const lines=new Map(all.rows.map(x=>[x.line_no,x]));
 for(const item of input.lines){
  if(!validBaseQty(item.quantity))throw new PurchaseFault(400,"RECEIPT_QTY_INVALID");
  const poLine=lines.get(item.orderLineNo);
  if(!poLine)throw new PurchaseFault(409,"PURCHASE_LINE_MISSING");
  const r=await db.query<{already:string}>(
   `SELECT COALESCE(sum(quantity_base),0)::numeric(24,6)::text AS already
    FROM purchase_receipt_line WHERE installation_id=$1 AND branch_id=$2
      AND order_id=$3 AND order_line_no=$4`,[t,b,input.orderId,item.orderLineNo]);
  const check=await db.query<{ok:boolean}>(
   "SELECT $1::numeric + $2::numeric <= $3::numeric AS ok",
    [r.rows[0]!.already,item.quantity,poLine.quantity_base]);
  if(check.rows[0]?.ok!==true)throw new PurchaseFault(409,"RECEIPT_OVER_ORDERED");
 }
 const header=await db.query<{id:string}>(
  `INSERT INTO purchase_receipt(installation_id,branch_id,order_id,warehouse_id,posted_by,request_id)
   VALUES($1,$2,$3,$4,$5,$6) RETURNING id`,
   [t,b,input.orderId,w,ctx.actorId,ctx.requestId]);
 const receiptId=header.rows[0]!.id;
 for(let i=0;i<input.lines.length;i++){
  const item=input.lines[i]!,poLine=lines.get(item.orderLineNo)!;
  const ledger=await db.query<{id:string}>(
   `INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,product_id,
     kind,source_type,source_id,source_line,delta_base,actor_id,request_id)
     VALUES($1,$2,$3,$4,'RECEIPT','PURCHASE_RECEIPT',$5,$6,$7::numeric,$8,$9)
     RETURNING id`,
   [t,b,w,poLine.product_id,receiptId,i+1,item.quantity,ctx.actorId,ctx.requestId]);
  await db.query(
   `INSERT INTO purchase_receipt_line(installation_id,branch_id,receipt_id,line_no,
      order_id,order_line_no,product_id,quantity_base,unit_cost,inventory_ledger_id,warehouse_id)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8::numeric,$9::numeric,$10,$11)`,
   [t,b,receiptId,i+1,input.orderId,item.orderLineNo,poLine.product_id,
    item.quantity,poLine.unit_cost,ledger.rows[0]!.id,w]);
 }
 const remaining=await db.query<{all_received:boolean}>(
  `SELECT bool_and(coalesce(got.received,0)>=l.quantity_base) AS all_received
   FROM purchase_order_line l LEFT JOIN LATERAL(
     SELECT sum(quantity_base) AS received FROM purchase_receipt_line r
     WHERE r.installation_id=l.installation_id AND r.branch_id=l.branch_id
       AND r.order_id=l.order_id AND r.order_line_no=l.line_no
   ) got ON true
   WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3`,
  [t,b,input.orderId]);
 const next=remaining.rows[0]?.all_received===true?"RECEIVED":"PARTIALLY_RECEIVED";
 const updated=await db.query<{revision:number}>(
  `UPDATE purchase_order SET status=$4,revision=revision+1,updated_at=now()
   WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::integer`,
   [t,b,input.orderId,next]);
 return {status:201,body:{id:receiptId,orderId:input.orderId,status:"POSTED",
    purchaseStatus:next,purchaseRevision:updated.rows[0]!.revision,
    lineCount:input.lines.length}};
}
