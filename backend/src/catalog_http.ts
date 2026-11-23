import type { IncomingMessage, ServerResponse } from "node:http";
import type { Pool, PoolClient } from "pg";
import { resolveSession } from "./auth.ts";
import { userAccess } from "./identity_admin.ts";
import { hasPermission } from "./rbac.ts";
import { executeMutation, MutationFault, requireRevision, type MutationContext } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";
import type { IdentityOptions } from "./identity_http.ts";
import { clonePriceList } from "./r1c_price_list.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CODE = /^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$/;
const AMOUNT = /^(?:0|[1-9][0-9]{0,13})(?:\.[0-9]{1,4})?$/;
const DISCOUNT = /^(?:100(?:\.0{1,2})?|(?:[0-9]|[1-9][0-9])(?:\.[0-9]{1,2})?)$/;
const FACTOR = /^(?:0\.[0-9]{0,5}[1-9]|[1-9][0-9]{0,11}(?:\.[0-9]{1,6})?)$/;
const BARCODE = /^[A-Za-z0-9._-]{4,64}$/;

class CatalogError extends Error {
  readonly status:number;
  readonly code:string;
  constructor(status:number,code:string){super(code);this.status=status;this.code=code;}
}
function isOriginValid(value:string|undefined):boolean {
  if(!value)return false;
  try {const u=new URL(value);return u.origin===value && (u.protocol==="https:" ||
    u.hostname==="localhost" && u.protocol==="http:");}
  catch{return false;}
}
function send(res:ServerResponse,status:number,body:unknown,id:string,origin?:string){
  const headers:Record<string,string>={
    "content-type":"application/json; charset=utf-8",
    "cache-control":"no-store",
    "x-request-id":id,
    "x-content-type-options":"nosniff",
    "referrer-policy":"no-referrer",
    "vary":"Origin",
  };
  if(origin){
    headers["access-control-allow-origin"]=origin;
    headers["access-control-allow-headers"]="content-type,authorization,idempotency-key,if-match,x-request-id";
    headers["access-control-allow-methods"]="GET, POST, PATCH, OPTIONS";
    headers["access-control-max-age"]="300";
  }
  res.writeHead(status,headers);res.end(status===204?"":JSON.stringify(body));
}
function fail(res:ServerResponse,status:number,code:string,id:string,origin?:string){
  const message=status===401?"Phiên đăng nhập không hợp lệ":
    status===403?"Không có quyền trên chi nhánh/kho":
    status===409?"Mã đã tồn tại hoặc dữ liệu đã thay đổi":
    status===503?"Danh mục đang tạm gián đoạn. Vui lòng thử lại.":
    status===404?"Không tìm thấy dữ liệu":"Dữ liệu yêu cầu không hợp lệ";
  send(res,status,{error:{code,message,requestId:id}},id,origin);
}
function tokenFrom(req:IncomingMessage):string|null{
  const h=req.headers.authorization;
  if(typeof h!=="string")return null;
  return /^Bearer ([A-Za-z0-9_-]{43})$/.exec(h)?.[1]??null;
}
async function payloadFrom(req:IncomingMessage):Promise<Record<string,unknown>>{
  if(req.headers["content-type"]?.split(";")[0]?.trim().toLowerCase()!=="application/json")
    throw new CatalogError(415,"INVALID_CONTENT_TYPE");
  if(Number(req.headers["content-length"]||0)>8192)throw new CatalogError(413,"BODY_TOO_LARGE");
  const buffers:Buffer[]=[];let bytes=0;
  for await(const chunk of req){
    const buffer=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk as Uint8Array);
    bytes+=buffer.length;if(bytes>8192)throw new CatalogError(413,"BODY_TOO_LARGE");
    buffers.push(buffer);
  }
  let value:unknown;
  try{value=JSON.parse(Buffer.concat(buffers).toString("utf8")) as unknown;}
  catch{throw new CatalogError(400,"INVALID_JSON");}
  if(!value||typeof value!=="object"||Array.isArray(value))
    throw new CatalogError(400,"INVALID_PAYLOAD");
  return value as Record<string,unknown>;
}
function requireUuid(value:unknown):string{
  if(typeof value!=="string"||!UUID.test(value))throw new CatalogError(400,"INVALID_UUID");
  return value;
}
function requireUnitCode(value:unknown):string{
  if(typeof value!=="string"||!/^[A-Za-z0-9][A-Za-z0-9._-]{0,23}$/.test(value))
    throw new CatalogError(400,"INVALID_UNIT_CODE");
  return value.toUpperCase();
}
function requireCode(value:unknown):string{
  if(typeof value!=="string"||!CODE.test(value))throw new CatalogError(400,"INVALID_CODE");
  return value;
}
function optionalBarcode(value:unknown):string|null{
  if(value==null||value==="")return null;
  if(typeof value!=="string"||!BARCODE.test(value))
    throw new CatalogError(400,"INVALID_BARCODE");
  return value;
}
function requirePhone(value:unknown):string{
  if(typeof value!=="string"||!/^\+?[0-9]{9,15}$/.test(value))
    throw new CatalogError(400,"INVALID_PHONE");
  return value;
}
function requireName(value:unknown,limit=160):string{
  if(typeof value!=="string"||value.trim().length<1||value.trim().length>limit)
    throw new CatalogError(400,"INVALID_NAME");
  return value.trim();
}
function requireAmount(value:unknown,pattern:RegExp):string{
  if(typeof value!=="string"||!pattern.test(value))
    throw new CatalogError(400,"INVALID_DECIMAL_STRING");
  return value;
}
function requireIso(value:unknown):string{
  if(typeof value!=="string"||!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$/.test(value) ||
    !Number.isFinite(Date.parse(value))) throw new CatalogError(400,"INVALID_EFFECTIVE_AT");
  return new Date(value).toISOString();
}
function r1cDate(value:unknown):string|null{
  return value===null?null:requireIso(value);
}
function r1cPriority(value:unknown):number{
  if(typeof value!=="number"||!Number.isSafeInteger(value)||
    value< -100000||value>100000)throw new CatalogError(400,"INVALID_PRICE_PRIORITY");
  return value;
}
function r1cRange(start:string|null,end:string|null):void{
  if(start!==null&&end!==null&&Date.parse(end)<=Date.parse(start))
    throw new CatalogError(400,"INVALID_PRICE_LIST_PERIOD");
}
function requestMutation(req:IncomingMessage,id:string,actorId:string,tenant:string,
  action:string,payload:Record<string,unknown>,versioned=false):MutationContext{
  const key=req.headers["idempotency-key"];
  const rev=req.headers["if-match"];
  const parsed=typeof rev==="string"&&/^(0|[1-9][0-9]{0,14})$/.test(rev)
    ? Number(rev) : NaN;
  if(typeof key!=="string"||!validIdempotencyKey(key) ||
      !Number.isSafeInteger(parsed)||(!versioned&&parsed!==0))
    throw new CatalogError(400,"INVALID_MUTATION_HEADERS");
  return {installationId:tenant,actorId,requestId:id,action,
    idempotencyKey:key,expectedRevision:parsed,payload};
}
type Resource="customers"|"customer-groups"|"customer-regions"|"suppliers"|"groups"|"products"|"price-lists"|"prices"|"warehouses"|"unit-definitions";
const resources=new Set<Resource>(["customers","customer-groups","customer-regions","suppliers","groups","products","price-lists","prices","warehouses","unit-definitions"]);
function resourceOf(value:string):Resource{
  if(!resources.has(value as Resource))throw new CatalogError(404,"UNKNOWN_RESOURCE");
  return value as Resource;
}
const selections:Record<Resource,string>={
  "customers":`SELECT id,code,name,customer_group AS "customerGroup",
    customer_group_id AS "customerGroupId",customer_region_id AS "customerRegionId",
    (SELECT g.code FROM catalog_customer_group g WHERE
      g.installation_id=catalog_customer.installation_id AND
      g.branch_id=catalog_customer.branch_id AND g.id=catalog_customer.customer_group_id)
      AS "customerGroupCode",
    (SELECT g.name FROM catalog_customer_group g WHERE
      g.installation_id=catalog_customer.installation_id AND
      g.branch_id=catalog_customer.branch_id AND g.id=catalog_customer.customer_group_id)
      AS "customerGroupName",
    (SELECT r.code FROM catalog_customer_region r WHERE
      r.installation_id=catalog_customer.installation_id AND
      r.branch_id=catalog_customer.branch_id AND r.id=catalog_customer.customer_region_id)
      AS "customerRegionCode",
    (SELECT r.name FROM catalog_customer_region r WHERE
      r.installation_id=catalog_customer.installation_id AND
      r.branch_id=catalog_customer.branch_id AND r.id=catalog_customer.customer_region_id)
      AS "customerRegionName",
    phone,delivery_address AS "deliveryAddress",
    payment_terms_days AS "paymentTermsDays",active,revision::integer FROM catalog_customer`,
  "customer-groups":'SELECT id,code,name,active,revision::integer FROM catalog_customer_group',
  "customer-regions":'SELECT id,code,name,active,revision::integer FROM catalog_customer_region',
  "suppliers":'SELECT id,code,name,active,revision::integer FROM catalog_supplier',
  "groups":'SELECT id,code,name,active,revision::integer FROM catalog_product_group',
  "unit-definitions":'SELECT id,code,name,active,revision::integer FROM catalog_unit_definition',
  "products":`SELECT id,sku AS code,name,base_unit AS "baseUnit",group_id AS "groupId",
    (SELECT g.name FROM catalog_product_group g WHERE
      g.installation_id=catalog_product.installation_id AND
      g.branch_id=catalog_product.branch_id AND g.id=catalog_product.group_id)
      AS "groupName",
    (SELECT count(*)::integer FROM catalog_sell_sku s WHERE
      s.installation_id=catalog_product.installation_id AND
      s.branch_id=catalog_product.branch_id AND s.product_id=catalog_product.id
      AND s.active) AS "sellSkuCount",
    (SELECT b.barcode FROM catalog_sku_barcode b
      JOIN catalog_sell_sku s ON s.installation_id=b.installation_id
        AND s.branch_id=b.branch_id AND s.id=b.sell_sku_id
      WHERE s.installation_id=catalog_product.installation_id
        AND s.branch_id=catalog_product.branch_id
        AND s.product_id=catalog_product.id AND s.is_base
        AND b.active ORDER BY b.is_primary DESC,b.barcode LIMIT 1) AS barcode,
    active,revision::integer FROM catalog_product`,
  "price-lists":'SELECT id,code,name,currency,active,revision::integer FROM catalog_price_list',
  "prices":'SELECT id,price_list_id AS "priceListId",product_id AS "productId",amount::text,discount_rate::text AS "discountRate",effective_at AS "effectiveAt" FROM catalog_price_entry',
  "warehouses":'SELECT id,code,name,branch_id AS "branchId" FROM warehouse',
};
const tableFor:Record<Exclude<Resource,"warehouses"|"prices">,string>={
  "customers":"catalog_customer",
  "customer-groups":"catalog_customer_group",
  "customer-regions":"catalog_customer_region",
  "suppliers":"catalog_supplier",
  "groups":"catalog_product_group",
  "unit-definitions":"catalog_unit_definition",
  "products":"catalog_product",
  "price-lists":"catalog_price_list",
};
async function hasR1CatalogSchema(db:Pool|PoolClient):Promise<boolean>{
  try{
    const result=await db.query<{ok:boolean}>(
      "SELECT EXISTS(SELECT 1 FROM public.schema_migrations WHERE version='0009_r1_catalog_pricing.sql') AS ok");
    return result.rows[0]?.ok===true;
  }catch{return false;}
}
async function hasPriceRetirementSchema(db:Pool|PoolClient):Promise<boolean>{
  try{
    const result=await db.query<{ok:boolean}>(
      "SELECT EXISTS(SELECT 1 FROM public.schema_migrations WHERE version='0010_r1_sales_price_snapshot.sql') AS ok");
    return result.rows[0]?.ok===true;
  }catch{return false;}
}
async function hasUnitDictionary(db:Pool|PoolClient):Promise<boolean>{
  try{
    const result=await db.query<{ok:boolean}>(
      "SELECT EXISTS(SELECT 1 FROM public.schema_migrations WHERE version='0015_r1_unit_dictionary.sql') AS ok");
    return result.rows[0]?.ok===true;
  }catch{return false;}
}
async function hasR1CPriceSchema(db:Pool|PoolClient):Promise<boolean>{
  try{
    const r=await db.query<{ready:boolean}>(`SELECT EXISTS(
      SELECT 1 FROM public.schema_migrations
      WHERE version='0018_r1c_price_list_assignment.sql') AS ready`);
    return r.rows[0]?.ready===true;
  }catch{return false;}
}
async function hasCustomerDirectories(db:Pool|PoolClient):Promise<boolean>{
  try{
    const r=await db.query<{ok:boolean}>(
      "SELECT EXISTS(SELECT 1 FROM public.schema_migrations WHERE version='0017_r1a_customer_directories.sql') AS ok");
    return r.rows[0]?.ok===true;
  }catch{return false;}
}
// IDs, never free-text labels, are the client contract for shared directories.
// All lookups are tenant+branch scoped and deny disabled selections.
async function activeDirectoryCode(db:PoolClient,table:"catalog_customer_group"|"catalog_customer_region"|"catalog_product_group",
  installationId:string,branchId:string,ref:string|null):Promise<string|null>{
  if(ref===null)return null;
  const r=await db.query<{code:string;active:boolean}>(
    `SELECT code,active FROM ${table} WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR SHARE`,
    [installationId,branchId,ref]);
  if(r.rows[0]?.active!==true)throw new CatalogError(400,"INVALID_OR_INACTIVE_DIRECTORY");
  return r.rows[0]!.code;
}
async function hasCatalogSchema(db:Pool):Promise<boolean>{
  try {
    const r=await db.query<{present:boolean}>(
      "SELECT (SELECT count(*)::integer FROM public.schema_migrations WHERE version IN ('0006_catalog.sql','0007_catalog_controls.sql'))=2 AS present");
    return r.rows[0]?.present===true;
  }catch{return false;}
}
async function listing(db:PoolClient,tenant:string,actorId:string,branchId:string,
  resource:Resource,search:string,afterCode=""):Promise<unknown[]>{
  if(resource==="warehouses"){
    const grants=await userAccess(db,tenant,actorId);
    const ids=grants.filter(g=>g.branchId===branchId&&g.permission==="inventory.read"&&g.warehouseId)
      .map(g=>g.warehouseId!);
    if(ids.length===0)throw new CatalogError(403,"WAREHOUSE_SCOPE_REQUIRED");
    const w=await db.query(`${selections.warehouses}
       WHERE installation_id=$1 AND branch_id=$2 AND id=ANY($3::uuid[])
         AND (code ILIKE $4 OR name ILIKE $4) ORDER BY code,id LIMIT 100`,
      [tenant,branchId,ids,"%"+search+"%"]);
    return w.rows;
  }
  if(!await hasPermission(db,{installationId:tenant,actorId,permission:"catalog.read",branchId}))
    throw new CatalogError(403,"CATALOG_READ_DENIED");
  if((resource==="customer-groups"||resource==="customer-regions")&&
     !await hasCustomerDirectories(db))
    throw new CatalogError(503,"CUSTOMER_DICTIONARY_MIGRATION_REQUIRED");
  if(resource==="unit-definitions"&&!await hasUnitDictionary(db))
    throw new CatalogError(503,"UNIT_DICTIONARY_MIGRATION_REQUIRED");
  if(resource==="unit-definitions"||resource==="customer-groups"||
     resource==="customer-regions"){
    // Keyset cursor ensures every UOM remains reachable, not just the first
    // 100 codes. Code is unique within installation+branch.
    const rows=await db.query(`${selections[resource]}
      WHERE installation_id=$1 AND branch_id=$2
        AND (code ILIKE $3 OR name ILIKE $3) AND code>$4
      ORDER BY code,id LIMIT 100`,
      [tenant,branchId,"%"+search+"%",afterCode]);
    return rows.rows;
  }
  const values=[tenant,branchId,"%"+search+"%"];
  // Installations staged on catalog 0006/0007 must still list products
  // even before the separate R1 SKU/barcode migration 0009 is applied.
  const r1Ready=resource==="products"&&await hasR1CatalogSchema(db);
  const productSelection=r1Ready?selections.products:
    `SELECT id,sku AS code,name,base_unit AS "baseUnit",
      group_id AS "groupId",
      (SELECT g.name FROM catalog_product_group g WHERE
        g.installation_id=catalog_product.installation_id AND
        g.branch_id=catalog_product.branch_id AND g.id=catalog_product.group_id)
      AS "groupName",0::integer AS "sellSkuCount",NULL::text AS barcode,
      active,revision::integer FROM catalog_product`;
  const customerReady=resource==="customers"&&await hasCustomerDirectories(db);
  const customerSelection=customerReady?selections.customers:
    'SELECT id,code,name,customer_group AS "customerGroup",NULL::uuid AS "customerGroupId",'+
    'NULL::uuid AS "customerRegionId",NULL::text AS "customerGroupCode",'+
    'customer_group AS "customerGroupName",NULL::text AS "customerRegionCode",'+
    'NULL::text AS "customerRegionName",phone,delivery_address AS "deliveryAddress",'+
    'payment_terms_days AS "paymentTermsDays",active,revision::integer FROM catalog_customer';
  const listSelection=resource==="price-lists"&&await hasR1CPriceSchema(db)
    ?'SELECT id,code,name,currency,active,revision::integer,priority,'
      +'effective_from AS "effectiveFrom",effective_to AS "effectiveTo" FROM catalog_price_list'
    :'SELECT id,code,name,currency,active,revision::integer,0::integer AS priority,'
      +'NULL::timestamptz AS "effectiveFrom",NULL::timestamptz AS "effectiveTo" '
      +'FROM catalog_price_list';
  const r=await db.query(
    resource==="prices"
      ?`SELECT e.id,e.price_list_id AS "priceListId",l.code AS "priceListCode",
          e.product_id AS "productId",p.sku AS "productCode",p.name AS "productName",
          e.amount::text,e.discount_rate::text AS "discountRate",
          e.effective_at AS "effectiveAt"
          FROM catalog_price_entry e
          JOIN catalog_product p ON p.installation_id=e.installation_id
            AND p.branch_id=e.branch_id AND p.id=e.product_id
          JOIN catalog_price_list l ON l.installation_id=e.installation_id
            AND l.branch_id=e.branch_id AND l.id=e.price_list_id
          WHERE e.installation_id=$1 AND e.branch_id=$2
            AND (p.sku ILIKE $3 OR p.name ILIKE $3 OR l.code ILIKE $3)
          ORDER BY e.effective_at DESC,e.id DESC LIMIT 100`
      :`${resource==="products"?productSelection:resource==="customers"?customerSelection:resource==="price-lists"?listSelection:selections[resource]} WHERE installation_id=$1 AND branch_id=$2
          AND (${resource==="products"?"sku":"code"} ILIKE $3 OR name ILIKE $3
          ${resource==="customers"?"OR phone ILIKE $3 OR customer_group ILIKE $3":""})
          ORDER BY ${resource==="products"?"sku":"code"},id LIMIT 100`,
    values);
  return r.rows;
}

export function checkCreate(resource:Resource,raw:Record<string,unknown>){
  if(resource==="warehouses")throw new CatalogError(405,"READ_ONLY_WAREHOUSE");
  const branchId=requireUuid(raw.branchId);
  if(resource==="prices"){
    const priceListId=requireUuid(raw.priceListId);
    const productId=requireUuid(raw.productId);
    const amount=requireAmount(raw.amount,AMOUNT);
    const discountRate=requireAmount(raw.discountRate??"0",DISCOUNT);
    const effectiveAt=requireIso(raw.effectiveAt);
    return {branchId,priceListId,productId,amount,discountRate,effectiveAt};
  }
  const code=resource==="unit-definitions"?requireUnitCode(raw.code):requireCode(raw.code);
  const name=requireName(raw.name,resource==="unit-definitions"?80:160);
  if(resource==="price-lists"){
    if(Object.keys(raw).some(k=>!["branchId","code","name","effectiveFrom",
      "effectiveTo","priority"].includes(k)))
      throw new CatalogError(400,"UNKNOWN_FIELD");
    const hasWindow=["effectiveFrom","effectiveTo","priority"]
      .some(k=>Object.prototype.hasOwnProperty.call(raw,k));
    if(hasWindow){
      const effectiveFrom=raw.effectiveFrom==null?null:r1cDate(raw.effectiveFrom);
      const effectiveTo=raw.effectiveTo==null?null:r1cDate(raw.effectiveTo);
      const priority=r1cPriority(raw.priority??0);
      r1cRange(effectiveFrom,effectiveTo);
      return {branchId,code,name,effectiveFrom,effectiveTo,priority};
    }
    return {branchId,code,name};
  }
  if(resource==="unit-definitions"){
    if(Object.keys(raw).some(k=>!["branchId","code","name"].includes(k)))
      throw new CatalogError(400,"UNKNOWN_FIELD");
    return {branchId,code,name};
  }
  if(resource==="products"){
    if(Object.keys(raw).some(x=>!["branchId","code","name","baseUnit","groupId","barcode","units"].includes(x)))
      throw new CatalogError(400,"UNKNOWN_FIELD");
    const baseUnit=requireName(raw.baseUnit,24);
    const barcode=optionalBarcode(raw.barcode);
    const groupId=raw.groupId==null?null:requireUuid(raw.groupId);
    const units=raw.units??[];
    if(!Array.isArray(units)||units.length>12)throw new CatalogError(400,"INVALID_UNITS");
    const names=new Set<string>([baseUnit.toUpperCase()]);
    const skuCodes=new Set<string>([code.toUpperCase()]);
    const barcodes=new Set<string>(barcode?[barcode.toUpperCase()]:[]);
    const conversions:{unitCode:string;toBase:string;sku:string|null;barcode:string|null}[]=[];
    for(const entry of units){
      if(!entry||typeof entry!=="object"||Array.isArray(entry))
        throw new CatalogError(400,"INVALID_UNITS");
      const obj=entry as Record<string,unknown>;
      const unitCode=requireName(obj.unitCode,24);
      const toBase=requireAmount(obj.toBase,FACTOR);
      const sku=obj.sku==null||obj.sku===""?null:requireCode(obj.sku);
      const unitBarcode=optionalBarcode(obj.barcode);
      if(unitBarcode&&!sku)throw new CatalogError(400,"BARCODE_REQUIRES_SKU");
      if(names.has(unitCode.toUpperCase()))throw new CatalogError(400,"DUPLICATE_UNIT");
      if(sku&&skuCodes.has(sku.toUpperCase()))throw new CatalogError(400,"DUPLICATE_SKU");
      if(unitBarcode&&barcodes.has(unitBarcode.toUpperCase()))
        throw new CatalogError(400,"DUPLICATE_BARCODE");
      names.add(unitCode.toUpperCase());
      if(sku)skuCodes.add(sku.toUpperCase());
      if(unitBarcode)barcodes.add(unitBarcode.toUpperCase());
      conversions.push({unitCode,toBase,sku,barcode:unitBarcode});
    }
    return {branchId,code,name,baseUnit,groupId,barcode,units:conversions};
  }
  if(resource==="customers"){
    if(Object.keys(raw).some(k=>!["branchId","code","name","customerGroupId","customerRegionId","phone","deliveryAddress","paymentTermsDays"].includes(k)))
      throw new CatalogError(400,"UNKNOWN_FIELD");
    const customerGroupId=raw.customerGroupId==null?null:requireUuid(raw.customerGroupId);
    const customerRegionId=raw.customerRegionId==null?null:requireUuid(raw.customerRegionId);
    const phone=raw.phone==null?null:requirePhone(raw.phone);
    const deliveryAddress=raw.deliveryAddress==null?null:requireName(raw.deliveryAddress,500);
    const paymentTermsDays=raw.paymentTermsDays??0;
    if(typeof paymentTermsDays!=="number"||!Number.isInteger(paymentTermsDays)||
      paymentTermsDays<0||paymentTermsDays>365)
      throw new CatalogError(400,"INVALID_PAYMENT_TERMS");
    return {branchId,code,name,customerGroupId,customerRegionId,phone,deliveryAddress,paymentTermsDays};
  }
  return {branchId,code,name};
}
type CreateInput=ReturnType<typeof checkCreate>;
export async function executeCreate(db:PoolClient,context:MutationContext,
  resource:Exclude<Resource,"warehouses">,value:CreateInput){
  const {installationId,actorId}=context;
  const branchId=value.branchId;
  if(!await hasPermission(db,{installationId,actorId,permission:"catalog.write",branchId}))
    throw new MutationFault("FORBIDDEN",403);
  if(resource==="prices"){
    if(!("priceListId" in value))throw new CatalogError(400,"INVALID_PRICE");
    // Applies to BOTH single-price editing and bulk import: serialize same
    // effective-time insertions, without touching posted historical prices.
    // Lock the whole list+product stream, not only one timestamp:
    // an approved bulk preview must detect every concurrent price append.
    const scope=[installationId,branchId,value.priceListId,value.productId].join("|");
    await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))",[scope]);
    const duplicate=await db.query(
      "SELECT id FROM catalog_price_entry WHERE installation_id=$1 AND branch_id=$2 "+
      "AND price_list_id=$3 AND product_id=$4 AND effective_at=$5::timestamptz LIMIT 1",
      [installationId,branchId,value.priceListId,value.productId,value.effectiveAt]);
    if(duplicate.rowCount)throw new CatalogError(409,"EFFECTIVE_PRICE_EXISTS");
    const r=await db.query<{id:string;amount:string;discountRate:string;effectiveAt:Date}>(
      `INSERT INTO catalog_price_entry
       (installation_id,branch_id,price_list_id,product_id,amount,discount_rate,effective_at)
       VALUES ($1,$2,$3,$4,$5::numeric,$6::numeric,$7::timestamptz)
       RETURNING id,amount::text,discount_rate::text AS "discountRate",effective_at AS "effectiveAt"`,
      [installationId,branchId,value.priceListId,value.productId,
        value.amount,value.discountRate,value.effectiveAt]);
    const item=r.rows[0]!;
    return {status:201,body:{id:item.id,priceListId:value.priceListId,
      productId:value.productId,amount:item.amount,discountRate:item.discountRate,
      effectiveAt:item.effectiveAt.toISOString()}};
  }
  if(resource==="price-lists"&&"effectiveFrom" in value){
    if(!await hasR1CPriceSchema(db))
      throw new CatalogError(503,"R1C_PRICE_LIST_MIGRATION_REQUIRED");
    const r=await db.query<{id:string}>(`INSERT INTO catalog_price_list
      (installation_id,branch_id,code,name,effective_from,effective_to,priority)
      VALUES($1,$2,$3,$4,$5::timestamptz,$6::timestamptz,$7) RETURNING id`,
      [installationId,branchId,value.code,value.name,
        value.effectiveFrom,value.effectiveTo,value.priority]);
    return {status:201,body:{id:r.rows[0]!.id,code:value.code,
      name:value.name,revision:0,effectiveFrom:value.effectiveFrom,
      effectiveTo:value.effectiveTo,priority:value.priority}};
  }
  if(resource==="products"){
    if(!("baseUnit" in value))throw new CatalogError(400,"INVALID_PRODUCT");
    // Preserve older catalog clients while maintaining the new shared
    // dictionary. New codes imported from an item default to code==name;
    // operators can rename the label separately. All writes are atomic.
    if(await hasUnitDictionary(db)){
      for(const uom of [value.baseUnit,...(value.units??[]).map(x=>x.unitCode)]){
        await db.query(`INSERT INTO catalog_unit_definition
          (installation_id,branch_id,code,name)
          VALUES ($1,$2,$3,$3) ON CONFLICT(installation_id,branch_id,code) DO NOTHING`,
          [installationId,branchId,uom]);
        const known=await db.query<{active:boolean}>(`SELECT active FROM catalog_unit_definition
          WHERE installation_id=$1 AND branch_id=$2 AND code=$3`,
          [installationId,branchId,uom]);
        if(known.rows[0]?.active!==true)
          throw new CatalogError(400,"UNIT_DISABLED");
      }
    }
    if(value.groupId!==null)
      await activeDirectoryCode(db,"catalog_product_group",installationId,branchId,value.groupId??null);
    const r=await db.query<{id:string}>(
      `INSERT INTO catalog_product(installation_id,branch_id,sku,name,group_id,base_unit)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [installationId,branchId,value.code,value.name,value.groupId,value.baseUnit]);
    const id=r.rows[0]!.id;
    await db.query(`INSERT INTO catalog_unit
      (installation_id,branch_id,product_id,unit_code,to_base) VALUES ($1,$2,$3,$4,1)`,
      [installationId,branchId,id,value.baseUnit]);
    for(const unit of value.units??[]){
      await db.query(`INSERT INTO catalog_unit
        (installation_id,branch_id,product_id,unit_code,to_base) VALUES ($1,$2,$3,$4,$5::numeric)`,
        [installationId,branchId,id,unit.unitCode,unit.toBase]);
    }
    // Product, units, sellable variants and their barcodes are one idempotent
    // transaction. No partially configured product after a failed insert.
    const baseSku=await db.query<{id:string}>(`INSERT INTO catalog_sell_sku
      (installation_id,branch_id,product_id,sku,unit_code,conversion_to_base,is_base)
      VALUES($1,$2,$3,$4,$5,1,true) RETURNING id`,
      [installationId,branchId,id,value.code,value.baseUnit]);
    const variants=[{id:baseSku.rows[0]!.id,sku:value.code,unitCode:value.baseUnit}];
    if(value.barcode){
      await db.query(`INSERT INTO catalog_sku_barcode
        (installation_id,branch_id,sell_sku_id,barcode,is_primary)
        VALUES ($1,$2,$3,$4,true)`,
        [installationId,branchId,baseSku.rows[0]!.id,value.barcode]);
    }
    for(const unit of value.units??[]){
      if(!unit.sku)continue;
      const inserted=await db.query<{id:string}>(`INSERT INTO catalog_sell_sku
        (installation_id,branch_id,product_id,sku,unit_code,conversion_to_base)
        VALUES ($1,$2,$3,$4,$5,$6::numeric) RETURNING id`,
        [installationId,branchId,id,unit.sku,unit.unitCode,unit.toBase]);
      const sellSkuId=inserted.rows[0]!.id;
      variants.push({id:sellSkuId,sku:unit.sku,unitCode:unit.unitCode});
      if(unit.barcode){
        await db.query(`INSERT INTO catalog_sku_barcode
          (installation_id,branch_id,sell_sku_id,barcode,is_primary)
          VALUES ($1,$2,$3,$4,true)`,
          [installationId,branchId,sellSkuId,unit.barcode]);
      }
    }
    return {status:201,body:{id,code:value.code,name:value.name,
      baseUnit:value.baseUnit,groupId:value.groupId,revision:0,variants}};
  }
  if(!("code" in value))throw new CatalogError(400,"INVALID_RESOURCE");
  const table=tableFor[resource];
  const withGroup=resource==="customers";
  let groupCode:string|null=null;
  if(withGroup){
    if(!("customerGroupId" in value))throw new CatalogError(400,"INVALID_CUSTOMER_REFERENCE");
    groupCode=await activeDirectoryCode(db,"catalog_customer_group",
      installationId,branchId,value.customerGroupId??null);
    await activeDirectoryCode(db,"catalog_customer_region",
      installationId,branchId,value.customerRegionId??null);
  }
  const r=await db.query<{id:string}>(
    withGroup
      ?`INSERT INTO ${table}
         (installation_id,branch_id,code,name,customer_group,customer_group_id,customer_region_id,
          phone,delivery_address,payment_terms_days)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id`
      :`INSERT INTO ${table}(installation_id,branch_id,code,name)
         VALUES ($1,$2,$3,$4) RETURNING id`,
    withGroup?[installationId,branchId,value.code,value.name,groupCode,
      "customerGroupId" in value?value.customerGroupId:null,
      "customerRegionId" in value?value.customerRegionId:null,
      "phone" in value?value.phone:null,"deliveryAddress" in value?value.deliveryAddress:null,
      "paymentTermsDays" in value?value.paymentTermsDays:0]:
      [installationId,branchId,value.code,value.name]);
  return {status:201,body:{id:r.rows[0]!.id,code:value.code,name:value.name,revision:0}};
}

type Editable = "customers"|"customer-groups"|"customer-regions"|"suppliers"|"groups"|"products"|"price-lists"|"unit-definitions";
const editable = new Set<Editable>(["customers","customer-groups","customer-regions","suppliers","groups","products","price-lists","unit-definitions"]);
const editTables:Record<Editable,string>={
  "customers":"catalog_customer","suppliers":"catalog_supplier",
  "customer-groups":"catalog_customer_group","customer-regions":"catalog_customer_region",
  "groups":"catalog_product_group","products":"catalog_product",
  "unit-definitions":"catalog_unit_definition",
  "price-lists":"catalog_price_list",
};
export function parseEdit(resource:Editable,raw:Record<string,unknown>){
  const branchId=requireUuid(raw.branchId);
  const columns:Record<string,unknown>={};
  const allow=new Set(["branchId","name","active",
    ...(resource==="customers"?["customerGroupId","customerRegionId","phone","deliveryAddress","paymentTermsDays"]:[]),
    ...(resource==="products"?["groupId"]:[]),
    ...(resource==="price-lists"?["effectiveFrom","effectiveTo","priority"]:[])]);
  if(Object.keys(raw).some(key=>!allow.has(key)))throw new CatalogError(400,"UNKNOWN_FIELD");
  if(Object.prototype.hasOwnProperty.call(raw,"name"))
    columns.name=requireName(raw.name,resource==="unit-definitions"?80:160);
  if(Object.prototype.hasOwnProperty.call(raw,"active")){
    if(typeof raw.active!=="boolean")throw new CatalogError(400,"INVALID_ACTIVE");
    columns.active=raw.active;
  }
  if(resource==="customers"&&Object.prototype.hasOwnProperty.call(raw,"customerGroupId"))
    columns.customer_group_id=raw.customerGroupId===null?null:requireUuid(raw.customerGroupId);
  if(resource==="customers"&&Object.prototype.hasOwnProperty.call(raw,"customerRegionId"))
    columns.customer_region_id=raw.customerRegionId===null?null:requireUuid(raw.customerRegionId);
  if(resource==="customers"&&Object.prototype.hasOwnProperty.call(raw,"phone")){
    columns.phone=raw.phone===null?null:requirePhone(raw.phone);
  }
  if(resource==="customers"&&Object.prototype.hasOwnProperty.call(raw,"deliveryAddress")){
    columns.delivery_address=raw.deliveryAddress===null?null:requireName(raw.deliveryAddress,500);
  }
  if(resource==="customers"&&Object.prototype.hasOwnProperty.call(raw,"paymentTermsDays")){
    if(typeof raw.paymentTermsDays!=="number"||!Number.isInteger(raw.paymentTermsDays)||
      raw.paymentTermsDays<0||raw.paymentTermsDays>365)
      throw new CatalogError(400,"INVALID_PAYMENT_TERMS");
    columns.payment_terms_days=raw.paymentTermsDays;
  }
  if(resource==="price-lists"){
    if(Object.prototype.hasOwnProperty.call(raw,"effectiveFrom"))
      columns.effective_from=r1cDate(raw.effectiveFrom);
    if(Object.prototype.hasOwnProperty.call(raw,"effectiveTo"))
      columns.effective_to=r1cDate(raw.effectiveTo);
    if(Object.prototype.hasOwnProperty.call(raw,"priority"))
      columns.priority=r1cPriority(raw.priority);
    if(columns.effective_from!==undefined&&columns.effective_to!==undefined)
      r1cRange(columns.effective_from as string|null,columns.effective_to as string|null);
  }
  if(resource==="products"&&Object.prototype.hasOwnProperty.call(raw,"groupId")){
    columns.group_id=raw.groupId===null?null:requireUuid(raw.groupId);
  }
  if(Object.keys(columns).length===0)throw new CatalogError(400,"EMPTY_UPDATE");
  return {branchId,columns};
}
export async function applyEdit(db:PoolClient,context:MutationContext,
  resource:Editable,targetId:string,value:ReturnType<typeof parseEdit>){
  const {installationId,actorId,expectedRevision}=context;
  if(!await hasPermission(db,{installationId,actorId,
    permission:"catalog.write",branchId:value.branchId}))
    throw new MutationFault("FORBIDDEN",403);
  if(resource==="price-lists"&&
    Object.keys(value.columns).some(x=>["effective_from","effective_to","priority"].includes(x))&&
    !await hasR1CPriceSchema(db))
    throw new CatalogError(503,"R1C_PRICE_LIST_MIGRATION_REQUIRED");
  const table=editTables[resource];
  const row=await db.query<{revision:string}>(
    `SELECT revision::text FROM ${table} WHERE installation_id=$1
      AND branch_id=$2 AND id=$3 FOR UPDATE`,
    [installationId,value.branchId,targetId]);
  if(row.rowCount===0)throw new CatalogError(404,"NOT_FOUND");
  requireRevision(expectedRevision,Number(row.rows[0]!.revision));
  if(resource==="customers"){
    if(Object.prototype.hasOwnProperty.call(value.columns,"customer_group_id"))
      value.columns.customer_group=await activeDirectoryCode(db,"catalog_customer_group",
        installationId,value.branchId,value.columns.customer_group_id as string|null);
    if(Object.prototype.hasOwnProperty.call(value.columns,"customer_region_id"))
      await activeDirectoryCode(db,"catalog_customer_region",
        installationId,value.branchId,value.columns.customer_region_id as string|null);
  }
  if(resource==="products"&&Object.prototype.hasOwnProperty.call(value.columns,"group_id"))
    await activeDirectoryCode(db,"catalog_product_group",
      installationId,value.branchId,value.columns.group_id as string|null);
  const columnEntries=Object.entries(value.columns);
  const sets=columnEntries.map(([key],i)=>key+"=$"+(i+4));
  const args=[installationId,value.branchId,targetId,...columnEntries.map(x=>x[1])];
  const saved=await db.query<{revision:string}>(
    `UPDATE ${table} SET ${sets.join(",")},revision=revision+1
      WHERE installation_id=$1 AND branch_id=$2 AND id=$3
      RETURNING revision::text`,args);
  return {status:200,body:{id:targetId,revision:Number(saved.rows[0]!.revision)}};
}
/** Read-model pricing is advisory only; inventory stock and order posting remain blocked. */
async function livePrice(db:PoolClient,installationId:string,branchId:string,
  priceListId:string,productId:string){
  const r=await db.query<{
    id:string;amount:string;discountRate:string;effectiveAt:Date;
    currency:string;productRevision:string;priceListRevision:string;
  }>(`SELECT e.id,e.amount::text,e.discount_rate::text AS "discountRate",
       e.effective_at AS "effectiveAt", l.currency,
       p.revision::text AS "productRevision",
       l.revision::text AS "priceListRevision"
    FROM catalog_price_entry e
    JOIN catalog_product p ON p.installation_id=e.installation_id
      AND p.branch_id=e.branch_id AND p.id=e.product_id AND p.active
    JOIN catalog_price_list l ON l.installation_id=e.installation_id
      AND l.branch_id=e.branch_id AND l.id=e.price_list_id AND l.active
    WHERE e.installation_id=$1 AND e.branch_id=$2 AND e.price_list_id=$3
      AND e.product_id=$4 AND e.effective_at <= now()
    ORDER BY e.effective_at DESC,e.id DESC LIMIT 1`,
    [installationId,branchId,priceListId,productId]);
  const q=r.rows[0];
  if(!q)return null;
  return {priceEntryId:q.id,productId,priceListId,amount:q.amount,
    discountRate:q.discountRate,currency:q.currency,
    effectiveAt:q.effectiveAt.toISOString(),
    productRevision:Number(q.productRevision),priceListRevision:Number(q.priceListRevision)};
}
async function pricingRead(db:PoolClient,installationId:string,actorId:string,
  branchId:string,priceListId:string,productId:string){
  if(!await hasPermission(db,{installationId,actorId,permission:"catalog.read",branchId}))
    throw new CatalogError(403,"CATALOG_READ_DENIED");
  return livePrice(db,installationId,branchId,priceListId,productId);
}

/** Issue #7 route: tenant + session + branch RBAC, migration-gated and audit-backed. */
export async function handleCatalogHttp(req:IncomingMessage,res:ServerResponse,
  requestId:string,url:URL,opts:IdentityOptions,ready:()=>Promise<boolean>):Promise<void>{
  const origin=typeof req.headers.origin==="string"?req.headers.origin:undefined;
  const corsOrigin=origin&&origin===opts.allowedOrigin?origin:undefined;
  if(origin&&!corsOrigin){fail(res,403,"ORIGIN_DENIED",requestId);return;}
  if(req.method==="OPTIONS"){
    if(!corsOrigin){fail(res,403,"ORIGIN_DENIED",requestId);return;}
    send(res,204,null,requestId,corsOrigin);return;
  }
  const tenant=opts.installationId,pool=opts.pool;
  if(!tenant||!UUID.test(tenant)||!pool||!isOriginValid(opts.allowedOrigin)){
    fail(res,503,"CATALOG_NOT_CONFIGURED",requestId,corsOrigin);return;
  }
  try {
    if(!await ready()||!await hasCatalogSchema(pool)){
      fail(res,503,"CATALOG_MIGRATION_REQUIRED",requestId,corsOrigin);return;
    }
    const bearer=tokenFrom(req);
    const db=await pool.connect();
    let actorId:string|undefined;
    try{
      const actor=bearer?await resolveSession(db,tenant,bearer):null;
      actorId=actor?.actorId;
    }finally{db.release();}
    if(!actorId){fail(res,401,"AUTH_DENIED",requestId,corsOrigin);return;}
    if(url.pathname==="/v1/catalog/branches"&&req.method==="GET"){
      const client=await pool.connect();
      try{
        const grants=await userAccess(client,tenant,actorId);
        const branchIds=[...new Set(grants.filter(g=>g.branchId!==null&&(
          g.permission==="catalog.read"||g.permission==="catalog.write"||
          g.permission==="inventory.read"||g.permission==="inventory.post"||
          g.permission==="orders.read"||g.permission==="orders.create"))
          .map(g=>g.branchId!))];
        const branches=branchIds.length===0?[]:(await client.query(
          'SELECT id,code,name FROM branch WHERE installation_id=$1 AND id=ANY($2::uuid[]) ORDER BY code LIMIT 100',
          [tenant,branchIds])).rows;
        send(res,200,{items:branches,requestId},requestId,corsOrigin);
      }finally{client.release();}
      return;
    }
    if(url.pathname==="/v1/catalog/prices/quote" && req.method==="GET"){
      const branchId=requireUuid(url.searchParams.get("branchId"));
      const priceListId=requireUuid(url.searchParams.get("priceListId"));
      const productId=requireUuid(url.searchParams.get("productId"));
      const db=await pool.connect();
      try {
        const quote=await pricingRead(db,tenant,actorId,branchId,priceListId,productId);
        send(res,200,{quote,stockStatus:"NOT_VERIFIED",confirmationAllowed:false,
          requestId},requestId,corsOrigin);
      }finally{db.release();}
      return;
    }
    if(url.pathname==="/v1/catalog/prices/check" && req.method==="POST"){
      const input=await payloadFrom(req);
      const branchId=requireUuid(input.branchId);
      const priceListId=requireUuid(input.priceListId);
      const productId=requireUuid(input.productId);
      const expectedPriceEntryId=requireUuid(input.expectedPriceEntryId);
      const db=await pool.connect();
      try {
        const quote=await pricingRead(db,tenant,actorId,branchId,priceListId,productId);
        if(!quote||quote.priceEntryId!==expectedPriceEntryId){
          fail(res,409,"PRICE_STALE",requestId,corsOrigin);return;
        }
        send(res,200,{current:true,quote,stockStatus:"NOT_VERIFIED",
          confirmationAllowed:false,requestId},requestId,corsOrigin);
      }finally{db.release();}
      return;
    }
    // A separate idempotent creation: source revision protects against
    // cloning an edited list without a deliberate user refresh.
    const clonePath=/^\/v1\/catalog\/price-lists\/([0-9a-f-]{36})\/clone$/i.exec(url.pathname);
    if(clonePath&&req.method==="POST"){
      if(!await hasR1CatalogSchema(pool)||
         !await hasPriceRetirementSchema(pool))
        throw new CatalogError(503,"R1_PRICE_SCHEMA_REQUIRED");
      const raw=await payloadFrom(req);
      if(Object.keys(raw).some(k=>!["branchId","code","name","sourceRevision"].includes(k)))
        throw new CatalogError(400,"UNKNOWN_FIELD");
      const branchId=requireUuid(raw.branchId),sourceId=requireUuid(clonePath[1]);
      const code=requireCode(raw.code),name=requireName(raw.name);
      const sourceRevision=raw.sourceRevision;
      if(typeof sourceRevision!=="number"||!Number.isSafeInteger(sourceRevision)||
         sourceRevision<0)throw new CatalogError(400,"INVALID_REVISION");
      const input={branchId,sourceId,sourceRevision,code,name};
      const context=requestMutation(req,requestId,actorId,tenant,
        "catalog.price_lists.clone",input);
      const outcome=await executeMutation(pool,context,{
        authorize:(db,ctx)=>hasPermission(db,{installationId:ctx.installationId,
          actorId:ctx.actorId,permission:"catalog.write",branchId}),
        execute:async(db,ctx)=>{
          const result=await clonePriceList(db,{...input,installationId:ctx.installationId});
          if(!result)throw new CatalogError(404,"PRICE_LIST_NOT_FOUND");
          return result;
        },
      });
      send(res,outcome.status,outcome.body,requestId,corsOrigin);return;
    }
    const updatePath=/^\/v1\/catalog\/(customers|customer-groups|customer-regions|suppliers|groups|products|price-lists|unit-definitions)\/([0-9a-f-]{36})$/.exec(url.pathname);
    if(updatePath&&req.method==="PATCH"){
      const resource=updatePath[1] as Editable;
      if(!editable.has(resource))throw new CatalogError(404,"UNKNOWN_RESOURCE");
      if((resource==="customers"||resource==="customer-groups"||
        resource==="customer-regions")&&!await hasCustomerDirectories(pool))
        throw new CatalogError(503,"CUSTOMER_DICTIONARY_MIGRATION_REQUIRED");
      const targetId=requireUuid(updatePath[2]);
      const input=parseEdit(resource,await payloadFrom(req));
      const payload={id:targetId,branchId:input.branchId,...input.columns};
      const context=requestMutation(req,requestId,actorId,tenant,
        "catalog."+resource.replaceAll("-","_")+".update",payload,true);
      const outcome=await executeMutation(pool,context,{
        authorize:(db,ctx)=>hasPermission(db,{installationId:ctx.installationId,
          actorId:ctx.actorId,permission:"catalog.write",branchId:input.branchId}),
        execute:(db,ctx)=>applyEdit(db,ctx,resource,targetId,input),
      });
      send(res,outcome.status,outcome.body,requestId,corsOrigin);return;
    }
    const resource=resourceOf(url.pathname.slice("/v1/catalog/".length));
    if((resource==="customer-groups"||resource==="customer-regions")&&
       !await hasCustomerDirectories(pool))
      throw new CatalogError(503,"CUSTOMER_DICTIONARY_MIGRATION_REQUIRED");
    if(resource==="unit-definitions"&&!await hasUnitDictionary(pool))
      throw new CatalogError(503,"UNIT_DICTIONARY_MIGRATION_REQUIRED");
    if(req.method==="GET"){
      const branchId=requireUuid(url.searchParams.get("branchId"));
      const search=(url.searchParams.get("q")??"").trim();
      if(search.length>64)throw new CatalogError(400,"SEARCH_TOO_LONG");
      const paged=resource==="unit-definitions"||resource==="customer-groups"||
        resource==="customer-regions";
      const afterCode=paged?(url.searchParams.get("after")??""):"";
      // Cursor comes from existing stored data, including legacy display
      // strings such as "Hộp 12". New-code validation must not reject it.
      if(afterCode&&([...afterCode].length>(resource==="unit-definitions"?24:64)||
        afterCode.trim().length===0||/[\u0000-\u001f\u007f]/.test(afterCode)))
        throw new CatalogError(400,"INVALID_UNIT_CURSOR");
      const client=await pool.connect();
      try{
        const rows=await listing(client,tenant,actorId,branchId,resource,search,afterCode);
        const nextAfter=paged&&rows.length===100
          ?(rows[rows.length-1] as {code:string}).code:null;
        send(res,200,{items:rows,
          ...(nextAfter?{nextAfter}:{}),
          ...(resource==="products"?{r1ProductReady:await hasR1CatalogSchema(client)}:{}),
          requestId},requestId,corsOrigin);
      }finally{client.release();}
      return;
    }
    if(req.method==="POST"){
      // R1 sale variants/barcodes do not exist on 0006/0007-only installations.
      // Reject BEFORE the mutation transaction, never expose a half-created
      // product or a generic retryable provider error.
      if((resource==="customers"||resource==="customer-groups"||
        resource==="customer-regions")&&!await hasCustomerDirectories(pool))
        throw new CatalogError(503,"CUSTOMER_DICTIONARY_MIGRATION_REQUIRED");
      if(resource==="products"&&!await hasR1CatalogSchema(pool))
        throw new CatalogError(503,"R1_PRODUCT_SCHEMA_REQUIRED");
      const input=checkCreate(resource,await payloadFrom(req));
      const context=requestMutation(req,requestId,actorId,tenant,
        "catalog."+resource.replaceAll("-","_")+".create",input);
      const response=await executeMutation(pool,context,{
        authorize:(db,ctx)=>hasPermission(db,{installationId:ctx.installationId,
          actorId:ctx.actorId,permission:"catalog.write",branchId:input.branchId}),
        execute:(db,ctx)=>executeCreate(db,ctx,resource as Exclude<Resource,"warehouses">,input),
      });
      send(res,response.status,response.body,requestId,corsOrigin);return;
    }
    fail(res,405,"METHOD_NOT_ALLOWED",requestId,corsOrigin);
  }catch(error){
    if(error instanceof CatalogError){fail(res,error.status,error.code,requestId,corsOrigin);return;}
    if(error instanceof MutationFault){fail(res,error.httpStatus,error.code,requestId,corsOrigin);return;}
    if(typeof error==="object"&&error!==null&&"code" in error){
      if(error.code==="23505"){fail(res,409,"DUPLICATE",requestId,corsOrigin);return;}
      if(error.code==="23503"){fail(res,400,"INVALID_REFERENCE",requestId,corsOrigin);return;}
      if(error.code==="23514"){fail(res,400,"INVALID_VALUE",requestId,corsOrigin);return;}
    }
    fail(res,503,"CATALOG_UNAVAILABLE",requestId,corsOrigin);
  }
}
