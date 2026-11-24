import type { PoolClient } from "pg";
import { randomUUID } from "node:crypto";
import { hasPermission } from "./rbac.ts";
import type { MutationContext } from "./mutation.ts";

// Adapted from legacy sales-order.js:354–440, 630–729:
// scoped walk-in identity, immutable version context, and server defaults.
// ERP keeps branch-scoped customer IDs, exact version lifecycle and receipts.
export class OrderContextFault extends Error {
 constructor(readonly status:number,readonly code:string){super(code);}
}
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const DELIVERY_CHOICES=["MANUAL","TRIP","PICKUP"] as const;
export const COLLECTION_POLICIES=["COLLECT_ON_DELIVERY","PREPAID","COLLECT_AFTER_DELIVERY","CREDIT_TERMS"] as const;
type DeliveryChoice=typeof DELIVERY_CHOICES[number];
type CollectionPolicy=typeof COLLECTION_POLICIES[number];
export type OrderContextInput={
 warehouseId:string;deliveryChoice:DeliveryChoice;collectionPolicy:CollectionPolicy;
 customerMode:"EXISTING"|"WALK_IN";customerLocationId?:string;
 deliveryAddress?:string;requestedDeliveryDate?:string;walkInName?:string;walkInPhone?:string;
 rememberDeliveryChoice?:true;
};
type Snapshot=Omit<OrderContextInput,"rememberDeliveryChoice"> & {
 warehouseCode:string;warehouseName:string;paymentTermsDays:number;customerId:string;
};
export async function hasOrderContextSchema(db:PoolClient):Promise<boolean>{
 const r=await db.query<{ready:boolean}>(
  "SELECT EXISTS(SELECT 1 FROM public.schema_migrations WHERE version='0022_t1_sales_order_context.sql') AS ready");
 return r.rows[0]?.ready===true;
}
function optionalText(value:unknown,max:number):string|undefined{
 if(value==null)return undefined;
 if(typeof value!=="string"||value.length>max)throw new OrderContextFault(400,"INVALID_ORDER_CONTEXT");
 return value.trim()||undefined;
}
function requiredId(value:unknown):string{
 if(typeof value!=="string"||!UUID.test(value))throw new OrderContextFault(400,"INVALID_ORDER_CONTEXT");
 return value.toLowerCase();
}
export function parseOrderContext(value:unknown):OrderContextInput|undefined{
 if(value===undefined)return undefined;
 if(!value||typeof value!=="object"||Array.isArray(value))
  throw new OrderContextFault(400,"INVALID_ORDER_CONTEXT");
 const raw=value as Record<string,unknown>;
 if(Object.keys(raw).some(k=>!["warehouseId","deliveryChoice","collectionPolicy","customerMode",
   "customerLocationId","deliveryAddress","requestedDeliveryDate","walkInName","walkInPhone",
   "rememberDeliveryChoice"].includes(k)))
  throw new OrderContextFault(400,"INVALID_ORDER_CONTEXT");
 const warehouseId=requiredId(raw.warehouseId);
 const deliveryChoice=raw.deliveryChoice as DeliveryChoice,collectionPolicy=raw.collectionPolicy as CollectionPolicy;
 const customerMode=raw.customerMode??"EXISTING";
 if(!DELIVERY_CHOICES.includes(deliveryChoice)||!COLLECTION_POLICIES.includes(collectionPolicy)||
   (customerMode!=="EXISTING"&&customerMode!=="WALK_IN")||
   (raw.rememberDeliveryChoice!==undefined&&typeof raw.rememberDeliveryChoice!=="boolean"))
  throw new OrderContextFault(400,"INVALID_ORDER_CONTEXT");
 const customerLocationId=raw.customerLocationId==null?undefined:requiredId(raw.customerLocationId);
 const deliveryAddress=optionalText(raw.deliveryAddress,500);
 const requestedDeliveryDate=optionalText(raw.requestedDeliveryDate,10);
 const walkInName=optionalText(raw.walkInName,160),walkInPhone=optionalText(raw.walkInPhone,16);
 if(requestedDeliveryDate){
  const date=new Date(requestedDeliveryDate+"T00:00:00Z");
  if(!/^\d{4}-\d{2}-\d{2}$/.test(requestedDeliveryDate)||!Number.isFinite(date.getTime())||
     date.toISOString().slice(0,10)!==requestedDeliveryDate)
   throw new OrderContextFault(400,"INVALID_DELIVERY_DATE");
 }
 if(walkInPhone&&!/^\+?[0-9]{9,15}$/.test(walkInPhone))throw new OrderContextFault(400,"INVALID_WALK_IN_PHONE");
 if(deliveryChoice==="PICKUP"&&(customerLocationId||deliveryAddress))
  throw new OrderContextFault(400,"PICKUP_HAS_DELIVERY_ADDRESS");
 if(customerMode==="EXISTING"&&(walkInName||walkInPhone))
  throw new OrderContextFault(400,"INVALID_CUSTOMER_MODE");
 if(customerMode==="WALK_IN"&&(deliveryChoice!=="PICKUP"||
   !["PREPAID","COLLECT_ON_DELIVERY"].includes(collectionPolicy)))
  throw new OrderContextFault(400,"WALK_IN_PICKUP_PAYMENT_REQUIRED");
 return {warehouseId,deliveryChoice,collectionPolicy,customerMode,
  ...(customerLocationId?{customerLocationId}:{}),...(deliveryAddress?{deliveryAddress}:{}),
  ...(requestedDeliveryDate?{requestedDeliveryDate}:{}),...(walkInName?{walkInName}:{}),
  ...(walkInPhone?{walkInPhone}:{}),...(raw.rememberDeliveryChoice?{rememberDeliveryChoice:true as const}:{})};
}
async function walkIn(db:PoolClient,t:string,b:string){
 const r=await db.query<{id:string;code:string;name:string;active:boolean}>(`
  SELECT c.id,c.code,c.name,c.active FROM sales_walk_in_customer w
  JOIN catalog_customer c ON c.installation_id=w.installation_id AND c.branch_id=w.branch_id AND c.id=w.customer_id
  WHERE w.installation_id=$1 AND w.branch_id=$2`,[t,b]);
 return r.rows[0]??null;
}
export async function ensureWalkInCustomer(db:PoolClient,ctx:MutationContext,b:string){
 if(!await hasOrderContextSchema(db))throw new OrderContextFault(503,"ORDER_CONTEXT_MIGRATION_REQUIRED");
 const t=ctx.installationId;
 // Legacy advisory-lock behavior, now scoped to both installation and branch.
 await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))",["erp:sales-walk-in:"+t+":"+b]);
 let customer=await walkIn(db,t,b);
 if(!customer){
  const r=await db.query<{id:string;code:string;name:string;active:boolean}>(`
   INSERT INTO catalog_customer(installation_id,branch_id,code,name,payment_terms_days)
   VALUES($1,$2,$3,'Khách lẻ',0) RETURNING id,code,name,active`,
   [t,b,"WALKIN_"+randomUUID().replaceAll("-","").slice(0,16).toUpperCase()]);
  customer=r.rows[0]!;
  await db.query(`INSERT INTO sales_walk_in_customer(installation_id,branch_id,customer_id,created_by)
   VALUES($1,$2,$3,$4)`,[t,b,customer.id,ctx.actorId]);
 }
 if(!customer.active)throw new OrderContextFault(409,"WALK_IN_UNAVAILABLE");
 return {status:200,body:{customer}};
}
export async function readEntrySettings(db:PoolClient,t:string,b:string,actor:string){
 if(!await hasOrderContextSchema(db))throw new OrderContextFault(503,"ORDER_CONTEXT_MIGRATION_REQUIRED");
 const p=await db.query<{deliveryChoice:DeliveryChoice}>(`
  SELECT delivery_choice AS "deliveryChoice" FROM sales_order_entry_preference
  WHERE installation_id=$1 AND actor_id=$2`,[t,actor]);
 return {deliveryChoice:p.rows[0]?.deliveryChoice??null,walkInCustomer:await walkIn(db,t,b)};
}
const snapshotFields=`customer_id AS "customerId",customer_mode AS "customerMode",
 walk_in_name AS "walkInName",walk_in_phone AS "walkInPhone",warehouse_id AS "warehouseId",
 warehouse_code AS "warehouseCode",warehouse_name AS "warehouseName",
 delivery_choice AS "deliveryChoice",customer_location_id AS "customerLocationId",
 delivery_address AS "deliveryAddress",requested_delivery_date::text AS "requestedDeliveryDate",
 collection_policy AS "collectionPolicy",payment_terms_days AS "paymentTermsDays"`;
export async function readOrderContext(db:PoolClient,t:string,b:string,id:string,v:number):Promise<Snapshot|null>{
 if(!await hasOrderContextSchema(db))return null;
 const r=await db.query<Snapshot>(`SELECT ${snapshotFields} FROM sales_order_version_context
  WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=$4`,[t,b,id,v]);
 return r.rows[0]??null;
}
export async function requireWarehouseAccess(db:PoolClient,t:string,b:string,actor:string,warehouse:string){
 if(!await hasPermission(db,{installationId:t,actorId:actor,branchId:b,
   warehouseId:warehouse,permission:"inventory.read"}))
  throw new OrderContextFault(403,"ORDER_WAREHOUSE_DENIED");
}
export async function authorizeOrderContext(db:PoolClient,t:string,b:string,actor:string,id:string,v:number){
 const current=await readOrderContext(db,t,b,id,v);
 if(current)await requireWarehouseAccess(db,t,b,actor,current.warehouseId);
 return current;
}
export async function saveOrderContext(db:PoolClient,ctx:MutationContext,b:string,id:string,v:number,
 customerId:string,input:OrderContextInput|undefined,creating:boolean){
 const t=ctx.installationId;
 if(!await hasOrderContextSchema(db)){
  if(input)throw new OrderContextFault(503,"ORDER_CONTEXT_MIGRATION_REQUIRED");
  return;
 }
 const previous=creating?null:await readOrderContext(db,t,b,id,v);
 if(previous)await requireWarehouseAccess(db,t,b,ctx.actorId,previous.warehouseId);
 const canonicalWalkIn=await walkIn(db,t,b);
 const isWalkIn=canonicalWalkIn?.id===customerId;
 if(!input){
  if(isWalkIn||previous&&previous.customerId!==customerId)
   throw new OrderContextFault(400,"ORDER_CONTEXT_REQUIRED");
  return;
 }
 if(isWalkIn!==(input.customerMode==="WALK_IN"))
  throw new OrderContextFault(400,"INVALID_CUSTOMER_MODE");
 if(!creating&&input.rememberDeliveryChoice)
  throw new OrderContextFault(400,"DEFAULT_ONLY_ON_CREATE");
 await requireWarehouseAccess(db,t,b,ctx.actorId,input.warehouseId);
 const warehouse=await db.query<{code:string;name:string}>(
  "SELECT code,name FROM warehouse WHERE installation_id=$1 AND branch_id=$2 AND id=$3",
  [t,b,input.warehouseId]);
 if(!warehouse.rows[0])throw new OrderContextFault(409,"ORDER_WAREHOUSE_UNAVAILABLE");
 const customer=await db.query<{payment_terms_days:number;delivery_address:string|null}>(
  "SELECT payment_terms_days,delivery_address FROM catalog_customer WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active FOR SHARE",
  [t,b,customerId]);
 if(!customer.rows[0])throw new OrderContextFault(409,"CUSTOMER_UNAVAILABLE");
 let address:string|null=input.deliveryAddress??null;
 if(input.customerLocationId){
  // Keep historical address snapshot on an unchanged selection even if the
  // directory was edited or retired since the draft was saved.
  if(previous?.customerId===customerId&&previous.customerLocationId===input.customerLocationId&&
    (input.deliveryAddress??null)===(previous.deliveryAddress??null)){
   address=previous.deliveryAddress??null;
  }else{
   const location=await db.query<{address:string}>(`
    SELECT address FROM catalog_customer_location WHERE installation_id=$1 AND branch_id=$2
     AND customer_id=$3 AND id=$4 AND active FOR SHARE`,[t,b,customerId,input.customerLocationId]);
   if(!location.rows[0])throw new OrderContextFault(409,"CUSTOMER_LOCATION_UNAVAILABLE");
   address=location.rows[0].address;
  }
 }else if(input.deliveryChoice!=="PICKUP"&&address===null){
  address=customer.rows[0].delivery_address;
 }
 const paymentTermsDays=isWalkIn?0:customer.rows[0].payment_terms_days;
 const w=warehouse.rows[0];
 await db.query(`INSERT INTO sales_order_version_context(installation_id,branch_id,order_id,version_no,
   customer_id,customer_mode,walk_in_name,walk_in_phone,warehouse_id,warehouse_code,warehouse_name,
   delivery_choice,customer_location_id,delivery_address,requested_delivery_date,collection_policy,payment_terms_days)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)
  ON CONFLICT (installation_id,branch_id,order_id,version_no) DO UPDATE SET
   customer_id=EXCLUDED.customer_id,customer_mode=EXCLUDED.customer_mode,
   walk_in_name=EXCLUDED.walk_in_name,walk_in_phone=EXCLUDED.walk_in_phone,
   warehouse_id=EXCLUDED.warehouse_id,warehouse_code=EXCLUDED.warehouse_code,warehouse_name=EXCLUDED.warehouse_name,
   delivery_choice=EXCLUDED.delivery_choice,customer_location_id=EXCLUDED.customer_location_id,
   delivery_address=EXCLUDED.delivery_address,requested_delivery_date=EXCLUDED.requested_delivery_date,
   collection_policy=EXCLUDED.collection_policy,payment_terms_days=EXCLUDED.payment_terms_days`,
  [t,b,id,v,customerId,input.customerMode,input.walkInName??null,input.walkInPhone??null,
   input.warehouseId,w.code,w.name,input.deliveryChoice,input.customerLocationId??null,address,
   input.requestedDeliveryDate??null,input.collectionPolicy,paymentTermsDays]);
 if(creating&&input.rememberDeliveryChoice){
  await db.query(`INSERT INTO sales_order_entry_preference(installation_id,actor_id,delivery_choice)
    VALUES($1,$2,$3) ON CONFLICT(installation_id,actor_id)
    DO UPDATE SET delivery_choice=EXCLUDED.delivery_choice,updated_at=now()`,
    [t,ctx.actorId,input.deliveryChoice]);
 }
}
export async function copyOrderContext(db:PoolClient,t:string,b:string,id:string,from:number,to:number){
 if(!await hasOrderContextSchema(db))return;
 await db.query(`INSERT INTO sales_order_version_context(installation_id,branch_id,order_id,version_no,
   customer_id,customer_mode,walk_in_name,walk_in_phone,warehouse_id,warehouse_code,warehouse_name,
   delivery_choice,customer_location_id,delivery_address,requested_delivery_date,collection_policy,payment_terms_days)
  SELECT installation_id,branch_id,order_id,$5,customer_id,customer_mode,walk_in_name,walk_in_phone,
   warehouse_id,warehouse_code,warehouse_name,delivery_choice,customer_location_id,delivery_address,
   requested_delivery_date,collection_policy,payment_terms_days FROM sales_order_version_context
  WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=$4`,[t,b,id,from,to]);
}

// Inventory holds a warehouse FOR UPDATE before touching the order.
// Acquire FK-compatible locks before the parent lock on edit/amend so
// an order version context INSERT cannot invert that ordering.
export async function lockContextWarehouses(db:PoolClient,t:string,b:string,id:string,newWarehouse?:string){
 if(!await hasOrderContextSchema(db))return;
 const r=await db.query<{warehouse_id:string}>(`
  SELECT c.warehouse_id FROM sales_order o JOIN sales_order_version_context c
    ON c.installation_id=o.installation_id AND c.branch_id=o.branch_id
    AND c.order_id=o.id AND c.version_no=o.current_version
  WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$3`,[t,b,id]);
 const ids=[...new Set([...(r.rows.map(x=>x.warehouse_id)),...(newWarehouse?[newWarehouse]:[])])];
 if(ids.length)await db.query(`SELECT id FROM warehouse
  WHERE installation_id=$1 AND branch_id=$2 AND id=ANY($3::uuid[])
  ORDER BY id FOR KEY SHARE`,[t,b,ids]);
}
