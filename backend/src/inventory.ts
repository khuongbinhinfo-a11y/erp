import type { PoolClient } from "pg";
import type { MutationContext } from "./mutation.ts";
import { requireRevision } from "./mutation.ts";

/** R3.1: warehouse locking serializes all stock/reservation writers in one scope.
 * The ledger is the sole stock authority, never a cached client balance. */
export class InventoryFault extends Error {
  constructor(readonly status:number, readonly code:string){super(code);}
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
export async function balance(db:PoolClient,t:string,s:WarehouseScope,productId:string){
 const r=await db.query<{onHand:string;reserved:string;available:string}>(
  `SELECT on_hand::text AS "onHand",reserved::text AS "reserved",available::text AS "available"
   FROM inventory_stock_balance WHERE installation_id=$1 AND branch_id=$2
     AND warehouse_id=$3 AND product_id=$4`,
  [t,s.branchId,s.warehouseId,productId]);
 return r.rows[0]??{onHand:"0",reserved:"0",available:"0"};
}
export async function balances(db:PoolClient,t:string,s:WarehouseScope){
 const r=await db.query(
  `SELECT v.product_id AS "productId",p.sku,p.name,p.base_unit AS "baseUnit",
    v.on_hand::text AS "onHand",v.reserved::text AS "reserved",
    v.available::text AS "available"
    FROM inventory_stock_balance v
    JOIN catalog_product p ON p.installation_id=v.installation_id
      AND p.branch_id=v.branch_id AND p.id=v.product_id
    WHERE v.installation_id=$1 AND v.branch_id=$2 AND v.warehouse_id=$3
    ORDER BY p.sku,v.product_id LIMIT 100`,[t,s.branchId,s.warehouseId]);
 return r.rows;
}
export async function movements(db:PoolClient,t:string,s:WarehouseScope){
 const r=await db.query(
  `SELECT id,product_id AS "productId",kind,source_type AS "sourceType",
       source_id AS "sourceId",source_line AS "sourceLine",
       delta_base::text AS "deltaBase",posted_at AS "postedAt",reversal_of AS "reversalOf"
   FROM inventory_ledger WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3
   ORDER BY posted_at DESC,id DESC LIMIT 100`,[t,s.branchId,s.warehouseId]);
 return r.rows;
}
export async function reservations(db:PoolClient,t:string,s:WarehouseScope){
 const r=await db.query(
  `SELECT id,product_id AS "productId",order_id AS "orderId",version_no AS version,
    line_no AS "lineNo",quantity_base::text AS "quantityBase",state,revision::text,
    created_at AS "createdAt",released_at AS "releasedAt"
    FROM inventory_reservation WHERE installation_id=$1 AND branch_id=$2 AND warehouse_id=$3
    ORDER BY created_at DESC,id DESC LIMIT 100`,[t,s.branchId,s.warehouseId]);
 return r.rows;
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
 const stock=await balance(db,t,input,order.product_id);
 const enough=await db.query<{ok:boolean}>(
  "SELECT $1::numeric <= $2::numeric AS ok",[quantity,stock.available]);
 if(enough.rows[0]?.ok!==true)throw new InventoryFault(409,"INSUFFICIENT_AVAILABLE_STOCK");
 const r=await db.query<{id:string;qty:string}>(
  `INSERT INTO inventory_reservation(installation_id,branch_id,warehouse_id,product_id,
    order_id,version_no,line_no,quantity_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8::numeric,$9,$10)
    RETURNING id,quantity_base::text AS qty`,
  [t,b,w,order.product_id,input.orderId,input.version,input.lineNo,quantity,ctx.actorId,ctx.requestId]);
 return {status:201,body:{id:r.rows[0]!.id,orderId:input.orderId,
   warehouseId:w,productId:order.product_id,quantityBase:r.rows[0]!.qty,
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
