import { createHash } from "node:crypto";
import type { PoolClient } from "pg";

const MONEY=/^(?:0|[1-9][0-9]{0,12})(?:\.[0-9]{1,4})?$/;
const RATE=/^(?:100(?:\.0{1,2})?|(?:0|[1-9][0-9]?)(?:\.[0-9]{1,2})?)$/;
export class ManualPriceFault extends Error {
 readonly status:number;readonly code:string;
 constructor(code:string,status=400){super(code);this.status=status;this.code=code;}
}
export function manualPriceFields(value:{
 unitPrice?:unknown;discountRate?:unknown;taxRate?:unknown;
}):{unitPrice:string;discountRate:string;taxRate:string}{
 const unitPrice=value.unitPrice,discountRate=value.discountRate??"0",
  taxRate=value.taxRate??"0";
 if(typeof unitPrice!=="string"||!MONEY.test(unitPrice)||
  typeof discountRate!=="string"||!RATE.test(discountRate)||
  typeof taxRate!=="string"||!RATE.test(taxRate))
  throw new ManualPriceFault("INVALID_MANUAL_PRICE");
 return {unitPrice,discountRate,taxRate};
}
function canonicalDecimal(value:string):string {
 const [integer="0",fraction=""]=value.split(".");
 const tail=fraction.replace(/0+$/,"");
 return integer.replace(/^0+(?=\d)/,"")+(tail?"."+tail:"");
}
export async function quoteManualSku(db:PoolClient,input:{
 installationId:string;branchId:string;priceListId:string;
 customerId:string;channelId?:string;sellSkuId:string;
 quantity:string;unitPrice:string;discountRate:string;taxRate:string;
}){
 const meta=await db.query<{id:string;sku:string;productId:string;productName:string;unitCode:string;toBase:string}>(
  `SELECT s.id,s.sku,s.product_id AS "productId",p.name AS "productName",
   s.unit_code AS "unitCode",s.conversion_to_base::text AS "toBase"
   FROM catalog_sell_sku s JOIN catalog_product p
     ON p.installation_id=s.installation_id AND p.branch_id=s.branch_id
      AND p.id=s.product_id
   WHERE s.installation_id=$1 AND s.branch_id=$2 AND s.id=$3
     AND s.active AND p.active`,
  [input.installationId,input.branchId,input.sellSkuId]);
 const sku=meta.rows[0];
 if(!sku)throw new ManualPriceFault("SKU_UNAVAILABLE",409);
 const totals=await db.query<{
  subtotal:string;discountAmount:string;taxAmount:string;lineTotal:string;
  normalizedBaseQuantity:string;
 }>(`WITH gross AS (
   SELECT round($1::numeric*$2::numeric,0) AS subtotal,
    round($1::numeric*$5::numeric,6) AS normalized
  ),discounted AS (
   SELECT subtotal,normalized,
    round(subtotal*$3::numeric/100,0) AS discount FROM gross
  ),taxed AS (
   SELECT subtotal,discount,normalized,
    round((subtotal-discount)*$4::numeric/100,0) AS tax FROM discounted
  ) SELECT subtotal::text,"discount"::text AS "discountAmount",
    tax::text AS "taxAmount",
    (subtotal-discount+tax)::text AS "lineTotal",
    normalized::numeric(20,6)::text AS "normalizedBaseQuantity" FROM taxed`,
  [input.quantity,input.unitPrice,input.discountRate,input.taxRate,sku.toBase]);
 const money=totals.rows[0]!;
 const signature=createHash("sha256").update(JSON.stringify({
  kind:"ERP_MANUAL_SKU_PRICE_V1",installationId:input.installationId,
  branchId:input.branchId,customerId:input.customerId,
  priceListId:input.priceListId,channelId:input.channelId??null,
  sellSkuId:sku.id,productId:sku.productId,unitCode:sku.unitCode,
  toBase:sku.toBase,quantity:canonicalDecimal(input.quantity),
  unitPrice:canonicalDecimal(input.unitPrice),
  discountRate:canonicalDecimal(input.discountRate),
  taxRate:canonicalDecimal(input.taxRate),
  lineTotal:money.lineTotal,
 })).digest("hex");
 return {...sku,sellSkuId:sku.id,quantity:input.quantity,currency:"VND",
  priceListId:input.priceListId,customerId:input.customerId,
  channelId:input.channelId??null,
  unitPrice:input.unitPrice,discountRate:input.discountRate,taxRate:input.taxRate,
  subtotal:money.subtotal,discountAmount:money.discountAmount,
  taxAmount:money.taxAmount,lineTotal:money.lineTotal,
  normalizedBaseQuantity:money.normalizedBaseQuantity,
  manualOverride:true,priceSignature:signature,trace:[]};
}
