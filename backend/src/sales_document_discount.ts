// Legacy SalesOrderCommercialForm.tsx:273–326, adapted to server VND integer
// values. Largest-remainder allocation conserves the discount exactly.
import type { PoolClient } from "pg";
export class DiscountFault extends Error{
 readonly status=400;readonly code:string;
 constructor(code:string){super(code);this.code=code;}
}
export type DocumentDiscount={mode:"PERCENT"|"TOTAL_AMOUNT";value:string;reason:string};
export function parseDocumentDiscount(raw:unknown,requireReason:boolean):DocumentDiscount|undefined{
 if(raw===undefined)return;
 if(!raw||typeof raw!=="object"||Array.isArray(raw))throw new DiscountFault("INVALID_DOCUMENT_DISCOUNT");
 const r=raw as Record<string,unknown>;
 if(Object.keys(r).some(k=>!["mode","value","reason"].includes(k)))throw new DiscountFault("INVALID_DOCUMENT_DISCOUNT");
 if(r.mode!=="PERCENT"&&r.mode!=="TOTAL_AMOUNT")throw new DiscountFault("INVALID_DOCUMENT_DISCOUNT");
 const value=r.value;
 if(typeof value!=="string"||!(r.mode==="PERCENT"?/^(?:100(?:\.0{1,2})?|(?:0|[1-9][0-9]?)(?:\.[0-9]{1,2})?)$/:/^(?:0|[1-9][0-9]{0,19})$/).test(value))
  throw new DiscountFault("INVALID_DOCUMENT_DISCOUNT");
 const reason=r.reason??"";
 if(typeof reason!=="string"||reason.length>500||(requireReason&&!reason.trim()))
  throw new DiscountFault("DOCUMENT_DISCOUNT_REASON_REQUIRED");
 if(!/[1-9]/.test(value))return;
 return {mode:r.mode,value,reason:reason.trim()};
}
function bp(x:string):bigint{
 const [w="0",f=""]=x.split(".");return BigInt(w)*100n+BigInt((f+"00").slice(0,2));
}
const sum=(a:bigint[])=>a.reduce((s,x)=>s+x,0n);
const halfUp=(n:bigint,d:bigint)=>(n+d/2n)/d;
export type DiscountBase={subtotal:string;discountAmount:string;taxRate:string;taxAmount:string;lineTotal:string};
export function allocateDocumentDiscount(lines:DiscountBase[],input:DocumentDiscount){
 if(lines.some(l=>BigInt(l.discountAmount)>0n))throw new DiscountFault("MIXED_DISCOUNT_SCOPE");
 const gross=lines.map(l=>BigInt(l.subtotal)),total=sum(gross);
 const target=input.mode==="PERCENT"?halfUp(total*bp(input.value),10000n):BigInt(input.value);
 if(target>total)throw new DiscountFault("DOCUMENT_DISCOUNT_EXCEEDS_TOTAL");
 const allocation=gross.map(v=>total===0n?0n:v*target/total);
 const ranked=gross.map((v,i)=>({i,remainder:total===0n?0n:v*target%total}))
  .sort((a,b)=>a.remainder===b.remainder?a.i-b.i:a.remainder>b.remainder?-1:1);
 let left=target-sum(allocation);
 for(const r of ranked){if(left===0n)break;if(allocation[r.i]!<gross[r.i]!){allocation[r.i]!++;left--;}}
 if(left!==0n)throw new DiscountFault("DOCUMENT_DISCOUNT_ALLOCATION_FAILED");
 return lines.map((l,i)=>{
  const discount=allocation[i]!,net=gross[i]!-discount,tax=halfUp(net*bp(l.taxRate),10000n);
  return {subtotal:l.subtotal,discountAmount:discount.toString(),taxAmount:tax.toString(),
   lineTotal:(net+tax).toString()};
 });
}
export async function applyDocumentDiscount(db:PoolClient,t:string,b:string,id:string,version:number,input:DocumentDiscount,actor:string){
 const r=await db.query<DiscountBase&{lineNo:number}>(`SELECT line_no AS "lineNo",subtotal::text,
  discount_amount::text AS "discountAmount",tax_rate::text AS "taxRate",
  tax_amount::text AS "taxAmount",line_total::text AS "lineTotal"
  FROM sales_order_line WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=$4
  ORDER BY line_no`,[t,b,id,version]);
 const computed=allocateDocumentDiscount(r.rows,input);
 for(let i=0;i<r.rows.length;i++){
  const base=r.rows[i]!,line=computed[i]!;
  await db.query(`UPDATE sales_order_line SET discount_amount=$6::numeric,tax_amount=$7::numeric,
   line_total=$8::numeric,price_snapshot=price_snapshot||$9::jsonb
   WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=$4 AND line_no=$5`,
   [t,b,id,version,base.lineNo,line.discountAmount,line.taxAmount,line.lineTotal,
   JSON.stringify({documentDiscount:{...input,allocatedAmount:line.discountAmount,
    originalLineTotal:base.lineTotal,actorId:actor}})]);
 }
}
