import type { PoolClient } from "pg";
import { requireRevision } from "./mutation.ts";

/** A copy creates a distinct price-list identity and copies the latest
 * effective product-price entries plus all unexpired/unretired SKU policies.
 * Policy effective times are preserved; synthetic UUIDs encode source ID
 * ordering within ties, keeping BASE/EXCLUSIVE/STOP rule precedence stable.
 * Original immutable rows are never changed. New list inherits its date
 * window and priority, but not source customer bindings (prevent accidental
 * commercial reassignment). */
export async function clonePriceList(db:PoolClient,input:{
  installationId:string;branchId:string;sourceId:string;
  sourceRevision:number;code:string;name:string;
}){
  const {installationId:t,branchId:b,sourceId,code,name}=input;
  const gate=await db.query<{ready:boolean}>(`SELECT EXISTS(
    SELECT 1 FROM public.schema_migrations
    WHERE version='0018_r1c_price_list_assignment.sql') AS ready`);
  const r1c=gate.rows[0]?.ready===true;
  const original=await db.query<{
    revision:string;currency:string;effectiveFrom:Date|null;
    effectiveTo:Date|null;priority:number;
  }>(r1c?`SELECT revision::text,currency,
      effective_from AS "effectiveFrom",effective_to AS "effectiveTo",priority
      FROM catalog_price_list WHERE installation_id=$1 AND branch_id=$2
      AND id=$3 FOR UPDATE`:
    `SELECT revision::text,currency,NULL::timestamptz AS "effectiveFrom",
      NULL::timestamptz AS "effectiveTo",0::integer AS priority
      FROM catalog_price_list WHERE installation_id=$1 AND branch_id=$2
      AND id=$3 FOR UPDATE`,[t,b,sourceId]);
  // FOR UPDATE serializes concurrent price/rule inserts via their FK
  // KEY SHARE checks, preventing a mixed point-in-time snapshot.
  if(!original.rows[0])return null;
  requireRevision(input.sourceRevision,Number(original.rows[0].revision));
  // NOW() is stable inside the surrounding executeMutation transaction.
  const fresh=await db.query<{id:string;revision:number}>(
    r1c?`INSERT INTO catalog_price_list
       (installation_id,branch_id,code,name,currency,active,
        effective_from,effective_to,priority)
       VALUES($1,$2,$3,$4,$5,true,$6::timestamptz,$7::timestamptz,$8)
       RETURNING id,revision::integer`:
    `INSERT INTO catalog_price_list
       (installation_id,branch_id,code,name,currency,active)
       VALUES($1,$2,$3,$4,$5,true) RETURNING id,revision::integer`,
    r1c?[t,b,code,name,original.rows[0].currency,
      original.rows[0].effectiveFrom,original.rows[0].effectiveTo,
      original.rows[0].priority]:[t,b,code,name,original.rows[0].currency]);
  const targetId=fresh.rows[0]!.id;
  const productEntries=await db.query(
    `INSERT INTO catalog_price_entry
       (installation_id,branch_id,price_list_id,product_id,amount,discount_rate,effective_at)
     SELECT DISTINCT ON (e.product_id) e.installation_id,e.branch_id,$4::uuid,
       e.product_id,e.amount,e.discount_rate,transaction_timestamp()
     FROM catalog_price_entry e
     JOIN catalog_product p ON p.installation_id=e.installation_id
       AND p.branch_id=e.branch_id AND p.id=e.product_id AND p.active
     WHERE e.installation_id=$1 AND e.branch_id=$2 AND e.price_list_id=$3
       AND e.effective_at<=transaction_timestamp()
     ORDER BY e.product_id,e.effective_at DESC,e.id DESC`,
    [t,b,sourceId,targetId]);
  const skuRules=await db.query(
    `INSERT INTO catalog_sku_price_rule
      (id,installation_id,branch_id,price_list_id,sell_sku_id,scope_kind,
       channel_id,customer_id,customer_group,adjustment,amount,priority,
       stacking,stop_processing,min_quantity,effective_from,effective_to)
     SELECT (
       substr(md5($4::text),1,8)||'-'||substr(md5($4::text),9,4)||
       '-4'||substr(md5($4::text),14,3)||'-a'||substr(md5($4::text),18,3)||
       '-'||lpad(to_hex(row_number() OVER (
         ORDER BY r.effective_from ASC,r.id ASC)::bigint),12,'0')
     )::uuid,r.installation_id,r.branch_id,$4::uuid,r.sell_sku_id,r.scope_kind,
       r.channel_id,r.customer_id,r.customer_group,r.adjustment,r.amount,
       r.priority,r.stacking,r.stop_processing,r.min_quantity,
       r.effective_from,r.effective_to
     FROM catalog_sku_price_rule r
     JOIN catalog_sell_sku s ON s.installation_id=r.installation_id
       AND s.branch_id=r.branch_id AND s.id=r.sell_sku_id AND s.active
     JOIN catalog_product p ON p.installation_id=s.installation_id
       AND p.branch_id=s.branch_id AND p.id=s.product_id AND p.active
     WHERE r.installation_id=$1 AND r.branch_id=$2 AND r.price_list_id=$3
       AND (r.effective_to IS NULL OR r.effective_to>transaction_timestamp())
       AND NOT EXISTS (
         SELECT 1 FROM catalog_sku_price_retirement x
         WHERE x.installation_id=r.installation_id AND x.branch_id=r.branch_id
           AND x.rule_id=r.id AND x.retired_at<=transaction_timestamp()
       )`,
    [t,b,sourceId,targetId]);
  return {status:201,body:{
    id:targetId,code,name,sourceId,revision:fresh.rows[0]!.revision,
    copiedPrices:productEntries.rowCount??0,copiedRules:skuRules.rowCount??0,
  }};
}
