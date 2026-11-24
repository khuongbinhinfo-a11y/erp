import type { IncomingMessage,ServerResponse } from "node:http";
import type { Pool,PoolClient } from "pg";
import { resolveSession } from "./auth.ts";
import { hasPermission } from "./rbac.ts";
import { executeMutation,MutationFault,requireRevision,type MutationContext } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";
import type { IdentityOptions } from "./identity_http.ts";
import { resolveR1Price,R1QuoteError,r1QuoteSignature } from "./r1_pricing.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CODE=/^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$/;
const BAR=/^[A-Za-z0-9._-]{4,64}$/;
const FACTOR=/^(?:0\.[0-9]{0,5}[1-9]|[1-9][0-9]{0,11}(?:\.[0-9]{1,6})?)$/;
const QTY=/^(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,3})?$/;
const MONEY=/^(?:0|[1-9][0-9]{0,12})(?:\.[0-9]{1,4})?$/;
class R1Error extends Error{
  readonly status:number;readonly code:string;
  constructor(status:number,code:string){super(code);this.status=status;this.code=code;}
}
function send(res:ServerResponse,status:number,body:unknown,id:string,origin?:string){
 const h:Record<string,string>={
  "content-type":"application/json; charset=utf-8","cache-control":"no-store",
  "x-request-id":id,"x-content-type-options":"nosniff","vary":"Origin",
 };
 if(origin){
  h["access-control-allow-origin"]=origin;
  h["access-control-allow-headers"]="content-type,authorization,idempotency-key,if-match,x-request-id";
  h["access-control-allow-methods"]="GET,POST,PATCH,OPTIONS";
 }
 res.writeHead(status,h);res.end(JSON.stringify(body));
}
function fail(res:ServerResponse,status:number,code:string,id:string,origin?:string){
 const message=status===401?"Vui lòng đăng nhập lại.":
  status===403?"Bạn không có quyền tại chi nhánh này.":
  status===404?"Không tìm thấy dữ liệu đang chọn.":
  status===409?"Dữ liệu đã tồn tại hoặc giá không còn phù hợp.":
  status===503?"Danh mục đang tạm gián đoạn. Vui lòng thử lại.":
  "Thông tin nhập chưa hợp lệ.";
 send(res,status,{error:{code,message,requestId:id}},id,origin);
}
function keys(raw:Record<string,unknown>,allowed:string[]){
 if(Object.keys(raw).some(x=>!allowed.includes(x)))throw new R1Error(400,"UNKNOWN_FIELD");
}
function id(value:unknown):string{
 if(typeof value!=="string"||!UUID.test(value))throw new R1Error(400,"INVALID_ID");
 return value.toLowerCase();
}
function optionalId(value:unknown):string|undefined{
 return value==null?undefined:id(value);
}
function code(value:unknown):string{
 if(typeof value!=="string"||!CODE.test(value))throw new R1Error(400,"INVALID_CODE");
 return value;
}
function label(value:unknown,max=160):string{
 if(typeof value!=="string"||!value.trim()||value.trim().length>max)
  throw new R1Error(400,"INVALID_TEXT");
 return value.trim();
}
function decimal(value:unknown,rx:RegExp):string{
 if(typeof value!=="string"||!rx.test(value))throw new R1Error(400,"INVALID_DECIMAL");
 if(rx===QTY && !/[1-9]/.test(value))throw new R1Error(400,"ZERO_QUANTITY");
 return value;
}
function bool(value:unknown,defaultValue=false):boolean{
 if(value===undefined)return defaultValue;
 if(typeof value!=="boolean")throw new R1Error(400,"INVALID_BOOLEAN");
 return value;
}
function enumVal(value:unknown,choices:string[]):string{
 if(typeof value!=="string"||!choices.includes(value))throw new R1Error(400,"INVALID_CHOICE");
 return value;
}
function iso(value:unknown):string{
 if(typeof value!=="string"||!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$/.test(value)||
   !Number.isFinite(Date.parse(value)))throw new R1Error(400,"INVALID_TIME");
 return value;
}
function number(value:unknown,minimum:number,maximum:number):number{
 if(typeof value!=="number"||!Number.isSafeInteger(value)||value<minimum||value>maximum)
  throw new R1Error(400,"INVALID_INTEGER");
 return value;
}
async function body(req:IncomingMessage):Promise<Record<string,unknown>>{
 if(req.headers["content-type"]?.split(";")[0]?.trim().toLowerCase()!=="application/json")
  throw new R1Error(415,"INVALID_CONTENT_TYPE");
 if(Number(req.headers["content-length"]??0)>16384)throw new R1Error(413,"BODY_TOO_LARGE");
 const chunks:Buffer[]=[];let size=0;
 for await(const part of req){
  const chunk=Buffer.isBuffer(part)?part:Buffer.from(part as Uint8Array);
  size+=chunk.length;
  if(size>16384)throw new R1Error(413,"BODY_TOO_LARGE");
  chunks.push(chunk);
 }
 try{
  const parsed:unknown=JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if(!parsed||typeof parsed!=="object"||Array.isArray(parsed))throw Error("shape");
  return parsed as Record<string,unknown>;
 }catch{throw new R1Error(400,"INVALID_JSON");}
}
function mutation(req:IncomingMessage,ctx:Omit<MutationContext,"idempotencyKey"|"expectedRevision">):MutationContext{
 const raw=req.headers["idempotency-key"],rev=req.headers["if-match"];
 if(typeof raw!=="string"||!validIdempotencyKey(raw)||rev!=="0")
  throw new R1Error(400,"INVALID_MUTATION_HEADERS");
 return {...ctx,idempotencyKey:raw,expectedRevision:0};
}
function patchMutation(req:IncomingMessage,
  ctx:Omit<MutationContext,"idempotencyKey"|"expectedRevision">):MutationContext{
  const key=req.headers["idempotency-key"],version=req.headers["if-match"];
  if(typeof key!=="string"||!validIdempotencyKey(key)||
     typeof version!=="string"||!/^(0|[1-9][0-9]{0,14})$/.test(version))
    throw new R1Error(400,"INVALID_MUTATION_HEADERS");
  const n=Number(version);
  if(!Number.isSafeInteger(n))throw new R1Error(400,"INVALID_REVISION");
  return {...ctx,idempotencyKey:key,expectedRevision:n};
}
async function hasR1A(db:Pool|PoolClient):Promise<boolean>{
 const r=await db.query<{ready:boolean}>(`SELECT EXISTS(
   SELECT 1 FROM public.schema_migrations
   WHERE version='0017_r1a_customer_directories.sql') AS ready`);
 return r.rows[0]?.ready===true;
}
async function schema(db:Pool){
 try{
  const r=await db.query<{ok:boolean}>(
   "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0010_r1_sales_price_snapshot.sql') AS ok");
  return r.rows[0]?.ok===true;
 }catch{return false;}
}
type Kind="units"|"skus"|"barcodes"|"channels"|"rules";
function kind(value:string):Kind{
 if(!["units","skus","barcodes","channels","rules"].includes(value))
  throw new R1Error(404,"UNKNOWN_RESOURCE");
 return value as Kind;
}
export function parse(kind:Kind,raw:Record<string,unknown>){
 const branchId=id(raw.branchId);
 if(kind==="units"){
  keys(raw,["branchId","productId","unitCode","toBase"]);
  return {branchId,productId:id(raw.productId),
   unitCode:label(raw.unitCode,24),toBase:decimal(raw.toBase,FACTOR)};
 }
 if(kind==="skus"){
  keys(raw,["branchId","productId","sku","unitCode","toBase"]);
  return {branchId,productId:id(raw.productId),sku:code(raw.sku),
   unitCode:label(raw.unitCode,24),toBase:decimal(raw.toBase,FACTOR)};
 }
 if(kind==="barcodes"){
  keys(raw,["branchId","sellSkuId","barcode","isPrimary"]);
  if(typeof raw.barcode!=="string"||!BAR.test(raw.barcode))
   throw new R1Error(400,"INVALID_BARCODE");
  return {branchId,sellSkuId:id(raw.sellSkuId),barcode:raw.barcode,
   isPrimary:bool(raw.isPrimary)};
 }
 if(kind==="channels"){
  keys(raw,["branchId","code","name"]);
  return {branchId,code:code(raw.code),name:label(raw.name)};
 }
 keys(raw,["branchId","priceListId","sellSkuId","scopeKind","channelId","customerId",
  "customerGroup","adjustment","amount","priority","stacking","stopProcessing",
  "minQuantity","effectiveFrom","effectiveTo","importGrossAmount","importDiscountRate"]);
 const scopeKind=enumVal(raw.scopeKind,["BASE","CHANNEL","CUSTOMER_GROUP","CUSTOMER","PROMOTION"]);
 const adjustment=enumVal(raw.adjustment,["FIXED_PRICE","PERCENT_DISCOUNT",
  "AMOUNT_DISCOUNT","PERCENT_MARKUP","AMOUNT_MARKUP"]);
 const amount=decimal(raw.amount,MONEY);
 const importing=raw.importGrossAmount!==undefined||raw.importDiscountRate!==undefined;
 if(importing&&(scopeKind!=="BASE"||adjustment!=="FIXED_PRICE"||
   raw.importGrossAmount===undefined||raw.importDiscountRate===undefined))
  throw new R1Error(400,"INVALID_IMPORT_PRICE_METADATA");
 const importGrossAmount=importing?decimal(raw.importGrossAmount,MONEY):undefined;
 const importDiscountRate=importing?decimal(raw.importDiscountRate,/^(?:100(?:\.0{1,2})?|(?:[0-9]|[1-9][0-9])(?:\.[0-9]{1,2})?)$/):undefined;
 const channelId=optionalId(raw.channelId),customerId=optionalId(raw.customerId);
 const customerGroup=raw.customerGroup==null?undefined:label(raw.customerGroup,64);
 if(scopeKind==="BASE"&&(adjustment!=="FIXED_PRICE"||channelId||customerId||customerGroup))
  throw new R1Error(400,"INVALID_BASE_PRICE");
 if(scopeKind==="CHANNEL"&&(!channelId||customerId||customerGroup))
  throw new R1Error(400,"INVALID_CHANNEL_SCOPE");
 if(scopeKind==="CUSTOMER_GROUP"&&(!customerGroup||customerId))
  throw new R1Error(400,"INVALID_GROUP_SCOPE");
 if(scopeKind==="CUSTOMER"&&!customerId)throw new R1Error(400,"INVALID_CUSTOMER_SCOPE");
 if(["PERCENT_DISCOUNT","PERCENT_MARKUP"].includes(adjustment)){
  const split=amount.split(".");
  if(BigInt(split[0]??"0")>100n||
    (split[0]==="100"&&/[1-9]/.test(split[1]??"")))
    throw new R1Error(400,"INVALID_PERCENT");
 }
 const start=iso(raw.effectiveFrom),end=raw.effectiveTo==null?undefined:iso(raw.effectiveTo);
 if(end&&Date.parse(end)<=Date.parse(start))throw new R1Error(400,"INVALID_EFFECTIVE_RANGE");
 if(scopeKind==="PROMOTION"&&!end)throw new R1Error(400,"PROMOTION_EXPIRY_REQUIRED");
 return {branchId,priceListId:id(raw.priceListId),sellSkuId:id(raw.sellSkuId),
  scopeKind,adjustment,amount,channelId,customerId,customerGroup,
  priority:number(raw.priority??0,-100000,100000),
  stacking:enumVal(raw.stacking??"EXCLUSIVE",["EXCLUSIVE","STACKABLE"]),
  stopProcessing:bool(raw.stopProcessing),minQuantity:decimal(raw.minQuantity??"1",QTY),
  effectiveFrom:start,effectiveTo:end,importGrossAmount,importDiscountRate};
}
type Parsed=ReturnType<typeof parse>;
export async function create(db:PoolClient,tenant:string,kind:Kind,parsed:Parsed){
 const b=parsed.branchId;
 if(kind==="units"&&"productId" in parsed){
  const r=await db.query<{product_id:string}>(`INSERT INTO catalog_unit
    (installation_id,branch_id,product_id,unit_code,to_base)
    SELECT $1,$2,p.id,$4,$5::numeric FROM catalog_product p
    WHERE p.installation_id=$1 AND p.branch_id=$2 AND p.id=$3 AND p.active
    RETURNING product_id`,[tenant,b,parsed.productId,parsed.unitCode,parsed.toBase]);
  if(!r.rows[0])throw new R1Error(409,"PRODUCT_UNAVAILABLE");
  return {status:201,body:{productId:r.rows[0].product_id,
   unitCode:parsed.unitCode,toBase:parsed.toBase}};
 }
 if(kind==="skus"&&"productId" in parsed){
  // Lock product first, the same order used by SKU lifecycle retirement.
  // Recheck active after acquiring lock to prevent concurrent retirement.
  const parent=await db.query<{active:boolean}>(
   'SELECT active FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 '+
   'AND id=$3 FOR UPDATE',[tenant,b,parsed.productId]);
  if(parent.rows[0]?.active!==true)throw new R1Error(409,"PRODUCT_UNAVAILABLE");
  const r=await db.query<{id:string}>(`INSERT INTO catalog_sell_sku
   (installation_id,branch_id,product_id,sku,unit_code,conversion_to_base)
   SELECT $1,$2,p.id,$4,$5,$6::numeric FROM catalog_product p
   WHERE p.installation_id=$1 AND p.branch_id=$2 AND p.id=$3 AND p.active
   RETURNING id`,[tenant,b,parsed.productId,parsed.sku,parsed.unitCode,parsed.toBase]);
  if(!r.rows[0])throw new R1Error(409,"PRODUCT_UNAVAILABLE");
  return {status:201,body:{id:r.rows[0].id,sku:parsed.sku,unitCode:parsed.unitCode,
   conversionToBase:parsed.toBase}};
 }
 if(kind==="barcodes"&&"sellSkuId" in parsed){
  const r=await db.query<{id:string}>(`INSERT INTO catalog_sku_barcode
   (installation_id,branch_id,sell_sku_id,barcode,is_primary)
   SELECT $1,$2,s.id,$4,$5 FROM catalog_sell_sku s
   WHERE s.installation_id=$1 AND s.branch_id=$2 AND s.id=$3 AND s.active
   RETURNING id`,[tenant,b,parsed.sellSkuId,parsed.barcode,parsed.isPrimary]);
  if(!r.rows[0])throw new R1Error(409,"SKU_UNAVAILABLE");
  return {status:201,body:{id:r.rows[0].id,barcode:parsed.barcode,
   sellSkuId:parsed.sellSkuId}};
 }
 if(kind==="channels"&&"code" in parsed){
  const r=await db.query<{id:string}>(`INSERT INTO catalog_sales_channel
    (installation_id,branch_id,code,name) VALUES($1,$2,$3,$4) RETURNING id`,
    [tenant,b,parsed.code,parsed.name]);
  return {status:201,body:{id:r.rows[0]!.id,code:parsed.code,name:parsed.name}};
 }
 if(kind==="rules"&&"scopeKind" in parsed){
  // New customer-group rules must reference an existing active coded directory.
  // Legacy immutable price rules remain untouched; never rewrite their snapshot.
  if(parsed.customerGroup){
    const group=await db.query<{id:string}>(`SELECT id FROM catalog_customer_group
      WHERE installation_id=$1 AND branch_id=$2 AND code=$3 AND active`,
      [tenant,b,parsed.customerGroup]);
    if(group.rowCount!==1)throw new R1Error(400,"CUSTOMER_GROUP_REFERENCE_REQUIRED");
  }
  // Two conflicting policies at identical priority/threshold/target and
  // overlapping effective periods are ambiguous. Lock that exact commercial
  // scope so concurrent requests cannot both pass the overlap check.
  const [whole="0",fraction=""]=(parsed.minQuantity??"1").split(".");
  const cleanFraction=fraction.replace(/0+$/,"");
  const canonicalQuantity=cleanFraction?whole+"."+cleanFraction:whole;
  const scopeLock=JSON.stringify([tenant,b,parsed.priceListId,parsed.sellSkuId,
    parsed.scopeKind,parsed.channelId??null,parsed.customerId??null,
    parsed.customerGroup??null,parsed.priority,canonicalQuantity]);
  await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))",[scopeLock]);
  const args=[tenant,b,parsed.priceListId,parsed.sellSkuId,parsed.scopeKind,
    parsed.channelId??null,parsed.customerId??null,parsed.customerGroup??null,
    parsed.adjustment,parsed.amount,parsed.priority,parsed.stacking,
    parsed.stopProcessing,parsed.minQuantity,parsed.effectiveFrom,parsed.effectiveTo??null];
  const clash=await db.query(`SELECT r.id FROM catalog_sku_price_rule r
    WHERE r.installation_id=$1 AND r.branch_id=$2
      AND r.price_list_id=$3 AND r.sell_sku_id=$4 AND r.scope_kind=$5
      AND r.channel_id IS NOT DISTINCT FROM $6::uuid
      AND r.customer_id IS NOT DISTINCT FROM $7::uuid
      AND r.customer_group IS NOT DISTINCT FROM $8::text
      AND r.priority=$11 AND r.min_quantity=$14::numeric
      -- BASE is an append-only timeline: later effective dates supersede
      -- earlier open-ended prices without rewriting historical rules.
      -- Same-time contradictory BASE policies are still rejected.
      AND (r.scope_kind<>'BASE' OR r.effective_from=$15::timestamptz)
      AND r.effective_from<coalesce($16::timestamptz,'infinity'::timestamptz)
      AND coalesce(r.effective_to,'infinity'::timestamptz)>$15::timestamptz
      AND (r.adjustment<>$9 OR r.amount<>$10::numeric
        OR r.stacking<>$12 OR r.stop_processing<>$13)
      AND NOT EXISTS (SELECT 1 FROM catalog_sku_price_retirement x
        WHERE x.installation_id=r.installation_id AND x.branch_id=r.branch_id
          AND x.rule_id=r.id AND x.retired_at<=transaction_timestamp())
    LIMIT 1`,args);
  if(clash.rows.length)throw new R1Error(409,"PRICE_RULE_OVERLAP");
  const metadata=parsed.importGrossAmount!==undefined;
  if(metadata){
   const state=await db.query<{ready:boolean}>(`SELECT EXISTS(
     SELECT 1 FROM public.schema_migrations
     WHERE version='0019_p0_price_order_parity.sql') AS ready`);
   if(!state.rows[0]?.ready)throw new R1Error(503,"P0_PRICE_SCHEMA_REQUIRED");
  }
  const extraColumns=metadata?",imported_gross_amount,imported_discount_rate":"";
  const extraParameters=metadata?",$17::numeric,$18::numeric":"";
  const insertArgs=metadata?[...args,parsed.importGrossAmount,parsed.importDiscountRate]:args;
  const r=await db.query<{id:string}>(`INSERT INTO catalog_sku_price_rule
   (installation_id,branch_id,price_list_id,sell_sku_id,scope_kind,
    channel_id,customer_id,customer_group,adjustment,amount,priority,stacking,
    stop_processing,min_quantity,effective_from,effective_to${extraColumns})
   SELECT $1,$2,l.id,s.id,$5,$6,$7,$8,$9,$10::numeric,$11,$12,
      $13,$14::numeric,$15::timestamptz,$16::timestamptz${extraParameters}
   FROM catalog_price_list l
   JOIN catalog_sell_sku s ON s.installation_id=l.installation_id
     AND s.branch_id=l.branch_id AND s.id=$4 AND s.active
   JOIN catalog_product p ON p.installation_id=s.installation_id
     AND p.branch_id=s.branch_id AND p.id=s.product_id AND p.active
   WHERE l.installation_id=$1 AND l.branch_id=$2 AND l.id=$3 AND l.active
   RETURNING id`,
   insertArgs);
  if(!r.rows[0])throw new R1Error(409,"PRICE_TARGET_UNAVAILABLE");
  return {status:201,body:{id:r.rows[0].id,scopeKind:parsed.scopeKind,
    adjustment:parsed.adjustment,amount:parsed.amount,priceListId:parsed.priceListId,
    sellSkuId:parsed.sellSkuId}};
 }
 throw new R1Error(404,"UNKNOWN_RESOURCE");
}
async function retireRule(db:PoolClient,tenant:string,actorId:string,branchId:string,
  ruleId:string,reason:string){
 const r=await db.query<{retiredAt:Date}>(`INSERT INTO catalog_sku_price_retirement
    (installation_id,branch_id,rule_id,reason,actor_id)
    SELECT p.installation_id,p.branch_id,p.id,$4,$5
    FROM catalog_sku_price_rule p
    WHERE p.installation_id=$1 AND p.branch_id=$2 AND p.id=$3
      AND p.scope_kind <> 'BASE'
    RETURNING retired_at AS "retiredAt"`,
   [tenant,branchId,ruleId,reason,actorId]);
 if(!r.rows[0])throw new R1Error(404,"RULE_NOT_FOUND");
 return {status:200,body:{id:ruleId,branchId,retiredAt:r.rows[0].retiredAt.toISOString()}};
}
export function buildSkuTaxonomyFilters(scope?:{brandId?:string;groupId?:string;categoryId?:string;productId?:string;afterId?:string}){
  const filters:string[]=[];
  const values:string[]=[];
  const add=(id:string)=>{
    values.push(id);
    return "$"+(values.length+3)+"::uuid";
  };
  if(scope?.productId)filters.push(`s.product_id=${add(scope.productId)}`);
  if(scope?.afterId)filters.push(`s.id>${add(scope.afterId)}`);
  if(scope?.groupId)filters.push(`p.group_id=${add(scope.groupId)}`);
  if(scope?.categoryId)filters.push(`p.category_id IN (
    WITH RECURSIVE descendants(id) AS (
      SELECT id FROM catalog_product_category
       WHERE installation_id=p.installation_id AND branch_id=p.branch_id
         AND id=${add(scope.categoryId)}
      UNION ALL
      SELECT c.id FROM catalog_product_category c JOIN descendants d
        ON c.parent_id=d.id
       WHERE c.installation_id=p.installation_id AND c.branch_id=p.branch_id
    ) SELECT id FROM descendants)`);
  if(scope?.brandId)filters.push(`EXISTS (SELECT 1 FROM catalog_product_group g WHERE
      g.installation_id=p.installation_id AND g.branch_id=p.branch_id
      AND g.id=p.group_id AND g.brand_id=${add(scope.brandId)})`);
  return {filters,values};
}
async function listing(db:PoolClient,t:string,b:string,kind:Kind,q:string,skuId?:string,
  scope?:{brandId?:string;groupId?:string;categoryId?:string;productId?:string;afterId?:string}){
 if(kind==="units"){
  const r=await db.query(`SELECT u.product_id AS "productId",p.sku AS "productCode",
    p.name AS "productName",u.unit_code AS "unitCode",u.to_base::text AS "toBase"
    FROM catalog_unit u JOIN catalog_product p ON p.installation_id=u.installation_id
      AND p.branch_id=u.branch_id AND p.id=u.product_id
    WHERE u.installation_id=$1 AND u.branch_id=$2
      AND (p.sku ILIKE $3 OR p.name ILIKE $3 OR u.unit_code ILIKE $3)
      ${scope?.productId?'AND u.product_id=$4 AND ($5::text IS NULL OR u.unit_code>$5)':''}
    ORDER BY ${scope?.productId?'u.unit_code':'p.sku,u.unit_code'} LIMIT ${scope?.productId?101:100}`,
    [t,b,"%"+q+"%",...(scope?.productId?[scope.productId,scope.afterId??null]:[])]);
  return r.rows;
 }
 if(kind==="skus"){
  // Filter before the LIMIT, not on the client: large catalogs remain reachable.
  const {filters,values}=buildSkuTaxonomyFilters(scope);
  const params=[t,b,"%"+q+"%",...values];
  const skuFilter=skuId?'AND s.id=
  const r=await db.query(`SELECT s.id,s.product_id AS "productId",s.sku AS code,
   p.name AS "productName",s.unit_code AS "unitCode",
   s.conversion_to_base::text AS "toBase",s.is_base AS "isBase",s.active,s.revision::integer,
   (SELECT b.barcode FROM catalog_sku_barcode b
    WHERE b.installation_id=s.installation_id AND b.branch_id=s.branch_id
      AND b.sell_sku_id=s.id AND b.active
    ORDER BY b.is_primary DESC,b.barcode LIMIT 1) AS barcode
   FROM catalog_sell_sku s
   JOIN catalog_product p ON p.installation_id=s.installation_id
     AND p.branch_id=s.branch_id AND p.id=s.product_id
   WHERE s.installation_id=$1 AND s.branch_id=$2
    AND (s.sku ILIKE $3 OR p.name ILIKE $3 OR EXISTS (
     SELECT 1 FROM catalog_sku_barcode bc
     WHERE bc.installation_id=s.installation_id AND bc.branch_id=s.branch_id
      AND bc.sell_sku_id=s.id AND bc.active AND bc.barcode ILIKE $3))
    ${filters.length?'AND '+filters.join(' AND '):''}
    ${skuFilter}
   ORDER BY ${scope?.productId?'s.id':'s.sku,s.id'}
   LIMIT ${scope?.productId?'101':'100'}`,params);
  return r.rows;
 }
 if(kind==="barcodes"){
  // 0017 adds the row revision. Barcode listing must remain readable on 0016
  // during a maintenance/rolling backend rollout.
  const revision=(await hasR1A(db))?"c.revision::integer":"0::integer";
  const r=await db.query(`SELECT c.id,c.sell_sku_id AS "sellSkuId",s.sku,
     c.barcode,c.is_primary AS "isPrimary",c.active,${revision} AS revision,s.product_id AS "productId"
   FROM catalog_sku_barcode c JOIN catalog_sell_sku s ON
    s.installation_id=c.installation_id AND s.branch_id=c.branch_id
    AND s.id=c.sell_sku_id
   WHERE c.installation_id=$1 AND c.branch_id=$2
    AND ($3::uuid IS NULL OR c.sell_sku_id=$3::uuid)
    AND (c.barcode ILIKE $4 OR s.sku ILIKE $4)
   ${scope?.productId?'AND s.product_id=$5 AND ($6::uuid IS NULL OR c.id>$6)':''}
   ORDER BY ${scope?.productId?'c.id':'c.is_primary DESC,c.barcode'} LIMIT ${scope?.productId?101:100}`,
    [t,b,skuId??null,"%"+q+"%",...(scope?.productId?[scope.productId,scope.afterId??null]:[])]);
  return r.rows;
 }
 if(kind==="channels"){
  const r=await db.query(`SELECT id,code,name,active,revision::integer FROM catalog_sales_channel
   WHERE installation_id=$1 AND branch_id=$2 AND
     (code ILIKE $3 OR name ILIKE $3)
   ORDER BY code,id LIMIT 100`,[t,b,"%"+q+"%"]);
  return r.rows;
 }
 const r=await db.query(`SELECT r.id,r.price_list_id AS "priceListId",
    l.code AS "priceListCode",r.sell_sku_id AS "sellSkuId",s.sku,
    r.scope_kind AS "scopeKind",r.channel_id AS "channelId",ch.code AS "channelCode",
    r.customer_id AS "customerId",c.code AS "customerCode",
    r.customer_group AS "customerGroup",
    r.adjustment,r.amount::text,r.priority,r.stacking,
    r.stop_processing AS "stopProcessing",r.min_quantity::text AS "minQuantity",
    r.effective_from AS "effectiveFrom",r.effective_to AS "effectiveTo",
    x.retired_at AS "retiredAt"
   FROM catalog_sku_price_rule r
   JOIN catalog_price_list l ON l.installation_id=r.installation_id
      AND l.branch_id=r.branch_id AND l.id=r.price_list_id
   LEFT JOIN catalog_sales_channel ch ON ch.installation_id=r.installation_id
      AND ch.branch_id=r.branch_id AND ch.id=r.channel_id
   LEFT JOIN catalog_customer c ON c.installation_id=r.installation_id
      AND c.branch_id=r.branch_id AND c.id=r.customer_id
   LEFT JOIN catalog_sku_price_retirement x ON
     x.installation_id=r.installation_id AND x.branch_id=r.branch_id
     AND x.rule_id=r.id
   JOIN catalog_sell_sku s
    ON s.installation_id=r.installation_id AND s.branch_id=r.branch_id
    AND s.id=r.sell_sku_id
   WHERE r.installation_id=$1 AND r.branch_id=$2
    AND (s.sku ILIKE $3 OR r.scope_kind ILIKE $3 OR l.code ILIKE $3
       OR c.code ILIKE $3 OR ch.code ILIKE $3 OR r.customer_group ILIKE $3)
   ORDER BY r.created_at DESC,r.id DESC LIMIT 100`,[t,b,"%"+q+"%"]);
 return r.rows;
}
export async function handleR1Http(req:IncomingMessage,res:ServerResponse,
 requestId:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin&&origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fail(res,403,"ORIGIN_DENIED",requestId);return;}
 if(req.method==="OPTIONS"){
  if(!cors){fail(res,403,"ORIGIN_DENIED",requestId);return;}
  send(res,204,null,requestId,cors);return;
 }
 const t=opts.installationId,pool=opts.pool;
 if(!pool||!t||!UUID.test(t)||!opts.allowedOrigin){
  fail(res,503,"NOT_CONFIGURED",requestId,cors);return;
 }
 try{
  if(!await ready()||!await schema(pool)){
   fail(res,503,"R1_MIGRATION_REQUIRED",requestId,cors);return;
  }
  const raw=req.headers.authorization;
  const token=typeof raw==="string"?/^Bearer ([A-Za-z0-9_-]{43})$/.exec(raw)?.[1]:null;
  const conn=await pool.connect();let actorId:string|undefined;
  try{actorId=token?(await resolveSession(conn,t,token))?.actorId:undefined;}
  finally{conn.release();}
  if(!actorId){fail(res,401,"AUTH_REQUIRED",requestId,cors);return;}
  if(url.pathname==="/v1/catalog/r1/resolve"&&req.method==="POST"){
   const raw=await body(req);
   keys(raw,["branchId","sellSkuId","priceListId","quantity","customerId","channelId","priceAt"]);
   const branchId=id(raw.branchId),sellSkuId=id(raw.sellSkuId),
    priceListId=optionalId(raw.priceListId),quantity=decimal(raw.quantity,QTY);
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:t,actorId,branchId,permission:"catalog.read"}))
     throw new R1Error(403,"DENIED");
    const quote=await resolveR1Price(db,{
      installationId:t,branchId,sellSkuId,priceListId,quantity,
      customerId:optionalId(raw.customerId),channelId:optionalId(raw.channelId),
      priceAt:raw.priceAt==null?new Date().toISOString():iso(raw.priceAt),
    });
    send(res,200,{quote:{...quote,priceSignature:r1QuoteSignature(quote)},requestId},requestId,cors);
   }finally{db.release();}
   return;
  }
  const retirePath=/^\/v1\/catalog\/r1\/rules\/([0-9a-f-]{36})\/retire$/i.exec(url.pathname);
  if(retirePath&&req.method==="POST"){
   const ruleId=id(retirePath[1]),raw=await body(req);
   keys(raw,["branchId","reason"]);
   const branchId=id(raw.branchId),reason=label(raw.reason,500);
   if(reason.length<3)throw new R1Error(400,"REASON_REQUIRED");
   const ctx=mutation(req,{installationId:t,actorId,requestId,
     action:"r1.catalog.rules.retire",payload:{branchId,ruleId,reason}});
   const result=await executeMutation(pool,ctx,{
     authorize:(db,c)=>hasPermission(db,{installationId:c.installationId,
       actorId:c.actorId,permission:"catalog.write",branchId}),
     execute:(db,c)=>retireRule(db,c.installationId,c.actorId,branchId,ruleId,reason),
   });
   send(res,result.status,result.body,requestId,cors);
   return;
  }
  const patchPath=/^\/v1\/catalog\/r1\/(skus|barcodes|channels)\/([0-9a-f-]{36})$/i.exec(url.pathname);
  if(patchPath&&req.method==="PATCH"){
    const targetKind=patchPath[1] as "skus"|"barcodes"|"channels";
    if(targetKind==="barcodes"&&!await hasR1A(pool))
      throw new R1Error(503,"R1A_MIGRATION_REQUIRED");
    const targetId=id(patchPath[2]),raw=await body(req);
    const branchId=id(raw.branchId);
    if(targetKind==="skus")keys(raw,["branchId","active","reason"]);
    if(targetKind==="barcodes")keys(raw,["branchId","active","isPrimary"]);
    if(targetKind==="channels")keys(raw,["branchId","name","active"]);
    const activeFlag=raw.active===undefined?undefined:bool(raw.active);
    const primaryFlag=raw.isPrimary===undefined?undefined:bool(raw.isPrimary);
    const name=raw.name===undefined?undefined:label(raw.name);
    const reason=raw.reason===undefined?undefined:label(raw.reason,500);
    if(targetKind==="skus"&&activeFlag===false&&(!reason||reason.length<3))
      throw new R1Error(400,"SKU_DISABLE_REASON_REQUIRED");
    if(activeFlag===undefined&&primaryFlag===undefined&&name===undefined)
      throw new R1Error(400,"EMPTY_UPDATE");
    const ctx=patchMutation(req,{installationId:t,actorId,requestId,
      action:"r1.catalog."+targetKind+".update",
      payload:{branchId,targetId,targetKind,
        ...(activeFlag!==undefined?{active:activeFlag}:{}),
        ...(primaryFlag!==undefined?{isPrimary:primaryFlag}:{}),
        ...(name!==undefined?{name}:{}),
        ...(reason!==undefined?{reason}:{})}});
    const outcome=await executeMutation(pool,ctx,{
      authorize:(db,c)=>hasPermission(db,{installationId:c.installationId,
        actorId:c.actorId,branchId,permission:"catalog.write"}),
      execute:async(db,c)=>{
        const table=targetKind==="skus"?"catalog_sell_sku":
          targetKind==="barcodes"?"catalog_sku_barcode":"catalog_sales_channel";
        if(targetKind==="skus"){
          // Lock the parent before variant locks so concurrent deactivations
          // cannot leave an enabled product with zero sellable variants.
          await db.query(`SELECT id FROM catalog_product WHERE installation_id=$1
            AND branch_id=$2 AND id=(SELECT product_id FROM catalog_sell_sku
              WHERE installation_id=$1 AND branch_id=$2 AND id=$3) FOR UPDATE`,
            [t,branchId,targetId]);
        }
        const current=await db.query<{revision:string;active:boolean;
           isBase?:boolean;productId?:string;sellSkuId?:string;isPrimary?:boolean}>(
          `SELECT revision::text,active${targetKind==="skus"?
            ',is_base AS "isBase",product_id AS "productId"':targetKind==="barcodes"?
            ',sell_sku_id AS "sellSkuId",is_primary AS "isPrimary"':''}
           FROM ${table} WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE`,
          [t,branchId,targetId]);
        if(!current.rows[0])throw new R1Error(404,"NOT_FOUND");
        requireRevision(c.expectedRevision,Number(current.rows[0].revision));
        if(targetKind==="skus"){
          if(activeFlag===true){
            const product=await db.query<{active:boolean}>(`SELECT active FROM catalog_product
              WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
              [t,branchId,current.rows[0].productId]);
            if(product.rows[0]?.active!==true)
              throw new R1Error(409,"PRODUCT_DISABLED_ENABLE_FIRST");
          }
          await db.query(`UPDATE catalog_sell_sku
            SET active=$4,revision=revision+1
            WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
            [t,branchId,targetId,activeFlag]);
          if(activeFlag===false){
            const other=await db.query(`SELECT 1 FROM catalog_sell_sku
              WHERE installation_id=$1 AND branch_id=$2 AND product_id=$3
                AND active LIMIT 1`,
              [t,branchId,current.rows[0].productId]);
            if(other.rowCount===0)
              await db.query(`UPDATE catalog_product
                SET active=false,revision=revision+1
                WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active`,
                [t,branchId,current.rows[0].productId]);
          }
        }else if(targetKind==="channels"){
          await db.query(`UPDATE catalog_sales_channel
            SET name=COALESCE($4,name),active=COALESCE($5,active),
              revision=revision+1
            WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
            [t,branchId,targetId,name??null,activeFlag??null]);
        }else{
          const newActive=activeFlag??current.rows[0].active;
          const newPrimary=newActive?(primaryFlag??current.rows[0].isPrimary??false):false;
          if(newPrimary){
            // One primary per SKU, change prior choice atomically with the same
            // audited command. Concurrent writers cannot bypass unique index.
            await db.query(`UPDATE catalog_sku_barcode
              SET is_primary=false,revision=revision+1
              WHERE installation_id=$1 AND branch_id=$2 AND sell_sku_id=$3
                AND id<>$4 AND is_primary AND active`,
                [t,branchId,current.rows[0].sellSkuId,targetId]);
          }
          await db.query(`UPDATE catalog_sku_barcode
            SET active=$4,is_primary=$5,revision=revision+1
            WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
            [t,branchId,targetId,newActive,newPrimary]);
        }
        const saved=await db.query<{revision:string}>(`SELECT revision::text FROM ${table}
          WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
          [t,branchId,targetId]);
        // Receipt stores the corrective reason (in addition to fingerprint),
        // so the SKU lifecycle decision remains reviewable after ACK/replay.
        return {status:200,body:{id:targetId,revision:Number(saved.rows[0]!.revision),
          ...(targetKind==="skus"&&activeFlag===false?{reason}:{}),
        }};
      },
    });
    send(res,outcome.status,outcome.body,requestId,cors);return;
  }
  const type=kind(url.pathname.slice("/v1/catalog/r1/".length));
  if(req.method==="GET"){
   const branchId=id(url.searchParams.get("branchId")),q=(url.searchParams.get("q")??"").trim();
   if(q.length>80)throw new R1Error(400,"SEARCH_TOO_LONG");
   const skuId=optionalId(url.searchParams.get("sellSkuId"));
   const brandId=optionalId(url.searchParams.get("brandId"));
   const groupId=optionalId(url.searchParams.get("groupId"));
   const categoryId=optionalId(url.searchParams.get("categoryId"));
   const productId=optionalId(url.searchParams.get("productId"));
   const rawAfter=url.searchParams.get("after");
   const scoped=productId!=null&&["units","skus","barcodes"].includes(type);
   if(rawAfter!==null&&!scoped)throw new R1Error(400,"INVALID_PAGINATION");
   if(productId&&!scoped)throw new R1Error(400,"INVALID_PRODUCT_SCOPE");
   const afterId=rawAfter===null?undefined:type==="units"?label(rawAfter,24):id(rawAfter);
   if((brandId||categoryId)&&type==="skus"){
     const schema=await pool.query<{ready:boolean}>(
       "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0020_catalog_hierarchy_locations.sql') AS ready");
     if(schema.rows[0]?.ready!==true)throw new R1Error(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
   }
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:t,actorId,branchId,permission:"catalog.read"}))
     throw new R1Error(403,"DENIED");
    const items=await listing(db,t,branchId,type,q,skuId,
      (type==="skus"||scoped)?{brandId:brandId??undefined,groupId:groupId??undefined,
        categoryId:categoryId??undefined,productId:productId??undefined,
        afterId:afterId??undefined}:undefined);
    // Product-scoped keyset pagination precedes the LIMIT: never use a
    // global 100-SKU page as the selectable units for a single product.
    send(res,200,{items:scoped?items.slice(0,100):items,
      ...(scoped&&items.length>100?{nextAfter:type==="units"?items[99].unitCode:items[99].id}:{}),requestId},requestId,cors);
   }finally{db.release();}
   return;
  }
  if(req.method==="POST"){
   const parsed=parse(type,await body(req));
   // Fingerprint only JSON fields actually provided; undefined is not JSON
   // and must not break idempotent writes for optional pricing scopes.
   const fingerprintPayload=Object.fromEntries(Object.entries(parsed)
     .filter(([,value])=>value!==undefined));
   const ctx=mutation(req,{installationId:t,actorId,requestId,
    action:"r1.catalog."+type+".create",payload:{type,...fingerprintPayload}});
   const result=await executeMutation(pool,ctx,{
    authorize:(db,c)=>hasPermission(db,{installationId:c.installationId,
      actorId:c.actorId,permission:"catalog.write",branchId:parsed.branchId}),
    execute:(db,c)=>create(db,c.installationId,type,parsed),
   });
   send(res,result.status,result.body,requestId,cors);
   return;
  }
  fail(res,405,"METHOD_NOT_ALLOWED",requestId,cors);
 }catch(err){
  if(err instanceof R1Error||err instanceof R1QuoteError){
   fail(res,err.status,err.code,requestId,cors);return;
  }
  if(err instanceof MutationFault){
   fail(res,err.httpStatus,err.code,requestId,cors);return;
  }
  if(typeof err==="object"&&err!==null&&"code" in err){
   if(err.code==="23505"){fail(res,409,"DUPLICATE",requestId,cors);return;}
   if(err.code==="23503"||err.code==="23514"){
    fail(res,400,"INVALID_REFERENCE",requestId,cors);return;
   }
   if(err.code==="P0001"){fail(res,409,"IMMUTABLE_OR_UNIT_MISMATCH",requestId,cors);return;}
  }
  fail(res,503,"R1_UNAVAILABLE",requestId,cors);
 }
}
+(params.length+1):'';
  if(skuId)params.push(skuId);
  const r=await db.query(`SELECT s.id,s.product_id AS "productId",s.sku AS code,
   p.name AS "productName",s.unit_code AS "unitCode",
   s.conversion_to_base::text AS "toBase",s.is_base AS "isBase",s.active,s.revision::integer,
   (SELECT b.barcode FROM catalog_sku_barcode b
    WHERE b.installation_id=s.installation_id AND b.branch_id=s.branch_id
      AND b.sell_sku_id=s.id AND b.active
    ORDER BY b.is_primary DESC,b.barcode LIMIT 1) AS barcode
   FROM catalog_sell_sku s
   JOIN catalog_product p ON p.installation_id=s.installation_id
     AND p.branch_id=s.branch_id AND p.id=s.product_id
   WHERE s.installation_id=$1 AND s.branch_id=$2
    AND (s.sku ILIKE $3 OR p.name ILIKE $3 OR EXISTS (
     SELECT 1 FROM catalog_sku_barcode bc
     WHERE bc.installation_id=s.installation_id AND bc.branch_id=s.branch_id
      AND bc.sell_sku_id=s.id AND bc.active AND bc.barcode ILIKE $3))
    ${filters.length?'AND '+filters.join(' AND '):''}
   ORDER BY ${scope?.productId?'s.id':'s.sku,s.id'}
   LIMIT ${scope?.productId?'101':'100'}`,params);
  return r.rows;
 }
 if(kind==="barcodes"){
  // 0017 adds the row revision. Barcode listing must remain readable on 0016
  // during a maintenance/rolling backend rollout.
  const revision=(await hasR1A(db))?"c.revision::integer":"0::integer";
  const r=await db.query(`SELECT c.id,c.sell_sku_id AS "sellSkuId",s.sku,
     c.barcode,c.is_primary AS "isPrimary",c.active,${revision} AS revision,s.product_id AS "productId"
   FROM catalog_sku_barcode c JOIN catalog_sell_sku s ON
    s.installation_id=c.installation_id AND s.branch_id=c.branch_id
    AND s.id=c.sell_sku_id
   WHERE c.installation_id=$1 AND c.branch_id=$2
    AND ($3::uuid IS NULL OR c.sell_sku_id=$3::uuid)
    AND (c.barcode ILIKE $4 OR s.sku ILIKE $4)
   ${scope?.productId?'AND s.product_id=$5 AND ($6::uuid IS NULL OR c.id>$6)':''}
   ORDER BY ${scope?.productId?'c.id':'c.is_primary DESC,c.barcode'} LIMIT ${scope?.productId?101:100}`,
    [t,b,skuId??null,"%"+q+"%",...(scope?.productId?[scope.productId,scope.afterId??null]:[])]);
  return r.rows;
 }
 if(kind==="channels"){
  const r=await db.query(`SELECT id,code,name,active,revision::integer FROM catalog_sales_channel
   WHERE installation_id=$1 AND branch_id=$2 AND
     (code ILIKE $3 OR name ILIKE $3)
   ORDER BY code,id LIMIT 100`,[t,b,"%"+q+"%"]);
  return r.rows;
 }
 const r=await db.query(`SELECT r.id,r.price_list_id AS "priceListId",
    l.code AS "priceListCode",r.sell_sku_id AS "sellSkuId",s.sku,
    r.scope_kind AS "scopeKind",r.channel_id AS "channelId",ch.code AS "channelCode",
    r.customer_id AS "customerId",c.code AS "customerCode",
    r.customer_group AS "customerGroup",
    r.adjustment,r.amount::text,r.priority,r.stacking,
    r.stop_processing AS "stopProcessing",r.min_quantity::text AS "minQuantity",
    r.effective_from AS "effectiveFrom",r.effective_to AS "effectiveTo",
    x.retired_at AS "retiredAt"
   FROM catalog_sku_price_rule r
   JOIN catalog_price_list l ON l.installation_id=r.installation_id
      AND l.branch_id=r.branch_id AND l.id=r.price_list_id
   LEFT JOIN catalog_sales_channel ch ON ch.installation_id=r.installation_id
      AND ch.branch_id=r.branch_id AND ch.id=r.channel_id
   LEFT JOIN catalog_customer c ON c.installation_id=r.installation_id
      AND c.branch_id=r.branch_id AND c.id=r.customer_id
   LEFT JOIN catalog_sku_price_retirement x ON
     x.installation_id=r.installation_id AND x.branch_id=r.branch_id
     AND x.rule_id=r.id
   JOIN catalog_sell_sku s
    ON s.installation_id=r.installation_id AND s.branch_id=r.branch_id
    AND s.id=r.sell_sku_id
   WHERE r.installation_id=$1 AND r.branch_id=$2
    AND (s.sku ILIKE $3 OR r.scope_kind ILIKE $3 OR l.code ILIKE $3
       OR c.code ILIKE $3 OR ch.code ILIKE $3 OR r.customer_group ILIKE $3)
   ORDER BY r.created_at DESC,r.id DESC LIMIT 100`,[t,b,"%"+q+"%"]);
 return r.rows;
}
export async function handleR1Http(req:IncomingMessage,res:ServerResponse,
 requestId:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
 const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
 const cors=origin&&origin===opts.allowedOrigin?origin:undefined;
 if(origin&&!cors){fail(res,403,"ORIGIN_DENIED",requestId);return;}
 if(req.method==="OPTIONS"){
  if(!cors){fail(res,403,"ORIGIN_DENIED",requestId);return;}
  send(res,204,null,requestId,cors);return;
 }
 const t=opts.installationId,pool=opts.pool;
 if(!pool||!t||!UUID.test(t)||!opts.allowedOrigin){
  fail(res,503,"NOT_CONFIGURED",requestId,cors);return;
 }
 try{
  if(!await ready()||!await schema(pool)){
   fail(res,503,"R1_MIGRATION_REQUIRED",requestId,cors);return;
  }
  const raw=req.headers.authorization;
  const token=typeof raw==="string"?/^Bearer ([A-Za-z0-9_-]{43})$/.exec(raw)?.[1]:null;
  const conn=await pool.connect();let actorId:string|undefined;
  try{actorId=token?(await resolveSession(conn,t,token))?.actorId:undefined;}
  finally{conn.release();}
  if(!actorId){fail(res,401,"AUTH_REQUIRED",requestId,cors);return;}
  if(url.pathname==="/v1/catalog/r1/resolve"&&req.method==="POST"){
   const raw=await body(req);
   keys(raw,["branchId","sellSkuId","priceListId","quantity","customerId","channelId","priceAt"]);
   const branchId=id(raw.branchId),sellSkuId=id(raw.sellSkuId),
    priceListId=optionalId(raw.priceListId),quantity=decimal(raw.quantity,QTY);
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:t,actorId,branchId,permission:"catalog.read"}))
     throw new R1Error(403,"DENIED");
    const quote=await resolveR1Price(db,{
      installationId:t,branchId,sellSkuId,priceListId,quantity,
      customerId:optionalId(raw.customerId),channelId:optionalId(raw.channelId),
      priceAt:raw.priceAt==null?new Date().toISOString():iso(raw.priceAt),
    });
    send(res,200,{quote:{...quote,priceSignature:r1QuoteSignature(quote)},requestId},requestId,cors);
   }finally{db.release();}
   return;
  }
  const retirePath=/^\/v1\/catalog\/r1\/rules\/([0-9a-f-]{36})\/retire$/i.exec(url.pathname);
  if(retirePath&&req.method==="POST"){
   const ruleId=id(retirePath[1]),raw=await body(req);
   keys(raw,["branchId","reason"]);
   const branchId=id(raw.branchId),reason=label(raw.reason,500);
   if(reason.length<3)throw new R1Error(400,"REASON_REQUIRED");
   const ctx=mutation(req,{installationId:t,actorId,requestId,
     action:"r1.catalog.rules.retire",payload:{branchId,ruleId,reason}});
   const result=await executeMutation(pool,ctx,{
     authorize:(db,c)=>hasPermission(db,{installationId:c.installationId,
       actorId:c.actorId,permission:"catalog.write",branchId}),
     execute:(db,c)=>retireRule(db,c.installationId,c.actorId,branchId,ruleId,reason),
   });
   send(res,result.status,result.body,requestId,cors);
   return;
  }
  const patchPath=/^\/v1\/catalog\/r1\/(skus|barcodes|channels)\/([0-9a-f-]{36})$/i.exec(url.pathname);
  if(patchPath&&req.method==="PATCH"){
    const targetKind=patchPath[1] as "skus"|"barcodes"|"channels";
    if(targetKind==="barcodes"&&!await hasR1A(pool))
      throw new R1Error(503,"R1A_MIGRATION_REQUIRED");
    const targetId=id(patchPath[2]),raw=await body(req);
    const branchId=id(raw.branchId);
    if(targetKind==="skus")keys(raw,["branchId","active","reason"]);
    if(targetKind==="barcodes")keys(raw,["branchId","active","isPrimary"]);
    if(targetKind==="channels")keys(raw,["branchId","name","active"]);
    const activeFlag=raw.active===undefined?undefined:bool(raw.active);
    const primaryFlag=raw.isPrimary===undefined?undefined:bool(raw.isPrimary);
    const name=raw.name===undefined?undefined:label(raw.name);
    const reason=raw.reason===undefined?undefined:label(raw.reason,500);
    if(targetKind==="skus"&&activeFlag===false&&(!reason||reason.length<3))
      throw new R1Error(400,"SKU_DISABLE_REASON_REQUIRED");
    if(activeFlag===undefined&&primaryFlag===undefined&&name===undefined)
      throw new R1Error(400,"EMPTY_UPDATE");
    const ctx=patchMutation(req,{installationId:t,actorId,requestId,
      action:"r1.catalog."+targetKind+".update",
      payload:{branchId,targetId,targetKind,
        ...(activeFlag!==undefined?{active:activeFlag}:{}),
        ...(primaryFlag!==undefined?{isPrimary:primaryFlag}:{}),
        ...(name!==undefined?{name}:{}),
        ...(reason!==undefined?{reason}:{})}});
    const outcome=await executeMutation(pool,ctx,{
      authorize:(db,c)=>hasPermission(db,{installationId:c.installationId,
        actorId:c.actorId,branchId,permission:"catalog.write"}),
      execute:async(db,c)=>{
        const table=targetKind==="skus"?"catalog_sell_sku":
          targetKind==="barcodes"?"catalog_sku_barcode":"catalog_sales_channel";
        if(targetKind==="skus"){
          // Lock the parent before variant locks so concurrent deactivations
          // cannot leave an enabled product with zero sellable variants.
          await db.query(`SELECT id FROM catalog_product WHERE installation_id=$1
            AND branch_id=$2 AND id=(SELECT product_id FROM catalog_sell_sku
              WHERE installation_id=$1 AND branch_id=$2 AND id=$3) FOR UPDATE`,
            [t,branchId,targetId]);
        }
        const current=await db.query<{revision:string;active:boolean;
           isBase?:boolean;productId?:string;sellSkuId?:string;isPrimary?:boolean}>(
          `SELECT revision::text,active${targetKind==="skus"?
            ',is_base AS "isBase",product_id AS "productId"':targetKind==="barcodes"?
            ',sell_sku_id AS "sellSkuId",is_primary AS "isPrimary"':''}
           FROM ${table} WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE`,
          [t,branchId,targetId]);
        if(!current.rows[0])throw new R1Error(404,"NOT_FOUND");
        requireRevision(c.expectedRevision,Number(current.rows[0].revision));
        if(targetKind==="skus"){
          if(activeFlag===true){
            const product=await db.query<{active:boolean}>(`SELECT active FROM catalog_product
              WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
              [t,branchId,current.rows[0].productId]);
            if(product.rows[0]?.active!==true)
              throw new R1Error(409,"PRODUCT_DISABLED_ENABLE_FIRST");
          }
          await db.query(`UPDATE catalog_sell_sku
            SET active=$4,revision=revision+1
            WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
            [t,branchId,targetId,activeFlag]);
          if(activeFlag===false){
            const other=await db.query(`SELECT 1 FROM catalog_sell_sku
              WHERE installation_id=$1 AND branch_id=$2 AND product_id=$3
                AND active LIMIT 1`,
              [t,branchId,current.rows[0].productId]);
            if(other.rowCount===0)
              await db.query(`UPDATE catalog_product
                SET active=false,revision=revision+1
                WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active`,
                [t,branchId,current.rows[0].productId]);
          }
        }else if(targetKind==="channels"){
          await db.query(`UPDATE catalog_sales_channel
            SET name=COALESCE($4,name),active=COALESCE($5,active),
              revision=revision+1
            WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
            [t,branchId,targetId,name??null,activeFlag??null]);
        }else{
          const newActive=activeFlag??current.rows[0].active;
          const newPrimary=newActive?(primaryFlag??current.rows[0].isPrimary??false):false;
          if(newPrimary){
            // One primary per SKU, change prior choice atomically with the same
            // audited command. Concurrent writers cannot bypass unique index.
            await db.query(`UPDATE catalog_sku_barcode
              SET is_primary=false,revision=revision+1
              WHERE installation_id=$1 AND branch_id=$2 AND sell_sku_id=$3
                AND id<>$4 AND is_primary AND active`,
                [t,branchId,current.rows[0].sellSkuId,targetId]);
          }
          await db.query(`UPDATE catalog_sku_barcode
            SET active=$4,is_primary=$5,revision=revision+1
            WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
            [t,branchId,targetId,newActive,newPrimary]);
        }
        const saved=await db.query<{revision:string}>(`SELECT revision::text FROM ${table}
          WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
          [t,branchId,targetId]);
        // Receipt stores the corrective reason (in addition to fingerprint),
        // so the SKU lifecycle decision remains reviewable after ACK/replay.
        return {status:200,body:{id:targetId,revision:Number(saved.rows[0]!.revision),
          ...(targetKind==="skus"&&activeFlag===false?{reason}:{}),
        }};
      },
    });
    send(res,outcome.status,outcome.body,requestId,cors);return;
  }
  const type=kind(url.pathname.slice("/v1/catalog/r1/".length));
  if(req.method==="GET"){
   const branchId=id(url.searchParams.get("branchId")),q=(url.searchParams.get("q")??"").trim();
   if(q.length>80)throw new R1Error(400,"SEARCH_TOO_LONG");
   const skuId=optionalId(url.searchParams.get("sellSkuId"));
   const brandId=optionalId(url.searchParams.get("brandId"));
   const groupId=optionalId(url.searchParams.get("groupId"));
   const categoryId=optionalId(url.searchParams.get("categoryId"));
   const productId=optionalId(url.searchParams.get("productId"));
   const rawAfter=url.searchParams.get("after");
   const scoped=productId!=null&&["units","skus","barcodes"].includes(type);
   if(rawAfter!==null&&!scoped)throw new R1Error(400,"INVALID_PAGINATION");
   if(productId&&!scoped)throw new R1Error(400,"INVALID_PRODUCT_SCOPE");
   const afterId=rawAfter===null?undefined:type==="units"?label(rawAfter,24):id(rawAfter);
   if((brandId||categoryId)&&type==="skus"){
     const schema=await pool.query<{ready:boolean}>(
       "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0020_catalog_hierarchy_locations.sql') AS ready");
     if(schema.rows[0]?.ready!==true)throw new R1Error(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
   }
   const db=await pool.connect();
   try{
    if(!await hasPermission(db,{installationId:t,actorId,branchId,permission:"catalog.read"}))
     throw new R1Error(403,"DENIED");
    const items=await listing(db,t,branchId,type,q,skuId,
      (type==="skus"||scoped)?{brandId:brandId??undefined,groupId:groupId??undefined,
        categoryId:categoryId??undefined,productId:productId??undefined,
        afterId:afterId??undefined}:undefined);
    // Product-scoped keyset pagination precedes the LIMIT: never use a
    // global 100-SKU page as the selectable units for a single product.
    send(res,200,{items:scoped?items.slice(0,100):items,
      ...(scoped&&items.length>100?{nextAfter:type==="units"?items[99].unitCode:items[99].id}:{}),requestId},requestId,cors);
   }finally{db.release();}
   return;
  }
  if(req.method==="POST"){
   const parsed=parse(type,await body(req));
   // Fingerprint only JSON fields actually provided; undefined is not JSON
   // and must not break idempotent writes for optional pricing scopes.
   const fingerprintPayload=Object.fromEntries(Object.entries(parsed)
     .filter(([,value])=>value!==undefined));
   const ctx=mutation(req,{installationId:t,actorId,requestId,
    action:"r1.catalog."+type+".create",payload:{type,...fingerprintPayload}});
   const result=await executeMutation(pool,ctx,{
    authorize:(db,c)=>hasPermission(db,{installationId:c.installationId,
      actorId:c.actorId,permission:"catalog.write",branchId:parsed.branchId}),
    execute:(db,c)=>create(db,c.installationId,type,parsed),
   });
   send(res,result.status,result.body,requestId,cors);
   return;
  }
  fail(res,405,"METHOD_NOT_ALLOWED",requestId,cors);
 }catch(err){
  if(err instanceof R1Error||err instanceof R1QuoteError){
   fail(res,err.status,err.code,requestId,cors);return;
  }
  if(err instanceof MutationFault){
   fail(res,err.httpStatus,err.code,requestId,cors);return;
  }
  if(typeof err==="object"&&err!==null&&"code" in err){
   if(err.code==="23505"){fail(res,409,"DUPLICATE",requestId,cors);return;}
   if(err.code==="23503"||err.code==="23514"){
    fail(res,400,"INVALID_REFERENCE",requestId,cors);return;
   }
   if(err.code==="P0001"){fail(res,409,"IMMUTABLE_OR_UNIT_MISMATCH",requestId,cors);return;}
  }
  fail(res,503,"R1_UNAVAILABLE",requestId,cors);
 }
}
