import type { PoolClient } from "pg";
import type { MutationContext } from "./mutation.ts";
import { requireRevision } from "./mutation.ts";

/** R3.1: warehouse locking serializes all stock/reservation writers in one scope.
 * The ledger is the sole stock authority, never a cached client balance. */
export class InventoryFault extends Error {
  readonly status:number;
  readonly code:string;
  constructor(status:number, code:string){
    super(code);this.status=status;this.code=code;
  }
}
/** Legacy allocateWarehouseDemand, adapted to ERP's exact scaled bigint units.
 * Source: NPP-Platform d39e8a87, sales-fulfillment.js:178-200.
 * One warehouse/product scope, ordered in caller-defined stable order.
 * Negative availability is a shortage, not a negative reservation.
 * T0 characterization only: wire to transactional demand storage after
 * migration/lock review; do not weaken existing ledger constraints here.
 */
export function allocateWarehouseDemand<T extends {ordered:bigint}>(
 lines:readonly T[],available:bigint,allowBackorder:boolean,
){
 if(lines.some(line=>line.ordered<=0n))throw new InventoryFault(400,"INVALID_QUANTITY");
 let remaining=available>0n?available:0n;
 const required=lines.reduce((sum,line)=>sum+line.ordered,0n);
 if(!allowBackorder&&required>remaining)return {
   ok:false as const,code:"SALES_ORDER_INSUFFICIENT_STOCK" as const,
   required,available:remaining,
 };
 return {ok:true as const,allocations:lines.map(line=>{
   const reserved=line.ordered<remaining?line.ordered:remaining;
   remaining-=reserved;
   return {...line,reserved,backordered:line.ordered-reserved};
 })};
}

/** Exact six-decimal minor units for inventory; never use JS float. */
export function stockDecimalUnits(value:string):bigint{
 const m=/^(-?)([0-9]{1,18})(?:\.([0-9]{1,6}))?$/.exec(value);
 if(!m)throw new InventoryFault(409,"INVALID_STOCK_DECIMAL");
 const unit=BigInt(m[2]!)*1000000n+BigInt((m[3]??"").padEnd(6,"0"));
 return m[1]==="-"?-unit:unit;
}
export function stockUnitsDecimal(units:bigint):string{
 const neg=units<0n?"-":"",n=units<0n?-units:units;
 return neg+(n/1000000n).toString()+"."+(n%1000000n).toString().padStart(6,"0");
}

export type WarehouseScope={branchId:string;warehouseId:string};
export type OpeningInput=WarehouseScope&{productId:string;quantity:string};
export type ReserveInput=WarehouseScope&{orderId:string;version:number;lineNo:number};
const DECIMAL=/^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,6})?$/;
export function validBaseQty(v:unknown):v is string {
 return typeof v==="string"&&DECIMAL.test(v)&&/[1-9]/.test(v);
}
async function lockWarehouse(db:PoolClient,t:string,s:WarehouseScope):Promise<void>{
 const r=await db.query(
  "SELECT id FROM warehouse WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE",
  [t,s.branchId,s.warehouseId]);
 if(r.rowCount!==1)throw new InventoryFault(404,"WAREHOUSE_NOT_FOUND");
}
export type ShortageMode="BLOCK"|"WARN"|"ALLOW";
/** Warehouse policy read; absence means warning-first for demand, but
 * actual negative ledger posting remains deny-by-default. */
export async function readInventoryGuardPolicy(db:PoolClient,t:string,s:WarehouseScope){
 const q=await db.query<{reserveShortageMode:ShortageMode;revision:string}>(
  `SELECT reserve_shortage_mode AS "reserveShortageMode",revision::text AS revision
   FROM inventory_guard_policy WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3`,
  [t,s.branchId,s.warehouseId]);
 return {branchId:s.branchId,warehouseId:s.warehouseId,
  reserveShortageMode:q.rows[0]?.reserveShortageMode??"WARN",
  negativeIssueMode:"BLOCK",revision:Number(q.rows[0]?.revision??"0")};
}
export async function setInventoryGuardPolicy(db:PoolClient,ctx:MutationContext,
 s:WarehouseScope,mode:ShortageMode){
 await lockWarehouse(db,ctx.installationId,s);
 const old=await db.query<{revision:string}>(`SELECT revision::text AS revision
  FROM inventory_guard_policy WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3
  FOR UPDATE`,[ctx.installationId,s.branchId,s.warehouseId]);
 requireRevision(ctx.expectedRevision,Number(old.rows[0]?.revision??"0"));
 await db.query(`INSERT INTO inventory_guard_policy(
   installation_id,branch_id,warehouse_id,reserve_shortage_mode,updated_by)
   VALUES($1,$2,$3,$4,$5)
   ON CONFLICT (installation_id,branch_id,warehouse_id) DO UPDATE SET
   reserve_shortage_mode=EXCLUDED.reserve_shortage_mode,revision=inventory_guard_policy.revision+1,
   updated_by=EXCLUDED.updated_by,updated_at=now()`,
   [ctx.installationId,s.branchId,s.warehouseId,mode,ctx.actorId]);
 return {status:200,body:await readInventoryGuardPolicy(db,ctx.installationId,s)};
}

export async function balance(db:PoolClient,t:string,s:WarehouseScope,productId:string){
 const r=await db.query<{onHand:string;reserved:string;available:string}>(
  `SELECT on_hand::text AS "onHand",reserved::text AS "reserved",available::text AS "available"
   FROM inventory_stock_balance WHERE installation_id=$1 AND branch_id=$2
     AND warehouse_id=$3 AND product_id=$4`,
  [t,s.branchId,s.warehouseId,productId]);
 return r.rows[0]??{onHand:"0",reserved:"0",available:"0"};
}
export async function balances(db:PoolClient,t:string,s:WarehouseScope,offset=0){
 const r=await db.query(
  `SELECT v.product_id AS "productId",p.sku,p.name,p.base_unit AS "baseUnit",
    v.on_hand::text AS "onHand",v.reserved::text AS "reserved",
    v.available::text AS "available"
    FROM inventory_stock_balance v
    JOIN catalog_product p ON p.installation_id=v.installation_id
      AND p.branch_id=v.branch_id AND p.id=v.product_id
    WHERE v.installation_id=$1 AND v.branch_id=$2 AND v.warehouse_id=$3
    ORDER BY p.sku,v.product_id LIMIT 101 OFFSET $4`,
      [t,s.branchId,s.warehouseId,offset]);
 return {items:r.rows.slice(0,100),hasMore:r.rows.length>100};
}
export async function movements(db:PoolClient,t:string,s:WarehouseScope,offset=0){
 const r=await db.query(
  `SELECT l.id,l.product_id AS "productId",p.sku,p.name AS "productName",
       l.kind,l.source_type AS "sourceType",l.source_id AS "sourceId",
       l.source_line AS "sourceLine",l.delta_base::text AS "deltaBase",
       l.posted_at AS "postedAt",l.reversal_of AS "reversalOf"
   FROM inventory_ledger l
   JOIN catalog_product p ON p.installation_id=l.installation_id
     AND p.branch_id=l.branch_id AND p.id=l.product_id
   WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.warehouse_id=$3
   ORDER BY l.posted_at DESC,l.id DESC LIMIT 101 OFFSET $4`,
      [t,s.branchId,s.warehouseId,offset]);
 return {items:r.rows.slice(0,100),hasMore:r.rows.length>100};
}
/** Each page includes only one reservation lifecycle; released history cannot hide ACTIVE holds. */
export async function reservations(db:PoolClient,t:string,s:WarehouseScope,
 state:"ACTIVE"|"RELEASED"="ACTIVE",offset=0){
 const r=await db.query(
  `SELECT r.id,r.product_id AS "productId",p.sku,p.name AS "productName",
    r.order_id AS "orderId",o.document_no AS "documentNo",r.version_no AS version,
    r.line_no AS "lineNo",r.quantity_base::text AS "quantityBase",
    r.backordered_base::text AS "backorderedBase",
    r.state,r.revision::text,r.created_at AS "createdAt",r.released_at AS "releasedAt"
    FROM inventory_reservation r
    JOIN catalog_product p ON p.installation_id=r.installation_id
      AND p.branch_id=r.branch_id AND p.id=r.product_id
    JOIN sales_order o ON o.installation_id=r.installation_id
      AND o.branch_id=r.branch_id AND o.id=r.order_id
    WHERE r.installation_id=$1 AND r.branch_id=$2 AND r.warehouse_id=$3 AND r.state=$4
    ORDER BY r.created_at DESC,r.id DESC LIMIT 101 OFFSET $5`,
    [t,s.branchId,s.warehouseId,state,offset]);
 return {items:r.rows.slice(0,100),hasMore:r.rows.length>100};
}
export async function openStock(db:PoolClient,ctx:MutationContext,input:OpeningInput){
 if(!validBaseQty(input.quantity))throw new InventoryFault(400,"INVALID_QUANTITY");
 const t=ctx.installationId,b=input.branchId,w=input.warehouseId,p=input.productId;
 await lockWarehouse(db,t,input);
 const prod=await db.query(
  "SELECT id FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active FOR SHARE",
  [t,b,p]);
 if(prod.rowCount!==1)throw new InventoryFault(409,"PRODUCT_UNAVAILABLE");
 // Opening may be posted exactly once per warehouse/product, before all other facts.
 const existing=await db.query<{n:string}>(
  `SELECT ((SELECT count(*) FROM inventory_ledger
           WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND product_id=$4)
         +(SELECT count(*) FROM inventory_reservation
           WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND product_id=$4))::text AS n`,
  [t,b,w,p]);
 if(existing.rows[0]?.n!=="0")throw new InventoryFault(409,"OPENING_ALREADY_EXISTS");
 const inserted=await db.query<{id:string;deltaBase:string}>(
  `INSERT INTO inventory_ledger(installation_id,branch_id,warehouse_id,product_id,
    kind,source_type,source_id,source_line,delta_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,'OPENING','OPENING',$4,1,$5::numeric,$6,$7)
    RETURNING id,delta_base::text AS "deltaBase"`,
  [t,b,w,p,input.quantity,ctx.actorId,ctx.requestId]);
 return {status:201,body:{id:inserted.rows[0]!.id,kind:"OPENING",productId:p,
   warehouseId:w,deltaBase:inserted.rows[0]!.deltaBase,stock:await balance(db,t,input,p)}};
}
export async function reserveStock(db:PoolClient,ctx:MutationContext,input:ReserveInput){
 const t=ctx.installationId,b=input.branchId,w=input.warehouseId;
 await lockWarehouse(db,t,input);
 // Lock sale parent to serialize reservation with amendment/cancellation.
 const line=await db.query<{
   status:string;current_version:number;state:string;product_id:string;
   pricing_engine:string;quantity:string;unit_code:string;base_unit:string;
   price_snapshot:Record<string,unknown>|null;
 }>(`SELECT o.status,o.current_version,v.state,l.product_id,l.pricing_engine,
     l.quantity::text,l.unit_code,p.base_unit,l.price_snapshot
   FROM sales_order o
   JOIN sales_order_version v ON v.installation_id=o.installation_id
     AND v.branch_id=o.branch_id AND v.order_id=o.id AND v.version_no=$4
   JOIN sales_order_line l ON l.installation_id=v.installation_id
     AND l.branch_id=v.branch_id AND l.order_id=v.order_id
     AND l.version_no=v.version_no AND l.line_no=$5
   JOIN catalog_product p ON p.installation_id=l.installation_id
     AND p.branch_id=l.branch_id AND p.id=l.product_id
   WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$3 FOR SHARE OF o`,
   [t,b,input.orderId,input.version,input.lineNo]);
 const order=line.rows[0];
 if(!order||order.status!=="CONFIRMED"||order.state!=="CONFIRMED"||
    order.current_version!==input.version)
   throw new InventoryFault(409,"CONFIRMED_ORDER_REQUIRED");
 const quantity=order.pricing_engine==="R1"
   ?order.price_snapshot?.normalizedBaseQuantity
   :order.unit_code===order.base_unit?order.quantity:null;
 if(!validBaseQty(quantity))throw new InventoryFault(409,"BASE_QUANTITY_SNAPSHOT_REQUIRED");
 // Policy and allocation are read while holding the warehouse lock.
 // A rolling backend on pre-0021 schema keeps strict reserve behavior.
 const ready=await db.query<{ok:boolean}>(
  "SELECT to_regclass('public.inventory_guard_policy') IS NOT NULL AS ok");
 let shortageMode:"ALLOW"|"WARN"|"BLOCK"="BLOCK";
 if(ready.rows[0]?.ok===true){
  const policy=await db.query<{reserve_shortage_mode:"ALLOW"|"WARN"|"BLOCK"}>(
   `SELECT reserve_shortage_mode FROM inventory_guard_policy
    WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 FOR SHARE`,
   [t,b,w]);
  shortageMode=policy.rows[0]?.reserve_shortage_mode??"WARN";
 }
 const stock=await balance(db,t,input,order.product_id);
 const required=stockDecimalUnits(quantity),available=stockDecimalUnits(stock.available);
 const result=allocateWarehouseDemand([{ordered:required}],available,shortageMode!=="BLOCK");
 if(!result.ok)throw new InventoryFault(409,"INSUFFICIENT_AVAILABLE_STOCK");
 const reserved=stockUnitsDecimal(result.allocations[0]!.reserved);
 const backordered=stockUnitsDecimal(result.allocations[0]!.backordered);
 const r=await db.query<{id:string;qty:string;backordered:string}>(
  `INSERT INTO inventory_reservation(installation_id,branch_id,warehouse_id,product_id,
    order_id,version_no,line_no,quantity_base,backordered_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8::numeric,$9::numeric,$10,$11)
    RETURNING id,quantity_base::text AS qty,backordered_base::text AS backordered`,
  [t,b,w,order.product_id,input.orderId,input.version,input.lineNo,
   reserved,backordered,ctx.actorId,ctx.requestId]);
 const warnings=result.allocations[0]!.backordered>0n&&shortageMode==="WARN"
   ?[{code:"INSUFFICIENT_AVAILABLE_STOCK",severity:"WARN",
      message:"Tồn kho không đủ. Đã giữ phần có và ghi phần chờ hàng."}]:[];
 return {status:201,body:{id:r.rows[0]!.id,orderId:input.orderId,
   warehouseId:w,productId:order.product_id,quantityBase:r.rows[0]!.qty,
   backorderedBase:r.rows[0]!.backordered,warnings,
   state:"ACTIVE",revision:0,stock:await balance(db,t,input,order.product_id)}};
}
export async function releaseStock(db:PoolClient,ctx:MutationContext,scope:WarehouseScope,id:string){
 const t=ctx.installationId,b=scope.branchId,w=scope.warehouseId;
 await lockWarehouse(db,t,scope);
 const q=await db.query<{product_id:string;state:string;revision:string}>(
  `SELECT product_id,state,revision::text FROM inventory_reservation
     WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3 AND id=$4 FOR UPDATE`,
  [t,b,w,id]);
 const record=q.rows[0];
 if(!record)throw new InventoryFault(404,"RESERVATION_NOT_FOUND");
 requireRevision(ctx.expectedRevision,Number(record.revision));
 if(record.state!=="ACTIVE")throw new InventoryFault(409,"RESERVATION_NOT_ACTIVE");
 const changed=await db.query<{revision:string}>(
  `UPDATE inventory_reservation SET state='RELEASED',revision=revision+1,released_at=now()
   WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,
  [t,b,id]);
 return {status:200,body:{id,state:"RELEASED",revision:Number(changed.rows[0]!.revision),
   stock:await balance(db,t,scope,record.product_id)}};
}
