import {randomUUID} from "node:crypto";
import type {PoolClient} from "pg";
import {requireRevision,type MutationContext} from "./mutation.ts";
import {InventoryFault,stockDecimalUnits,stockUnitsDecimal,validBaseQty,type WarehouseScope} from "./inventory.ts";
import {checkScope} from "./direct_stock_issue.ts";

export type TripScope=WarehouseScope&{orderId:string;version:number};
export type TripPrepareItem={lineNo:number;pickedBase:string;packedBase:string;locationId?:string;lotId?:string};
export type TripDispatchItem={preparationId:string;sourceLine:number;quantityBase:string};
const q=stockDecimalUnits;
function zeroOrPositive(value:unknown):value is string{
 if(typeof value!=="string")return false;
 try{return q(value)>=0n;}catch{return false;}
}
function mustQty(value:unknown):asserts value is string{
 if(!validBaseQty(value))throw new InventoryFault(400,"INVALID_QUANTITY");
}
export async function requireT3c(db:PoolClient):Promise<void>{
 const r=await db.query<{ok:boolean}>(`SELECT EXISTS(
   SELECT 1 FROM schema_migrations WHERE version='0025_t3c_trip_preparation_dispatch.sql'
 ) AS ok`);
 if(!r.rows[0]?.ok)throw new InventoryFault(503,"T3C_MIGRATION_REQUIRED");
}
async function lockTrip(db:PoolClient,c:MutationContext,input:TripScope){
 const t=c.installationId,b=input.branchId,w=input.warehouseId;
 const wh=await db.query("SELECT 1 FROM warehouse WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE",
  [t,b,w]);
 if(!wh.rowCount)throw new InventoryFault(404,"WAREHOUSE_NOT_FOUND");
 const rows=await db.query<{revision:string;status:string;version_state:string;
  current_version:number;fulfillment_status:string;delivery_status:string;
  payment_status:string;delivery_choice:string;chosen_warehouse:string}>(`
  SELECT o.revision::text,o.status,v.state AS version_state,o.current_version,
   o.fulfillment_status,o.delivery_status,o.payment_status,
   x.delivery_choice,x.warehouse_id AS chosen_warehouse
  FROM sales_order o
  JOIN sales_order_version v ON v.installation_id=o.installation_id
   AND v.branch_id=o.branch_id AND v.order_id=o.id AND v.version_no=o.current_version
  JOIN sales_order_version_context x ON x.installation_id=v.installation_id
   AND x.branch_id=v.branch_id AND x.order_id=v.order_id AND x.version_no=v.version_no
  WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$3 FOR UPDATE OF o
 `,[t,b,input.orderId]);
 const row=rows.rows[0];
 if(!row||row.status!=="CONFIRMED"||row.version_state!=="CONFIRMED"||
    row.current_version!==input.version||row.delivery_choice!=="TRIP"||
    row.chosen_warehouse!==w||row.delivery_status!=="NOT_DISPATCHED"||
    row.payment_status!=="NOT_DUE"||row.fulfillment_status==="COMPLETED")
  throw new InventoryFault(409,"TRIP_ORDER_NOT_READY");
 requireRevision(c.expectedRevision,Number(row.revision));
 return row;
}

/** Exact immutable warehouse progress; no cached calculation decides an OUT. */
export async function tripWork(db:PoolClient,t:string,input:TripScope){
 await requireT3c(db);
 const b=input.branchId,w=input.warehouseId,id=input.orderId,v=input.version;
 const order=await db.query<{revision:string;status:string;current_version:number;
  delivery_choice:string;warehouse_id:string;fulfillment_status:string;
  delivery_status:string;payment_status:string}>(`
  SELECT o.revision::text,o.status,o.current_version,c.delivery_choice,c.warehouse_id,
   o.fulfillment_status,o.delivery_status,o.payment_status
  FROM sales_order o JOIN sales_order_version_context c
   ON c.installation_id=o.installation_id AND c.branch_id=o.branch_id
    AND c.order_id=o.id AND c.version_no=o.current_version
  WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$3
 `,[t,b,id]);
 const o=order.rows[0];
 if(!o||o.current_version!==v||o.delivery_choice!=="TRIP"||
  o.warehouse_id!==w)throw new InventoryFault(409,"TRIP_ORDER_UNAVAILABLE");
 const lines=await db.query<{line_no:number;product_id:string;sku:string;product_name:string;
  unit_code:string;quantity:string;reservation_id:string|null;reserved:string;backordered:string}>(`
  SELECT l.line_no,l.product_id,l.sku,l.product_name,l.unit_code,l.quantity::text,
   r.id AS reservation_id,coalesce(r.quantity_base,0)::text AS reserved,
   coalesce(r.backordered_base,0)::text AS backordered
  FROM sales_order_line l LEFT JOIN inventory_reservation r
   ON r.installation_id=l.installation_id AND r.branch_id=l.branch_id
    AND r.order_id=l.order_id AND r.version_no=l.version_no
    AND r.line_no=l.line_no AND r.state='ACTIVE'
  WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3
    AND l.version_no=$4 ORDER BY l.line_no
 `,[t,b,id,v]);
 const prep=await db.query<{preparation_id:string;source_line:number;order_line_no:number;
  product_id:string;picked:string;packed:string;location_id:string|null;lot_id:string|null;
  dispatched:string}>(`
  SELECT p.preparation_id,p.source_line,p.order_line_no,p.product_id,
   p.picked_base::text AS picked,p.packed_base::text AS packed,
   p.location_id,p.lot_id,coalesce(d.issued,0)::text AS dispatched
  FROM sales_trip_preparation_line p JOIN sales_trip_preparation h
   ON h.installation_id=p.installation_id AND h.branch_id=p.branch_id
    AND h.id=p.preparation_id
  LEFT JOIN LATERAL (
   SELECT sum(x.quantity_base) AS issued FROM sales_trip_dispatch_line x
   WHERE x.installation_id=p.installation_id AND x.branch_id=p.branch_id
    AND x.preparation_id=p.preparation_id AND x.preparation_line_no=p.source_line
  ) d ON true
  WHERE h.installation_id=$1 AND h.branch_id=$2 AND h.warehouse_id=$3
   AND h.order_id=$4 AND h.version_no=$5
  ORDER BY h.prepared_at,p.preparation_id,p.source_line
 `,[t,b,w,id,v]);
 const result=lines.rows.map(line=>{
  const parts=prep.rows.filter(x=>x.order_line_no===line.line_no);
  const picked=parts.reduce((n,p)=>n+q(p.picked),0n);
  const packed=parts.reduce((n,p)=>n+q(p.packed),0n);
  const issued=parts.reduce((n,p)=>n+q(p.dispatched),0n);
  return {lineNo:line.line_no,productId:line.product_id,sku:line.sku,
   productName:line.product_name,unitCode:line.unit_code,quantity:line.quantity,
   reservationId:line.reservation_id,reservedBase:line.reserved,
   backorderedBase:line.backordered,pickedBase:stockUnitsDecimal(picked),
   packedBase:stockUnitsDecimal(packed),dispatchedBase:stockUnitsDecimal(issued),
   readyBase:stockUnitsDecimal(packed-issued),
   preparations:parts.map(p=>({preparationId:p.preparation_id,sourceLine:p.source_line,
    pickedBase:p.picked,packedBase:p.packed,dispatchedBase:p.dispatched,
    readyBase:stockUnitsDecimal(q(p.packed)-q(p.dispatched)),
    locationId:p.location_id,lotId:p.lot_id}))};
 });
 return {orderId:id,version:v,warehouseId:w,revision:Number(o.revision),
  status:o.status,fulfillmentStatus:o.fulfillment_status,
  deliveryStatus:o.delivery_status,paymentStatus:o.payment_status,lines:result,
  hasBackorder:result.some(x=>q(x.backorderedBase)>0n)};
}
export async function prepareTrip(db:PoolClient,c:MutationContext,input:TripScope&{lines:TripPrepareItem[]}){
 await requireT3c(db);
 if(!input.lines.length||input.lines.length>100)
  throw new InventoryFault(400,"TRIP_LINES_REQUIRED");
 await lockTrip(db,c,input);
 const t=c.installationId,b=input.branchId,w=input.warehouseId,id=input.orderId;
 const active=await db.query<{line_no:number;product_id:string;reservation_id:string}>(`
  SELECT l.line_no,l.product_id,r.id AS reservation_id
  FROM sales_order_line l JOIN inventory_reservation r
   ON r.installation_id=l.installation_id AND r.branch_id=l.branch_id
    AND r.order_id=l.order_id AND r.version_no=l.version_no AND r.line_no=l.line_no
    AND r.state='ACTIVE'
  WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3
    AND l.version_no=$4 AND r.warehouse_id=$5 ORDER BY l.line_no FOR SHARE OF l,r
 `,[t,b,id,input.version,w]);
 const holds=new Map(active.rows.map(x=>[x.line_no,x]));
 const seen=new Set<string>();
 for(const line of input.lines){
  const hold=holds.get(line.lineNo);
  if(!Number.isSafeInteger(line.lineNo)||!hold)
   throw new InventoryFault(409,"TRIP_HOLD_REQUIRED");
  if(!zeroOrPositive(line.pickedBase)||!zeroOrPositive(line.packedBase)||
    q(line.pickedBase)+q(line.packedBase)<=0n)
   throw new InventoryFault(400,"INVALID_QUANTITY");
  const key=[line.lineNo,line.locationId??"",line.lotId??""].join(":");
  if(seen.has(key))throw new InventoryFault(400,"DUPLICATE_PREPARATION_SCOPE");
  seen.add(key);
  await checkScope(db,t,input,hold.product_id,line.locationId,line.lotId);
 }
 const documentId=randomUUID();
 await db.query(`INSERT INTO sales_trip_preparation(installation_id,branch_id,id,order_id,
  version_no,warehouse_id,actor_id,request_id)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[t,b,documentId,id,input.version,w,c.actorId,c.requestId]);
 for(const [i,line] of input.lines.entries()){
  const hold=holds.get(line.lineNo)!;
  await db.query(`INSERT INTO sales_trip_preparation_line
   (installation_id,branch_id,preparation_id,source_line,order_line_no,
    reservation_id,product_id,picked_base,packed_base,location_id,lot_id)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8::numeric,$9::numeric,$10,$11)`,
   [t,b,documentId,i+1,line.lineNo,hold.reservation_id,hold.product_id,
    line.pickedBase,line.packedBase,line.locationId??null,line.lotId??null]);
 }
 const updated=await db.query<{revision:string}>(`UPDATE sales_order SET
    fulfillment_status='PARTIAL',revision=revision+1,updated_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,
    [t,b,id]);
 return {status:201,body:{id:documentId,
  ...(await tripWork(db,t,input)),revision:Number(updated.rows[0]!.revision),
  inventoryPosted:false,deliveryPosted:false,receivablePosted:false}};
}
export async function dispatchTrip(db:PoolClient,c:MutationContext,input:TripScope&{lines:TripDispatchItem[]}){
 await requireT3c(db);
 if(!input.lines.length||input.lines.length>100)
  throw new InventoryFault(400,"TRIP_LINES_REQUIRED");
 await lockTrip(db,c,input);
 const t=c.installationId,b=input.branchId,w=input.warehouseId,id=input.orderId;
 const seen=new Set<string>();
 const source=await db.query<{preparation_id:string;source_line:number;product_id:string;
  order_line_no:number;reservation_id:string;location_id:string|null;lot_id:string|null;
  packed:string;sent:string}>(`
  SELECT p.preparation_id,p.source_line,p.product_id,p.order_line_no,p.reservation_id,
    p.location_id,p.lot_id,p.packed_base::text AS packed,
    coalesce((SELECT sum(dl.quantity_base) FROM sales_trip_dispatch_line dl
     WHERE dl.installation_id=p.installation_id AND dl.branch_id=p.branch_id
      AND dl.preparation_id=p.preparation_id AND dl.preparation_line_no=p.source_line),0)::text AS sent
  FROM sales_trip_preparation_line p JOIN sales_trip_preparation h
    ON h.installation_id=p.installation_id AND h.branch_id=p.branch_id
     AND h.id=p.preparation_id
  WHERE h.installation_id=$1 AND h.branch_id=$2 AND h.warehouse_id=$3
   AND h.order_id=$4 AND h.version_no=$5
  ORDER BY p.preparation_id,p.source_line FOR SHARE OF p
 `,[t,b,w,id,input.version]);
 const available=new Map(source.rows.map(x=>[[x.preparation_id,x.source_line].join(":"),x]));
 for(const line of input.lines){
  mustQty(line.quantityBase);
  const key=[line.preparationId,line.sourceLine].join(":");
  if(seen.has(key))throw new InventoryFault(400,"DUPLICATE_DISPATCH_SOURCE");
  seen.add(key);
  const preparation=available.get(key);
  if(!preparation||q(line.quantityBase)>q(preparation.packed)-q(preparation.sent))
   throw new InventoryFault(409,"TRIP_DISPATCH_EXCEEDS_PACKED");
 }
 const dispatchId=randomUUID();
 await db.query(`INSERT INTO sales_trip_dispatch(installation_id,branch_id,id,order_id,
  version_no,warehouse_id,actor_id,request_id)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[t,b,dispatchId,id,input.version,w,c.actorId,c.requestId]);
 const posted=[];
 for(const [i,item] of input.lines.entries()){
  const row=available.get([item.preparationId,item.sourceLine].join(":"))!;
  const sourceLine=i+1;
  await db.query(`INSERT INTO sales_trip_dispatch_line
   (installation_id,branch_id,dispatch_id,source_line,preparation_id,
    preparation_line_no,order_line_no,reservation_id,product_id,
    quantity_base,location_id,lot_id)
   VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::numeric,$11,$12)`,
   [t,b,dispatchId,sourceLine,item.preparationId,item.sourceLine,row.order_line_no,
    row.reservation_id,row.product_id,item.quantityBase,row.location_id,row.lot_id]);
  const movement=await db.query<{id:string}>(`INSERT INTO inventory_ledger
    (installation_id,branch_id,warehouse_id,product_id,kind,source_type,source_id,
     source_line,delta_base,actor_id,request_id)
    VALUES($1,$2,$3,$4,'ISSUE','FULFILLMENT',$5,$6,-$7::numeric,$8,$9)
    RETURNING id`,[t,b,w,row.product_id,dispatchId,sourceLine,item.quantityBase,c.actorId,c.requestId]);
  posted.push({movementId:movement.rows[0]!.id,productId:row.product_id,
   lineNo:row.order_line_no,quantityBase:item.quantityBase,
   locationId:row.location_id,lotId:row.lot_id});
 }
 // A TRIP is fully issued only when every canonical order line has been
 // physically dispatched. Packing/backorders do not count as shipped.
 const remaining=await db.query<{pending:string}>(`
  SELECT count(*)::text AS pending FROM sales_order_line l
  JOIN catalog_product p ON p.installation_id=l.installation_id
   AND p.branch_id=l.branch_id AND p.id=l.product_id
  WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.order_id=$3
   AND l.version_no=$4 AND
    (CASE WHEN l.pricing_engine='R1' THEN (l.price_snapshot->>'normalizedBaseQuantity')::numeric
      WHEN l.unit_code=p.base_unit THEN l.quantity ELSE null END)
       >coalesce((SELECT sum(d.quantity_base) FROM sales_trip_dispatch_line d
           JOIN sales_trip_dispatch h ON h.installation_id=d.installation_id
            AND h.branch_id=d.branch_id AND h.id=d.dispatch_id
          WHERE h.installation_id=l.installation_id AND h.branch_id=l.branch_id
           AND h.order_id=l.order_id AND h.version_no=l.version_no
           AND d.order_line_no=l.line_no),0)
 `,[t,b,id,input.version]);
 const done=remaining.rows[0]?.pending==="0";
 const revision=await db.query<{revision:string}>(`UPDATE sales_order
   SET fulfillment_status=$4,revision=revision+1,updated_at=now()
   WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,
   [t,b,id,done?"COMPLETED":"PARTIAL"]);
 return {status:201,body:{id:dispatchId,orderId:id,version:input.version,
   warehouseId:w,revision:Number(revision.rows[0]!.revision),
   fulfillmentStatus:done?"COMPLETED":"PARTIAL",posted,
   inventoryPosted:true,deliveryPosted:false,paymentPosted:false,receivablePosted:false,
   deliveryStatus:"NOT_DISPATCHED"}};
}
