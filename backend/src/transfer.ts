import type { PoolClient } from "pg";
import type { MutationContext } from "./mutation.ts";
import { requireRevision } from "./mutation.ts";
import { validBaseQty } from "./inventory.ts";

export class TransferFault extends Error {
 readonly status:number;
 readonly code:string;
 constructor(status:number,code:string){super(code);this.status=status;this.code=code;}
}
export type TransferScope={branchId:string;sourceWarehouseId:string;destinationWarehouseId:string};
export type TransferLine={productId:string;quantity:string};
export type TransferCreate=TransferScope&{note:string;lines:TransferLine[]};
export type TransferReceiptLine={transferLineNo:number;quantity:string};
export type TransferReceipt=TransferScope&{transferId:string;lines:TransferReceiptLine[]};
type LockedTransfer={status:string;revision:string;source_warehouse_id:string;destination_warehouse_id:string};
async function lockWarehouses(db:PoolClient,t:string,scope:TransferScope){
 if(scope.sourceWarehouseId===scope.destinationWarehouseId)
  throw new TransferFault(400,"SAME_WAREHOUSE");
 const keys=[scope.sourceWarehouseId,scope.destinationWarehouseId].sort();
 for(const wh of keys){
  const q=await db.query(
   "SELECT id FROM warehouse WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE",
   [t,scope.branchId,wh]);
  if(q.rowCount!==1)throw new TransferFault(404,"WAREHOUSE_NOT_FOUND");
 }
}
async function lockDocument(db:PoolClient,t:string,s:TransferScope,id:string):Promise<LockedTransfer>{
 const q=await db.query<LockedTransfer>(
  `SELECT status,revision::text,source_warehouse_id,destination_warehouse_id
   FROM inventory_transfer WHERE installation_id=$1 AND branch_id=$2 AND id=$3
   FOR UPDATE`,[t,s.branchId,id]);
 const v=q.rows[0];
 if(!v||v.source_warehouse_id!==s.sourceWarehouseId||
    v.destination_warehouse_id!==s.destinationWarehouseId)
  throw new TransferFault(404,"TRANSFER_NOT_FOUND");
 return v;
}
export async function listTransfers(db:PoolClient,t:string,b:string,warehouseId:string,offset:number){
 const q=await db.query(
  `SELECT t.id,t.status,t.revision::integer,t.note,
   t.source_warehouse_id AS "sourceWarehouseId",
   t.destination_warehouse_id AS "destinationWarehouseId",
   a.name AS "sourceWarehouseName",z.name AS "destinationWarehouseName",
   t.created_at AS "createdAt",t.dispatched_at AS "dispatchedAt",
   (SELECT count(*)::integer FROM inventory_transfer_line l WHERE
     l.installation_id=t.installation_id AND l.branch_id=t.branch_id AND l.transfer_id=t.id)
     AS "lineCount",
   (SELECT count(*)::integer FROM inventory_transfer_receipt r WHERE
     r.installation_id=t.installation_id AND r.branch_id=t.branch_id AND r.transfer_id=t.id)
     AS "receiptCount"
   FROM inventory_transfer t
   JOIN warehouse a ON a.installation_id=t.installation_id AND a.branch_id=t.branch_id
      AND a.id=t.source_warehouse_id
   JOIN warehouse z ON z.installation_id=t.installation_id AND z.branch_id=t.branch_id
      AND z.id=t.destination_warehouse_id
   WHERE t.installation_id=$1 AND t.branch_id=$2
     AND (t.source_warehouse_id=$3 OR t.destination_warehouse_id=$3)
   ORDER BY CASE WHEN t.status IN ('IN_TRANSIT','PARTIALLY_RECEIVED') THEN 0
                 WHEN t.status IN ('CREATED','APPROVED') THEN 1 ELSE 2 END,
            t.created_at DESC,t.id DESC LIMIT 101 OFFSET $4`,[t,b,warehouseId,offset]);
 return {items:q.rows.slice(0,100),hasMore:q.rows.length>100};
}
export async function transferDetail(db:PoolClient,t:string,s:TransferScope,id:string){
 const header=await db.query(
  `SELECT t.id,t.status,t.revision::integer,t.note,
   t.source_warehouse_id AS "sourceWarehouseId",
   t.destination_warehouse_id AS "destinationWarehouseId",
   a.name AS "sourceWarehouseName",z.name AS "destinationWarehouseName",
   t.created_at AS "createdAt",t.approved_at AS "approvedAt",
   t.dispatched_at AS "dispatchedAt"
   FROM inventory_transfer t
   JOIN warehouse a ON a.installation_id=t.installation_id AND a.branch_id=t.branch_id
     AND a.id=t.source_warehouse_id
   JOIN warehouse z ON z.installation_id=t.installation_id AND z.branch_id=t.branch_id
     AND z.id=t.destination_warehouse_id
   WHERE t.installation_id=$1 AND t.branch_id=$2 AND t.id=$3
    AND t.source_warehouse_id=$4 AND t.destination_warehouse_id=$5`,
   [t,s.branchId,id,s.sourceWarehouseId,s.destinationWarehouseId]);
 if(!header.rows[0])throw new TransferFault(404,"TRANSFER_NOT_FOUND");
 const lines=await db.query(
  `SELECT l.line_no AS "lineNo",l.product_id AS "productId",p.sku,p.name,
    l.quantity_base::text AS "dispatchedBase",
    COALESCE((SELECT sum(x.quantity_base) FROM inventory_transfer_receipt_line x
       WHERE x.installation_id=l.installation_id AND x.branch_id=l.branch_id
         AND x.transfer_id=l.transfer_id AND x.transfer_line_no=l.line_no),0)
       ::numeric(24,6)::text AS "receivedBase",
    CASE WHEN $4::text IS NULL THEN NULL ELSE
       (CASE WHEN t.status IN ('IN_TRANSIT','PARTIALLY_RECEIVED','RECEIVED')
         THEN l.quantity_base-COALESCE((SELECT sum(x.quantity_base)
           FROM inventory_transfer_receipt_line x WHERE
             x.installation_id=l.installation_id AND x.branch_id=l.branch_id
             AND x.transfer_id=l.transfer_id AND x.transfer_line_no=l.line_no),0)
         ELSE 0 END)::numeric(24,6)::text END AS "inTransitBase"
   FROM inventory_transfer_line l
   JOIN inventory_transfer t ON t.installation_id=l.installation_id
     AND t.branch_id=l.branch_id AND t.id=l.transfer_id
   JOIN catalog_product p ON p.installation_id=l.installation_id
     AND p.branch_id=l.branch_id AND p.id=l.product_id
   WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.transfer_id=$3
   ORDER BY l.line_no`,[t,s.branchId,id,"present"]);
 const receipts=await db.query(
  `SELECT r.id,r.posted_at AS "postedAt",count(x.line_no)::integer AS "lineCount"
    FROM inventory_transfer_receipt r
    LEFT JOIN inventory_transfer_receipt_line x
      ON x.installation_id=r.installation_id AND x.branch_id=r.branch_id
       AND x.receipt_id=r.id
    WHERE r.installation_id=$1 AND r.branch_id=$2 AND r.transfer_id=$3
    GROUP BY r.id,r.posted_at ORDER BY r.posted_at DESC,r.id DESC`,
  [t,s.branchId,id]);
 return {...header.rows[0] as object,lines:lines.rows,receipts:receipts.rows};
}
export async function createTransfer(db:PoolClient,ctx:MutationContext,input:TransferCreate){
 const t=ctx.installationId,b=input.branchId;
 requireRevision(ctx.expectedRevision,0);
 if(input.lines.length<1||input.lines.length>40||
    input.note.length>500)throw new TransferFault(400,"TRANSFER_INPUT_INVALID");
 await lockWarehouses(db,t,input);
 const products=input.lines.map(x=>x.productId);
 if(products.length!==new Set(products).size)throw new TransferFault(400,"DUPLICATE_TRANSFER_SKU");
 if(input.lines.some(x=>!validBaseQty(x.quantity)))
  throw new TransferFault(400,"INVALID_QUANTITY");
 const p=await db.query(
  `SELECT id FROM catalog_product WHERE installation_id=$1 AND branch_id=$2
   AND id=ANY($3::uuid[]) AND active FOR SHARE`,[t,b,products]);
 if(p.rowCount!==products.length)throw new TransferFault(409,"PRODUCT_UNAVAILABLE");
 const q=await db.query<{id:string}>(
  `INSERT INTO inventory_transfer(installation_id,branch_id,source_warehouse_id,
    destination_warehouse_id,note,created_by,request_id)
   VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
  [t,b,input.sourceWarehouseId,input.destinationWarehouseId,input.note,
   ctx.actorId,ctx.requestId]);
 const id=q.rows[0]!.id;
 for(let i=0;i<input.lines.length;i++){
  const line=input.lines[i]!;
  await db.query(
    `INSERT INTO inventory_transfer_line
     (installation_id,branch_id,transfer_id,line_no,product_id,quantity_base)
     VALUES($1,$2,$3,$4,$5,$6::numeric)`,
     [t,b,id,i+1,line.productId,line.quantity]);
 }
 return {status:201,body:{id,status:"CREATED",revision:0,
   sourceWarehouseId:input.sourceWarehouseId,
   destinationWarehouseId:input.destinationWarehouseId,
   lineCount:input.lines.length}};
}
export async function transitionTransfer(db:PoolClient,ctx:MutationContext,
 input:TransferScope,id:string,step:"approve"|"dispatch"|"cancel"){
 const t=ctx.installationId,b=input.branchId;
 await lockWarehouses(db,t,input);
 const doc=await lockDocument(db,t,input,id);
 requireRevision(ctx.expectedRevision,Number(doc.revision));
 if(step==="approve"&&doc.status!=="CREATED")throw new TransferFault(409,"TRANSFER_NOT_CREATED");
 if(step==="dispatch"&&doc.status!=="APPROVED")throw new TransferFault(409,"TRANSFER_NOT_APPROVED");
 if(step==="cancel"&&!["CREATED","APPROVED"].includes(doc.status))
  throw new TransferFault(409,"TRANSFER_CANNOT_CANCEL");
 const lines=await db.query<{line_no:number;product_id:string;quantity_base:string}>(
  `SELECT line_no,product_id,quantity_base::text FROM inventory_transfer_line
   WHERE installation_id=$1 AND branch_id=$2 AND transfer_id=$3
   ORDER BY line_no FOR SHARE`,[t,b,id]);
 if(lines.rowCount===0)throw new TransferFault(409,"TRANSFER_LINES_EMPTY");
 if(step==="dispatch"){
  // Physical issue is separate from commercial approval and all lines are posted atomically.
  for(const line of lines.rows){
   await db.query(
    `INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,product_id,
      kind,source_type,source_id,source_line,delta_base,actor_id,request_id)
     VALUES($1,$2,$3,$4,'TRANSFER_OUT','TRANSFER',$5,$6,-$7::numeric,$8,$9)`,
    [t,b,input.sourceWarehouseId,line.product_id,id,line.line_no,
      line.quantity_base,ctx.actorId,ctx.requestId]);
  }
 }
 const update=step==="approve"?
  `UPDATE inventory_transfer SET status='APPROVED',revision=revision+1,
    approved_by=$4,approved_at=now(),updated_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::integer`:
  step==="dispatch"?
  `UPDATE inventory_transfer SET status='IN_TRANSIT',revision=revision+1,
    dispatched_by=$4,dispatched_at=now(),updated_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::integer`:
  `UPDATE inventory_transfer SET status='CANCELLED',revision=revision+1,
    updated_at=now() WHERE installation_id=$1 AND branch_id=$2 AND id=$3
    RETURNING revision::integer`;
 const q=await db.query<{revision:number}>(update,
  step==="cancel"?[t,b,id]:[t,b,id,ctx.actorId]);
 return {status:200,body:{id,status:step==="approve"?"APPROVED":
   step==="dispatch"?"IN_TRANSIT":"CANCELLED",revision:q.rows[0]!.revision}};
}
export async function receiveTransfer(db:PoolClient,ctx:MutationContext,input:TransferReceipt){
 const t=ctx.installationId,b=input.branchId;
 if(input.lines.length<1||input.lines.length>40||
  new Set(input.lines.map(x=>x.transferLineNo)).size!==input.lines.length)
  throw new TransferFault(400,"TRANSFER_RECEIPT_LINES_INVALID");
 if(input.lines.some(x=>!validBaseQty(x.quantity)||
  !Number.isInteger(x.transferLineNo)||x.transferLineNo<1))
   throw new TransferFault(400,"TRANSFER_RECEIPT_QUANTITY_INVALID");
 await lockWarehouses(db,t,input);
 const doc=await lockDocument(db,t,input,input.transferId);
 requireRevision(ctx.expectedRevision,Number(doc.revision));
 if(!["IN_TRANSIT","PARTIALLY_RECEIVED"].includes(doc.status))
  throw new TransferFault(409,"TRANSFER_NOT_IN_TRANSIT");
 const all=await db.query<{line_no:number;product_id:string;quantity_base:string}>(
  `SELECT line_no,product_id,quantity_base::text FROM inventory_transfer_line
   WHERE installation_id=$1 AND branch_id=$2 AND transfer_id=$3
   ORDER BY line_no FOR SHARE`,[t,b,input.transferId]);
 const lines=new Map(all.rows.map(x=>[x.line_no,x]));
 for(const row of input.lines){
  const line=lines.get(row.transferLineNo);
  if(!line)throw new TransferFault(409,"TRANSFER_LINE_NOT_FOUND");
  const qty=await db.query<{ok:boolean}>(
   `SELECT ($1::numeric+COALESCE((SELECT sum(quantity_base)
      FROM inventory_transfer_receipt_line WHERE installation_id=$2
      AND branch_id=$3 AND transfer_id=$4 AND transfer_line_no=$5),0))
      <=$6::numeric AS ok`,
   [row.quantity,t,b,input.transferId,row.transferLineNo,line.quantity_base]);
  if(qty.rows[0]?.ok!==true)throw new TransferFault(409,"TRANSFER_OVER_RECEIVED");
 }
 const header=await db.query<{id:string}>(
  `INSERT INTO inventory_transfer_receipt(installation_id,branch_id,transfer_id,
   destination_warehouse_id,posted_by,request_id)
   VALUES($1,$2,$3,$4,$5,$6) RETURNING id`,
  [t,b,input.transferId,input.destinationWarehouseId,ctx.actorId,ctx.requestId]);
 const receiptId=header.rows[0]!.id;
 for(let i=0;i<input.lines.length;i++){
  const row=input.lines[i]!,line=lines.get(row.transferLineNo)!;
  const ledger=await db.query<{id:string}>(
   `INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,product_id,
      kind,source_type,source_id,source_line,delta_base,actor_id,request_id)
     VALUES($1,$2,$3,$4,'TRANSFER_IN','TRANSFER',$5,$6,$7::numeric,$8,$9)
     RETURNING id`,[t,b,input.destinationWarehouseId,line.product_id,
      receiptId,i+1,row.quantity,ctx.actorId,ctx.requestId]);
  await db.query(
   `INSERT INTO inventory_transfer_receipt_line
     (installation_id,branch_id,receipt_id,line_no,transfer_id,transfer_line_no,
      product_id,destination_warehouse_id,quantity_base,ledger_id)
     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::numeric,$10)`,
    [t,b,receiptId,i+1,input.transferId,row.transferLineNo,line.product_id,
     input.destinationWarehouseId,row.quantity,ledger.rows[0]!.id]);
 }
 const remaining=await db.query<{complete:boolean}>(
  `SELECT bool_and(l.quantity_base<=COALESCE(got.received,0)) AS complete
   FROM inventory_transfer_line l LEFT JOIN LATERAL(
     SELECT sum(quantity_base) AS received FROM inventory_transfer_receipt_line x
     WHERE x.installation_id=l.installation_id AND x.branch_id=l.branch_id
       AND x.transfer_id=l.transfer_id AND x.transfer_line_no=l.line_no
   ) got ON true
   WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.transfer_id=$3`,
   [t,b,input.transferId]);
 const state=remaining.rows[0]?.complete===true?"RECEIVED":"PARTIALLY_RECEIVED";
 const q=await db.query<{revision:number}>(
  `UPDATE inventory_transfer SET status=$4,revision=revision+1,updated_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::integer`,
    [t,b,input.transferId,state]);
 return {status:201,body:{id:receiptId,transferId:input.transferId,status:"POSTED",
    transferStatus:state,transferRevision:q.rows[0]!.revision,
    lineCount:input.lines.length}};
}
