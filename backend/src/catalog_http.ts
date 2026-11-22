import type { IncomingMessage, ServerResponse } from "node:http";
import type { Pool, PoolClient } from "pg";
import { resolveSession } from "./auth.ts";
import { userAccess } from "./identity_admin.ts";
import { hasPermission } from "./rbac.ts";
import { executeMutation, MutationFault, requireRevision, type MutationContext } from "./mutation.ts";
import { validIdempotencyKey } from "./contracts.ts";
import type { IdentityOptions } from "./identity_http.ts";

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
type Resource="customers"|"suppliers"|"groups"|"products"|"price-lists"|"prices"|"warehouses";
const resources=new Set<Resource>(["customers","suppliers","groups","products","price-lists","prices","warehouses"]);
function resourceOf(value:string):Resource{
  if(!resources.has(value as Resource))throw new CatalogError(404,"UNKNOWN_RESOURCE");
  return value as Resource;
}
const selections:Record<Resource,string>={
  "customers":'SELECT id,code,name,customer_group AS "customerGroup",phone,delivery_address AS "deliveryAddress",payment_terms_days AS "paymentTermsDays",active,revision::integer FROM catalog_customer',
  "suppliers":'SELECT id,code,name,active,revision::integer FROM catalog_supplier',
  "groups":'SELECT id,code,name,active,revision::integer FROM catalog_product_group',
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
  "suppliers":"catalog_supplier",
  "groups":"catalog_product_group",
  "products":"catalog_product",
  "price-lists":"catalog_price_list",
};
async function hasR1CatalogSchema(db:Pool):Promise<boolean>{
  try{
    const result=await db.query<{ok:boolean}>(
      "SELECT EXISTS(SELECT 1 FROM public.schema_migrations WHERE version='0009_r1_catalog_pricing.sql') AS ok");
    return result.rows[0]?.ok===true;
  }catch{return false;}
}
async function hasCatalogSchema(db:Pool):Promise<boolean>{
  try {
    const r=await db.query<{present:boolean}>(
      "SELECT (SELECT count(*)::integer FROM public.schema_migrations WHERE version IN ('0006_catalog.sql','0007_catalog_controls.sql'))=2 AS present");
    return r.rows[0]?.present===true;
  }catch{return false;}
}
async function listing(db:PoolClient,tenant:string,actorId:string,branchId:string,
  resource:Resource,search:string):Promise<unknown[]>{
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
  const values=resource==="prices"?[tenant,branchId]:
    [tenant,branchId,"%"+search+"%"];
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
  const r=await db.query(
    resource==="prices"
      ?`${selections.prices} WHERE installation_id=$1 AND branch_id=$2
          ORDER BY effective_at DESC,id LIMIT 100`
      :`${resource==="products"?productSelection:selections[resource]} WHERE installation_id=$1 AND branch_id=$2
          AND (${resource==="products"?"sku":"code"} ILIKE $3 OR name ILIKE $3
          ${resource==="customers"?"OR phone ILIKE $3 OR customer_group ILIKE $3":""})
          ORDER BY ${resource==="products"?"sku":"code"},id LIMIT 100`,
    values);
  return r.rows;
}

function checkCreate(resource:Resource,raw:Record<string,unknown>){
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
  const code=requireCode(raw.code);
  const name=requireName(raw.name);
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
    const customerGroup=raw.customerGroup==null?null:requireName(raw.customerGroup,64);
    const phone=raw.phone==null?null:requirePhone(raw.phone);
    const deliveryAddress=raw.deliveryAddress==null?null:requireName(raw.deliveryAddress,500);
    const paymentTermsDays=raw.paymentTermsDays??0;
    if(typeof paymentTermsDays!=="number"||!Number.isInteger(paymentTermsDays)||
      paymentTermsDays<0||paymentTermsDays>365)
      throw new CatalogError(400,"INVALID_PAYMENT_TERMS");
    return {branchId,code,name,customerGroup,phone,deliveryAddress,paymentTermsDays};
  }
  return {branchId,code,name};
}
type CreateInput=ReturnType<typeof checkCreate>;
async function executeCreate(db:PoolClient,context:MutationContext,
  resource:Exclude<Resource,"warehouses">,value:CreateInput){
  const {installationId,actorId}=context;
  const branchId=value.branchId;
  if(!await hasPermission(db,{installationId,actorId,permission:"catalog.write",branchId}))
    throw new MutationFault("FORBIDDEN",403);
  if(resource==="prices"){
    if(!("priceListId" in value))throw new CatalogError(400,"INVALID_PRICE");
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
  if(resource==="products"){
    if(!("baseUnit" in value))throw new CatalogError(400,"INVALID_PRODUCT");
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
  const r=await db.query<{id:string}>(
    withGroup
      ?`INSERT INTO ${table}
         (installation_id,branch_id,code,name,customer_group,phone,delivery_address,payment_terms_days)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`
      :`INSERT INTO ${table}(installation_id,branch_id,code,name)
         VALUES ($1,$2,$3,$4) RETURNING id`,
    withGroup?[installationId,branchId,value.code,value.name,
      "customerGroup" in value?value.customerGroup:null,
      "phone" in value?value.phone:null,"deliveryAddress" in value?value.deliveryAddress:null,
      "paymentTermsDays" in value?value.paymentTermsDays:0]:
      [installationId,branchId,value.code,value.name]);
  return {status:201,body:{id:r.rows[0]!.id,code:value.code,name:value.name,revision:0}};
}

type Editable = "customers"|"suppliers"|"groups"|"products"|"price-lists";
const editable = new Set<Editable>(["customers","suppliers","groups","products","price-lists"]);
const editTables:Record<Editable,string>={
  "customers":"catalog_customer","suppliers":"catalog_supplier",
  "groups":"catalog_product_group","products":"catalog_product",
  "price-lists":"catalog_price_list",
};
function parseEdit(resource:Editable,raw:Record<string,unknown>){
  const branchId=requireUuid(raw.branchId);
  const columns:Record<string,unknown>={};
  const allow=new Set(["branchId","name","active",
    ...(resource==="customers"?["customerGroup","phone","deliveryAddress","paymentTermsDays"]:[]),
    ...(resource==="products"?["groupId"]:[])]);
  if(Object.keys(raw).some(key=>!allow.has(key)))throw new CatalogError(400,"UNKNOWN_FIELD");
  if(Object.prototype.hasOwnProperty.call(raw,"name"))columns.name=requireName(raw.name);
  if(Object.prototype.hasOwnProperty.call(raw,"active")){
    if(typeof raw.active!=="boolean")throw new CatalogError(400,"INVALID_ACTIVE");
    columns.active=raw.active;
  }
  if(resource==="customers"&&Object.prototype.hasOwnProperty.call(raw,"customerGroup")){
    columns.customer_group=raw.customerGroup===null?null:requireName(raw.customerGroup,64);
  }
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
  if(resource==="products"&&Object.prototype.hasOwnProperty.call(raw,"groupId")){
    columns.group_id=raw.groupId===null?null:requireUuid(raw.groupId);
  }
  if(Object.keys(columns).length===0)throw new CatalogError(400,"EMPTY_UPDATE");
  return {branchId,columns};
}
async function applyEdit(db:PoolClient,context:MutationContext,
  resource:Editable,targetId:string,value:ReturnType<typeof parseEdit>){
  const {installationId,actorId,expectedRevision}=context;
  if(!await hasPermission(db,{installationId,actorId,
    permission:"catalog.write",branchId:value.branchId}))
    throw new MutationFault("FORBIDDEN",403);
  const table=editTables[resource];
  const row=await db.query<{revision:string}>(
    `SELECT revision::text FROM ${table} WHERE installation_id=$1
      AND branch_id=$2 AND id=$3 FOR UPDATE`,
    [installationId,value.branchId,targetId]);
  if(row.rowCount===0)throw new CatalogError(404,"NOT_FOUND");
  requireRevision(expectedRevision,Number(row.rows[0]!.revision));
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
    const updatePath=/^\/v1\/catalog\/(customers|suppliers|groups|products|price-lists)\/([0-9a-f-]{36})$/.exec(url.pathname);
    if(updatePath&&req.method==="PATCH"){
      const resource=updatePath[1] as Editable;
      if(!editable.has(resource))throw new CatalogError(404,"UNKNOWN_RESOURCE");
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
    if(req.method==="GET"){
      const branchId=requireUuid(url.searchParams.get("branchId"));
      const search=(url.searchParams.get("q")??"").trim();
      if(search.length>64)throw new CatalogError(400,"SEARCH_TOO_LONG");
      const client=await pool.connect();
      try{
        const rows=await listing(client,tenant,actorId,branchId,resource,search);
        send(res,200,{items:rows,
          ...(resource==="products"?{r1ProductReady:await hasR1CatalogSchema(pool)}:{}),
          requestId},requestId,corsOrigin);
      }finally{client.release();}
      return;
    }
    if(req.method==="POST"){
      // R1 sale variants/barcodes do not exist on 0006/0007-only installations.
      // Reject BEFORE the mutation transaction, never expose a half-created
      // product or a generic retryable provider error.
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
