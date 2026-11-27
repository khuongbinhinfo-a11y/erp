import {randomUUID} from "node:crypto";
import type {PoolClient} from "pg";
import {requireRevision,type MutationContext} from "./mutation.ts";
import {hasPermission} from "./rbac.ts";
import {InventoryFault,stockDecimalUnits,stockUnitsDecimal,validBaseQty,
 balance,type WarehouseScope,type ShortageMode} from "./inventory.ts";

export type DirectIssueItem={
 lineNo:number;quantityBase:string;locationId?:string;lotId?:string;
};
export type DirectIssueInput=WarehouseScope&{
 orderId:string;version:number;lines:DirectIssueItem[];allowNegative:boolean;
};
export type ScopeAssignInput=WarehouseScope&{
 productId:string;quantityBase:string;locationId?:string;lotId?:string;
};
const q=(v:string)=>stockDecimalUnits(v);
async function locked(db:PoolClient,t:string,s:WarehouseScope){
 const r=await db.query("SELECT 1 FROM warehouse WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE",
  [t,s.branchId,s.warehouseId]);
 if(!r.rowCount)throw new InventoryFault(404,"WAREHOUSE_NOT_FOUND");
}
export async function requireT3b(db:PoolClient){
 const r=await db.query<{ok:boolean}>(
  "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0024_t3b_manual_direct_issue.sql') AS ok");
 if(!r.rows[0]?.ok)throw new InventoryFault(503,"T3B_MIGRATION_REQUIRED");
}
async function checkScope(db:PoolClient,t:string,s:WarehouseScope,p:string,
 locationId?:string,lotId?:string){
 const [policy,location,lot]=await Promise.all([
  db.query<{require_location:boolean;require_lot:boolean}>(
   `SELECT require_location,require_lot FROM inventory_product_tracking
    WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND product_id=$4`,
   [t,s.branchId,s.warehouseId,p]),
  locationId?db.query("SELECT 1 FROM inventory_storage_location WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND id=$4 AND active",
   [t,s.branchId,s.warehouseId,locationId]):Promise.resolve(null),
  lotId?db.query("SELECT 1 FROM inventory_product_lot WHERE installation_id=$1 AND branch_id=$2 AND product_id=$3 AND id=$4 AND (expiry_date IS NULL OR expiry_date>=CURRENT_DATE)",
   [t,s.branchId,p,lotId]):Promise.resolve(null),
 ]);
 if((policy.rows[0]?.require_location&&!locationId)||
    (policy.rows[0]?.require_lot&&!lotId)||
    (locationId&&!location?.rowCount)||(lotId&&!lot?.rowCount))
  throw new InventoryFault(409,"STOCK_SCOPE_REQUIRED_OR_UNAVAILABLE");
}
export async function createLocation(db:PoolClient,c:MutationContext,s:WarehouseScope,
 code:string,name:string){
 await requireT3b(db);await locked(db,c.installationId,s);
 const r=await db.query<{id:string}>(`INSERT INTO inventory_storage_location
  (installation_id,branch_id,warehouse_id,code,name,created_by)
  VALUES($1,$2,$3,$4,$5,$6) RETURNING id`,
  [c.installationId,s.branchId,s.warehouseId,code,name,c.actorId]);
 return {status:201,body:{id:r.rows[0]!.id,branchId:s.branchId,
  warehouseId:s.warehouseId,code,name,active:true}};
}
export async function createLot(db:PoolClient,c:MutationContext,s:WarehouseScope,
 productId:string,lotCode:string,expiryDate:string|null){
 await requireT3b(db);await locked(db,c.installationId,s);
 const p=await db.query("SELECT 1 FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active",
  [c.installationId,s.branchId,productId]);
 if(!p.rowCount)throw new InventoryFault(409,"PRODUCT_UNAVAILABLE");
 if(expiryDate){
  const ok=await db.query<{ok:boolean}>(
   "SELECT $1::date>=CURRENT_DATE AS ok",[expiryDate]);
  if(!ok.rows[0]?.ok)throw new InventoryFault(409,"LOT_EXPIRED");
 }
 const r=await db.query<{id:string}>(`INSERT INTO inventory_product_lot
  (installation_id,branch_id,product_id,lot_code,expiry_date,created_by)
  VALUES($1,$2,$3,$4,$5,$6) RETURNING id`,
  [c.installationId,s.branchId,productId,lotCode,expiryDate,c.actorId]);
 return {status:201,body:{id:r.rows[0]!.id,productId,lotCode,expiryDate}};
}
export async function setTrackingPolicy(db:PoolClient,c:MutationContext,
 s:WarehouseScope,productId:string,requireLocation:boolean,requireLot:boolean){
 await requireT3b(db);await locked(db,c.installationId,s);
 const existing=await db.query<{revision:string}>(`SELECT revision::text
  FROM inventory_product_tracking WHERE installation_id=$1 AND branch_id=$2
   AND warehouse_id=$3 AND product_id=$4 FOR UPDATE`,
  [c.installationId,s.branchId,s.warehouseId,productId]);
 requireRevision(c.expectedRevision,Number(existing.rows[0]?.revision??"0"));
 const r=await db.query<{revision:string}>(`INSERT INTO inventory_product_tracking
   (installation_id,branch_id,warehouse_id,product_id,require_location,require_lot,
    revision,updated_by)
  VALUES($1,$2,$3,$4,$5,$6,1,$7)
  ON CONFLICT(installation_id,branch_id,warehouse_id,product_id) DO UPDATE SET
   require_location=EXCLUDED.require_location,require_lot=EXCLUDED.require_lot,
   revision=inventory_product_tracking.revision+1,updated_by=EXCLUDED.updated_by,
   updated_at=now() RETURNING revision::text`,
  [c.installationId,s.branchId,s.warehouseId,productId,requireLocation,requireLot,c.actorId]);
 return {status:200,body:{productId,warehouseId:s.warehouseId,
  requireLocation,requireLot,revision:Number(r.rows[0]!.revision)}};
}
export async function assignStockScope(db:PoolClient,c:MutationContext,input:ScopeAssignInput){
 await requireT3b(db);await locked(db,c.installationId,input);
 const t=c.installationId,b=input.branchId,w=input.warehouseId,p=input.productId;
 if(!input.locationId&&!input.lotId)throw new InventoryFault(400,"SCOPE_REQUIRED");
 await checkScope(db,t,input,p,input.locationId,input.lotId);
 const stock=await balance(db,t,input,p);
 const total=await db.query<{classified:string}>(`SELECT coalesce(sum(quantity_base),0)::text AS classified
  FROM inventory_scope_balance WHERE installation_id=$1 AND branch_id=$2
   AND warehouse_id=$3 AND product_id=$4`,[t,b,w,p]);
 if(q(stock.available)-q(total.rows[0]?.classified??"0")<q(input.quantityBase))
  throw new InventoryFault(409,"INSUFFICIENT_UNASSIGNED_STOCK");
 const r=await db.query<{id:string}>(`INSERT INTO inventory_scope_assignment
  (installation_id,branch_id,warehouse_id,product_id,location_id,lot_id,
   quantity_base,actor_id,request_id) VALUES($1,$2,$3,$4,$5,$6,$7::numeric,$8,$9)
   RETURNING id`,
  [t,b,w,p,input.locationId??null,input.lotId??null,
   input.quantityBase,c.actorId,c.requestId]);
 return {status:201,body:{id:r.rows[0]!.id,productId:p,
  locationId:input.locationId??null,lotId:input.lotId??null,
  quantityBase:input.quantityBase,stock:await balance(db,t,input,p)}};
}
/** Returns all eligible lot/location choices, never silently truncates
 * source-critical stock selectors after 100 rows. The UI can search/filter
 * the complete result without inventing a stock fact. */
export async function stockScopes(db:PoolClient,t:string,s:WarehouseScope,p:string){
 await requireT3b(db);
 const locations=await db.query(`SELECT id,code,name FROM inventory_storage_location
  WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND active
  ORDER BY code`,[t,s.branchId,s.warehouseId]);
 const lots=await db.query(`SELECT id,lot_code AS "lotCode",expiry_date AS "expiryDate"
  FROM inventory_product_lot WHERE installation_id=$1 AND branch_id=$2
  AND product_id=$3 AND (expiry_date IS NULL OR expiry_date>=CURRENT_DATE)
  ORDER BY expiry_date NULLS LAST,lot_code`,[t,s.branchId,p]);
 const scoped=await db.query(`SELECT location_id AS "locationId",lot_id AS "lotId",
  quantity_base::text AS "quantityBase" FROM inventory_scope_balance
  WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND product_id=$4
  AND quantity_base>0 ORDER BY location_id NULLS FIRST,lot_id NULLS FIRST`,
  [t,s.branchId,s.warehouseId,p]);
 const tracking=await db.query(`SELECT require_location AS "requireLocation",
  require_lot AS "requireLot",revision::text FROM inventory_product_tracking
  WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND product_id=$4`,
  [t,s.branchId,s.warehouseId,p]);
 return {locations:locations.rows,lots:lots.rows,scopes:scoped.rows,
  policy:tracking.rows[0]??{requireLocation:false,requireLot:false,revision:"0"}};
}
export async function directIssueHistory(db:PoolClient,t:string,s:WarehouseScope,orderId:string){
 await requireT3b(db);
 const r=await db.query(`SELECT d.id,d.order_id AS "orderId",d.version_no AS version,
  d.issued_at AS "issuedAt",d.allow_negative AS "allowNegative",
  l.source_line AS "sourceLine",l.order_line_no AS "lineNo",
  l.product_id AS "productId",l.quantity_base::text AS "quantityBase",
  l.location_id AS "locationId",l.lot_id AS "lotId"
 FROM sales_direct_issue d JOIN sales_direct_issue_line l
  ON l.installation_id=d.installation_id AND l.branch_id=d.branch_id AND l.issue_id=d.id
 WHERE d.installation_id=$1 AND d.branch_id=$2 AND d.warehouse_id=$3 AND d.order_id=$4
 ORDER BY d.issued_at,d.id,l.source_line LIMIT 500`,
 [t,s.branchId,s.warehouseId,orderId]);
 return r.rows;
}
/** Complete aggregate, not first 500 audit events: safe for large partial issues. */
export async function directIssueTotals(db:PoolClient,t:string,s:WarehouseScope,orderId:string){
 await requireT3b(db);
 const r=await db.query<{
  lineNo:number;productId:string;baseUnit:string;issuedBase:string;
 }>(`
 SELECT l.line_no AS "lineNo",l.product_id AS "productId",
  p.base_unit AS "baseUnit",coalesce(issued.qty,0)::text AS "issuedBase"
 FROM sales_order o
 JOIN sales_order_line l ON l.installation_id=o.installation_id AND l.branch_id=o.branch_id
   AND l.order_id=o.id AND l.version_no=o.current_version
 JOIN catalog_product p ON p.installation_id=l.installation_id AND p.branch_id=l.branch_id
  AND p.id=l.product_id
 LEFT JOIN LATERAL (
  SELECT sum(i.quantity_base) AS qty FROM sales_direct_issue d
  JOIN sales_direct_issue_line i ON i.installation_id=d.installation_id
   AND i.branch_id=d.branch_id AND i.issue_id=d.id
  WHERE d.installation_id=o.installation_id AND d.branch_id=o.branch_id
   AND d.order_id=o.id AND d.version_no=o.current_version
   AND d.warehouse_id=$3 AND i.order_line_no=l.line_no
 ) issued ON TRUE
 WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$4
   AND EXISTS(SELECT 1 FROM sales_order_version_context c
    WHERE c.installation_id=o.installation_id AND c.branch_id=o.branch_id
     AND c.order_id=o.id AND c.version_no=o.current_version
     AND c.warehouse_id=$3 AND c.delivery_choice='MANUAL')
 ORDER BY l.line_no`,[t,s.branchId,s.warehouseId,orderId]);
 return r.rows;
}
export async function reconcileManualIssues(db:PoolClient,t:string,s:WarehouseScope,orderId:string){
 await requireT3b(db);
 const rows=await db.query<{lineNo:number;productId:string;issueId:string;
  sourceLine:number;issued:string;posted:string;movementCount:string}>(`
 SELECT l.order_line_no AS "lineNo",l.product_id AS "productId",
  d.id AS "issueId",l.source_line AS "sourceLine",
  l.quantity_base::text AS issued,
  coalesce(-sum(m.delta_base),0)::text AS posted,
  count(m.id)::text AS "movementCount"
 FROM sales_direct_issue d JOIN sales_direct_issue_line l ON
  l.installation_id=d.installation_id AND l.branch_id=d.branch_id AND l.issue_id=d.id
 LEFT JOIN inventory_ledger m ON m.installation_id=d.installation_id
  AND m.branch_id=d.branch_id AND m.warehouse_id=d.warehouse_id
  AND m.source_type='FULFILLMENT' AND m.kind='ISSUE'
  AND m.source_id=d.id AND m.source_line=l.source_line
  AND m.product_id=l.product_id
 WHERE d.installation_id=$1 AND d.branch_id=$2 AND d.warehouse_id=$3
  AND d.order_id=$4
 GROUP BY l.order_line_no,l.product_id,d.id,l.source_line,l.quantity_base
 ORDER BY d.id,l.source_line`,[t,s.branchId,s.warehouseId,orderId]);
 const matched=rows.rows.every(x=>q(x.issued)===q(x.posted)&&x.movementCount==="1");
 const extra=await db.query<{n:string}>(`
 SELECT count(*)::text AS n FROM inventory_ledger m
 JOIN sales_direct_issue d ON d.installation_id=m.installation_id
  AND d.branch_id=m.branch_id AND d.id=m.source_id
 WHERE d.installation_id=$1 AND d.branch_id=$2 AND d.warehouse_id=$3
  AND d.order_id=$4 AND m.kind='ISSUE' AND m.source_type='FULFILLMENT'
  AND NOT EXISTS (
   SELECT 1 FROM sales_direct_issue_line l
   WHERE l.installation_id=m.installation_id AND l.branch_id=m.branch_id
    AND l.issue_id=m.source_id AND l.source_line=m.source_line
    AND l.product_id=m.product_id AND l.quantity_base=-m.delta_base
  )`,[t,s.branchId,s.warehouseId,orderId]);
 const warehouse=await db.query<{productId:string;onHand:string;ledgerTotal:string}>(`
 SELECT p.id AS "productId",coalesce(v.on_hand,0)::text AS "onHand",
   coalesce((SELECT sum(l.delta_base) FROM inventory_ledger l
    WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.warehouse_id=$3
     AND l.product_id=p.id),0)::text AS "ledgerTotal"
 FROM catalog_product p LEFT JOIN inventory_stock_balance v
  ON v.installation_id=p.installation_id AND v.branch_id=p.branch_id
   AND v.warehouse_id=$3 AND v.product_id=p.id
 WHERE p.installation_id=$1 AND p.branch_id=$2
   AND p.id IN (SELECT DISTINCT l.product_id FROM sales_direct_issue_line l
    JOIN sales_direct_issue d ON d.installation_id=l.installation_id
     AND d.branch_id=l.branch_id AND d.id=l.issue_id
    WHERE d.installation_id=$1 AND d.branch_id=$2
     AND d.warehouse_id=$3 AND d.order_id=$4)`,
 [t,s.branchId,s.warehouseId,orderId]);
 const balanceMatched=warehouse.rows.every(x=>q(x.onHand)===q(x.ledgerTotal));
 return {orderId,warehouseId:s.warehouseId,
  reconciled:matched&&balanceMatched&&extra.rows[0]?.n==="0",
  unmatchedMovementCount:Number(extra.rows[0]?.n??"0"),lines:rows.rows.map(x=>({
    issueId:x.issueId,lineNo:x.lineNo,sourceLine:x.sourceLine,
    productId:x.productId,quantityBase:x.issued,postedBase:x.posted,
    movementCount:Number(x.movementCount)})),
  stock:warehouse.rows};
}
export async function issueManualStock(db:PoolClient,c:MutationContext,input:DirectIssueInput){
 await requireT3b(db);
 const t=c.installationId,b=input.branchId,w=input.warehouseId;
 await locked(db,t,input);
 const sale=await db.query<{
  revision:string;status:string;version_state:string;current_version:number;
  delivery_choice:string;warehouse_id:string;source_type:string;
  fulfillment_status:string;delivery_status:string;
 }>(`SELECT o.revision::text,o.status,v.state AS version_state,o.current_version,
   c.delivery_choice,c.warehouse_id,o.source_type,o.fulfillment_status,o.delivery_status
 FROM sales_order o JOIN sales_order_version v ON v.installation_id=o.installation_id
   AND v.branch_id=o.branch_id AND v.order_id=o.id AND v.version_no=$4
 JOIN sales_order_version_context c ON c.installation_id=v.installation_id
   AND c.branch_id=v.branch_id AND c.order_id=v.order_id AND c.version_no=v.version_no
 WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$3 FOR UPDATE OF o`,
 [t,b,input.orderId,input.version]);
 const o=sale.rows[0];
 if(!o||o.status!=="CONFIRMED"||o.version_state!=="CONFIRMED"||
   o.current_version!==input.version||o.delivery_choice!=="MANUAL"||
   o.warehouse_id!==w||o.source_type==="RETAIL")
  throw new InventoryFault(409,"CONFIRMED_MANUAL_ORDER_REQUIRED");
 requireRevision(c.expectedRevision,Number(o.revision));
 if(o.fulfillment_status==="COMPLETED"||o.delivery_status!=="NOT_DISPATCHED")
  throw new InventoryFault(409,"ORDER_ALREADY_EXECUTING");
 const held=await db.query(`SELECT 1 FROM inventory_reservation
  WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND state='ACTIVE' LIMIT 1`,
  [t,b,input.orderId]);
 if(held.rowCount)throw new InventoryFault(409,"RELEASE_ORDER_HOLDS_FIRST");
 const orderLines=await db.query<{
  line_no:number;product_id:string;pricing_engine:string;
  price_snapshot:{normalizedBaseQuantity?:unknown}|null;
  quantity:string;unit_code:string;base_unit:string;
 }>(`SELECT l.line_no,l.product_id,l.pricing_engine,l.price_snapshot,
  l.quantity::text,l.unit_code,p.base_unit FROM sales_order_line l
 JOIN catalog_product p ON p.installation_id=l.installation_id
  AND p.branch_id=l.branch_id AND p.id=l.product_id
 WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3 AND l.version_no=$4
 ORDER BY l.line_no FOR SHARE OF l`,[t,b,input.orderId,input.version]);
 const all=new Map<number,{productId:string;ordered:bigint}>();
 for(const row of orderLines.rows){
  const raw=row.pricing_engine==="R1"?row.price_snapshot?.normalizedBaseQuantity:
    row.unit_code===row.base_unit?row.quantity:null;
  if(!validBaseQty(raw))throw new InventoryFault(409,"BASE_QUANTITY_SNAPSHOT_REQUIRED");
  all.set(row.line_no,{productId:row.product_id,ordered:q(raw)});
 }
 const previous=await db.query<{line_no:number;issued:string}>(`
 SELECT l.order_line_no AS line_no,sum(l.quantity_base)::text AS issued
 FROM sales_direct_issue d JOIN sales_direct_issue_line l
  ON l.installation_id=d.installation_id AND l.branch_id=d.branch_id AND l.issue_id=d.id
 WHERE d.installation_id=$1 AND d.branch_id=$2 AND d.order_id=$3 AND d.version_no=$4
 GROUP BY l.order_line_no`,[t,b,input.orderId,input.version]);
 const prev=new Map(previous.rows.map(row=>[row.line_no,q(row.issued)]));
 const requested=new Map<number,bigint>(),byProduct=new Map<string,bigint>(),seen=new Set<string>();
 const byScope=new Map<string,{productId:string;locationId?:string;lotId?:string;qty:bigint}>();
 const byUntracked=new Map<string,bigint>();
 for(const line of input.lines){
  const source=all.get(line.lineNo);
  if(!source)throw new InventoryFault(409,"ORDER_LINE_UNAVAILABLE");
  const key=[line.lineNo,line.locationId??"",line.lotId??""].join(":");
  if(seen.has(key))throw new InventoryFault(400,"DUPLICATE_ISSUE_SCOPE");
  seen.add(key);
  await checkScope(db,t,input,source.productId,line.locationId,line.lotId);
  const qty=q(line.quantityBase);
  requested.set(line.lineNo,(requested.get(line.lineNo)??0n)+qty);
  byProduct.set(source.productId,(byProduct.get(source.productId)??0n)+qty);
  if(!line.locationId&&!line.lotId)
   byUntracked.set(source.productId,(byUntracked.get(source.productId)??0n)+qty);
  else{
   const scopeKey=[source.productId,line.locationId??"",line.lotId??""].join(":");
   const old=byScope.get(scopeKey);
   byScope.set(scopeKey,{productId:source.productId,
    locationId:line.locationId,lotId:line.lotId,qty:(old?.qty??0n)+qty});
  }
 }
 for(const [lineNo,qty] of requested){
  if((prev.get(lineNo)??0n)+qty>all.get(lineNo)!.ordered)
   throw new InventoryFault(409,"ISSUE_EXCEEDS_ORDER_LINE");
 }
 // A scoped issue cannot borrow from another lot/bin. Unscoped stock must
 // never consume previously classified stock, even when warehouse total is high.
 for(const item of byScope.values()){
  const r=await db.query<{n:string}>(`SELECT coalesce(sum(quantity_base),0)::text AS n
    FROM inventory_scope_balance WHERE installation_id=$1 AND branch_id=$2
    AND warehouse_id=$3 AND product_id=$4
    AND location_id IS NOT DISTINCT FROM $5::uuid
    AND lot_id IS NOT DISTINCT FROM $6::uuid`,
    [t,b,w,item.productId,item.locationId??null,item.lotId??null]);
  if(q(r.rows[0]?.n??"0")<item.qty)
   throw new InventoryFault(409,"INSUFFICIENT_SCOPED_STOCK");
 }
 for(const [productId,quantity] of byUntracked){
  const stock=await balance(db,t,input,productId);
  const r=await db.query<{n:string}>(`SELECT coalesce(sum(quantity_base),0)::text AS n
    FROM inventory_scope_balance WHERE installation_id=$1 AND branch_id=$2
    AND warehouse_id=$3 AND product_id=$4`,[t,b,w,productId]);
  if(q(r.rows[0]?.n??"0")>0n&&q(stock.available)-q(r.rows[0]!.n)<quantity)
   throw new InventoryFault(409,"STOCK_CLASSIFIED_IN_OTHER_SCOPE");
 }
 let negativeRequired=false;
 for(const [productId,quantity] of byProduct){
  const stock=await balance(db,t,input,productId);
  if(quantity>q(stock.available)){
   negativeRequired=true;
   const pol=await db.query<{negative_issue_mode:ShortageMode}>(`
    SELECT negative_issue_mode FROM inventory_guard_policy
    WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3`,
    [t,b,w]);
   const mode=pol.rows[0]?.negative_issue_mode??"BLOCK";
   if(mode==="WARN")throw new InventoryFault(409,"NEGATIVE_ISSUE_REQUIRES_POLICY_ALLOW");
   if(mode!=="ALLOW"||!input.allowNegative)
    throw new InventoryFault(409,"INSUFFICIENT_AVAILABLE_STOCK");
   if(!await hasPermission(db,{installationId:t,actorId:c.actorId,
      permission:"inventory.negative.issue",branchId:b,warehouseId:w}))
    throw new InventoryFault(403,"NEGATIVE_ISSUE_DENIED");
   if(input.lines.some(x=>all.get(x.lineNo)?.productId===productId&&(x.lotId||x.locationId)))
    throw new InventoryFault(409,"NEGATIVE_TRACKED_STOCK_DENIED");
   const classified=await db.query<{n:string}>(`SELECT coalesce(sum(quantity_base),0)::text AS n
     FROM inventory_scope_balance WHERE installation_id=$1 AND branch_id=$2
      AND warehouse_id=$3 AND product_id=$4`,[t,b,w,productId]);
   if(q(classified.rows[0]?.n??"0")>0n)
    throw new InventoryFault(409,"NEGATIVE_TRACKED_STOCK_DENIED");
  }
 }
 const issueId=randomUUID();
 await db.query(`INSERT INTO sales_direct_issue
  (installation_id,branch_id,id,order_id,version_no,warehouse_id,allow_negative,
   actor_id,request_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
  [t,b,issueId,input.orderId,input.version,w,negativeRequired&&input.allowNegative,
   c.actorId,c.requestId]);
 const posted=[];
 for(let i=0;i<input.lines.length;i++){
  const line=input.lines[i]!,productId=all.get(line.lineNo)!.productId;
  const seq=i+1;
  await db.query(`INSERT INTO sales_direct_issue_line
   (installation_id,branch_id,issue_id,source_line,order_line_no,product_id,
    quantity_base,location_id,lot_id)
   VALUES($1,$2,$3,$4,$5,$6,$7::numeric,$8,$9)`,
   [t,b,issueId,seq,line.lineNo,productId,line.quantityBase,
    line.locationId??null,line.lotId??null]);
  const movement=await db.query<{id:string}>(`INSERT INTO inventory_ledger
   (installation_id,branch_id,warehouse_id,product_id,kind,source_type,source_id,
    source_line,delta_base,actor_id,request_id)
   VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,$6,-$7::numeric,$8,$9)
   RETURNING id`,
   [t,b,w,productId,issueId,seq,line.quantityBase,c.actorId,c.requestId]);
  posted.push({movementId:movement.rows[0]!.id,lineNo:line.lineNo,productId,
   quantityBase:line.quantityBase,locationId:line.locationId??null,lotId:line.lotId??null});
 }
 const remaining=Array.from(all,([number,row])=>({
  lineNo:number,remainingBase:stockUnitsDecimal(row.ordered-
   (prev.get(number)??0n)-(requested.get(number)??0n)),
 }));
 const completed=remaining.every(x=>q(x.remainingBase)===0n);
 const updated=await db.query<{revision:string}>(`UPDATE sales_order SET
  fulfillment_status=$4,revision=revision+1,updated_at=now()
  WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,
  [t,b,input.orderId,completed?"COMPLETED":"PARTIAL"]);
 const stock=[];
 for(const productId of byProduct.keys())
  stock.push({productId,...await balance(db,t,input,productId)});
 return {status:201,body:{id:issueId,orderId:input.orderId,version:input.version,
  warehouseId:w,revision:Number(updated.rows[0]!.revision),
  fulfillmentStatus:completed?"COMPLETED":"PARTIAL",
  deliveryStatus:"NOT_DISPATCHED",paymentPosted:false,receivablePosted:false,
  posted,remaining,stock,negativeIssued:negativeRequired}};
}
