import { createHash } from "node:crypto";
import type { PoolClient } from "pg";

export class R1QuoteError extends Error {
  readonly status:number;
  readonly code:string;
  constructor(status:number,code:string){super(code);this.status=status;this.code=code;}
}
type Query={
  installationId:string;branchId:string;sellSkuId:string;priceListId:string;
  quantity:string;customerId?:string;channelId?:string;priceAt:string;
};
type Rule={
  id:string;scope_kind:string;adjustment:string;amount:string;priority:number;min_quantity:string;
  stacking:string;stop_processing:boolean;channel_id:string|null;
  customer_id:string|null;customer_group:string|null;effective_from:Date;
};
const percent=new Set(["PERCENT_DISCOUNT","PERCENT_MARKUP"]);
const deduct=new Set(["PERCENT_DISCOUNT","AMOUNT_DISCOUNT"]);
async function exact(db:PoolClient,amount:string,rule:Rule):Promise<string>{
  // A fixed-price rule is already PostgreSQL NUMERIC::text. Returning it
  // directly avoids an untyped unused bind parameter in a SQL SELECT.
  if(rule.adjustment==="FIXED_PRICE")return rule.amount;
  const expression=percent.has(rule.adjustment)
    ?deduct.has(rule.adjustment)
      ?"greatest(0,round($1::numeric*(1-$2::numeric/100),0))"
      :"round($1::numeric*(1+$2::numeric/100),0)"
    :deduct.has(rule.adjustment)
      ?"greatest(0,round($1::numeric-$2::numeric,0))"
      :"round($1::numeric+$2::numeric,0)";
  const q=await db.query<{result:string}>(
    "SELECT "+expression+"::text AS result",[amount,rule.amount]);
  return q.rows[0]!.result;
}
export async function resolveR1Price(db:PoolClient,input:Query){
  const t=input.installationId.toLowerCase(),b=input.branchId.toLowerCase();
  const customerId=input.customerId?.toLowerCase(),channelId=input.channelId?.toLowerCase();
  const sku=await db.query<{
    id:string;sku:string;name:string;unitCode:string;toBase:string;
    isBase:boolean;productId:string;
  }>(`SELECT s.id,s.sku,p.name,s.unit_code AS "unitCode",
      s.conversion_to_base::text AS "toBase",s.is_base AS "isBase",
      s.product_id AS "productId"
     FROM catalog_sell_sku s JOIN catalog_product p ON
       p.installation_id=s.installation_id AND p.branch_id=s.branch_id
       AND p.id=s.product_id
     WHERE s.installation_id=$1 AND s.branch_id=$2 AND s.id=$3
       AND s.active AND p.active`,[t,b,input.sellSkuId]);
  const item=sku.rows[0];
  if(!item)throw new R1QuoteError(404,"SKU_UNAVAILABLE");
  const list=await db.query<{currency:string}>(
    "SELECT currency FROM catalog_price_list WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active",
    [t,b,input.priceListId]);
  if(list.rows[0]?.currency!=="VND")throw new R1QuoteError(409,"PRICE_LIST_UNAVAILABLE");
  // A customer selected from a canonical group can match both new CODE-based
  // rules and immutable legacy LABEL-based rules. No historical rule is edited.
  // Before 0017 is installed, legacy customer_group text still works.
  const customerGroups=new Set<string>();
  let canonicalGroup:string|null=null;
  if(customerId){
    const found=await db.query<{ready:boolean}>(`SELECT EXISTS(
      SELECT 1 FROM public.schema_migrations
      WHERE version='0017_r1a_customer_directories.sql') AS ready`);
    const customerSql=found.rows[0]?.ready===true
      ? "SELECT customer_group,customer_group_id FROM catalog_customer WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active"
      : "SELECT customer_group,NULL::uuid AS customer_group_id FROM catalog_customer WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active";
    const r=await db.query<{customer_group:string|null;customer_group_id:string|null}>(
      customerSql,[t,b,customerId]);
    if(!r.rows[0])throw new R1QuoteError(409,"CUSTOMER_UNAVAILABLE");
    if(r.rows[0].customer_group)customerGroups.add(r.rows[0].customer_group);
    if(r.rows[0].customer_group_id){
      const mapped=await db.query<{code:string;legacy_label:string|null}>(`SELECT g.code,g.legacy_label
        FROM catalog_customer_group g
        WHERE g.installation_id=$1 AND g.branch_id=$2 AND g.id=$3`,
        [t,b,r.rows[0].customer_group_id]);
      if(!mapped.rows[0])throw new R1QuoteError(409,"CUSTOMER_GROUP_REFERENCE_INVALID");
      canonicalGroup=mapped.rows[0].code;
      customerGroups.add(mapped.rows[0].code);
      // Do not derive historical matching from editable group.name.
      if(mapped.rows[0].legacy_label)
        customerGroups.add(mapped.rows[0].legacy_label);
    }
  }
  if(channelId){
    const r=await db.query("SELECT id FROM catalog_sales_channel WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active",
      [t,b,channelId]);
    if(!r.rows[0])throw new R1QuoteError(409,"CHANNEL_UNAVAILABLE");
  }
  const rules=await db.query<Rule>(`SELECT r.id,r.scope_kind,r.adjustment,r.amount::text,
      r.priority,r.stacking,r.stop_processing,r.channel_id,r.customer_id,r.customer_group,r.min_quantity::text,r.effective_from
    FROM catalog_sku_price_rule r
    WHERE r.installation_id=$1 AND r.branch_id=$2 AND r.price_list_id=$3
      AND r.sell_sku_id=$4 AND r.effective_from<=$5::timestamptz
      AND (r.effective_to IS NULL OR r.effective_to>$5::timestamptz)
      AND r.min_quantity<=$6::numeric
      AND NOT EXISTS (
        SELECT 1 FROM catalog_sku_price_retirement x
        WHERE x.installation_id=r.installation_id AND x.branch_id=r.branch_id
          AND x.rule_id=r.id AND x.retired_at<=$5::timestamptz
      )
    ORDER BY r.priority DESC,r.effective_from DESC,r.id DESC`,
    [t,b,input.priceListId,input.sellSkuId,input.priceAt,input.quantity]);
  const base=rules.rows.find(r=>r.scope_kind==="BASE");
  let basePrice:string|null=base?.amount??null;
  let sourceId:string|null=base?.id??null;
  let origin="BASE_RULE";
  // Existing product/base-unit price history remains available to old sales.
  // Do not infer carton prices from retail price times conversion.
  if(basePrice===null && item.isBase){
    const q=await db.query<{id:string;amount:string;discount:string}>(`
      SELECT e.id,e.amount::text,e.discount_rate::text AS discount
      FROM catalog_price_entry e
      WHERE e.installation_id=$1 AND e.branch_id=$2
        AND e.price_list_id=$3 AND e.product_id=$4
        AND e.effective_at<=$5::timestamptz
      ORDER BY e.effective_at DESC,e.id DESC LIMIT 1`,
      [t,b,input.priceListId,item.productId,input.priceAt]);
    const old=q.rows[0];
    if(old){
      const computed=await db.query<{unit:string}>(
        "SELECT greatest(0,round($1::numeric*(1-$2::numeric/100),0))::text AS unit",
        [old.amount,old.discount]);
      basePrice=computed.rows[0]!.unit;
      sourceId=old.id;origin="EXISTING_BASE_PRICE";
    }
  }
  if(basePrice===null)throw new R1QuoteError(409,"SKU_HAS_NO_EFFECTIVE_BASE_PRICE");
  let price=basePrice,usedExclusive=false,stopped=false;
  const equivalentPolicies=new Set<string>();
  const trace:{ruleId:string|null;scope:string;adjustment:string;amount:string;result:string}[]=[
    {ruleId:sourceId,scope:origin,adjustment:"FIXED_PRICE",amount:basePrice,result:price},
  ];
  for(const rule of rules.rows){
    if(rule.scope_kind==="BASE")continue;
    if(stopped)break;
    const applies=(rule.customer_id===null||rule.customer_id===customerId)&&
      (rule.channel_id===null||rule.channel_id===channelId)&&
      (rule.customer_group===null||customerGroups.has(rule.customer_group))&&
      (rule.scope_kind!=="CUSTOMER"||rule.customer_id===customerId)&&
      (rule.scope_kind!=="CHANNEL"||rule.channel_id===channelId)&&
      (rule.scope_kind!=="CUSTOMER_GROUP"||
        rule.customer_group!==null&&customerGroups.has(rule.customer_group));
    if(!applies)continue;
    // Repeated identical immutable STACKABLE policies with different request
    // IDs or effective timestamps must never compound the same discount twice.
    // A distinct promotion/discount is still selected by different price
    // parameters, scope, priority or quantity threshold.
    const canonical=JSON.stringify([rule.scope_kind,rule.adjustment,rule.amount,
      rule.priority,rule.stacking,rule.stop_processing,rule.channel_id,
      rule.customer_id,
      rule.customer_group!==null&&canonicalGroup!==null&&customerGroups.has(rule.customer_group)
        ?canonicalGroup:rule.customer_group,
      rule.min_quantity]);
    if(equivalentPolicies.has(canonical))continue;
    equivalentPolicies.add(canonical);
    if(rule.stacking==="EXCLUSIVE"){
      if(usedExclusive)continue;
      usedExclusive=true;
    }
    price=await exact(db,price,rule);
    trace.push({ruleId:rule.id,scope:rule.scope_kind,
      adjustment:rule.adjustment,amount:rule.amount,result:price});
    if(rule.stop_processing)stopped=true;
  }
  const total=await db.query<{total:string;normalized:string}>(
    `SELECT round($1::numeric*$2::numeric,0)::text AS total,
      round($2::numeric*$3::numeric,6)::numeric(20,6)::text AS normalized`,
    [price,input.quantity,item.toBase]);
  return {
    sellSkuId:item.id,productId:item.productId,sku:item.sku,productName:item.name,unitCode:item.unitCode,
    conversionToBase:item.toBase,quantity:input.quantity,
    normalizedBaseQuantity:total.rows[0]!.normalized,
    currency:"VND",priceListId:input.priceListId.toLowerCase(),customerId:customerId??null,
    channelId:channelId??null,basePrice,unitPrice:price,
    lineTotal:total.rows[0]!.total,priceAt:input.priceAt,
    trace,stockStatus:"NOT_VERIFIED",confirmationAllowed:false,
  };
}

/** A stable, server-recomputed price receipt for UI quote -> order -> confirm.
 * The lookup clock is excluded; the selected rules, effective monetary result,
 * product identity and canonical quantity are included. Values stay strings. */
export function r1QuoteSignature(quote:Awaited<ReturnType<typeof resolveR1Price>>):string{
  const [whole="0",decimal=""]=quote.quantity.split(".");
  const fractional=decimal.replace(/0+$/,"");
  const fingerprint={
    sellSkuId:quote.sellSkuId,productId:quote.productId,
    sku:quote.sku,unitCode:quote.unitCode,conversionToBase:quote.conversionToBase,
    quantity:fractional?whole+"."+fractional:whole,
    normalizedBaseQuantity:quote.normalizedBaseQuantity,
    customerId:quote.customerId,channelId:quote.channelId,priceListId:quote.priceListId,
    basePrice:quote.basePrice,unitPrice:quote.unitPrice,lineTotal:quote.lineTotal,
    trace:quote.trace,
  };
  return createHash("sha256").update(JSON.stringify(fingerprint)).digest("hex");
}
