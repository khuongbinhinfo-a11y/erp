import { createHash } from "node:crypto";
import type { PoolClient } from "pg";
import { resolveR1Price,r1QuoteSignature } from "./r1_pricing.ts";

const MONEY=/^(?:0|[1-9][0-9]{0,12})(?:\.[0-9]{1,4})?$/;
const RATE=/^(?:100(?:\.0{1,2})?|(?:0|[1-9][0-9]?)(?:\.[0-9]{1,2})?)$/;
export class ManualPriceFault extends Error {
 readonly status:number;readonly code:string;
 constructor(code:string,status=400){super(code);this.status=status;this.code=code;}
}
export type ManualAdjustments={
 unitPrice?:string;discountRate?:string;taxRate?:string;
 discountMode?:"PERCENT"|"PER_UNIT"|"TOTAL_AMOUNT";discountValue?:string;
 taxMode?:"EXCLUSIVE"|"INCLUSIVE";
};
export function hasManualAdjustments(value:ManualAdjustments):boolean{
 return value.unitPrice!==undefined||value.discountRate!==undefined||
  value.taxRate!==undefined||value.discountMode!==undefined||
  value.discountValue!==undefined||value.taxMode!==undefined;
}
export function manualPriceFields(value:Record<string,unknown>):ManualAdjustments{
 const unitPrice=value.unitPrice,discountRate=value.discountRate,taxRate=value.taxRate,
  discountMode=value.discountMode,discountValue=value.discountValue,taxMode=value.taxMode;
 if(unitPrice!==undefined&&(typeof unitPrice!=="string"||!MONEY.test(unitPrice))||
  discountRate!==undefined&&(typeof discountRate!=="string"||!RATE.test(discountRate))||
  taxRate!==undefined&&(typeof taxRate!=="string"||!RATE.test(taxRate))||
  discountMode!==undefined&&discountMode!=="PERCENT"&&discountMode!=="PER_UNIT"&&discountMode!=="TOTAL_AMOUNT"||
  taxMode!==undefined&&taxMode!=="EXCLUSIVE"&&taxMode!=="INCLUSIVE")
  throw new ManualPriceFault("INVALID_MANUAL_PRICE");
 if(discountMode==="PER_UNIT"||discountMode==="TOTAL_AMOUNT"){
  if(discountRate!==undefined||typeof discountValue!=="string"||!MONEY.test(discountValue))
   throw new ManualPriceFault("INVALID_DISCOUNT_MODE");
 }else if(discountValue!==undefined)throw new ManualPriceFault("INVALID_DISCOUNT_MODE");
 return {...(unitPrice!==undefined?{unitPrice:unitPrice as string}:{}),
  ...(discountRate!==undefined?{discountRate:discountRate as string}:{}),
  ...(taxRate!==undefined?{taxRate:taxRate as string}:{}),
  ...(discountMode!==undefined?{discountMode:discountMode as ManualAdjustments["discountMode"]}:{}),
  ...(discountValue!==undefined?{discountValue:discountValue as string}:{}),
  ...(taxMode!==undefined?{taxMode:taxMode as ManualAdjustments["taxMode"]}:{})};
}
function canonicalDecimal(value:string):string {
 const [integer="0",fraction=""]=value.split(".");
 const tail=fraction.replace(/0+$/,"");
 return integer.replace(/^0+(?=\d)/,"")+(tail?"."+tail:"");
}
export async function quoteManualSku(db:PoolClient,input:{
 installationId:string;branchId:string;priceListId:string;
 customerId:string;channelId?:string;sellSkuId:string;
 quantity:string;
}&ManualAdjustments){
 const standard=input.unitPrice===undefined?await resolveR1Price(db,{
  installationId:input.installationId,branchId:input.branchId,priceListId:input.priceListId,
  customerId:input.customerId,channelId:input.channelId,sellSkuId:input.sellSkuId,
  quantity:input.quantity,priceAt:new Date().toISOString()}):null;
 const unitPrice=input.unitPrice??standard!.unitPrice,discountRate=input.discountRate??"0",
  taxRate=input.taxRate??"0",discountMode=input.discountMode??"PERCENT",
  taxMode=input.taxMode??"EXCLUSIVE",discountValue=input.discountValue??discountRate;
 const v2=standard!==null||input.discountMode!==undefined||input.taxMode!==undefined;

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
 // Legacy commercial form: per-unit, percent and fixed line discounts.
 // Numeric arithmetic and one rounding boundary are shared by quote/save/confirm.
 const totals=await db.query<{
  subtotal:string;discountAmount:string;taxAmount:string;lineTotal:string;
  normalizedBaseQuantity:string;grossBeforeTaxMode:string;rawDiscount:string;
 }>(`WITH gross AS (
   SELECT round($1::numeric*$2::numeric,0) AS gross,
    round($1::numeric*$5::numeric,6) AS normalized
  ),discounted AS (
   SELECT gross,normalized,CASE $6::text
    WHEN 'PER_UNIT' THEN round($1::numeric*$7::numeric,0)
    WHEN 'TOTAL_AMOUNT' THEN round($7::numeric,0)
    ELSE round(gross*$3::numeric/100,0) END AS raw_discount FROM gross
  ),taxed AS (
   SELECT gross,raw_discount,normalized,CASE WHEN $8::text='INCLUSIVE'
    THEN round((gross-raw_discount)*$4::numeric/(100+$4::numeric),0)
    ELSE round((gross-raw_discount)*$4::numeric/100,0) END AS tax,
    CASE WHEN $8::text='INCLUSIVE' THEN gross-round(gross*$4::numeric/(100+$4::numeric),0)
    ELSE gross END AS subtotal
   FROM discounted
  ) SELECT subtotal::text,
    (CASE WHEN $8::text='INCLUSIVE' THEN subtotal-(gross-raw_discount-tax) ELSE raw_discount END)::text AS "discountAmount",
    tax::text AS "taxAmount",
    (CASE WHEN $8::text='INCLUSIVE' THEN gross-raw_discount ELSE gross-raw_discount+tax END)::text AS "lineTotal",
    normalized::numeric(20,6)::text AS "normalizedBaseQuantity",
    gross::text AS "grossBeforeTaxMode",raw_discount::text AS "rawDiscount"
    FROM taxed WHERE raw_discount<=gross`,
  [input.quantity,unitPrice,discountRate,taxRate,sku.toBase,discountMode,discountValue,taxMode]);
 if(!totals.rows[0])throw new ManualPriceFault("DISCOUNT_EXCEEDS_LINE_TOTAL");
 const money=totals.rows[0]!;
 const signature=createHash("sha256").update(JSON.stringify({
  kind:v2?"ERP_MANUAL_SKU_PRICE_V2":"ERP_MANUAL_SKU_PRICE_V1",installationId:input.installationId,
  branchId:input.branchId,customerId:input.customerId,
  priceListId:input.priceListId,channelId:input.channelId??null,
  sellSkuId:sku.id,productId:sku.productId,unitCode:sku.unitCode,
  toBase:sku.toBase,quantity:canonicalDecimal(input.quantity),
  unitPrice:canonicalDecimal(unitPrice),
  discountRate:canonicalDecimal(discountRate),
  taxRate:canonicalDecimal(taxRate),
  ...(v2?{standardSignature:standard?r1QuoteSignature(standard):null,
   discountMode,discountValue:canonicalDecimal(discountValue),taxMode}:{}),
  lineTotal:money.lineTotal,
 })).digest("hex");
 return {...sku,sellSkuId:sku.id,quantity:input.quantity,currency:"VND",
  priceListId:input.priceListId,customerId:input.customerId,
  channelId:input.channelId??null,
  unitPrice,discountRate,taxRate,
  ...(v2?{manualPriceOverride:!standard,discountMode,discountValue,taxMode,
    grossBeforeTaxMode:money.grossBeforeTaxMode,rawDiscount:money.rawDiscount,
    standardSignature:standard?r1QuoteSignature(standard):null}:{}),
  subtotal:money.subtotal,discountAmount:money.discountAmount,
  taxAmount:money.taxAmount,lineTotal:money.lineTotal,
  normalizedBaseQuantity:money.normalizedBaseQuantity,
  discountOverride:input.discountRate!==undefined||input.discountMode!==undefined,
  taxOverride:input.taxRate!==undefined||input.taxMode!==undefined,
  manualOverride:true,priceSignature:signature,trace:standard?.trace??[]};
}
