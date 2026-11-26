import { resolveR1Price,R1QuoteError,r1QuoteSignature } from "./r1_pricing.ts";
import { quoteManualSku,manualPriceFields,hasManualAdjustments,type ManualAdjustments,ManualPriceFault } from "./order_manual_price.ts";
import { DiscountFault,parseDocumentDiscount,allocateDocumentDiscount,applyDocumentDiscount,type DocumentDiscount } from "./sales_document_discount.ts";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Pool, PoolClient } from "pg";
import { resolveSession } from "./auth.ts";
import type { IdentityOptions } from "./identity_http.ts";
import { hasPermission } from "./rbac.ts";
import { userAccess } from "./identity_admin.ts";
import { OrderContextFault,parseOrderContext,type OrderContextInput,hasOrderContextSchema,
  saveOrderContext,authorizeOrderContext,copyOrderContext,
  lockContextWarehouses,readEntrySettings,ensureWalkInCustomer } from "./sales_order_context.ts";
import { executeMutation, readCommittedMutation, MutationFault, requireRevision, type MutationContext, type MutationHandlers } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const QTY=/^(?:0|[1-9][0-9]{0,8})(?:\.[0-9]{1,3})?$/;
class SalesError extends Error {
  readonly httpStatus:number;
  readonly code:string;
  constructor(httpStatus:number,code:string){
    super(code);this.httpStatus=httpStatus;this.code=code;
  }
}
function send(res:ServerResponse,status:number,data:unknown,id:string,origin?:string){
  const headers:Record<string,string>={
    "content-type":"application/json; charset=utf-8","cache-control":"no-store",
    "x-content-type-options":"nosniff","x-request-id":id,"vary":"Origin",
  };
  if(origin){
    headers["access-control-allow-origin"]=origin;
    headers["access-control-allow-headers"]="content-type,authorization,idempotency-key,if-match,x-request-id";
    headers["access-control-allow-methods"]="GET, POST, PATCH, OPTIONS";
    headers["access-control-max-age"]="300";
  }
  res.writeHead(status,headers);res.end(status===204?"":JSON.stringify(data));
}
function fail(res:ServerResponse,status:number,code:string,id:string,origin?:string){
  const message=status===401?"Vui lòng đăng nhập lại.":
    status===403?"Bạn không có quyền thực hiện thao tác này.":
    status===404?"Không tìm thấy đơn hàng.":
    status===409?"Đơn hàng hoặc giá bán đã thay đổi. Vui lòng tải lại.":
    status===503?"Chức năng đơn hàng đang tạm gián đoạn.":"Thông tin đơn hàng không hợp lệ.";
  send(res,status,{error:{code,message,requestId:id}},id,origin);
}
function uuid(value:unknown):string{
  if(typeof value!=="string"||!UUID.test(value))throw new SalesError(400,"INVALID_ID");
  return value;
}
function asRecord(value:unknown):Record<string,unknown>{
  if(!value||typeof value!=="object"||Array.isArray(value))throw new SalesError(400,"INVALID_BODY");
  return value as Record<string,unknown>;
}
function allowKeys(value:Record<string,unknown>,keys:readonly string[]){
  if(Object.keys(value).some(k=>!keys.includes(k)))throw new SalesError(400,"UNKNOWN_FIELD");
}
function requireText(value:unknown,max:number,empty=false):string{
  if(typeof value!=="string"||value.length>max||(!empty&&!value.trim()))
    throw new SalesError(400,"INVALID_TEXT");
  return value.trim();
}
async function bodyOf(req:IncomingMessage):Promise<Record<string,unknown>>{
  if(req.headers["content-type"]?.split(";")[0]?.trim().toLowerCase()!=="application/json")
    throw new SalesError(415,"INVALID_CONTENT_TYPE");
  if(Number(req.headers["content-length"]??0)>32768)throw new SalesError(413,"BODY_TOO_LARGE");
  let size=0;const parts:Buffer[]=[];
  for await(const part of req){
    const b=Buffer.isBuffer(part)?part:Buffer.from(part as Uint8Array);
    size+=b.length;if(size>32768)throw new SalesError(413,"BODY_TOO_LARGE");
    parts.push(b);
  }
  let data:unknown;
  try{data=JSON.parse(Buffer.concat(parts).toString("utf8")) as unknown;}
  catch{throw new SalesError(400,"INVALID_JSON");}
  return asRecord(data);
}
function bearer(req:IncomingMessage):string|null{
  const v=req.headers.authorization;
  return typeof v==="string"?/^Bearer ([A-Za-z0-9_-]{43})$/.exec(v)?.[1]??null:null;
}
type LineInput={productId?:string;sellSkuId?:string;quantity:string;expectedPriceSignature?:string;
 overrideReason?:string}&ManualAdjustments;
type OrderInput={branchId:string;customerId:string;priceListId:string;
  channelId?:string;note:string;lines:LineInput[];shipping?:OrderContextInput;documentDiscount?:DocumentDiscount};
export function parseOrder(raw:Record<string,unknown>):OrderInput{
  allowKeys(raw,["branchId","customerId","priceListId","channelId","note","lines","shipping","documentDiscount"]);
  const branchId=uuid(raw.branchId),customerId=uuid(raw.customerId),priceListId=uuid(raw.priceListId);
  const channelId=raw.channelId==null?undefined:uuid(raw.channelId);
  const note=requireText(raw.note??"",1000,true);
  const shipping=parseOrderContext(raw.shipping);
  const documentDiscount=parseDocumentDiscount(raw.documentDiscount,true);
  if(!Array.isArray(raw.lines)||raw.lines.length<1||raw.lines.length>30)
    throw new SalesError(400,"INVALID_LINES");
  const used=new Set<string>();
  const lines:LineInput[]=raw.lines.map((rawItem:unknown)=>{
    const item=asRecord(rawItem);allowKeys(item,["productId","sellSkuId","quantity","expectedPriceSignature",
      "unitPrice","discountRate","taxRate","discountMode","discountValue","taxMode","overrideReason"]);
    const hasProduct=item.productId!==undefined,hasSku=item.sellSkuId!==undefined;
    if(hasProduct===hasSku)throw new SalesError(400,"INVALID_LINE_IDENTITY");
    const productId=hasProduct?uuid(item.productId):undefined;
    const sellSkuId=hasSku?uuid(item.sellSkuId):undefined;
    const quantity=item.quantity;
    if(typeof quantity!=="string"||!QTY.test(quantity)||!/[1-9]/.test(quantity))
      throw new SalesError(400,"INVALID_QUANTITY");
    const key=productId?"PRODUCT:"+productId:"SKU:"+sellSkuId;
    if(productId&&used.has(key))throw new SalesError(400,"DUPLICATE_PRODUCT");
    used.add(key);
    if(productId){
      if(hasManualAdjustments(manualPriceFields(item))||item.overrideReason!==undefined)
        throw new SalesError(400,"INVALID_MANUAL_PRICE_CONTEXT");
      if(item.expectedPriceSignature!==undefined)throw new SalesError(400,"INVALID_PRICE_CONTEXT");
      return {productId,quantity};
    }
    const expected=item.expectedPriceSignature;
    if(typeof expected!=="string"||!/^[0-9a-f]{64}$/.test(expected))
      throw new SalesError(400,"PRICE_QUOTE_REQUIRED");
    const manual=manualPriceFields(item);
    const overrideReason=item.overrideReason===undefined?undefined:requireText(item.overrideReason,500);
    if(overrideReason&&!hasManualAdjustments(manual))throw new SalesError(400,"INVALID_MANUAL_PRICE_CONTEXT");
    return {sellSkuId,quantity,expectedPriceSignature:expected,...manual,...(overrideReason?{overrideReason}:{})};
  });
  if(channelId&&lines.some(line=>!line.sellSkuId))
    throw new SalesError(400,"CHANNEL_REQUIRES_SELL_SKU");
  if(documentDiscount&&lines.some(line=>!line.sellSkuId))throw new DiscountFault("DOCUMENT_DISCOUNT_REQUIRES_SKU");
  return {branchId,customerId,priceListId,...(channelId?{channelId}:{}),note,lines,...(shipping?{shipping}:{}),...(documentDiscount?{documentDiscount}:{})};
}
type QuoteInput={branchId:string;customerId:string;priceListId:string;
  channelId?:string;lines:({sellSkuId:string;quantity:string}&ManualAdjustments)[];documentDiscount?:DocumentDiscount};
function parseQuote(raw:Record<string,unknown>):QuoteInput{
  allowKeys(raw,["branchId","customerId","priceListId","channelId","lines","documentDiscount"]);
  const documentDiscount=parseDocumentDiscount(raw.documentDiscount,false);
  const branchId=uuid(raw.branchId),customerId=uuid(raw.customerId);
  const priceListId=uuid(raw.priceListId);
  const channelId=raw.channelId==null?undefined:uuid(raw.channelId);
  if(!Array.isArray(raw.lines)||raw.lines.length<1||raw.lines.length>30)
    throw new SalesError(400,"INVALID_LINES");
  const seen=new Set<string>();
  const lines=raw.lines.map(value=>{
    const item=asRecord(value);allowKeys(item,["sellSkuId","quantity","unitPrice","discountRate","taxRate","discountMode","discountValue","taxMode"]);
    const sellSkuId=uuid(item.sellSkuId),quantity=item.quantity;
    if(typeof quantity!=="string"||!QTY.test(quantity)||!/[1-9]/.test(quantity))
      throw new SalesError(400,"INVALID_QUANTITY");
    const manual=manualPriceFields(item);
    return {sellSkuId,quantity,...manual};
  });
  return {branchId,customerId,priceListId,...(channelId?{channelId}:{}),lines,...(documentDiscount?{documentDiscount}:{})};
}
async function adjustmentAllowed(db:PoolClient,t:string,actor:string,input:OrderInput|QuoteInput){
  const b=input.branchId,lines=input.lines;
  if(!input.documentDiscount&&!lines.some(hasManualAdjustments))return true;
  if(!await hasOrderContextSchema(db))
    return hasPermission(db,{installationId:t,actorId:actor,branchId:b,permission:"orders.update"});
  const required=new Set<string>();
  if(lines.some(x=>x.unitPrice!==undefined))required.add("orders.price.override");
  if(input.documentDiscount||lines.some(x=>x.discountMode!==undefined||x.discountValue!==undefined||
    x.discountRate!==undefined&&(x.unitPrice===undefined||/[1-9]/.test(x.discountRate))))
    required.add("orders.discount.override");
  if(lines.some(x=>x.taxMode!==undefined||x.taxRate!==undefined&&(x.unitPrice===undefined||/[1-9]/.test(x.taxRate))))
    required.add("orders.tax.override");
  for(const permission of required)
    if(!await hasPermission(db,{installationId:t,actorId:actor,branchId:b,permission}))return false;
  return true;
}
async function previewOrder(db:PoolClient,t:string,input:QuoteInput){
  const {branchId:b,customerId,priceListId,channelId}=input;
  await eligibility(db,t,b,customerId,priceListId);
  const at=new Date().toISOString();
  let lines=[];
  for(const line of input.lines){
    if(hasManualAdjustments(line)){
      const quote=await quoteManualSku(db,{installationId:t,branchId:b,
        customerId,priceListId,channelId,sellSkuId:line.sellSkuId,
        quantity:line.quantity,...manualPriceFields(line)});
      lines.push(quote);
    }else{
      const quote=await resolveR1Price(db,{
        installationId:t,branchId:b,customerId,priceListId,channelId,
        sellSkuId:line.sellSkuId,quantity:line.quantity,priceAt:at,
      });
      lines.push({...quote,priceSignature:r1QuoteSignature(quote)});
    }
  }
  if(input.documentDiscount){
    const amounts=allocateDocumentDiscount(lines.map(line=>({subtotal:"subtotal" in line?line.subtotal:line.lineTotal,
      discountAmount:"discountAmount" in line?line.discountAmount:"0",taxRate:"taxRate" in line?line.taxRate:"0",
      taxAmount:"taxAmount" in line?line.taxAmount:"0",lineTotal:line.lineTotal,
      taxMode:"taxMode" in line?line.taxMode:undefined,
      grossBeforeTaxMode:"grossBeforeTaxMode" in line?line.grossBeforeTaxMode:undefined,
      rawDiscount:"rawDiscount" in line?line.rawDiscount:undefined})),input.documentDiscount);
    lines=lines.map((line,i)=>({...line,...amounts[i]!}));
  }
  // Single server-side NUMERIC aggregation, never a client JS/Flutter float.
  const summed=await db.query<{total:string}>(
    "SELECT coalesce(sum(x),0)::text AS total FROM unnest($1::numeric[]) AS x",
    [lines.map(line=>line.lineTotal)]);
  const total=summed.rows[0]!.total;
  const sums=await db.query<{subtotal:string;discount:string;tax:string}>(
    `SELECT coalesce(sum(x.subtotal),0)::text AS subtotal,
      coalesce(sum(x.discount),0)::text AS discount,
      coalesce(sum(x.tax),0)::text AS tax FROM unnest(
        $1::numeric[],$2::numeric[],$3::numeric[]
      ) AS x(subtotal,discount,tax)`,
    [lines.map(line=>"subtotal" in line?line.subtotal:line.lineTotal),
     lines.map(line=>"discountAmount" in line?line.discountAmount:"0"),
     lines.map(line=>"taxAmount" in line?line.taxAmount:"0")]);
  return {branchId:b,customerId,priceListId,channelId:channelId??null,
    priceAt:at,lines,subtotal:sums.rows[0]!.subtotal,
    discountTotal:sums.rows[0]!.discount,taxTotal:sums.rows[0]!.tax,
    grandTotal:total,currency:"VND",
    taxPolicy:lines.some(line=>"manualOverride" in line)?"USER_ENTERED":"NOT_CONFIGURED",
    fulfillmentStatus:"NOT_ALLOCATED",deliveryStatus:"NOT_DISPATCHED",
    paymentStatus:"NOT_DUE"};
}
function mutation(req:IncomingMessage,id:string,installationId:string,actorId:string,
  action:string,payload:Record<string,unknown>,create=false):MutationContext{
  const key=req.headers["idempotency-key"],raw=req.headers["if-match"];
  if(typeof key!=="string"||!validIdempotencyKey(key)||
    typeof raw!=="string"||!/^(0|[1-9][0-9]{0,14})$/.test(raw))
    throw new SalesError(400,"MISSING_MUTATION_HEADERS");
  const expectedRevision=Number(raw);
  if(!Number.isSafeInteger(expectedRevision)||(create&&expectedRevision!==0))
    throw new SalesError(400,"INVALID_REVISION");
  return {installationId,actorId,requestId:id,action,idempotencyKey:key,
    expectedRevision,payload};
}
async function hasSchema(pool:Pool){
  try{
    const r=await pool.query<{ok:boolean}>("SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0010_r1_sales_price_snapshot.sql') AS ok");
    return r.rows[0]?.ok===true;
  }catch{return false;}
}
async function r1cListWindowEnabled(db:PoolClient):Promise<boolean>{
  const state=await db.query<{ready:boolean}>(`SELECT EXISTS(
    SELECT 1 FROM public.schema_migrations
    WHERE version='0018_r1c_price_list_assignment.sql') AS ready`);
  return state.rows[0]?.ready===true;
}
async function eligibility(db:PoolClient,t:string,b:string,c:string,l:string){
  const customer=await db.query<{code:string;name:string}>(
    "SELECT code,name FROM catalog_customer WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active=true FOR SHARE",
    [t,b,c]);
  const windowEnabled=await r1cListWindowEnabled(db);
  const list=await db.query<{code:string;currency:string}>(
    "SELECT code,currency FROM catalog_price_list WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active=true"+
      (windowEnabled?" AND (effective_from IS NULL OR effective_from<=now())"+
       " AND (effective_to IS NULL OR effective_to>now())":"")+
      " FOR SHARE",
    [t,b,l]);
  if(customer.rowCount!==1||list.rowCount!==1||list.rows[0]?.currency!=="VND")
    throw new SalesError(409,"CUSTOMER_OR_PRICE_LIST_UNAVAILABLE");
  return {customer:customer.rows[0]!,list:list.rows[0]!};
}
type Quote={productId:string;sku:string;name:string;unitCode:string;
  priceEntryId:string;amount:string;discountRate:string};
async function priceAt(db:PoolClient,t:string,b:string,listId:string,productId:string):Promise<Quote>{
  const windowEnabled=await r1cListWindowEnabled(db);
  const listWindow=windowEnabled?
    " AND (l.effective_from IS NULL OR l.effective_from<=now())"+
    " AND (l.effective_to IS NULL OR l.effective_to>now())":"";
  const r=await db.query<{
    sku:string;name:string;unitCode:string;priceEntryId:string;amount:string;discountRate:string;
  }>(`SELECT p.sku,p.name,p.base_unit AS "unitCode",
      e.id AS "priceEntryId",e.amount::text,e.discount_rate::text AS "discountRate"
    FROM catalog_product p
    JOIN catalog_price_list l ON l.installation_id=p.installation_id
      AND l.branch_id=p.branch_id AND l.id=$3 AND l.active ${listWindow}
    JOIN LATERAL (
      SELECT ep.id,ep.amount,ep.discount_rate FROM catalog_price_entry ep
      WHERE ep.installation_id=p.installation_id AND ep.branch_id=p.branch_id
        AND ep.product_id=p.id AND ep.price_list_id=l.id AND ep.effective_at<=now()
      ORDER BY ep.effective_at DESC,ep.id DESC LIMIT 1
    ) e ON true
    WHERE p.installation_id=$1 AND p.branch_id=$2 AND p.id=$4 AND p.active=true`,
    [t,b,listId,productId]);
  const row=r.rows[0];
  if(!row)throw new SalesError(409,"PRICE_UNAVAILABLE_OR_PRODUCT_INACTIVE");
  return {productId,sku:row.sku,name:row.name,unitCode:row.unitCode,
    priceEntryId:row.priceEntryId,amount:row.amount,discountRate:row.discountRate};
}
async function addLines(db:PoolClient,t:string,b:string,orderId:string,
  version:number,listId:string,customerId:string,channelId:string|undefined,lines:LineInput[],actorId:string){
  let no=0;
  for(const input of lines){
    if(input.sellSkuId&&hasManualAdjustments(input)){
      const quote=await quoteManualSku(db,{installationId:t,branchId:b,
        priceListId:listId,customerId,channelId,sellSkuId:input.sellSkuId,
        quantity:input.quantity,...manualPriceFields(input)});
      if(quote.priceSignature!==input.expectedPriceSignature)
        throw new SalesError(409,"PRICE_STALE");
      await db.query(`INSERT INTO sales_order_line
       (installation_id,branch_id,order_id,version_no,line_no,product_id,
        price_entry_id,sell_sku_id,pricing_engine,price_snapshot,price_signature,
        sku,product_name,unit_code,quantity,unit_price,discount_rate,
        subtotal,discount_amount,tax_rate,tax_amount,line_total)
       VALUES($1,$2,$3,$4,$5,$6,NULL,$7,'R1',$8::jsonb,$9,$10,$11,$12,
        $13::numeric,$14::numeric,$15::numeric,$16::numeric,
        $17::numeric,$18::numeric,$19::numeric,$20::numeric)`,
       [t,b,orderId,version,++no,quote.productId,quote.sellSkuId,
        JSON.stringify({...quote,overrideActorId:actorId,...(input.overrideReason?{overrideReason:input.overrideReason}:{})}),quote.priceSignature,
        quote.sku,quote.productName,quote.unitCode,
        input.quantity,quote.unitPrice,quote.discountRate,quote.subtotal,
        quote.discountAmount,quote.taxRate,quote.taxAmount,quote.lineTotal]);
      continue;
    }
    if(input.sellSkuId){
      const quote=await resolveR1Price(db,{
        installationId:t,branchId:b,sellSkuId:input.sellSkuId,priceListId:listId,
        customerId,channelId,quantity:input.quantity,priceAt:new Date().toISOString(),
      });
      const signature=r1QuoteSignature(quote);
      if(signature!==input.expectedPriceSignature)throw new SalesError(409,"PRICE_STALE");
      await db.query(`INSERT INTO sales_order_line
        (installation_id,branch_id,order_id,version_no,line_no,product_id,
         price_entry_id,sell_sku_id,pricing_engine,price_snapshot,price_signature,
         sku,product_name,unit_code,quantity,unit_price,discount_rate,
         subtotal,discount_amount,tax_rate,tax_amount,line_total)
        VALUES($1,$2,$3,$4,$5,$6,NULL,$7,'R1',$8::jsonb,$9,$10,$11,$12,
          $13::numeric,$14::numeric,0,$15::numeric,0,0,0,$15::numeric)`,
        [t,b,orderId,version,++no,quote.productId,quote.sellSkuId,
          JSON.stringify(quote),signature,quote.sku,quote.productName,quote.unitCode,
          input.quantity,quote.unitPrice,quote.lineTotal]);
      continue;
    }
    const p=await priceAt(db,t,b,listId,input.productId!);
    const r=await db.query<{subtotal:string;discount:string;total:string}>(
      `WITH base AS (SELECT round($1::numeric*$2::numeric,0) AS subtotal),
        calc AS (SELECT subtotal,round(subtotal*$3::numeric/100,0) AS discount FROM base)
       SELECT subtotal::text,discount::text,(subtotal-discount)::text AS total FROM calc`,
      [input.quantity,p.amount,p.discountRate]);
    const m=r.rows[0]!;
    await db.query(`INSERT INTO sales_order_line
      (installation_id,branch_id,order_id,version_no,line_no,product_id,price_entry_id,
       sku,product_name,unit_code,quantity,unit_price,discount_rate,subtotal,
       discount_amount,tax_rate,tax_amount,line_total)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::numeric,$12::numeric,$13::numeric,
        $14::numeric,$15::numeric,0,0,$16::numeric)`,
      [t,b,orderId,version,++no,p.productId,p.priceEntryId,p.sku,p.name,p.unitCode,
        input.quantity,p.amount,p.discountRate,m.subtotal,m.discount,m.total]);
  }
}
async function recalc(db:PoolClient,t:string,b:string,id:string,version:number){
  const r=await db.query<{total:string}>(`WITH sums AS (
      SELECT coalesce(sum(subtotal),0) AS subtotal,coalesce(sum(discount_amount),0) AS discount,
       coalesce(sum(tax_amount),0) AS tax,coalesce(sum(line_total),0) AS total
      FROM sales_order_line WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=$4)
    UPDATE sales_order_version v SET subtotal=s.subtotal,discount_total=s.discount,
     tax_total=s.tax,grand_total=s.total FROM sums s
    WHERE v.installation_id=$1 AND v.branch_id=$2 AND v.order_id=$3 AND v.version_no=$4
    RETURNING v.grand_total::text AS total`,[t,b,id,version]);
  if(!r.rows[0])throw new SalesError(409,"VERSION_NOT_FOUND");
  return r.rows[0].total;
}
export async function create(db:PoolClient,ctx:MutationContext,input:OrderInput,retailRef?:string){
  const t=ctx.installationId,b=input.branchId;
  const refs=await eligibility(db,t,b,input.customerId,input.priceListId);
  const r=await db.query<{id:string}>(`INSERT INTO sales_order
    (installation_id,branch_id,customer_id,price_list_id,channel_id,created_by,source_type,source_ref)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`,
    [t,b,input.customerId,input.priceListId,input.channelId??null,ctx.actorId,retailRef?'RETAIL':'COMPANY',retailRef??null]);
  const id=r.rows[0]!.id;
  await db.query(`INSERT INTO sales_order_version
    (installation_id,branch_id,order_id,version_no,customer_code,customer_name,price_list_code,note,created_by)
    VALUES($1,$2,$3,1,$4,$5,$6,$7,$8)`,
    [t,b,id,refs.customer.code,refs.customer.name,refs.list.code,input.note,ctx.actorId]);
  await saveOrderContext(db,ctx,b,id,1,input.customerId,input.shipping,true);
  await addLines(db,t,b,id,1,input.priceListId,input.customerId,input.channelId,input.lines,ctx.actorId);
  if(input.documentDiscount)await applyDocumentDiscount(db,t,b,id,1,input.documentDiscount,ctx.actorId);
  const total=await recalc(db,t,b,id,1);
  return {status:201,body:{id,branchId:b,status:"DRAFT",versionStatus:"DRAFT",
    version:1,revision:0,documentNo:null,customerId:input.customerId,
    priceListId:input.priceListId,channelId:input.channelId??null,total}};
}
type Locked={revision:string;status:string;document_no:string|null;current_version:number;
  customer_id:string;price_list_id:string;channel_id:string|null;fulfillment_status:string;delivery_status:string;
  payment_status:string};
async function lockOrder(db:PoolClient,t:string,b:string,id:string):Promise<Locked>{
  const q=await db.query<Locked>(`SELECT revision::text,status,document_no,current_version,customer_id,
    price_list_id,channel_id,fulfillment_status,delivery_status,payment_status
    FROM sales_order WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE`,
    [t,b,id]);
  if(!q.rows[0])throw new SalesError(404,"ORDER_NOT_FOUND");
  return q.rows[0];
}
async function edit(db:PoolClient,ctx:MutationContext,id:string,input:OrderInput){
  const t=ctx.installationId,b=input.branchId;
  await lockContextWarehouses(db,t,b,id,input.shipping?.warehouseId);
  const o=await lockOrder(db,t,b,id);
  requireRevision(ctx.expectedRevision,Number(o.revision));
  if(o.status==="CANCELLED")throw new SalesError(409,"ORDER_CANCELLED");

  const v=o.current_version;
  const state=await db.query<{state:string}>(`SELECT state FROM sales_order_version
    WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=$4 FOR UPDATE`,
    [t,b,id,v]);
  if(state.rows[0]?.state!=="DRAFT")throw new SalesError(409,"VERSION_ALREADY_CONFIRMED");
  if(o.status==="CONFIRMED"&&(o.customer_id!==input.customerId||o.price_list_id!==input.priceListId||
      o.channel_id!==(input.channelId??null)))
    throw new SalesError(409,"CONFIRMED_CUSTOMER_OR_PRICE_LIST_IMMUTABLE");
  const refs=await eligibility(db,t,b,input.customerId,input.priceListId);
  await db.query(`DELETE FROM sales_order_line WHERE installation_id=$1 AND branch_id=$2
    AND order_id=$3 AND version_no=$4`,[t,b,id,v]);
  await db.query(`UPDATE sales_order_version SET customer_code=$5,customer_name=$6,
    price_list_code=$7,note=$8 WHERE installation_id=$1 AND branch_id=$2
    AND order_id=$3 AND version_no=$4`,
    [t,b,id,v,refs.customer.code,refs.customer.name,refs.list.code,input.note]);
  await saveOrderContext(db,ctx,b,id,v,input.customerId,input.shipping,false);
  await addLines(db,t,b,id,v,input.priceListId,input.customerId,input.channelId,input.lines,ctx.actorId);
  if(input.documentDiscount)await applyDocumentDiscount(db,t,b,id,v,input.documentDiscount,ctx.actorId);
  const total=await recalc(db,t,b,id,v);
  const q=await db.query<{revision:string}>(`UPDATE sales_order SET
    customer_id=$4,price_list_id=$5,channel_id=$6,revision=revision+1,updated_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,
    [t,b,id,input.customerId,input.priceListId,input.channelId??null]);
  return {status:200,body:{id,revision:Number(q.rows[0]!.revision),
    status:o.status,versionStatus:"DRAFT",version:v,total}};
}
export async function confirm(db:PoolClient,ctx:MutationContext,id:string,b:string){
  const t=ctx.installationId,o=await lockOrder(db,t,b,id);
  requireRevision(ctx.expectedRevision,Number(o.revision));
  if(o.status==="CANCELLED")throw new SalesError(409,"ORDER_CANCELLED");
  const v=o.current_version;
  await authorizeOrderContext(db,t,b,ctx.actorId,id,v);
  const record=await db.query<{state:string}>(`SELECT state FROM sales_order_version
    WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=$4 FOR UPDATE`,
    [t,b,id,v]);
  if(record.rows[0]?.state!=="DRAFT")throw new SalesError(409,"VERSION_ALREADY_CONFIRMED");
  await eligibility(db,t,b,o.customer_id,o.price_list_id);
  const lines=await db.query<{
    product_id:string;price_entry_id:string|null;sell_sku_id:string|null;
    price_signature:string|null;pricing_engine:string;quantity:string;
    price_snapshot:({manualOverride?:boolean;manualPriceOverride?:boolean}&ManualAdjustments)|null;
    unit_price:string;discount_rate:string;tax_rate:string;
  }>(`SELECT product_id,price_entry_id,sell_sku_id,price_signature,pricing_engine,
    price_snapshot,quantity::text,unit_price::text,discount_rate::text,tax_rate::text
    FROM sales_order_line WHERE installation_id=$1 AND branch_id=$2
    AND order_id=$3 AND version_no=$4 ORDER BY line_no FOR SHARE`,[t,b,id,v]);
  if(!lines.rowCount)throw new SalesError(409,"ORDER_HAS_NO_LINES");
  for(const line of lines.rows){
    if(line.pricing_engine==="R1"){
      if(!line.sell_sku_id||!line.price_signature)throw new SalesError(409,"PRICE_STALE");
      try{
        if(line.price_snapshot?.manualOverride===true){
          const manual=await quoteManualSku(db,{installationId:t,branchId:b,
            sellSkuId:line.sell_sku_id,priceListId:o.price_list_id,
            customerId:o.customer_id,channelId:o.channel_id??undefined,
            quantity:line.quantity,
            ...(line.price_snapshot.manualPriceOverride===false?{}:{unitPrice:line.unit_price}),
            ...(line.price_snapshot.discountMode&&line.price_snapshot.discountMode!=="PERCENT"
              ?{discountMode:line.price_snapshot.discountMode,discountValue:line.price_snapshot.discountValue}
              :{discountRate:line.discount_rate,...(line.price_snapshot.discountMode?{discountMode:line.price_snapshot.discountMode}:{})}),
            taxRate:line.tax_rate,...(line.price_snapshot.taxMode?{taxMode:line.price_snapshot.taxMode}:{})});
          if(manual.priceSignature!==line.price_signature)
            throw new SalesError(409,"PRICE_STALE");
          continue;
        }
        const fresh=await resolveR1Price(db,{
          installationId:t,branchId:b,sellSkuId:line.sell_sku_id,
          priceListId:o.price_list_id,customerId:o.customer_id,
          channelId:o.channel_id??undefined,quantity:line.quantity,
          priceAt:new Date().toISOString(),
        });
        if(r1QuoteSignature(fresh)!==line.price_signature)
          throw new SalesError(409,"PRICE_STALE");
      }catch(err){
        if(err instanceof R1QuoteError)throw new SalesError(409,"PRICE_STALE");
        throw err;
      }
    }else{
      const now=await priceAt(db,t,b,o.price_list_id,line.product_id);
      if(now.priceEntryId!==line.price_entry_id)throw new SalesError(409,"PRICE_STALE");
    }
  }
  let doc=o.document_no;
  if(!doc){
    const seq=await db.query<{n:string}>(`INSERT INTO sales_order_sequence
      (installation_id,branch_id,next_value) VALUES($1,$2,2)
      ON CONFLICT (installation_id,branch_id)
      DO UPDATE SET next_value=sales_order_sequence.next_value+1
      RETURNING (next_value-1)::text AS n`,[t,b]);
    const n=Number(seq.rows[0]?.n??"0");
    if(!Number.isSafeInteger(n)||n<1||n>999999)throw new SalesError(409,"NUMBER_LIMIT");
    const date=await db.query<{day:string}>("SELECT to_char(now() AT TIME ZONE 'UTC','YYYYMMDD') AS day");
    doc="SO-"+date.rows[0]!.day+"-"+String(n).padStart(6,"0");
  }
  await db.query(`UPDATE sales_order_version SET state='CONFIRMED',
    confirmed_by=$5,confirmed_at=now() WHERE installation_id=$1 AND branch_id=$2
    AND order_id=$3 AND version_no=$4`,[t,b,id,v,ctx.actorId]);
  const updated=await db.query<{revision:string}>(`UPDATE sales_order SET
    status='CONFIRMED',document_no=$4,confirmed_by=$5,confirmed_at=now(),
    revision=revision+1,updated_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,
    [t,b,id,doc,ctx.actorId]);
  return {status:200,body:{id,documentNo:doc,status:"CONFIRMED",version:v,
    revision:Number(updated.rows[0]!.revision),fulfillmentStatus:o.fulfillment_status,
    deliveryStatus:o.delivery_status,paymentStatus:o.payment_status}};
}
// Legacy installations without inventory 0011 must still edit Sales 0010.
// The release query is therefore guarded by a schema existence check.
/** Release unexecuted holds in the SAME order transaction, before amending
 * or cancelling. No warehouse lock is required to release capacity; taking one
 * after the Sales parent lock would invert reserveStock's warehouse->order lock.
 * ReserveStock's parent FOR SHARE serializes with this parent FOR UPDATE.
 */
async function releaseUnexecutedSalesHolds(db:PoolClient,t:string,b:string,id:string){
 const exists=await db.query<{present:boolean}>(
   "SELECT to_regclass('public.inventory_reservation') IS NOT NULL AS present");
 if(exists.rows[0]?.present!==true)return 0;
 const r=await db.query(`UPDATE inventory_reservation
  SET state='RELEASED',revision=revision+1,released_at=now()
  WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND state='ACTIVE'`,
  [t,b,id]);
 return r.rowCount??0;
}
async function amend(db:PoolClient,ctx:MutationContext,id:string,b:string,reason:string){
  const t=ctx.installationId;
  await lockContextWarehouses(db,t,b,id);
  const o=await lockOrder(db,t,b,id);
  await authorizeOrderContext(db,t,b,ctx.actorId,id,o.current_version);
  requireRevision(ctx.expectedRevision,Number(o.revision));
  if(o.status!=="CONFIRMED")throw new SalesError(409,"ORDER_NOT_CONFIRMED");
  if(o.fulfillment_status!=="NOT_ALLOCATED"||o.delivery_status!=="NOT_DISPATCHED"||
     o.payment_status!=="NOT_DUE")throw new SalesError(409,"ORDER_ALREADY_EXECUTING");
  await releaseUnexecutedSalesHolds(db,t,b,id);
  const newVersion=o.current_version+1;
  const current=await db.query<{state:string}>(`SELECT state FROM sales_order_version
    WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=$4 FOR UPDATE`,
    [t,b,id,o.current_version]);
  if(current.rows[0]?.state!=="CONFIRMED")throw new SalesError(409,"AMENDMENT_ALREADY_OPEN");
  await db.query(`INSERT INTO sales_order_version
    (installation_id,branch_id,order_id,version_no,state,customer_code,customer_name,
     price_list_code,currency,subtotal,discount_total,tax_total,grand_total,note,
     amendment_reason,created_by)
    SELECT installation_id,branch_id,order_id,$5,'DRAFT',customer_code,customer_name,
      price_list_code,currency,subtotal,discount_total,tax_total,grand_total,
      note,$6,$7 FROM sales_order_version
    WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=$4`,
    [t,b,id,o.current_version,newVersion,reason,ctx.actorId]);
  await copyOrderContext(db,t,b,id,o.current_version,newVersion);
  await db.query(`INSERT INTO sales_order_line
    (installation_id,branch_id,order_id,version_no,line_no,product_id,price_entry_id,
     sell_sku_id,pricing_engine,price_snapshot,price_signature,
     sku,product_name,unit_code,quantity,unit_price,discount_rate,tax_rate,
     subtotal,discount_amount,tax_amount,line_total)
    SELECT installation_id,branch_id,order_id,$5,line_no,product_id,price_entry_id,
      sell_sku_id,pricing_engine,price_snapshot,price_signature,
      sku,product_name,unit_code,quantity,unit_price,discount_rate,tax_rate,
      subtotal,discount_amount,tax_amount,line_total FROM sales_order_line
    WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3 AND version_no=$4`,
    [t,b,id,o.current_version,newVersion]);
  const q=await db.query<{revision:string}>(`UPDATE sales_order SET
    current_version=$4,revision=revision+1,updated_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,
    [t,b,id,newVersion]);
  return {status:201,body:{id,status:"CONFIRMED",versionStatus:"DRAFT",
    version:newVersion,revision:Number(q.rows[0]!.revision),documentNo:o.document_no}};
}
async function cancel(db:PoolClient,ctx:MutationContext,id:string,b:string,reason:string){
  const t=ctx.installationId,o=await lockOrder(db,t,b,id);
  await authorizeOrderContext(db,t,b,ctx.actorId,id,o.current_version);
  requireRevision(ctx.expectedRevision,Number(o.revision));
  if(o.status==="CANCELLED")throw new SalesError(409,"ORDER_CANCELLED");
  if(o.fulfillment_status!=="NOT_ALLOCATED"||o.delivery_status!=="NOT_DISPATCHED"||
    o.payment_status!=="NOT_DUE")throw new SalesError(409,"ORDER_ALREADY_EXECUTING");
  await releaseUnexecutedSalesHolds(db,t,b,id);
  await db.query(`UPDATE sales_order_version SET state='CANCELLED'
    WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3
      AND version_no=$4 AND state='DRAFT'`,[t,b,id,o.current_version]);
  const q=await db.query<{revision:string}>(`UPDATE sales_order SET
    status='CANCELLED',cancelled_by=$4,cancelled_at=now(),cancellation_reason=$5,
    revision=revision+1,updated_at=now()
    WHERE installation_id=$1 AND branch_id=$2 AND id=$3 RETURNING revision::text`,
    [t,b,id,ctx.actorId,reason]);
  return {status:200,body:{id,status:"CANCELLED",revision:Number(q.rows[0]!.revision)}};
}
async function listing(db:PoolClient,t:string,b:string,search:string,actor:string){
  const modern=await hasOrderContextSchema(db);
  const warehouseIds=modern?(await userAccess(db,t,actor))
    .filter(g=>g.branchId===b&&g.permission==="inventory.read"&&g.warehouseId).map(g=>g.warehouseId!):[];
  const r=await db.query(`SELECT o.id,o.document_no AS "documentNo",o.status,o.revision::integer,
    o.current_version AS version,v.state AS "versionStatus",v.grand_total::text AS total,
    c.code AS "customerCode",
    ${modern?'coalesce(sc.walk_in_name,c.name) AS "customerName",sc.delivery_choice AS "deliveryChoice",sc.warehouse_name AS "warehouseName",':'c.name AS "customerName",'}
    o.created_at AS "createdAt",
    o.fulfillment_status AS "fulfillmentStatus",o.delivery_status AS "deliveryStatus",
    o.payment_status AS "paymentStatus"
    FROM sales_order o
    JOIN sales_order_version v ON v.installation_id=o.installation_id
      AND v.branch_id=o.branch_id AND v.order_id=o.id AND v.version_no=o.current_version
    JOIN catalog_customer c ON c.installation_id=o.installation_id
      AND c.branch_id=o.branch_id AND c.id=o.customer_id
    ${modern?'LEFT JOIN sales_order_version_context sc ON sc.installation_id=v.installation_id AND sc.branch_id=v.branch_id AND sc.order_id=v.order_id AND sc.version_no=v.version_no':''}
    WHERE o.installation_id=$1 AND o.branch_id=$2
      ${modern?'AND (sc.warehouse_id IS NULL OR sc.warehouse_id=ANY($4::uuid[]))':''}
      AND ($3='' OR o.document_no ILIKE '%'||$3||'%' OR c.code ILIKE '%'||$3||'%'
        OR c.name ILIKE '%'||$3||'%' ${modern?"OR sc.walk_in_name ILIKE '%'||$3||'%'":""})
    ORDER BY o.created_at DESC,o.id DESC LIMIT 100`,[t,b,search,...(modern?[warehouseIds]:[])]);
  return r.rows;
}
async function orderWarehouseAllowed(db:PoolClient,t:string,b:string,id:string,actor:string){
  if(!await hasOrderContextSchema(db))return true;
  const r=await db.query<{warehouse_id:string}>(`SELECT c.warehouse_id FROM sales_order o
    JOIN sales_order_version_context c ON c.installation_id=o.installation_id AND
     c.branch_id=o.branch_id AND c.order_id=o.id AND c.version_no=o.current_version
    WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$3`,[t,b,id]);
  return !r.rows[0]||await hasPermission(db,{installationId:t,actorId:actor,permission:"inventory.read",
    branchId:b,warehouseId:r.rows[0].warehouse_id});
}
async function detail(db:PoolClient,t:string,b:string,id:string,actor:string){
  const r=await db.query(`SELECT o.id,o.branch_id AS "branchId",o.customer_id AS "customerId",
    o.price_list_id AS "priceListId",o.channel_id AS "channelId",
    o.document_no AS "documentNo",o.status,
    o.revision::integer,o.current_version AS version,v.state AS "versionStatus",
    v.grand_total::text AS total,v.subtotal::text,
    v.discount_total::text AS "discountTotal",v.tax_total::text AS "taxTotal",
    v.note,v.amendment_reason AS "amendmentReason",o.created_at AS "createdAt",
    o.fulfillment_status AS "fulfillmentStatus",o.delivery_status AS "deliveryStatus",
    o.payment_status AS "paymentStatus",v.customer_name AS "customerName"
    FROM sales_order o JOIN sales_order_version v ON v.installation_id=o.installation_id
      AND v.branch_id=o.branch_id AND v.order_id=o.id AND v.version_no=o.current_version
    WHERE o.installation_id=$1 AND o.branch_id=$2 AND o.id=$3`,[t,b,id]);
  const item=r.rows[0] as Record<string,unknown>|undefined;
  if(!item)throw new SalesError(404,"ORDER_NOT_FOUND");
  const shipping=await authorizeOrderContext(db,t,b,actor,id,Number(item.version));
  const lines=await db.query(`SELECT line_no AS "lineNo",product_id AS "productId",sku,
    product_name AS "productName",unit_code AS "unitCode",
    sell_sku_id AS "sellSkuId",pricing_engine AS "pricingEngine",
    price_snapshot AS "priceSnapshot",quantity::text,unit_price::text AS "unitPrice",
    discount_rate::text AS "discountRate",
    tax_rate::text AS "taxRate",subtotal::text,discount_amount::text AS "discountAmount",
    tax_amount::text AS "taxAmount",line_total::text AS "lineTotal"
    FROM sales_order_line WHERE installation_id=$1 AND branch_id=$2 AND order_id=$3
      AND version_no=$4 ORDER BY line_no`,[t,b,id,item.version]);
  const modern=await hasOrderContextSchema(db);
  const warehouseIds=modern?(await userAccess(db,t,actor))
    .filter(g=>g.branchId===b&&g.permission==="inventory.read"&&g.warehouseId).map(g=>g.warehouseId!):[];
  const versions=await db.query(`SELECT v.version_no AS version,v.state,v.grand_total::text AS total,
    v.amendment_reason AS "amendmentReason",v.created_at AS "createdAt",v.confirmed_at AS "confirmedAt"
    FROM sales_order_version v
    ${modern?'LEFT JOIN sales_order_version_context sc ON sc.installation_id=v.installation_id AND sc.branch_id=v.branch_id AND sc.order_id=v.order_id AND sc.version_no=v.version_no':''}
    WHERE v.installation_id=$1 AND v.branch_id=$2 AND v.order_id=$3
    ${modern?'AND (sc.warehouse_id IS NULL OR sc.warehouse_id=ANY($4::uuid[]))':''}
    ORDER BY v.version_no DESC`,[t,b,id,...(modern?[warehouseIds]:[])]);
  return {...item,...(shipping?{shipping}:{}),lines:lines.rows,history:versions.rows};
}
const authorizeCreate=async(db:PoolClient,c:MutationContext,input:OrderInput)=>
  await hasPermission(db,{installationId:c.installationId,actorId:c.actorId,
    permission:"orders.create",branchId:input.branchId})&&
  await adjustmentAllowed(db,c.installationId,c.actorId,input)&&
  (!input.shipping||await hasPermission(db,{installationId:c.installationId,actorId:c.actorId,
    permission:"inventory.read",branchId:input.branchId,warehouseId:input.shipping.warehouseId}));
const authorizeUpdate=async(db:PoolClient,c:MutationContext,orderId:string,input:OrderInput)=>
  await hasPermission(db,{installationId:c.installationId,actorId:c.actorId,
    permission:"orders.update",branchId:input.branchId})&&
  await orderWarehouseAllowed(db,c.installationId,input.branchId,orderId,c.actorId)&&
  await adjustmentAllowed(db,c.installationId,c.actorId,input)&&
  (!input.shipping||await hasPermission(db,{installationId:c.installationId,actorId:c.actorId,
    permission:"inventory.read",branchId:input.branchId,warehouseId:input.shipping.warehouseId}));
const authorizeAction=async(db:PoolClient,c:MutationContext,orderId:string,branchId:string,action:string)=>
  await hasPermission(db,{installationId:c.installationId,actorId:c.actorId,
    permission:"orders."+action,branchId})&&
  await orderWarehouseAllowed(db,c.installationId,branchId,orderId,c.actorId);

export async function handleSalesHttp(req:IncomingMessage,res:ServerResponse,
  id:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
  const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
  const cors=origin&&origin===opts.allowedOrigin?origin:undefined;
  if(origin&&!cors){fail(res,403,"ORIGIN_DENIED",id);return;}
  if(req.method==="OPTIONS"){
    if(!cors){fail(res,403,"ORIGIN_DENIED",id);return;}
    send(res,204,null,id,cors);return;
  }
  const tenant=opts.installationId,pool=opts.pool;
  if(!tenant||!UUID.test(tenant)||!pool||!opts.allowedOrigin){
    fail(res,503,"SALES_NOT_CONFIGURED",id,cors);return;
  }
  try{
    if(!await ready()||!await hasSchema(pool)){
      fail(res,503,"SALES_MIGRATION_REQUIRED",id,cors);return;
    }
    const token=bearer(req),client=await pool.connect();
    let actorId:string|undefined;
    try{
      const actor=token?await resolveSession(client,tenant,token):null;
      actorId=actor?.actorId;
    }finally{client.release();}
    if(!actorId){fail(res,401,"AUTH_REQUIRED",id,cors);return;}
    const orderPath=/^\/v1\/sales\/orders\/([0-9a-f-]{36})(?:\/(confirm|amend|cancel))?$/.exec(url.pathname);
    if(url.pathname==="/v1/sales/entry-settings"&&req.method==="GET"){
      const branchId=uuid(url.searchParams.get("branchId")),db=await pool.connect();
      try{
        const allowed=await hasPermission(db,{installationId:tenant,actorId,
          permission:"orders.create",branchId})||
          await hasPermission(db,{installationId:tenant,actorId,permission:"orders.update",branchId});
        if(!allowed)throw new SalesError(403,"ORDERS_ENTRY_DENIED");
        send(res,200,{settings:await readEntrySettings(db,tenant,branchId,actorId),requestId:id},id,cors);
      }finally{db.release();}
      return;
    }
    if(url.pathname==="/v1/sales/walk-in"&&req.method==="POST"){
      const raw=await bodyOf(req);allowKeys(raw,["branchId"]);const branchId=uuid(raw.branchId);
      const ctx=mutation(req,id,tenant,actorId,"sales.walk-in.prepare",{branchId},true);
      const out=await executeMutation(pool,ctx,{
        authorize:async(db,c)=>await hasPermission(db,{installationId:c.installationId,
          actorId:c.actorId,permission:"orders.create",branchId})||
          await hasPermission(db,{installationId:c.installationId,actorId:c.actorId,
            permission:"orders.update",branchId}),
        execute:(db,c)=>ensureWalkInCustomer(db,c,branchId),
      });
      send(res,out.status,out.body,id,cors);return;
    }
    if(url.pathname==="/v1/sales/quote"&&req.method==="POST"){
      const input=parseQuote(await bodyOf(req));
      const db=await pool.connect();
      try{
        const allowed=await hasPermission(db,{installationId:tenant,actorId,
          permission:"orders.create",branchId:input.branchId})||
          await hasPermission(db,{installationId:tenant,actorId,
            permission:"orders.update",branchId:input.branchId});
        if(!allowed)throw new SalesError(403,"ORDERS_QUOTE_DENIED");
        if(!await adjustmentAllowed(db,tenant,actorId,input))
          throw new SalesError(403,"MANUAL_PRICE_PERMISSION_REQUIRED");
        const quote=await previewOrder(db,tenant,input);
        send(res,200,{quote,requestId:id},id,cors);
      }finally{db.release();}
      return;
    }
    if(url.pathname==="/v1/sales/last-purchase"&&req.method==="GET"){
      const branchId=uuid(url.searchParams.get("branchId"));
      const customerId=uuid(url.searchParams.get("customerId"));
      const sellSkuId=uuid(url.searchParams.get("sellSkuId"));
      const db=await pool.connect();
      try{
        const allowed=await hasPermission(db,{installationId:tenant,actorId,
          permission:"orders.read",branchId})||
          await hasPermission(db,{installationId:tenant,actorId,
            permission:"orders.create",branchId})||
          await hasPermission(db,{installationId:tenant,actorId,
            permission:"orders.update",branchId});
        if(!allowed)throw new SalesError(403,"LAST_PURCHASE_DENIED");
        const customer=await db.query("SELECT id FROM catalog_customer WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active",
          [tenant,branchId,customerId]);
        if(!customer.rowCount)throw new SalesError(409,"CUSTOMER_UNAVAILABLE");
        const modern=await hasOrderContextSchema(db);
        if(modern&&(await db.query("SELECT 1 FROM sales_walk_in_customer WHERE installation_id=$1 AND branch_id=$2 AND customer_id=$3",[tenant,branchId,customerId])).rowCount){
          send(res,200,{price:null,requestId:id},id,cors);return;
        }
        const warehouseIds=modern?(await userAccess(db,tenant,actorId))
          .filter(g=>g.branchId===branchId&&g.permission==="inventory.read"&&g.warehouseId).map(g=>g.warehouseId!):[];
        const found=await db.query<{unitPrice:string;discountRate:string;discountMode:string;discountValue:string|null;taxRate:string;taxMode:string;confirmedAt:Date}>(
          `SELECT line.unit_price::text AS "unitPrice",
           line.discount_rate::text AS "discountRate",
           coalesce(line.price_snapshot->>'discountMode','PERCENT') AS "discountMode",
           line.price_snapshot->>'discountValue' AS "discountValue",
           line.tax_rate::text AS "taxRate",coalesce(line.price_snapshot->>'taxMode','EXCLUSIVE') AS "taxMode",v.confirmed_at AS "confirmedAt"
          FROM sales_order_line line
          JOIN sales_order_version v ON v.installation_id=line.installation_id
           AND v.branch_id=line.branch_id AND v.order_id=line.order_id
           AND v.version_no=line.version_no AND v.state='CONFIRMED'
          JOIN sales_order o ON o.installation_id=v.installation_id
           AND o.branch_id=v.branch_id AND o.id=v.order_id
          ${modern?'LEFT JOIN sales_order_version_context sc ON sc.installation_id=v.installation_id AND sc.branch_id=v.branch_id AND sc.order_id=v.order_id AND sc.version_no=v.version_no':''}
          WHERE line.installation_id=$1 AND line.branch_id=$2
           ${modern?'AND (sc.warehouse_id IS NULL OR sc.warehouse_id=ANY($5::uuid[]))':''}
           AND o.customer_id=$3 AND line.sell_sku_id=$4
           AND o.status='CONFIRMED'
          ORDER BY v.confirmed_at DESC,o.id DESC,line.line_no DESC LIMIT 1`,
          [tenant,branchId,customerId,sellSkuId,...(modern?[warehouseIds]:[])]);
        send(res,200,{price:found.rows[0]??null,requestId:id},id,cors);
      }finally{db.release();}
      return;
    }
    if(url.pathname==="/v1/sales/orders"&&req.method==="GET"){
      const b=uuid(url.searchParams.get("branchId")),q=(url.searchParams.get("q")??"").trim();
      if(q.length>80)throw new SalesError(400,"SEARCH_TOO_LONG");
      const db=await pool.connect();
      try{
        if(!await hasPermission(db,{installationId:tenant,actorId,permission:"orders.read",branchId:b}))
          throw new SalesError(403,"ORDERS_READ_DENIED");
        send(res,200,{items:await listing(db,tenant,b,q,actorId),requestId:id},id,cors);
      }finally{db.release();}
      return;
    }
    if(orderPath&&req.method==="GET"&&!orderPath[2]){
      const b=uuid(url.searchParams.get("branchId")),orderId=uuid(orderPath[1]);
      const db=await pool.connect();
      try{
        if(!await hasPermission(db,{installationId:tenant,actorId,permission:"orders.read",branchId:b}))
          throw new SalesError(403,"ORDERS_READ_DENIED");
        send(res,200,{order:await detail(db,tenant,b,orderId,actorId),requestId:id},id,cors);
      }finally{db.release();}
      return;
    }
    if(url.pathname==="/v1/sales/recovery"&&req.method==="POST"){
      const raw=await bodyOf(req);allowKeys(raw,["action","orderId","body"]);
      const action=raw.action,body=asRecord(raw.body);
      let ctx:MutationContext,authorize:MutationHandlers["authorize"];
      if(action==="create"){
        if(raw.orderId!==undefined)throw new SalesError(400,"INVALID_ID");
        const input=parseOrder(body);
        ctx=mutation(req,id,tenant,actorId,"sales.order.create",input,true);
        authorize=(db,c)=>authorizeCreate(db,c,input);
      }else if(action==="update"){
        const orderId=uuid(raw.orderId),input=parseOrder(body);
        ctx=mutation(req,id,tenant,actorId,"sales.order.update",{id:orderId,...input});
        authorize=(db,c)=>authorizeUpdate(db,c,orderId,input);
      }else if(action==="confirm"){
        const orderId=uuid(raw.orderId);allowKeys(body,["branchId"]);
        const branchId=uuid(body.branchId);
        ctx=mutation(req,id,tenant,actorId,"sales.order.confirm",{id:orderId,branchId});
        authorize=(db,c)=>authorizeAction(db,c,orderId,branchId,"confirm");
      }else throw new SalesError(400,"INVALID_ACTION");
      const receipt=await readCommittedMutation(pool,ctx,authorize);
      send(res,200,{receipt:receipt?.body??null,requestId:id},id,cors);return;
    }
    if(url.pathname==="/v1/sales/orders"&&req.method==="POST"){
      const input=parseOrder(await bodyOf(req));
      const ctx=mutation(req,id,tenant,actorId,"sales.order.create",input,true);
      const out=await executeMutation(pool,ctx,{
        authorize:(db,c)=>authorizeCreate(db,c,input),
        execute:(db,c)=>create(db,c,input),
      });
      send(res,out.status,out.body,id,cors);return;
    }
    if(orderPath&&req.method==="PATCH"&&!orderPath[2]){
      const orderId=uuid(orderPath[1]),input=parseOrder(await bodyOf(req));
      const ctx=mutation(req,id,tenant,actorId,"sales.order.update",{id:orderId,...input});
      const out=await executeMutation(pool,ctx,{
        authorize:(db,c)=>authorizeUpdate(db,c,orderId,input),
        execute:(db,c)=>edit(db,c,orderId,input),
      });
      send(res,out.status,out.body,id,cors);return;
    }
    if(orderPath&&req.method==="POST"&&orderPath[2]){
      const orderId=uuid(orderPath[1]),action=orderPath[2];
      const raw=await bodyOf(req);
      allowKeys(raw,action==="confirm"?["branchId"]:["branchId","reason"]);
      const b=uuid(raw.branchId);
      const reason=action==="confirm"?"":requireText(raw.reason,500);
      if(action!=="confirm"&&reason.length<3)throw new SalesError(400,"REASON_REQUIRED");
      const ctx=mutation(req,id,tenant,actorId,"sales.order."+action,{
        id:orderId,branchId:b,...(reason?{reason}:{})});
      const out=await executeMutation(pool,ctx,{
        authorize:(db,c)=>authorizeAction(db,c,orderId,b,action),
        execute:(db,c)=>action==="confirm"?confirm(db,c,orderId,b):
          action==="amend"?amend(db,c,orderId,b,reason):cancel(db,c,orderId,b,reason),
      });
      send(res,out.status,out.body,id,cors);return;
    }
    fail(res,405,"METHOD_NOT_ALLOWED",id,cors);
  }catch(err){
    if(err instanceof DiscountFault){fail(res,err.status,err.code,id,cors);return;}
    if(err instanceof OrderContextFault){fail(res,err.status,err.code,id,cors);return;}
    if(err instanceof SalesError){fail(res,err.httpStatus,err.code,id,cors);return;}
    if(err instanceof R1QuoteError){fail(res,err.status,err.code,id,cors);return;}
    if(err instanceof ManualPriceFault){fail(res,err.status,err.code,id,cors);return;}
    if(err instanceof MutationFault){fail(res,err.httpStatus,err.code,id,cors);return;}
    if(typeof err==="object"&&err!==null&&"code" in err){
      if(err.code==="23505"){fail(res,409,"DUPLICATE_ORDER",id,cors);return;}
      if(err.code==="23503"||err.code==="23514"){fail(res,400,"INVALID_REFERENCE",id,cors);return;}
    }
    fail(res,503,"SALES_UNAVAILABLE",id,cors);
  }
}
