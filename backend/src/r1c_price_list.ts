import type { PoolClient } from "pg";
import { requireRevision } from "./mutation.ts";

/** A copy is a new, independent price list. Its starting ledger is a
 * point-in-time snapshot: one latest effective product price per product,
 * plus unretired current/future SKU rules. Historical source rows are never
 * changed, and clone never carries expired/retired promotions forward. */
export async function clonePriceList(db:PoolClient,input:{
  installationId:string;branchId:string;sourceId:string;
  sourceRevision:number;code:string;name:string;
}){
  const {installationId:t,branchId:b,sourceId,code,name}=input;
  const original=await db.query<{revision:string;currency:string}>(
    `SELECT revision::text,currency FROM catalog_price_list
     WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR SHARE`,
    [t,b,sourceId]);
  if(!original.rows[0])return null;
  requireRevision(input.sourceRevision,Number(original.rows[0].revision));
  // NOW() is stable inside the surrounding executeMutation transaction.
  const fresh=await db.query<{id:string;revision:number}>(
    `INSERT INTO catalog_price_list
       (installation_id,branch_id,code,name,currency,active)
     VALUES($1,$2,$3,$4,$5,true)
     RETURNING id,revision::integer`,
    [t,b,code,name,original.rows[0].currency]);
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
      (installation_id,branch_id,price_list_id,sell_sku_id,scope_kind,
       channel_id,customer_id,customer_group,adjustment,amount,priority,
       stacking,stop_processing,min_quantity,effective_from,effective_to)
     SELECT r.installation_id,r.branch_id,$4::uuid,r.sell_sku_id,r.scope_kind,
       r.channel_id,r.customer_id,r.customer_group,r.adjustment,r.amount,
       r.priority,r.stacking,r.stop_processing,r.min_quantity,
       GREATEST(r.effective_from,transaction_timestamp()),r.effective_to
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
