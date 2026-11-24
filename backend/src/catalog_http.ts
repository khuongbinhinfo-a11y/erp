import type { IncomingMessage, ServerResponse } from "node:http";
import type { Pool, PoolClient } from "pg";
import { resolveSession } from "./auth.ts";
import { userAccess } from "./identity_admin.ts";
import { hasPermission } from "./rbac.ts";
import { executeMutation, MutationFault, requireRevision, type MutationContext } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";
import type { IdentityOptions } from "./identity_http.ts";
import { clonePriceList } from "./r1c_price_list.ts";
import { CustomerLocationFault,parseCustomerLocation,listCustomerLocations,
  createCustomerLocation,updateCustomerLocation } from "./catalog_customer_locations.ts";
import { PriceAssignmentFault,parsePriceAssignment,createPriceAssignment,
  listPriceAssignments,togglePriceAssignment } from "./r1c_price_assignment.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CODE = /^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$/;
const AMOUNT = /^(?:0|[1-9][0-9]{0,13})(?:\.[0-9]{1,4})?$/;
const DISCOUNT = /^(?:100(?:\.0{1,2})?|(?:[0-9]|[1-9][0-9])(?:\.[0-9]{1,2})?)$/;
const FACTOR = /^(?:0\.[0-9]{0,5}[1-9]|[1-9][0-9]{0,11}(?:\.[0-9]{1,6})?)$/;
const BARCODE = /^[A-Za-z0-9._-]{4,64}$/;

export class CatalogError extends Error {
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
type Resource="customers"|"customer-groups"|"customer-regions"|"suppliers"|"brands"|"groups"|"categories"|"products"|"price-lists"|"prices"|"warehouses"|"unit-definitions";
const resources=new Set<Resource>(["customers","customer-groups","customer-regions","suppliers","brands","groups","categories","products","price-lists","prices","warehouses","unit-definitions"]);
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
  "brands":'SELECT id,code,name,active,revision::integer FROM catalog_brand',
  "groups":'SELECT id,code,name,active,revision::integer FROM catalog_product_group',
  "categories":`SELECT id,code,name,group_id AS "groupId",parent_id AS "parentId",
    (SELECT p.code FROM catalog_product_category p WHERE
      p.installation_id=catalog_product_category.installation_id AND
      p.branch_id=catalog_product_category.branch_id AND p.id=catalog_product_category.parent_id)
      AS "parentCode",active,revision::integer FROM catalog_product_category`,
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
  "brands":"catalog_brand",
  "groups":"catalog_product_group",
  "categories":"catalog_product_category",
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
async function hasP0PriceSchema(db:Pool|PoolClient):Promise<boolean>{
 try{
  const r=await db.query<{ready:boolean}>(`SELECT EXISTS(
    SELECT 1 FROM public.schema_migrations
    WHERE version='0019_p0_price_order_parity.sql') AS ready`);
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
async function hasCatalogHierarchySchema(db:Pool|PoolClient):Promise<boolean>{
  try{
    const r=await db.query<{ok:boolean}>(
      "SELECT EXISTS(SELECT 1 FROM public.schema_migrations WHERE version='0020_catalog_hierarchy_locations.sql') AS ok");
    return r.rows[0]?.ok===true;
  }catch{return false;}
}
async function activeCategory(db:PoolClient,installationId:string,branchId:string,
  categoryId:string|null,groupId:string|null):Promise<void>{
  if(categoryId===null)return;
  if(!groupId)throw new CatalogError(400,"CATEGORY_REQUIRES_GROUP");
  const found=await db.query<{active:boolean}>(`SELECT active
    FROM catalog_product_category WHERE installation_id=$1 AND branch_id=$2
    AND id=$3 AND group_id=$4 FOR SHARE`,[installationId,branchId,categoryId,groupId]);
  if(found.rows[0]?.active!==true)throw new CatalogError(400,"INVALID_OR_INACTIVE_CATEGORY");
}
async function hasCatalogSchema(db:Pool):Promise<boolean>{
  try {
    const r=await db.query<{present:boolean}>(
      "SELECT (SELECT count(*)::integer FROM public.schema_migrations WHERE version IN ('0006_catalog.sql','0007_catalog_controls.sql'))=2 AS present");
    return r.rows[0]?.present===true;
  }catch{return false;}
}
async function listing(db:PoolClient,tenant:string,actorId:string,branchId:string,
  resource:Resource,search:string,afterCode="",exactId?:string):Promise<unknown[]>{
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
  const taxonomyReady=await hasCatalogHierarchySchema(db);
  if((resource==="brands"||resource==="categories")&&!taxonomyReady)
    throw new CatalogError(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
  const values=[tenant,branchId,"%"+search+"%"];
  // Installations staged on catalog 0006/0007 must still list products
  // even before the separate R1 SKU/barcode migration 0009 is applied.
  const r1Ready=resource==="products"&&await hasR1CatalogSchema(db);
  const productSelection=r1Ready?(
    taxonomyReady?selections.products.replace(
      'group_id AS "groupId",',
      'group_id AS "groupId",category_id AS "categoryId",'+
      '(SELECT c.name FROM catalog_product_category c WHERE c.installation_id=catalog_product.installation_id AND c.branch_id=catalog_product.branch_id AND c.id=catalog_product.category_id) AS "categoryName",'
    ):selections.products
  ):
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
  const p0Fields=resource==="price-lists"&&await hasP0PriceSchema(db);
  const listSelection=resource==="price-lists"&&await hasR1CPriceSchema(db)
    ?'SELECT id,code,name,currency,active,revision::integer,priority,'
      +'effective_from AS "effectiveFrom",effective_to AS "effectiveTo",'
      +(p0Fields?'stacking_mode AS "stackingMode",stop_processing AS "stopProcessing" '
        :"\'EXCLUSIVE\'::text AS \"stackingMode\",false AS \"stopProcessing\" ")
      +'FROM catalog_price_list'
    :'SELECT id,code,name,currency,active,revision::integer,0::integer AS priority,'
      +'NULL::timestamptz AS "effectiveFrom",NULL::timestamptz AS "effectiveTo",'
      +"'EXCLUSIVE'::text AS \"stackingMode\",false AS \"stopProcessing\" "
      +'FROM catalog_price_list';
  const groupSelection=taxonomyReady?
    'SELECT g.id,g.code,g.name,g.brand_id AS "brandId",b.name AS "brandName",g.active,g.revision::integer FROM catalog_product_group g LEFT JOIN catalog_brand b ON b.installation_id=g.installation_id AND b.branch_id=g.branch_id AND b.id=g.brand_id':
    selections.groups;
  if(exactId&&["groups","brands","categories"].includes(resource)){
    const selection=resource==="groups"?groupSelection:selections[resource];
    const prefix=resource==="groups"&&taxonomyReady?"g.":"";
    const one=await db.query(`${selection} WHERE ${prefix}installation_id=$1
      AND ${prefix}branch_id=$2 AND ${prefix}id=$3 LIMIT 1`,
      [tenant,branchId,exactId]);
    return one.rows;
  }
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
      :`${resource==="products"?productSelection:resource==="customers"?customerSelection:resource==="price-lists"?listSelection:resource==="groups"?groupSelection:selections[resource]} WHERE ${resource==="groups"&&taxonomyReady?"g.installation_id":"installation_id"}=$1 AND ${resource==="groups"&&taxonomyReady?"g.branch_id":"branch_id"}=$2
          AND (${resource==="products"?"sku":resource==="groups"&&taxonomyReady?"g.code":"code"} ILIKE $3 OR ${resource==="groups"&&taxonomyReady?"g.name":"name"} ILIKE $3
          ${resource==="customers"?"OR phone ILIKE $3 OR customer_group ILIKE $3":""})
          ORDER BY ${resource==="products"?"sku":resource==="groups"&&taxonomyReady?"g.code":"code"},${resource==="groups"&&taxonomyReady?"g.id":"id"} LIMIT 100`,
    values);
  return r.rows;
}

function listStackingMode(v:unknown):"EXCLUSIVE"|"STACKABLE"{
 if(v===undefined)return "EXCLUSIVE";
 if(v!=="EXCLUSIVE"&&v!=="STACKABLE")throw new CatalogError(400,"INVALID_PRICE_STACKING");
 return v;
}
function listStopProcessing(v:unknown):boolean{
 if(v===undefined)return false;
 if(typeof v!=="boolean")throw new CatalogError(400,"INVALID_PRICE_STOP");
 return v;
}
type PriceListScopeTargets={
 channelIds:string[];customerGroupIds:string[];customerIds:string[];
 defaultAssignment:boolean;
};
const PRICE_SCOPE_KEYS=["channelIds","customerGroupIds","customerIds","defaultAssignment"] as const;
function priceScopes(raw:Record<string,unknown>):PriceListScopeTargets|null{
 if(!PRICE_SCOPE_KEYS.some(k=>Object.prototype.hasOwnProperty.call(raw,k)))return null;
 const ids=(key:string):string[]=>{
  const value=raw[key]??[];
  if(!Array.isArray(value)||value.length>100)throw new CatalogError(400,"INVALID_PRICE_SCOPE");
  const result=value.map(requireUuid);
  if(new Set(result).size!==result.length)throw new CatalogError(400,"DUPLICATE_PRICE_SCOPE");
  return result;
 };
 const defaultAssignment=raw.defaultAssignment??false;
 if(typeof defaultAssignment!=="boolean")throw new CatalogError(400,"INVALID_PRICE_SCOPE");
 return {channelIds:ids("channelIds"),customerGroupIds:ids("customerGroupIds"),
  customerIds:ids("customerIds"),defaultAssignment};
}
async function syncPriceScopes(db:PoolClient,installationId:string,
 branchId:string,priceListId:string,desired:PriceListScopeTargets){
 const selected=await db.query<{priority:number}>(`SELECT priority FROM catalog_price_list
  WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE`,
  [installationId,branchId,priceListId]);
 if(!selected.rows[0])throw new CatalogError(404,"PRICE_LIST_UNAVAILABLE");
 const assignmentPriority=selected.rows[0].priority;
 const wanted=new Set<string>();
 const targets:{scopeKind:"DEFAULT"|"CUSTOMER"|"CUSTOMER_GROUP"|"CHANNEL";
  customerId:string|null;customerGroupId:string|null;channelId:string|null;}[]=[];
 const add=(scopeKind:"DEFAULT"|"CUSTOMER"|"CUSTOMER_GROUP"|"CHANNEL",id:string|null)=>{
  wanted.add(scopeKind+":"+(id??""));
  targets.push({scopeKind,customerId:scopeKind==="CUSTOMER"?id:null,
    customerGroupId:scopeKind==="CUSTOMER_GROUP"?id:null,
    channelId:scopeKind==="CHANNEL"?id:null});
 };
 if(desired.defaultAssignment)add("DEFAULT",null);
 for(const id of desired.channelIds)add("CHANNEL",id);
 for(const id of desired.customerGroupIds)add("CUSTOMER_GROUP",id);
 for(const id of desired.customerIds)add("CUSTOMER",id);
 const prior=await db.query<{id:string;scope_kind:string;customer_id:string|null;
  customer_group_id:string|null;channel_id:string|null;}>(`SELECT id,scope_kind,customer_id,
    customer_group_id,channel_id FROM catalog_price_list_assignment
   WHERE installation_id=$1 AND branch_id=$2 AND price_list_id=$3
    AND active FOR UPDATE`,[installationId,branchId,priceListId]);
 const already=new Set<string>();
 for(const old of prior.rows){
  const key=old.scope_kind+":"+(old.customer_id??old.customer_group_id??old.channel_id??"");
  if(wanted.has(key)){already.add(key);continue;}
  await db.query(`UPDATE catalog_price_list_assignment
   SET active=false,revision=revision+1 WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
    [installationId,branchId,old.id]);
 }
 for(const target of targets){
  const key=target.scopeKind+":"+(target.customerId??target.customerGroupId??target.channelId??"");
  if(already.has(key))continue;
  await createPriceAssignment(db,installationId,{branchId,priceListId,
   ...target,priority:assignmentPriority,effectiveFrom:null,effectiveTo:null});
 }
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
      "effectiveTo","priority","stackingMode","stopProcessing",...PRICE_SCOPE_KEYS].includes(k)))
      throw new CatalogError(400,"UNKNOWN_FIELD");
    const scopes=priceScopes(raw);
    const hasWindow=["effectiveFrom","effectiveTo","priority","stackingMode","stopProcessing",...PRICE_SCOPE_KEYS]
      .some(k=>Object.prototype.hasOwnProperty.call(raw,k));
    if(hasWindow){
      const effectiveFrom=raw.effectiveFrom==null?null:r1cDate(raw.effectiveFrom);
      const effectiveTo=raw.effectiveTo==null?null:r1cDate(raw.effectiveTo);
      const priority=r1cPriority(raw.priority??0);
      r1cRange(effectiveFrom,effectiveTo);
      return {branchId,code,name,effectiveFrom,effectiveTo,priority,scopes,
        stackingMode:listStackingMode(raw.stackingMode),
        stopProcessing:listStopProcessing(raw.stopProcessing)};
    }
    return {branchId,code,name};
  }
  if(resource==="brands"){
    if(Object.keys(raw).some(k=>!["branchId","code","name"].includes(k)))
      throw new CatalogError(400,"UNKNOWN_FIELD");
    return {branchId,code,name};
  }
  if(resource==="groups"){
    if(Object.keys(raw).some(k=>!["branchId","code","name","brandId"].includes(k)))
      throw new CatalogError(400,"UNKNOWN_FIELD");
    const brandId=raw.brandId==null?null:requireUuid(raw.brandId);
    return {branchId,code,name,brandId};
  }
  if(resource==="categories"){
    if(Object.keys(raw).some(k=>!["branchId","code","name","groupId","parentId"].includes(k)))
      throw new CatalogError(400,"UNKNOWN_FIELD");
    return {branchId,code,name,groupId:requireUuid(raw.groupId),
      parentId:raw.parentId==null?null:requireUuid(raw.parentId)};
  }
  if(resource==="unit-definitions"){
    if(Object.keys(raw).some(k=>!["branchId","code","name"].includes(k)))
      throw new CatalogError(400,"UNKNOWN_FIELD");
    return {branchId,code,name};
  }
  if(resource==="products"){
    if(Object.keys(raw).some(x=>!["branchId","code","name","baseUnit","groupId","categoryId","barcode","units"].includes(x)))
      throw new CatalogError(400,"UNKNOWN_FIELD");
    const baseUnit=requireName(raw.baseUnit,24);
    const barcode=optionalBarcode(raw.barcode);
    const groupId=raw.groupId==null?null:requireUuid(raw.groupId);
    const categoryId=raw.categoryId==null?null:requireUuid(raw.categoryId);
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
    return {branchId,code,name,baseUnit,groupId,categoryId,barcode,units:conversions};
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
    const p0=await hasP0PriceSchema(db);
    if(!p0&&(value.stackingMode!=="EXCLUSIVE"||value.stopProcessing))
      throw new CatalogError(503,"P0_PRICE_SCHEMA_REQUIRED");
    const r=await db.query<{id:string}>(`INSERT INTO catalog_price_list
      (installation_id,branch_id,code,name,effective_from,effective_to,priority
       ${p0?",stacking_mode,stop_processing":""})
      VALUES($1,$2,$3,$4,$5::timestamptz,$6::timestamptz,$7
       ${p0?",$8,$9":""}) RETURNING id`,
      [installationId,branchId,value.code,value.name,
        value.effectiveFrom,value.effectiveTo,value.priority,
        ...(p0?[value.stackingMode,value.stopProcessing]:[])]);
    if(value.scopes)await syncPriceScopes(db,installationId,branchId,r.rows[0]!.id,value.scopes);
    return {status:201,body:{id:r.rows[0]!.id,code:value.code,
      name:value.name,revision:0,effectiveFrom:value.effectiveFrom,
      effectiveTo:value.effectiveTo,priority:value.priority,
      stackingMode:value.stackingMode,stopProcessing:value.stopProcessing}};
  }
  if(resource==="groups"){
    if(!("brandId" in value))throw new CatalogError(400,"INVALID_GROUP");
    const hierarchy=await hasCatalogHierarchySchema(db);
    if(value.brandId){
      if(!hierarchy)throw new CatalogError(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
      const brand=await db.query<{active:boolean}>(`SELECT active FROM catalog_brand
        WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR SHARE`,
        [installationId,branchId,value.brandId]);
      if(brand.rows[0]?.active!==true)throw new CatalogError(400,"BRAND_UNAVAILABLE");
    }
    const result=await db.query<{id:string}>(
      hierarchy?
        `INSERT INTO catalog_product_group(installation_id,branch_id,code,name,brand_id)
          VALUES($1,$2,$3,$4,$5) RETURNING id`:
        `INSERT INTO catalog_product_group(installation_id,branch_id,code,name)
          VALUES($1,$2,$3,$4) RETURNING id`,
      hierarchy?[installationId,branchId,value.code,value.name,value.brandId]:
        [installationId,branchId,value.code,value.name]);
    return {status:201,body:{id:result.rows[0]!.id,code:value.code,name:value.name,revision:0}};
  }
  if(resource==="categories"){
    if(!("parentId" in value&&"groupId" in value))throw new CatalogError(400,"INVALID_CATEGORY");
    if(!await hasCatalogHierarchySchema(db))
      throw new CatalogError(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
    const categoryGroupId=requireUuid(value.groupId);
    const categoryParentId=value.parentId==null?null:requireUuid(value.parentId);
    await activeDirectoryCode(db,"catalog_product_group",installationId,branchId,categoryGroupId);
    await activeCategory(db,installationId,branchId,categoryParentId,categoryGroupId);
    const result=await db.query<{id:string}>(`INSERT INTO catalog_product_category
      (installation_id,branch_id,code,name,group_id,parent_id)
      VALUES($1,$2,$3,$4,$5,$6) RETURNING id`,
      [installationId,branchId,value.code,value.name,categoryGroupId,categoryParentId]);
    return {status:201,body:{id:result.rows[0]!.id,code:value.code,name:value.name,revision:0}};
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
    const hierarchy=await hasCatalogHierarchySchema(db);
    if(value.categoryId&&!hierarchy)
      throw new CatalogError(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
    if(value.categoryId)await activeCategory(db,installationId,branchId,
      value.categoryId,value.groupId);
    if(value.groupId!==null)
      await activeDirectoryCode(db,"catalog_product_group",installationId,branchId,value.groupId??null);
    const r=await db.query<{id:string}>(
      hierarchy?
        `INSERT INTO catalog_product(installation_id,branch_id,sku,name,group_id,base_unit,category_id)
          VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`:
        `INSERT INTO catalog_product(installation_id,branch_id,sku,name,group_id,base_unit)
          VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [installationId,branchId,value.code,value.name,value.groupId,value.baseUnit,
        ...(hierarchy?[value.categoryId]:[])]);
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
      baseUnit:value.baseUnit,groupId:value.groupId,categoryId:value.categoryId,revision:0,variants}};
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

type Editable = "customers"|"customer-groups"|"customer-regions"|"suppliers"|"brands"|"groups"|"categories"|"products"|"price-lists"|"unit-definitions";
const editable = new Set<Editable>(["customers","customer-groups","customer-regions","suppliers","brands","groups","categories","products","price-lists","unit-definitions"]);
const editTables:Record<Editable,string>={
  "customers":"catalog_customer","suppliers":"catalog_supplier",
  "customer-groups":"catalog_customer_group","customer-regions":"catalog_customer_region",
  "brands":"catalog_brand","groups":"catalog_product_group","categories":"catalog_product_category","products":"catalog_product",
  "unit-definitions":"catalog_unit_definition",
  "price-lists":"catalog_price_list",
};
export function parseEdit(resource:Editable,raw:Record<string,unknown>){
  const branchId=requireUuid(raw.branchId);
  const columns:Record<string,unknown>={};
  const allow=new Set(["branchId","name","active",
    ...(resource==="customers"?["customerGroupId","customerRegionId","phone","deliveryAddress","paymentTermsDays"]:[]),
    ...(resource==="products"?["groupId","categoryId"]:[]),
    ...(resource==="groups"?["brandId"]:[]),
    ...(resource==="categories"?["parentId"]:[]),
    ...(resource==="price-lists"?["effectiveFrom","effectiveTo","priority",
      "stackingMode","stopProcessing",...PRICE_SCOPE_KEYS]:[])]);
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
    if(Object.prototype.hasOwnProperty.call(raw,"stackingMode"))
      columns.stacking_mode=listStackingMode(raw.stackingMode);
    if(Object.prototype.hasOwnProperty.call(raw,"stopProcessing"))
      columns.stop_processing=listStopProcessing(raw.stopProcessing);
    if(columns.effective_from!==undefined&&columns.effective_to!==undefined)
      r1cRange(columns.effective_from as string|null,columns.effective_to as string|null);
  }
  if(resource==="products"&&Object.prototype.hasOwnProperty.call(raw,"groupId")){
    columns.group_id=raw.groupId===null?null:requireUuid(raw.groupId);
  }
  if(resource==="groups"&&Object.prototype.hasOwnProperty.call(raw,"brandId"))
    columns.brand_id=raw.brandId===null?null:requireUuid(raw.brandId);
  if(resource==="categories"&&Object.prototype.hasOwnProperty.call(raw,"parentId"))
    columns.parent_id=raw.parentId===null?null:requireUuid(raw.parentId);
  if(resource==="products"&&Object.prototype.hasOwnProperty.call(raw,"categoryId"))
    columns.category_id=raw.categoryId===null?null:requireUuid(raw.categoryId);
  const scopes=resource==="price-lists"?priceScopes(raw):null;
  if(Object.keys(columns).length===0&&scopes===null)throw new CatalogError(400,"EMPTY_UPDATE");
  return {branchId,columns,scopes};
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
  if(resource==="price-lists"&&
    Object.keys(value.columns).some(x=>["stacking_mode","stop_processing"].includes(x))&&
    !await hasP0PriceSchema(db))
    throw new CatalogError(503,"P0_PRICE_SCHEMA_REQUIRED");
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
  if(resource==="products"){
    if(Object.prototype.hasOwnProperty.call(value.columns,"group_id"))
      await activeDirectoryCode(db,"catalog_product_group",
        installationId,value.branchId,value.columns.group_id as string|null);
    if(Object.prototype.hasOwnProperty.call(value.columns,"category_id")||
       Object.prototype.hasOwnProperty.call(value.columns,"group_id")){
      const hierarchy=await hasCatalogHierarchySchema(db);
      if(!hierarchy&&Object.prototype.hasOwnProperty.call(value.columns,"category_id"))
        throw new CatalogError(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
      if(hierarchy){
        const current=await db.query<{group_id:string|null;category_id:string|null}>(
          'SELECT group_id,category_id FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 AND id=$3',
          [installationId,value.branchId,targetId]);
        const category=Object.prototype.hasOwnProperty.call(value.columns,"category_id")?
          value.columns.category_id as string|null:current.rows[0]?.category_id??null;
        const group=Object.prototype.hasOwnProperty.call(value.columns,"group_id")?
          value.columns.group_id as string|null:current.rows[0]?.group_id??null;
        await activeCategory(db,installationId,value.branchId,category,group);
      }
    }
  }
  if(resource==="groups"&&Object.prototype.hasOwnProperty.call(value.columns,"brand_id")){
    if(!await hasCatalogHierarchySchema(db))
      throw new CatalogError(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
    const brand=value.columns.brand_id as string|null;
    if(brand){
      const check=await db.query<{active:boolean}>(
        'SELECT active FROM catalog_brand WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR SHARE',
        [installationId,value.branchId,brand]);
      if(check.rows[0]?.active!==true)throw new CatalogError(400,"BRAND_UNAVAILABLE");
    }
  }
  if(resource==="categories"&&Object.prototype.hasOwnProperty.call(value.columns,"parent_id")){
    if(!await hasCatalogHierarchySchema(db))
      throw new CatalogError(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
    const existing=await db.query<{group_id:string}>(
      'SELECT group_id FROM catalog_product_category WHERE installation_id=$1 AND branch_id=$2 AND id=$3',
      [installationId,value.branchId,targetId]);
    await activeCategory(db,installationId,value.branchId,
      value.columns.parent_id as string|null,existing.rows[0]!.group_id);
  }
  if(resource==="price-lists"&&value.scopes)
    await syncPriceScopes(db,installationId,value.branchId,targetId,value.scopes);
  const columnEntries=Object.entries(value.columns);
  const sets=columnEntries.map(([key],i)=>key+"=$"+(i+4));
  const args=[installationId,value.branchId,targetId,...columnEntries.map(x=>x[1])];
  const saved=await db.query<{revision:string}>(
    `UPDATE ${table} SET ${[...sets,"revision=revision+1"].join(",")}
      WHERE installation_id=$1 AND branch_id=$2 AND id=$3
      RETURNING revision::text`,args);
  return {status:200,body:{id:targetId,revision:Number(saved.rows[0]!.revision)}};
}
/** Read-model pricing is advisory only; inventory stock and order posting remain blocked. */
async function livePrice(db:PoolClient,installationId:string,branchId:string,
  priceListId:string,productId:string){
  const listWindow=await hasR1CPriceSchema(db)?
    " AND (l.effective_from IS NULL OR l.effective_from<=now())"+
    " AND (l.effective_to IS NULL OR l.effective_to>now())":"";
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
      AND l.branch_id=e.branch_id AND l.id=e.price_list_id AND l.active ${listWindow}
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
    const assignmentPath=new RegExp("^/v1/catalog/price-lists/assignments/([0-9a-f-]{36})$","i")
      .exec(url.pathname);
    if(assignmentPath&&req.method==="PATCH"){
      if(!await hasR1CPriceSchema(pool))
        throw new CatalogError(503,"R1C_PRICE_LIST_MIGRATION_REQUIRED");
      const raw=await payloadFrom(req);
      if(Object.keys(raw).some(k=>!["branchId","active"].includes(k))||
        typeof raw.active!=="boolean")
        throw new CatalogError(400,"INVALID_ASSIGNMENT_UPDATE");
      const branchId=requireUuid(raw.branchId),id=requireUuid(assignmentPath[1]);
      const active=raw.active;
      const context=requestMutation(req,requestId,actorId,tenant,
        "catalog.price_lists.assignments.toggle",{branchId,id,active},true);
      const result=await executeMutation(pool,context,{
        authorize:(db,ctx)=>hasPermission(db,{installationId:ctx.installationId,
          actorId:ctx.actorId,permission:"catalog.write",branchId}),
        execute:(db,ctx)=>togglePriceAssignment(db,ctx.installationId,branchId,
          id,ctx.expectedRevision,active),
      });
      send(res,result.status,result.body,requestId,corsOrigin);return;
    }
    if(url.pathname==="/v1/catalog/price-lists/assignments"){
      if(!await hasR1CPriceSchema(pool))
        throw new CatalogError(503,"R1C_PRICE_LIST_MIGRATION_REQUIRED");
      if(req.method==="GET"){
        const branchId=requireUuid(url.searchParams.get("branchId"));
        const q=(url.searchParams.get("q")??"").trim();
        if(q.length>64)throw new CatalogError(400,"SEARCH_TOO_LONG");
        const listIdParam=url.searchParams.get("priceListId");
        const selectedListId=listIdParam?requireUuid(listIdParam):null;
        const offsetRaw=url.searchParams.get("offset")??"0";
        if(!/^(0|[1-9][0-9]{0,6})$/.test(offsetRaw)||
          Number(offsetRaw)>1000000||Number(offsetRaw)%100!==0)
          throw new CatalogError(400,"INVALID_ASSIGNMENT_PAGE");
        const db=await pool.connect();
        try{
          if(!await hasPermission(db,{installationId:tenant,actorId,
            permission:"catalog.read",branchId}))
            throw new CatalogError(403,"CATALOG_READ_DENIED");
          const page=await listPriceAssignments(db,tenant,branchId,q,
            selectedListId,Number(offsetRaw));
          send(res,200,{...page,requestId},requestId,corsOrigin);
        }finally{db.release();}
        return;
      }
      if(req.method==="POST"){
        const input=parsePriceAssignment(await payloadFrom(req));
        const context=requestMutation(req,requestId,actorId,tenant,
          "catalog.price_lists.assignments.create",input);
        const result=await executeMutation(pool,context,{
          authorize:(db,ctx)=>hasPermission(db,{installationId:ctx.installationId,
            actorId:ctx.actorId,permission:"catalog.write",branchId:input.branchId}),
          execute:(db,ctx)=>createPriceAssignment(db,ctx.installationId,input),
        });
        send(res,result.status,result.body,requestId,corsOrigin);return;
      }
      throw new CatalogError(405,"METHOD_NOT_ALLOWED");
    }
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
    const locationPath=/^\/v1\/catalog\/customers\/([0-9a-f-]{36})\/locations(?:\/([0-9a-f-]{36}))?$/.exec(url.pathname);
    if(locationPath){
      if(!await hasCatalogHierarchySchema(pool))
        throw new CatalogError(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
      const customerId=requireUuid(locationPath[1]);
      const locationId=locationPath[2]?requireUuid(locationPath[2]):null;
      if(req.method==="GET"&&!locationId){
        const branch=requireUuid(url.searchParams.get("branchId"));
        const db=await pool.connect();
        try{
          const items=await listCustomerLocations(db,tenant,actorId,branch,customerId);
          send(res,200,{items,requestId},requestId,corsOrigin);
        }finally{db.release();}
        return;
      }
      if((req.method==="POST"&&!locationId)||(req.method==="PATCH"&&locationId)){
        const input=parseCustomerLocation(await payloadFrom(req),req.method==="PATCH");
        const ctx=requestMutation(req,requestId,actorId,tenant,
          req.method==="POST"?"catalog.customer_location.create":"catalog.customer_location.update",
          {customerId,locationId,...input},req.method==="PATCH");
        const outcome=await executeMutation(pool,ctx,{
          authorize:(db,c)=>hasPermission(db,{installationId:c.installationId,
            actorId:c.actorId,permission:"catalog.write",branchId:input.branchId}),
          execute:(db,c)=>req.method==="POST"?
            createCustomerLocation(db,c,customerId,input):
            updateCustomerLocation(db,c,customerId,locationId!,input),
        });
        send(res,outcome.status,outcome.body,requestId,corsOrigin);return;
      }
      throw new CatalogError(405,"METHOD_NOT_ALLOWED");
    }
    const updatePath=/^\/v1\/catalog\/(customers|customer-groups|customer-regions|suppliers|brands|groups|categories|products|price-lists|unit-definitions)\/([0-9a-f-]{36})$/.exec(url.pathname);
    if(updatePath&&req.method==="PATCH"){
      const resource=updatePath[1] as Editable;
      if(!editable.has(resource))throw new CatalogError(404,"UNKNOWN_RESOURCE");
      if((resource==="customers"||resource==="customer-groups"||
        resource==="customer-regions")&&!await hasCustomerDirectories(pool))
        throw new CatalogError(503,"CUSTOMER_DICTIONARY_MIGRATION_REQUIRED");
      if((resource==="brands"||resource==="categories")&&!await hasCatalogHierarchySchema(pool))
        throw new CatalogError(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
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
    if((resource==="brands"||resource==="categories")&&
       !await hasCatalogHierarchySchema(pool))
      throw new CatalogError(503,"CATALOG_HIERARCHY_MIGRATION_REQUIRED");
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
      const exactId=["groups","brands","categories"].includes(resource)&&
        url.searchParams.has("id")?requireUuid(url.searchParams.get("id")):undefined;
      const client=await pool.connect();
      try{
        const rows=await listing(client,tenant,actorId,branchId,resource,search,afterCode,exactId);
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
    if(error instanceof CatalogError||error instanceof PriceAssignmentFault||error instanceof CustomerLocationFault){fail(res,error.status,error.code,requestId,corsOrigin);return;}
    if(error instanceof MutationFault){fail(res,error.httpStatus,error.code,requestId,corsOrigin);return;}
    if(typeof error==="object"&&error!==null&&"code" in error){
      if(error.code==="23505"){fail(res,409,"DUPLICATE",requestId,corsOrigin);return;}
      if(error.code==="23503"){fail(res,400,"INVALID_REFERENCE",requestId,corsOrigin);return;}
      if(error.code==="23514"){fail(res,400,"INVALID_VALUE",requestId,corsOrigin);return;}
    }
    fail(res,503,"CATALOG_UNAVAILABLE",requestId,corsOrigin);
  }
}
