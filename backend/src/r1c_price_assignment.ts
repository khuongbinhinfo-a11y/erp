import type { PoolClient } from "pg";
import { requireRevision } from "./mutation.ts";

/** R1-C list selection is a scoped overlay on the existing price engine.
 * Assignment changes never rewrite immutable SKU rules or posted order prices. */
export class PriceAssignmentFault extends Error {
  readonly status:number;
  readonly code:string;
  constructor(status:number,code:string){
    super(code);this.status=status;this.code=code;
  }
}
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
function uuid(v:unknown):string {
  if(typeof v!=="string"||!UUID.test(v))throw new PriceAssignmentFault(400,"INVALID_UUID");
  return v.toLowerCase();
}
function iso(v:unknown):string|null{
  if(v===null||v===undefined)return null;
  if(typeof v!=="string"||!/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?Z$/.test(v)
    ||!Number.isFinite(Date.parse(v)))throw new PriceAssignmentFault(400,"INVALID_EFFECTIVE_AT");
  return new Date(v).toISOString();
}
function priority(v:unknown):number{
  if(typeof v!=="number"||!Number.isSafeInteger(v)||v< -100000||v>100000)
    throw new PriceAssignmentFault(400,"INVALID_ASSIGNMENT_PRIORITY");
  return v;
}
export type PriceAssignmentInput={
  branchId:string;priceListId:string;
  scopeKind:"DEFAULT"|"CUSTOMER"|"CUSTOMER_GROUP"|"CHANNEL";
  customerId:string|null;customerGroupId:string|null;channelId:string|null;
  effectiveFrom:string|null;effectiveTo:string|null;priority:number;
};
export function parsePriceAssignment(raw:Record<string,unknown>):PriceAssignmentInput{
  const allowed=["branchId","priceListId","scopeKind","customerId",
    "customerGroupId","channelId","effectiveFrom","effectiveTo","priority"];
  if(Object.keys(raw).some(k=>!allowed.includes(k)))
    throw new PriceAssignmentFault(400,"UNKNOWN_FIELD");
  const scope=raw.scopeKind;
  if(!["DEFAULT","CUSTOMER","CUSTOMER_GROUP","CHANNEL"].includes(String(scope)))
    throw new PriceAssignmentFault(400,"INVALID_ASSIGNMENT_SCOPE");
  const scopeKind=scope as PriceAssignmentInput["scopeKind"];
  const customerId=raw.customerId==null?null:uuid(raw.customerId);
  const customerGroupId=raw.customerGroupId==null?null:uuid(raw.customerGroupId);
  const channelId=raw.channelId==null?null:uuid(raw.channelId);
  if((scopeKind==="CUSTOMER")!==Boolean(customerId)||
    (scopeKind==="CUSTOMER_GROUP")!==Boolean(customerGroupId)||
    (scopeKind==="CHANNEL")!==Boolean(channelId))
    throw new PriceAssignmentFault(400,"INVALID_ASSIGNMENT_TARGET");
  const effectiveFrom=iso(raw.effectiveFrom),effectiveTo=iso(raw.effectiveTo);
  if(effectiveFrom&&effectiveTo&&Date.parse(effectiveTo)<=Date.parse(effectiveFrom))
    throw new PriceAssignmentFault(400,"INVALID_ASSIGNMENT_PERIOD");
  return {branchId:uuid(raw.branchId),priceListId:uuid(raw.priceListId),
    scopeKind,customerId,customerGroupId,channelId,
    priority:priority(raw.priority??0),effectiveFrom,effectiveTo};
}
async function checkTarget(db:PoolClient,t:string,i:PriceAssignmentInput){
  const ok=await db.query(`SELECT id FROM catalog_price_list
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active FOR SHARE`,
    [t,i.branchId,i.priceListId]);
  if(!ok.rows.length)throw new PriceAssignmentFault(409,"PRICE_LIST_UNAVAILABLE");
  const table=i.customerId?"catalog_customer":
    i.customerGroupId?"catalog_customer_group":
    i.channelId?"catalog_sales_channel":null;
  const id=i.customerId??i.customerGroupId??i.channelId;
  if(table){
    const target=await db.query(`SELECT id FROM ${table}
      WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active FOR SHARE`,
      [t,i.branchId,id]);
    if(!target.rows.length)throw new PriceAssignmentFault(409,"ASSIGNMENT_TARGET_UNAVAILABLE");
  }
}
function assignmentLock(t:string,i:PriceAssignmentInput){return JSON.stringify([t,i.branchId,i.scopeKind,i.customerId,i.customerGroupId,i.channelId,i.priority]);}
async function assertNoOverlap(db:PoolClient,t:string,i:PriceAssignmentInput,except?:string){
  // Serialize one scoped priority before checking overlap; repeated concurrent
  // creates cannot establish two equally-ranked winners.
  const lock=assignmentLock(t,i);
  await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))",[lock]);
  const r=await db.query(`SELECT id FROM catalog_price_list_assignment
    WHERE installation_id=$1 AND branch_id=$2 AND scope_kind=$3
      AND customer_id IS NOT DISTINCT FROM $4::uuid
      AND customer_group_id IS NOT DISTINCT FROM $5::uuid
      AND channel_id IS NOT DISTINCT FROM $6::uuid
      AND priority=$7 AND active
      AND (effective_from IS NULL OR
        effective_from<coalesce($9::timestamptz,'infinity'::timestamptz))
      AND (effective_to IS NULL OR
        effective_to>coalesce($8::timestamptz,'-infinity'::timestamptz))
      AND ($10::uuid IS NULL OR id<>$10::uuid) LIMIT 1`,
    [t,i.branchId,i.scopeKind,i.customerId,i.customerGroupId,
      i.channelId,i.priority,i.effectiveFrom,i.effectiveTo,except??null]);
  if(r.rows.length)throw new PriceAssignmentFault(409,"PRICE_LIST_ASSIGNMENT_OVERLAP");
}
export async function createPriceAssignment(db:PoolClient,t:string,i:PriceAssignmentInput){
  await checkTarget(db,t,i);
  await assertNoOverlap(db,t,i);
  const r=await db.query<{id:string}>(`INSERT INTO catalog_price_list_assignment
    (installation_id,branch_id,price_list_id,scope_kind,customer_id,customer_group_id,
     channel_id,priority,effective_from,effective_to)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::timestamptz,$10::timestamptz)
    RETURNING id`,[t,i.branchId,i.priceListId,i.scopeKind,i.customerId,
      i.customerGroupId,i.channelId,i.priority,i.effectiveFrom,i.effectiveTo]);
  return {status:201,body:{id:r.rows[0]!.id,...i,revision:0,active:true}};
}
export async function listPriceAssignments(db:PoolClient,t:string,b:string,q:string,
  priceListId:string|null,offset:number){
  const r=await db.query(`SELECT a.id,a.price_list_id AS "priceListId",l.code AS "priceListCode",
    a.scope_kind AS "scopeKind",a.customer_id AS "customerId",
    c.code AS "customerCode",c.name AS "customerName",a.customer_group_id AS "customerGroupId",
    g.code AS "customerGroupCode",a.channel_id AS "channelId",
    ch.code AS "channelCode",a.priority,a.effective_from AS "effectiveFrom",
    a.effective_to AS "effectiveTo",a.active,a.revision::integer
    FROM catalog_price_list_assignment a JOIN catalog_price_list l
      ON l.installation_id=a.installation_id AND l.branch_id=a.branch_id
        AND l.id=a.price_list_id
    LEFT JOIN catalog_customer c ON c.installation_id=a.installation_id
      AND c.branch_id=a.branch_id AND c.id=a.customer_id
    LEFT JOIN catalog_customer_group g ON g.installation_id=a.installation_id
      AND g.branch_id=a.branch_id AND g.id=a.customer_group_id
    LEFT JOIN catalog_sales_channel ch ON ch.installation_id=a.installation_id
      AND ch.branch_id=a.branch_id AND ch.id=a.channel_id
    WHERE a.installation_id=$1 AND a.branch_id=$2
      AND ($4::uuid IS NULL OR a.price_list_id=$4::uuid)
      AND (l.code ILIKE $3 OR c.code ILIKE $3 OR c.name ILIKE $3 OR g.code ILIKE $3
        OR ch.code ILIKE $3 OR a.scope_kind ILIKE $3)
    ORDER BY a.active DESC,a.priority DESC,a.created_at DESC,a.id DESC
    LIMIT 101 OFFSET $5`,[t,b,"%"+q+"%",priceListId,offset]);
  return {items:r.rows.slice(0,100),hasMore:r.rows.length>100};
}
export async function togglePriceAssignment(db:PoolClient,t:string,
  branchId:string,id:string,expectedRevision:number,active:boolean){
  const found=await db.query<{
    revision:string;active:boolean;price_list_id:string;scope_kind:PriceAssignmentInput["scopeKind"];
    customer_id:string|null;customer_group_id:string|null;channel_id:string|null;
    priority:number;effective_from:Date|null;effective_to:Date|null;
  }>(`SELECT revision::text,active,price_list_id,scope_kind,customer_id,
    customer_group_id,channel_id,priority,effective_from,effective_to
    FROM catalog_price_list_assignment WHERE installation_id=$1
      AND branch_id=$2 AND id=$3 FOR UPDATE`,[t,branchId,id]);
  const old=found.rows[0];
  if(!old)throw new PriceAssignmentFault(404,"ASSIGNMENT_NOT_FOUND");
  requireRevision(expectedRevision,Number(old.revision));
  if(active){
    const input:PriceAssignmentInput={
      branchId,priceListId:old.price_list_id,scopeKind:old.scope_kind,
      customerId:old.customer_id,customerGroupId:old.customer_group_id,
      channelId:old.channel_id,priority:old.priority,
      effectiveFrom:old.effective_from?.toISOString()??null,
      effectiveTo:old.effective_to?.toISOString()??null,
    };
    await checkTarget(db,t,input);
    await assertNoOverlap(db,t,input,id);
  }
  const r=await db.query<{revision:number}>(`UPDATE catalog_price_list_assignment
    SET active=$4,revision=revision+1 WHERE installation_id=$1 AND branch_id=$2
    AND id=$3 RETURNING revision::integer`,[t,branchId,id,active]);
  return {status:200,body:{id,branchId,active,revision:r.rows[0]!.revision}};
}


/** Same validation and advisory lock keys as the single-target path, batched
 * for a price-list editor containing hundreds/thousands of customer IDs.
 * Caller owns a transaction and the list row lock. No partial assignment. */
export async function createUnboundedPriceAssignments(db:PoolClient,t:string,items:PriceAssignmentInput[]){
 if(items.length===0)return;
 const first=items[0]!;
 if(items.some(i=>i.branchId!==first.branchId||i.priceListId!==first.priceListId||
    i.priority!==first.priority||i.effectiveFrom!==null||i.effectiveTo!==null))
  throw new PriceAssignmentFault(400,"INVALID_ASSIGNMENT_BATCH");
 const keys=items.map(i=>assignmentLock(t,i));
 if(new Set(keys).size!==keys.length)throw new PriceAssignmentFault(400,"DUPLICATE_PRICE_SCOPE");
 const list=await db.query("SELECT id FROM catalog_price_list WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active FOR SHARE",[t,first.branchId,first.priceListId]);
 if(!list.rows.length)throw new PriceAssignmentFault(409,"PRICE_LIST_UNAVAILABLE");
 for(const [table,ids] of [
   ["catalog_customer",items.flatMap(i=>i.customerId?[i.customerId]:[])],
   ["catalog_customer_group",items.flatMap(i=>i.customerGroupId?[i.customerGroupId]:[])],
   ["catalog_sales_channel",items.flatMap(i=>i.channelId?[i.channelId]:[])],
 ] as const){
   if(!ids.length)continue;
   const found=await db.query(`SELECT id FROM ${table} WHERE installation_id=$1 AND branch_id=$2
     AND id=ANY($3::uuid[]) AND active ORDER BY id FOR SHARE`,[t,first.branchId,ids]);
   if(found.rows.length!==ids.length)throw new PriceAssignmentFault(409,"ASSIGNMENT_TARGET_UNAVAILABLE");
 }
 // Each lock is identical to assertNoOverlap, sorted before acquisition.
 await db.query("SELECT pg_advisory_xact_lock(hashtextextended(k,0)) FROM unnest($1::text[]) AS locks(k) ORDER BY k",[keys]);
 const data=JSON.stringify(items.map(i=>({scope_kind:i.scopeKind,customer_id:i.customerId,
   customer_group_id:i.customerGroupId,channel_id:i.channelId})));
 const records="jsonb_to_recordset($4::jsonb) AS x(scope_kind text,customer_id uuid,customer_group_id uuid,channel_id uuid)";
 const prior=await db.query(`SELECT a.id FROM catalog_price_list_assignment a JOIN ${records}
    ON a.scope_kind=x.scope_kind AND a.customer_id IS NOT DISTINCT FROM x.customer_id
      AND a.customer_group_id IS NOT DISTINCT FROM x.customer_group_id
      AND a.channel_id IS NOT DISTINCT FROM x.channel_id
    WHERE a.installation_id=$1 AND a.branch_id=$2 AND a.priority=$3 AND a.active LIMIT 1`,
    [t,first.branchId,first.priority,data]);
 if(prior.rows.length)throw new PriceAssignmentFault(409,"PRICE_LIST_ASSIGNMENT_OVERLAP");
 await db.query(`INSERT INTO catalog_price_list_assignment
   (installation_id,branch_id,price_list_id,scope_kind,customer_id,customer_group_id,channel_id,priority)
   SELECT $1,$2,$5,x.scope_kind,x.customer_id,x.customer_group_id,x.channel_id,$3 FROM ${records}`,
   [t,first.branchId,first.priority,data,first.priceListId]);
}
