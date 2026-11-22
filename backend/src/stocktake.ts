import type { PoolClient } from "pg";
import type { MutationContext } from "./mutation.ts";
import { requireRevision } from "./mutation.ts";
export type StocktakeScope={branchId:string;warehouseId:string};
export type StocktakeCountLine={lineNo:number;round:number;quantity:string};
export class StocktakeFault extends Error {
 readonly status:number;readonly code:string;
 constructor(status:number,code:string){super(code);this.status=status;this.code=code;}
}
const NONNEG=/^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,6})?$/;
export const validNonnegativeQty=(x:unknown):x is string=>
 typeof x==="string"&&NONNEG.test(x);
async function lockWarehouse(db:PoolClient,t:string,s:StocktakeScope){
 const q=await db.query(
  "SELECT 1 FROM warehouse WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE",
  [t,s.branchId,s.warehouseId]);
 if(q.rowCount!==1)throw new StocktakeFault(404,"WAREHOUSE_NOT_FOUND");
}
async function lockDocument(db:PoolClient,t:string,s:StocktakeScope,id:string){
 const q=await db.query<{status:string;revision:string;submitted_by:string|null}>(
  `SELECT status,revision::text,submitted_by FROM inventory_stocktake
   WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND warehouse_id=$4 FOR UPDATE`,
   [t,s.branchId,id,s.warehouseId]);
 const row=q.rows[0];if(!row)throw new StocktakeFault(404,"STOCKTAKE_NOT_FOUND");
 return row;
}
export async function listStocktakes(db:PoolClient,t:string,s:StocktakeScope,offset=0){
 const q=await db.query(
  `SELECT x.id,x.status,x.revision::integer,x.note,x.created_at AS "createdAt",
   x.warehouse_id AS "warehouseId",w.name AS "warehouseName",
   (SELECT count(*)::integer FROM inventory_stocktake_line l
      WHERE l.installation_id=x.installation_id AND l.branch_id=x.branch_id
        AND l.stocktake_id=x.id) AS "lineCount",
   (SELECT count(*)::integer FROM inventory_ledger v
      WHERE v.installation_id=x.installation_id AND v.branch_id=x.branch_id
        AND v.warehouse_id=x.warehouse_id AND v.source_type='STOCKTAKE'
        AND v.source_id=x.id) AS "adjustmentCount"
   FROM inventory_stocktake x
   JOIN warehouse w ON w.installation_id=x.installation_id AND w.branch_id=x.branch_id
    AND w.id=x.warehouse_id
   WHERE x.installation_id=$1 AND x.branch_id=$2 AND x.warehouse_id=$3
   ORDER BY CASE WHEN x.status IN ('COUNTING','SUBMITTED','APPROVED') THEN 0 ELSE 1 END,
    x.created_at DESC,x.id DESC LIMIT 101 OFFSET $4`,
  [t,s.branchId,s.warehouseId,offset]);
 return {items:q.rows.slice(0,100),hasMore:q.rows.length>100};
}
export async function stocktakeDetail(db:PoolClient,t:string,s:StocktakeScope,id:string){
 const head=await db.query(
  `SELECT id,status,revision::integer,note,warehouse_id AS "warehouseId",
    created_at AS "createdAt",submitted_at AS "submittedAt",
    approved_at AS "approvedAt",posted_at AS "postedAt"
   FROM inventory_stocktake WHERE installation_id=$1 AND branch_id=$2 AND id=$3
    AND warehouse_id=$4`,[t,s.branchId,id,s.warehouseId]);
 if(!head.rows[0])throw new StocktakeFault(404,"STOCKTAKE_NOT_FOUND");
 const rows=await db.query(
  `SELECT l.line_no AS "lineNo",l.product_id AS "productId",p.sku,p.name,
   l.snapshot_on_hand::text AS "snapshotOnHand",l.snapshot_movement_count::integer AS "snapshotMovements",
   c.counted_base::text AS "countedBase",c.round_no AS "roundNo",
   CASE WHEN c.counted_base IS NULL THEN NULL
        ELSE (c.counted_base-l.snapshot_on_hand)::numeric(24,6)::text END AS "differenceBase"
   FROM inventory_stocktake_line l
   JOIN catalog_product p ON p.installation_id=l.installation_id
    AND p.branch_id=l.branch_id AND p.id=l.product_id
   LEFT JOIN LATERAL(SELECT counted_base,round_no FROM inventory_stocktake_count x
      WHERE x.installation_id=l.installation_id AND x.branch_id=l.branch_id
       AND x.stocktake_id=l.stocktake_id AND x.line_no=l.line_no
      ORDER BY x.round_no DESC LIMIT 1) c ON true
   WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.stocktake_id=$3
   ORDER BY l.line_no`,[t,s.branchId,id]);
 return {...head.rows[0] as object,lines:rows.rows};
}
export async function createStocktake(db:PoolClient,ctx:MutationContext,
 input:StocktakeScope&{note:string}){
 const t=ctx.installationId,b=input.branchId;
 requireRevision(ctx.expectedRevision,0);
 if(input.note.length>500)throw new StocktakeFault(400,"INVALID_NOTE");
 await lockWarehouse(db,t,input);
 const available=await db.query<{product_id:string;on_hand:string;movement_count:string}>(
  `SELECT v.product_id,v.on_hand::text,
    (SELECT count(*)::text FROM inventory_ledger l
      WHERE l.installation_id=v.installation_id AND l.branch_id=v.branch_id
       AND l.warehouse_id=v.warehouse_id AND l.product_id=v.product_id)
     AS movement_count
   FROM inventory_stock_balance v
   JOIN catalog_product p ON p.installation_id=v.installation_id
    AND p.branch_id=v.branch_id AND p.id=v.product_id
   WHERE v.installation_id=$1 AND v.branch_id=$2 AND v.warehouse_id=$3
   ORDER BY p.sku,v.product_id LIMIT 10000`,[t,b,input.warehouseId]);
 if(available.rows.length===0||available.rows.length>10000)
  throw new StocktakeFault(409,"STOCKTAKE_NO_STOCK_SCOPE");
 const head=await db.query<{id:string}>(
  `INSERT INTO inventory_stocktake(installation_id,branch_id,warehouse_id,note,
    created_by,request_id) VALUES($1,$2,$3,$4,$5,$6) RETURNING id`,
  [t,b,input.warehouseId,input.note,ctx.actorId,ctx.requestId]);
 const id=head.rows[0]!.id;
 for(let i=0;i<available.rows.length;i++){
  const row=available.rows[i]!;
  await db.query(
   `INSERT INTO inventory_stocktake_line(installation_id,branch_id,stocktake_id,
     line_no,product_id,snapshot_on_hand,snapshot_movement_count)
    VALUES($1,$2,$3,$4,$5,$6::numeric,$7::bigint)`,
   [t,b,id,i+1,row.product_id,row.on_hand,row.movement_count]);
 }
 const state=await db.query<{revision:number}>(
   `UPDATE inventory_stocktake SET status='COUNTING',revision=revision+1,updated_at=now()
     WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::integer`,
   [t,b,id]);
 return {status:201,body:{id,status:"COUNTING",revision:state.rows[0]!.revision,
   warehouseId:input.warehouseId,lineCount:available.rows.length}};
}
export async function recordCounts(db:PoolClient,ctx:MutationContext,s:StocktakeScope,
 id:string,lines:StocktakeCountLine[]){
 const t=ctx.installationId,b=s.branchId;
 if(lines.length<1||lines.length>100||new Set(lines.map(x=>x.lineNo)).size!==lines.length)
  throw new StocktakeFault(400,"STOCKTAKE_COUNT_LINES_INVALID");
 if(lines.some(x=>!validNonnegativeQty(x.quantity)||!Number.isInteger(x.lineNo)
     ||x.lineNo<1||x.lineNo>10000||!Number.isInteger(x.round)
     ||x.round<1||x.round>3))
  throw new StocktakeFault(400,"STOCKTAKE_COUNT_INVALID");
 await lockWarehouse(db,t,s);
 const doc=await lockDocument(db,t,s,id);
 requireRevision(ctx.expectedRevision,Number(doc.revision));
 if(doc.status!=="COUNTING")throw new StocktakeFault(409,"STOCKTAKE_NOT_COUNTING");
 for(const row of lines){
  await db.query(
   `INSERT INTO inventory_stocktake_count(installation_id,branch_id,stocktake_id,
     line_no,round_no,counted_base,counted_by,request_id)
     VALUES($1,$2,$3,$4,$5,$6::numeric,$7,$8)`,
   [t,b,id,row.lineNo,row.round,row.quantity,ctx.actorId,ctx.requestId]);
 }
 return {status:201,body:{id,status:"COUNTING",revision:Number(doc.revision),
   recorded:lines.length}};
}
export async function transitionStocktake(db:PoolClient,ctx:MutationContext,
 s:StocktakeScope,id:string,action:"submit"|"approve"|"post"|"cancel"){
 const t=ctx.installationId,b=s.branchId;
 await lockWarehouse(db,t,s);
 const doc=await lockDocument(db,t,s,id);
 requireRevision(ctx.expectedRevision,Number(doc.revision));
 const expected=action==="submit"?"COUNTING":action==="approve"?"SUBMITTED":
  action==="post"?"APPROVED":"COUNTING";
 if(doc.status!==expected)throw new StocktakeFault(409,"STOCKTAKE_STATUS_INVALID");
 if(action==="approve"&&doc.submitted_by===ctx.actorId)
  throw new StocktakeFault(403,"STOCKTAKE_SEPARATE_APPROVER_REQUIRED");
 if(action==="submit"||action==="post"){
  const missing=await db.query<{total:string;missing:string}>(
   `SELECT count(*)::text AS total,
     count(*) FILTER(WHERE NOT EXISTS(
       SELECT 1 FROM inventory_stocktake_count c WHERE
        c.installation_id=l.installation_id AND c.branch_id=l.branch_id
        AND c.stocktake_id=l.stocktake_id AND c.line_no=l.line_no))::text AS missing
     FROM inventory_stocktake_line l WHERE l.installation_id=$1
       AND l.branch_id=$2 AND l.stocktake_id=$3`,[t,b,id]);
  if(missing.rows[0]?.total==="0"||missing.rows[0]?.missing!=="0")
   throw new StocktakeFault(409,"STOCKTAKE_INCOMPLETE_COUNT");
 }
 if(action==="post"){
  const rows=await db.query<{line_no:number;product_id:string;expected_delta:string;
     snapshot_movement_count:string;current_count:string}>(
   `SELECT l.line_no,l.product_id,
       (c.counted_base-l.snapshot_on_hand)::numeric(24,6)::text AS expected_delta,
       l.snapshot_movement_count::text,
       (SELECT count(*)::text FROM inventory_ledger v WHERE
        v.installation_id=l.installation_id AND v.branch_id=l.branch_id
        AND v.warehouse_id=$4 AND v.product_id=l.product_id) AS current_count
     FROM inventory_stocktake_line l
     JOIN LATERAL(
       SELECT counted_base FROM inventory_stocktake_count c WHERE
        c.installation_id=l.installation_id AND c.branch_id=l.branch_id
        AND c.stocktake_id=l.stocktake_id AND c.line_no=l.line_no
       ORDER BY c.round_no DESC LIMIT 1
     ) c ON true
     WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.stocktake_id=$3
     ORDER BY l.line_no`,[t,b,id,s.warehouseId]);
  for(const row of rows.rows){
   if(row.snapshot_movement_count!==row.current_count)
    throw new StocktakeFault(409,"STOCKTAKE_STALE_SNAPSHOT");
  }
  for(const row of rows.rows){
   if(row.expected_delta==="0.000000")continue;
   await db.query(
    `INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,
       product_id,kind,source_type,source_id,source_line,delta_base,actor_id,request_id)
      VALUES($1,$2,$3,$4,'ADJUSTMENT','STOCKTAKE',$5,$6,$7::numeric,$8,$9)`,
    [t,b,s.warehouseId,row.product_id,id,row.line_no,row.expected_delta,
      ctx.actorId,ctx.requestId]);
  }
 }
 const state=action==="submit"?"SUBMITTED":action==="approve"?"APPROVED":
   action==="post"?"POSTED":"CANCELLED";
 const field=action==="submit"?"submitted_by":action==="approve"?"approved_by":
  action==="post"?"posted_by":null;
 const time=action==="submit"?"submitted_at":action==="approve"?"approved_at":
  action==="post"?"posted_at":null;
 const query=field&&time?
  `UPDATE inventory_stocktake SET status=$4,revision=revision+1,updated_at=now(),
    ${field}=$5,${time}=now() WHERE installation_id=$1 AND branch_id=$2
    AND id=$3 RETURNING revision::integer`:
  `UPDATE inventory_stocktake SET status=$4,revision=revision+1,updated_at=now()
     WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::integer`;
 const q=await db.query<{revision:number}>(query,
  field?[t,b,id,state,ctx.actorId]:[t,b,id,state]);
 return {status:200,body:{id,status:state,revision:q.rows[0]!.revision}};
}
