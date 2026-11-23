import { createHash } from "node:crypto";
import type { PoolClient } from "pg";
import { canonicalPayload,requireRevision,type MutationContext } from "./mutation.ts";
import { checkCreate,executeCreate,parseEdit,applyEdit } from "./catalog_http.ts";
import { parse as parseR1,create as createR1 } from "./r1_catalog_http.ts";
import { parseBulkFile,type ParsedBulkFile } from "./bulk_file.ts";

export type BulkResource="customers"|"products"|"skus"|"prices";
export type BulkMode="CREATE"|"UPDATE"|"UPSERT";
export type BulkAction="CREATE"|"UPDATE"|"UNCHANGED"|"ERROR";
export type BulkInput={
 branchId:string;resource:BulkResource;mode:BulkMode;fileName:string;
 contentBase64:string;hasHeader:boolean;mapping:Record<string,string>;
};
export type BulkRow={
 line:number;key:string;action:BulkAction;before:Record<string,unknown>|null;
 after:Record<string,unknown>|null;revision:number|null;error:string|null;
 internal?:Record<string,unknown>;
};
export type BulkPlan={
 rows:BulkRow[];hash:string;
 summary:{create:number;update:number;unchanged:number;error:number;total:number};
};

export class BulkFault extends Error {
 readonly code:string;readonly status:number;
 constructor(code:string,status=400){super(code);this.code=code;this.status=status;}
}
const CODE=/^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$/;
const UNIT=/^.{1,24}$/u;
const DEC=/^(?:0\.[0-9]{0,5}[1-9]|[1-9][0-9]{0,11}(?:\.[0-9]{1,6})?)$/;
const MONEY=/^(?:0|[1-9][0-9]{0,12})(?:\.[0-9]{1,4})?$/;
const DISCOUNT=/^(?:100(?:\.0{1,2})?|(?:[0-9]|[1-9][0-9])(?:\.[0-9]{1,2})?)$/;
const ISO=/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/;
const DEFINITIONS:Record<BulkResource,Record<string,string[]>>={
 customers:{
  code:["Mã khách hàng","Mã KH","Customer Code","CustomerCode","code"],
  name:["Tên khách hàng","Tên khách","Customer Name","Name","name"],
  customerGroupCode:["Mã nhóm khách","Nhóm khách","Group Code","customerGroupCode"],
  customerRegionCode:["Mã khu vực","Khu vực bán hàng","Region Code","customerRegionCode"],
  phone:["Số điện thoại","Điện thoại","Phone","phone"],
  deliveryAddress:["Địa chỉ giao","Địa chỉ giao hàng","Delivery Address","deliveryAddress"],
  paymentTermsDays:["Số ngày công nợ","Hạn thanh toán","Payment Terms Days","paymentTermsDays"],
  active:["Trạng thái","Hoạt động","active"],
 },
 products:{
  code:["Mã sản phẩm","Mã hàng","Mã SP","SKU gốc","Product Code","code"],
  name:["Tên sản phẩm","Tên hàng","Product Name","name"],
  baseUnit:["Mã đơn vị gốc","Đơn vị tồn kho","Đơn vị tính","Base Unit","baseUnit"],
  groupCode:["Mã nhóm hàng","Nhóm hàng","Group Code","groupCode"],
  barcode:["Mã vạch gốc","Barcode","barcode"],
  active:["Trạng thái","Hoạt động","active"],
 },
 skus:{
  code:["Mã SKU","SKU bán","Sell SKU","code"],
  productCode:["Mã sản phẩm","Mã hàng gốc","Product Code","productCode"],
  unitCode:["Mã đơn vị","Đơn vị bán","Unit Code","unitCode"],
  toBase:["Hệ số quy đổi","Quy đổi về gốc","Conversion","toBase"],
  active:["Trạng thái","Hoạt động","active"],
  reason:["Lý do ngừng","Disable Reason","reason"],
 },
 prices:{
  priceListCode:["Mã bảng giá","Bảng giá","Price List Code","priceListCode"],
  productCode:["Mã sản phẩm","Mã hàng","Product Code","productCode"],
  amount:["Đơn giá","Giá bán","Giá","Price","amount"],
  discountRate:["Chiết khấu %","CK %","Discount Rate","discountRate"],
  effectiveAt:["Hiệu lực từ","Ngày hiệu lực","Effective At","effectiveAt"],
 },
};
export function bulkColumns(resource:BulkResource){
 return Object.keys(DEFINITIONS[resource]);
}
const simplified=(s:string)=>s.normalize("NFD").replace(/[\u0300-\u036f]/g,"")
 .replace(/[đĐ]/g,"d").toLowerCase().replace(/[^a-z0-9]+/g,"");
export function suggestBulkMapping(resource:BulkResource,headers:string[]):Record<string,string>{
 const result:Record<string,string>={};
 const used=new Set<string>();
 for(const [field,aliases] of Object.entries(DEFINITIONS[resource])){
  const candidate=headers.find(h=>!used.has(h)&&aliases.some(a=>simplified(h)===simplified(a)));
  if(candidate){result[field]=candidate;used.add(candidate);}
 }
 return result;
}
export function checkBulkInput(value:unknown):BulkInput{
 if(!value||typeof value!=="object"||Array.isArray(value))throw new BulkFault("INVALID_BULK_INPUT");
 const v=value as Record<string,unknown>;
 if(Object.keys(v).some(k=>!["branchId","resource","mode","fileName","contentBase64","hasHeader","mapping","previewHash"].includes(k)))
  throw new BulkFault("UNKNOWN_FIELD");
 if(typeof v.branchId!=="string"||
   !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v.branchId))
  throw new BulkFault("INVALID_BRANCH");
 if(!["customers","products","skus","prices"].includes(String(v.resource))||
    !["CREATE","UPDATE","UPSERT"].includes(String(v.mode)))
  throw new BulkFault("INVALID_BULK_KIND");
 if(typeof v.fileName!=="string"||typeof v.contentBase64!=="string"||
    typeof v.hasHeader!=="boolean"||!v.mapping||
    typeof v.mapping!=="object"||Array.isArray(v.mapping))
  throw new BulkFault("INVALID_FILE_MAPPING");
 const resource=v.resource as BulkResource;
 const mapping=v.mapping as Record<string,unknown>;
 if(Object.keys(mapping).some(x=>!DEFINITIONS[resource][x]||
    typeof mapping[x]!=="string"||(mapping[x] as string).length>160))
  throw new BulkFault("INVALID_FILE_MAPPING");
 if(new Set(Object.values(mapping)).size!==Object.keys(mapping).length)
  throw new BulkFault("DUPLICATE_COLUMN_MAPPING");
 const keys=resource==="prices"?["priceListCode","productCode"]:["code"];
 if(keys.some(k=>!mapping[k]))throw new BulkFault("MISSING_KEY_MAPPING");
 return {branchId:v.branchId,resource,mode:v.mode as BulkMode,
   fileName:v.fileName,contentBase64:v.contentBase64,
   hasHeader:v.hasHeader,mapping:mapping as Record<string,string>};
}
export function mappedRows(input:BulkInput,parsed:ParsedBulkFile){
 for(const column of Object.values(input.mapping)){
  if(!parsed.headers.includes(column))throw new BulkFault("MAPPING_HEADER_NOT_FOUND");
 }
 const pairs=Object.entries(input.mapping).map(([f,h])=>[f,parsed.headers.indexOf(h)] as const);
 return parsed.rows.map(cells=>Object.fromEntries(pairs.map(([f,index])=>
  [f,(cells[index]??"").trim()])) as Record<string,string>);
}
function code(v:string|undefined,kind:string):string{
 if(!v||!CODE.test(v))throw new BulkFault("INVALID_"+kind);
 return v;
}
function name(v:string|undefined,kind:string,max=160):string{
 if(!v||v.length>max)throw new BulkFault("INVALID_"+kind);
 return v;
}
function flag(v:string|undefined):boolean|undefined{
 if(v===undefined||v==="")return undefined;
 const k=simplified(v);
 if(["1","true","yes","co","hoatdong","dangdung","active"].includes(k))return true;
 if(["0","false","no","khong","ngung","ngunghoatdong","inactive"].includes(k))return false;
 throw new BulkFault("INVALID_ACTIVE");
}
function integer(v:string|undefined):number|undefined{
 if(v===undefined||v==="")return undefined;
 if(!/^(0|[1-9][0-9]{0,2})$/.test(v)||Number(v)>365)
  throw new BulkFault("INVALID_PAYMENT_TERMS");
 return Number(v);
}
const clean=(obj:Record<string,unknown>)=>
 Object.fromEntries(Object.entries(obj).filter(([,v])=>v!==undefined));
function equal(a:unknown,b:unknown):boolean{
 return canonicalPayload(a)===canonicalPayload(b);
}
function mapBy<T extends Record<string,any>>(items:T[],key:(item:T)=>string):Map<string,T>{
 return new Map(items.map(v=>[key(v),v]));
}
/** Compare fixed-decimal strings exactly, without IEEE754 rounding. */
export function equalDecimal(a:unknown,b:unknown):boolean{
 const normalize=(value:unknown):string=>{
  const raw=String(value),parts=raw.split(".");
  const integer=(parts[0]??"0").replace(/^0+(?=\d)/,"");
  const fraction=(parts[1]??"").replace(/0+$/,"");
  return integer+(fraction?"."+fraction:"");
 };
 return normalize(a)===normalize(b);
}
const exactDecimal=(s:string|undefined,rx:RegExp,codeName:string,optional=false):string|undefined=>{
 if(optional&&(s===undefined||s===""))return undefined;
 if(!s||!rx.test(s))throw new BulkFault("INVALID_"+codeName);
 return s;
};
function normalizeRow(
 resource:BulkResource,mode:BulkMode,raw:Record<string,string>,
 current:Record<string,any>|undefined,
 refs:{groups:Map<string,Record<string,any>>;regions:Map<string,Record<string,any>>;
  units:Map<string,Record<string,any>>;products:Map<string,Record<string,any>>;
  lists:Map<string,Record<string,any>>;productUnits:Map<string,Record<string,any>>},
 branchId:string,
):{after:Record<string,unknown>;operation:Record<string,unknown>}{
 const isNew=!current;
 const op:Record<string,unknown>={branchId},after:Record<string,unknown>={};
 const assign=(key:string,value:unknown)=>{
  if(value!==undefined){after[key]=value;op[key]=value;}
 };
 const required=(key:string,maximum=160)=>name(raw[key],"REQUIRED_"+key,maximum);
 if(resource==="customers"||resource==="products"){
  if(isNew)assign("name",required("name"));
  else if(raw.name!==undefined)assign("name",required("name"));
  const a=flag(raw.active);
  if(a!==undefined){
   if(isNew&&!a)throw new BulkFault("CREATE_INACTIVE_UNSUPPORTED");
   if(!isNew)assign("active",a);
  }
  const groupField=resource==="customers"?"customerGroupCode":"groupCode";
  if(raw[groupField]!==undefined){
   const value=raw[groupField],g=value===""?null:refs.groups.get(value);
   if(value!==""&&(!g||g.active!==true))throw new BulkFault("GROUP_CODE_NOT_FOUND_OR_INACTIVE");
   if(resource==="customers")assign("customerGroupId",g?.id??null);
   else assign("groupId",g?.id??null);
   after[groupField]=value;
  }
  if(resource==="customers"){
   if(raw.customerRegionCode!==undefined){
    const value=raw.customerRegionCode,r=value===""?null:refs.regions.get(value);
    if(value!==""&&(!r||r.active!==true))throw new BulkFault("REGION_CODE_NOT_FOUND_OR_INACTIVE");
    assign("customerRegionId",r?.id??null);after.customerRegionCode=value;
   }
   if(raw.phone!==undefined){
    // CSV-exported international numbers carry a leading apostrophe to
    // neutralize spreadsheet formula evaluation. Reverse ONLY this exact
    // protection for validated phone fields during import.
    {
      const value=raw.phone.startsWith("'+")?raw.phone.slice(1):raw.phone;
      if(value!==""&&!/^\+?[0-9]{9,15}$/.test(value))
       throw new BulkFault("INVALID_PHONE");
      assign("phone",value||null);
    }
   }
   if(raw.deliveryAddress!==undefined)
    assign("deliveryAddress",raw.deliveryAddress===""?null:
      name(raw.deliveryAddress,"DELIVERY_ADDRESS",500));
   const payment=integer(raw.paymentTermsDays);
   if(payment!==undefined)assign("paymentTermsDays",payment);
  }else{
   if(isNew){
    const u=required("baseUnit",24);
    if(!refs.units.has(u)||refs.units.get(u)?.active!==true)
     throw new BulkFault("UNIT_CODE_NOT_FOUND_OR_INACTIVE");
    assign("baseUnit",u);
    if(raw.barcode!==undefined&&raw.barcode!==""){
     if(!/^[A-Za-z0-9._-]{4,64}$/.test(raw.barcode))
      throw new BulkFault("INVALID_BARCODE");
     assign("barcode",raw.barcode);
    }
   }else{
    if(raw.baseUnit!==undefined&&raw.baseUnit!==""&&raw.baseUnit!==current.baseUnit)
     throw new BulkFault("IMMUTABLE_BASE_UNIT");
    // Re-importing the exact base barcode exported from ERP is unchanged.
    // Changing or removing a used barcode requires its own audited lifecycle.
    if(raw.barcode!==undefined&&raw.barcode!==(current.barcode??""))
     throw new BulkFault("BARCODE_UPDATE_USE_LIFECYCLE");
   }
  }
 }else if(resource==="skus"){
  if(isNew){
   const p=refs.products.get(code(raw.productCode,"PRODUCT_CODE"));
   if(!p||p.active!==true)throw new BulkFault("PRODUCT_CODE_NOT_FOUND_OR_INACTIVE");
   const unit=required("unitCode",24),factor=exactDecimal(raw.toBase,DEC,"TO_BASE")!;
   if(!UNIT.test(unit)||!refs.units.has(unit)||refs.units.get(unit)?.active!==true)
    throw new BulkFault("UNIT_CODE_NOT_FOUND_OR_INACTIVE");
   const known=refs.productUnits.get(p.id+"|"+unit);
   if(known&&!equalDecimal(known.toBase,factor))
    throw new BulkFault("CANONICAL_CONVERSION_MISMATCH");
   if(unit===p.baseUnit)throw new BulkFault("BASE_SKU_ALREADY_CANONICAL");
   if(flag(raw.active)===false)throw new BulkFault("CREATE_INACTIVE_UNSUPPORTED");
   assign("productId",p.id);assign("unitCode",unit);assign("toBase",factor);
   after.productCode=raw.productCode;
   op.createUnit=!known;
  }else{
   if(raw.productCode!==undefined&&raw.productCode!==""&&
      refs.products.get(raw.productCode??'')?.id!==current.productId)
    throw new BulkFault("IMMUTABLE_SKU_PRODUCT");
   if(raw.unitCode!==undefined&&raw.unitCode!==""&&raw.unitCode!==current.unitCode)
    throw new BulkFault("IMMUTABLE_SKU_UNIT");
   if(raw.toBase!==undefined&&raw.toBase!==""&&
      !equalDecimal(raw.toBase,current.toBase))
    throw new BulkFault("IMMUTABLE_SKU_CONVERSION");
   const a=flag(raw.active);
   if(a!==undefined)assign("active",a);
   if(a===false&&current.active===true){
    const reason=name(raw.reason,"DISABLE_REASON",500);
    if(reason.length<3)throw new BulkFault("DISABLE_REASON_TOO_SHORT");
    assign("reason",reason);
   }
   if(a===true&&!refs.products.get(current.productCode)?.active)
    throw new BulkFault("PRODUCT_DISABLED_ENABLE_FIRST");
  }
 }else{
  const l=refs.lists.get(code(raw.priceListCode,"PRICE_LIST_CODE"));
  const p=refs.products.get(code(raw.productCode,"PRODUCT_CODE"));
  if(!l||l.active!==true)throw new BulkFault("PRICE_LIST_NOT_FOUND_OR_INACTIVE");
  if(!p||p.active!==true)throw new BulkFault("PRODUCT_CODE_NOT_FOUND_OR_INACTIVE");
  const amount=exactDecimal(raw.amount,MONEY,"PRICE")!;
  const discount=exactDecimal(raw.discountRate,DISCOUNT,"DISCOUNT",true)??"0";
  const at=required("effectiveAt",64);
  if(!ISO.test(at)||!Number.isFinite(Date.parse(at)))throw new BulkFault("INVALID_EFFECTIVE_AT");
  assign("priceListId",l.id);assign("productId",p.id);
  assign("amount",amount);assign("discountRate",discount);assign("effectiveAt",at);
  after.priceListCode=raw.priceListCode;after.productCode=raw.productCode;
 }
 return {after,operation:op};
}
export async function buildBulkPlan(db:PoolClient,tenant:string,actor:string,
 input:BulkInput):Promise<BulkPlan>{
 const file=parseBulkFile(input.fileName,input.contentBase64,input.hasHeader);
 const data=mappedRows(input,file);
 const all=(f:string)=>[...new Set(data.map(r=>r[f]).filter(Boolean) as string[])];
 const branch=input.branchId,res=input.resource;
 const products=await db.query<Record<string,any>>(
  'SELECT id,sku AS code,name,base_unit AS "baseUnit",group_id AS "groupId",active,revision::int,'+
  '(SELECT b.barcode FROM catalog_sku_barcode b JOIN catalog_sell_sku s ON '+
  's.installation_id=b.installation_id AND s.branch_id=b.branch_id AND s.id=b.sell_sku_id '+
  'WHERE s.installation_id=catalog_product.installation_id AND '+
  's.branch_id=catalog_product.branch_id AND s.product_id=catalog_product.id '+
  'AND s.is_base AND b.active ORDER BY b.is_primary DESC,b.barcode LIMIT 1) AS barcode'+
  ' FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 AND ('+
  'sku=ANY($3::text[]) OR id IN (SELECT product_id FROM catalog_sell_sku '+
  'WHERE installation_id=$1 AND branch_id=$2 AND sku=ANY($3::text[])))',
  [tenant,branch,[...new Set([...all("code"),...all("productCode")])]]);
 const customers=res==="customers"?await db.query<Record<string,any>>(
  'SELECT id,code,name,customer_group_id AS "customerGroupId",'+
  'customer_region_id AS "customerRegionId",phone,delivery_address AS "deliveryAddress",'+
  'payment_terms_days AS "paymentTermsDays",active,revision::int'+
  ' FROM catalog_customer WHERE installation_id=$1 AND branch_id=$2 AND code=ANY($3::text[])',
  [tenant,branch,all("code")]):{rows:[]};
 const sku=res==="skus"?await db.query<Record<string,any>>(
  'SELECT s.id,s.sku AS code,s.product_id AS "productId",p.sku AS "productCode",'+
  's.unit_code AS "unitCode",s.conversion_to_base::text AS "toBase",s.active,s.is_base AS "isBase",'+
  's.revision::int FROM catalog_sell_sku s JOIN catalog_product p ON '+
  'p.installation_id=s.installation_id AND p.branch_id=s.branch_id AND p.id=s.product_id '+
  'WHERE s.installation_id=$1 AND s.branch_id=$2 AND s.sku=ANY($3::text[])',
  [tenant,branch,all("code")]):{rows:[]};
 // Identity is immutable, including inactive SKU occupancy. A different
 // code cannot take over the same product+unit even if the old SKU is stopped.
 const skuUnitOccupancy=res==="skus"?await db.query<Record<string,any>>(
  'SELECT s.id,s.sku AS code,s.product_id AS "productId",s.unit_code AS "unitCode" '+
  'FROM catalog_sell_sku s WHERE s.installation_id=$1 AND s.branch_id=$2 '+
  'AND s.product_id=ANY($3::uuid[])',
  [tenant,branch,products.rows.map(x=>x.id)]):{rows:[]};
 const priceLists=res==="prices"?await db.query<Record<string,any>>(
  'SELECT id,code,name,active FROM catalog_price_list '+
  'WHERE installation_id=$1 AND branch_id=$2 AND code=ANY($3::text[])',
  [tenant,branch,all("priceListCode")]):{rows:[]};
 const groups=(res==="customers"||res==="products")?await db.query<Record<string,any>>(
  'SELECT id,code,active FROM '+(res==="customers"?"catalog_customer_group":"catalog_product_group")+
  ' WHERE installation_id=$1 AND branch_id=$2 AND code=ANY($3::text[])',
  [tenant,branch,all(res==="customers"?"customerGroupCode":"groupCode")]):{rows:[]};
 const regions=res==="customers"?await db.query<Record<string,any>>(
  'SELECT id,code,active FROM catalog_customer_region '+
  'WHERE installation_id=$1 AND branch_id=$2 AND code=ANY($3::text[])',
  [tenant,branch,all("customerRegionCode")]):{rows:[]};
 const units=(res==="products"||res==="skus")?await db.query<Record<string,any>>(
  'SELECT id,code,active FROM catalog_unit_definition WHERE installation_id=$1 '+
  'AND branch_id=$2 AND code=ANY($3::text[])',
  [tenant,branch,all(res==="products"?"baseUnit":"unitCode")]):{rows:[]};
 const productUnits=res==="skus"?await db.query<Record<string,any>>(
  'SELECT product_id AS "productId",unit_code AS "unitCode",to_base::text AS "toBase" '+
  'FROM catalog_unit WHERE installation_id=$1 AND branch_id=$2 AND '+
  'product_id=ANY($3::uuid[])',
  [tenant,branch,products.rows.map(r=>r.id)]):{rows:[]};
 const prices=res==="prices"?await db.query<Record<string,any>>(
  'SELECT DISTINCT ON (e.price_list_id,e.product_id) e.id,'+
  'e.price_list_id AS "priceListId",e.product_id AS "productId",'+
  `e.amount::text,e.discount_rate::text AS "discountRate",to_char(e.effective_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "effectiveAt" `+
  'FROM catalog_price_entry e WHERE e.installation_id=$1 AND e.branch_id=$2 '+
  'AND e.price_list_id=ANY($3::uuid[]) AND e.product_id=ANY($4::uuid[]) '+
  'ORDER BY e.price_list_id,e.product_id,e.effective_at DESC,e.id DESC',
  [tenant,branch,priceLists.rows.map(l=>l.id),products.rows.map(p=>p.id)]):{rows:[]};
 // Find every EXACT requested timestamp, including historical versions
 // older than the most recent price. PostgreSQL compares timestamptz directly,
 // preserving microseconds and timezone offsets without JavaScript rounding.
 const requested=res==="prices"?data.map((r,index)=>({
  rowIndex:index,priceListCode:r.priceListCode??"",
  productCode:r.productCode??"",
  effectiveAt:ISO.test(r.effectiveAt??"")&&
    Number.isFinite(Date.parse(r.effectiveAt??""))?r.effectiveAt:"",
 })):[];
 const occupied=res==="prices"?await db.query<Record<string,any>>(`
  SELECT x."rowIndex",e.id,e.amount::text,
   e.discount_rate::text AS "discountRate",
   to_char(e.effective_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "effectiveAt",e.price_list_id AS "priceListId",
   e.product_id AS "productId"
  FROM jsonb_to_recordset($3::jsonb) AS x(
   "rowIndex" integer,"priceListCode" text,"productCode" text,"effectiveAt" text)
  JOIN catalog_price_list l ON l.installation_id=$1 AND l.branch_id=$2
   AND l.code=x."priceListCode"
  JOIN catalog_product p ON p.installation_id=$1 AND p.branch_id=$2
   AND p.sku=x."productCode"
  JOIN catalog_price_entry e ON e.installation_id=$1 AND e.branch_id=$2
   AND e.price_list_id=l.id AND e.product_id=p.id
   AND e.effective_at=NULLIF(x."effectiveAt",'')::timestamptz`,
  [tenant,branch,JSON.stringify(requested)]):{rows:[]};
 const occupiedByRow=mapBy(occupied.rows,x=>String(x.rowIndex));
 const refs={
  products:mapBy(products.rows,x=>x.code),
  groups:mapBy(groups.rows,x=>x.code),
  regions:mapBy(regions.rows,x=>x.code),
  units:mapBy(units.rows,x=>x.code),
  productUnits:mapBy(productUnits.rows,x=>x.productId+"|"+x.unitCode),
  lists:mapBy(priceLists.rows,x=>x.code),
 };
 const known=res==="customers"?mapBy(customers.rows,x=>x.code):
  res==="products"?mapBy(products.rows,x=>x.code):
  res==="skus"?mapBy(sku.rows,x=>x.code):
  mapBy(prices.rows,x=>x.priceListId+"|"+x.productId);
 const occupiedSkuPairs=mapBy(skuUnitOccupancy.rows,
  x=>x.productId+"|"+x.unitCode);
 const selectedSkuPairs=new Set<string>();
 const rows:BulkRow[]=[],seen=new Set<string>();
 for(let i=0;i<data.length;i++){
  const raw=data[i]!,line=file.firstLine+i;
  const key=res==="prices"?(raw.priceListCode??"")+"|"+(raw.productCode??""):(raw.code??"");
  try{
   const idKey=res==="prices"?code(raw.priceListCode,"PRICE_LIST_CODE")+"|"+
       code(raw.productCode,"PRODUCT_CODE"):code(raw.code,"CODE");
   if(seen.has(idKey))throw new BulkFault("DUPLICATE_FILE_KEY");
   seen.add(idKey);
   const current=res==="prices"?known.get((refs.lists.get(raw.priceListCode??'')?.id??"?")+"|"+
       (refs.products.get(raw.productCode??'')?.id??"?")):known.get(idKey);
   if(current&&input.mode==="CREATE")throw new BulkFault("ALREADY_EXISTS_USE_UPDATE");
   if(!current&&input.mode==="UPDATE")throw new BulkFault("NOT_FOUND_USE_CREATE");
   const converted=normalizeRow(res,input.mode,raw,current,refs,branch);
   if(res==="skus"){
    const productId=converted.operation.productId??current?.productId;
    const unitCode=converted.operation.unitCode??current?.unitCode;
    const occupancyKey=String(productId)+"|"+String(unitCode);
    if(!current&&occupiedSkuPairs.has(occupancyKey))
     throw new BulkFault("PRODUCT_UNIT_ALREADY_ASSIGNED_TO_SKU");
    if(selectedSkuPairs.has(occupancyKey))
     throw new BulkFault("DUPLICATE_FILE_PRODUCT_UNIT");
    selectedSkuPairs.add(occupancyKey);
   }
   const after=clean(converted.after);

   const revision=current?(typeof current.revision==="number"?current.revision:0):null;
   const exact=res==="prices"?occupiedByRow.get(String(i)):undefined;
   const samePrice=exact&&res==="prices"&&
    equalDecimal(exact.amount,after.amount)&&
    equalDecimal(exact.discountRate,after.discountRate);
   if(exact&&!samePrice)
    throw new BulkFault("PRICE_EFFECTIVE_TIME_CONFLICT");
   const isSame=res==="prices"?Boolean(samePrice):
    Boolean(current&&Object.entries(converted.operation)
     .filter(([k])=>k!=="branchId"&&k!=="reason")
     .every(([k,v])=>equal((current as Record<string,unknown>)[k],v)));
   const action:BulkAction=!current?"CREATE":isSame?"UNCHANGED":"UPDATE";
   const matched=exact??current;
   const beforeMatched=matched?clean(Object.fromEntries(Object.entries(matched)
    .map(([k,v])=>[k,v instanceof Date?v.toISOString():v]))):null;
   rows.push({line,key:idKey,action,before:beforeMatched,after,revision,error:null,
    internal:{...converted.operation,id:matched?.id??null}});
  }catch(e){
   rows.push({line,key,action:"ERROR",before:null,after:null,revision:null,
    error:e instanceof BulkFault?e.code:"INVALID_ROW"});
  }
 }
 const summary={create:rows.filter(x=>x.action==="CREATE").length,
  update:rows.filter(x=>x.action==="UPDATE").length,
  unchanged:rows.filter(x=>x.action==="UNCHANGED").length,
  error:rows.filter(x=>x.action==="ERROR").length,total:rows.length};
 const digest=rows.map(({line,key,action,before,after,revision,error})=>
  ({line,key,action,before,after,revision,error}));
 const hash=createHash("sha256").update(canonicalPayload({
  tenant,actor,branch,resource:res,mode:input.mode,
  fileDigest:createHash("sha256").update(input.contentBase64).digest("hex"),
  mapping:input.mapping,hasHeader:input.hasHeader,rows:digest,
 })).digest("hex");
 return {rows,hash,summary};
}
export function publicBulkPlan(plan:BulkPlan):BulkPlan{
 return {...plan,rows:plan.rows.map(({internal:_,...rest})=>rest)};
}
export async function applyBulkPlan(db:PoolClient,ctx:MutationContext,
 input:BulkInput,expectedHash:string):Promise<{status:number;body:unknown}>{
 if(input.resource==="prices"){
  // Preview uses GET, apply must acquire same scope locks as single-price
  // inserts BEFORE checking the preview hash. Deterministic order avoids
  // deadlocks when two batches overlap multiple price lists/products.
  const raw=mappedRows(input,parseBulkFile(input.fileName,input.contentBase64,input.hasHeader));
  const listCodes=[...new Set(raw.map(r=>r.priceListCode).filter(Boolean) as string[])];
  const productCodes=[...new Set(raw.map(r=>r.productCode).filter(Boolean) as string[])];
  const lists=await db.query<{id:string;code:string}>(
   'SELECT id,code FROM catalog_price_list WHERE installation_id=$1 AND branch_id=$2 '+
   'AND code=ANY($3::text[])',[ctx.installationId,input.branchId,listCodes]);
  const products=await db.query<{id:string;code:string}>(
   'SELECT id,sku AS code FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 '+
   'AND sku=ANY($3::text[])',[ctx.installationId,input.branchId,productCodes]);
  const listIds=new Map(lists.rows.map(r=>[r.code,r.id]));
  const productIds=new Map(products.rows.map(r=>[r.code,r.id]));
  const locks=[...new Set(raw.map(r=>{
   const l=listIds.get(r.priceListCode??''),p=productIds.get(r.productCode??'');
   return l&&p?[ctx.installationId,input.branchId,l,p].join('|'):null;
  }).filter((x):x is string=>x!==null))].sort();
  for(const scope of locks)
   await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[scope]);
 }
 const plan=await buildBulkPlan(db,ctx.installationId,ctx.actorId,input);
 if(plan.summary.error||plan.hash!==expectedHash)
  throw new BulkFault("PREVIEW_STALE_OR_HAS_ERRORS",409);
 const applied:{line:number;action:string;id:string;reason?:string}[]=[];
 const skuProductsToCheck=new Set<string>();
 for(const row of plan.rows){
  if(row.action==="UNCHANGED")continue;
  if(!row.internal)throw new BulkFault("INVALID_PLAN",500);
  const data=row.internal,creating=row.action==="CREATE",result=async()=>{
   if(input.resource==="customers"||input.resource==="products"){
    if(creating){
     const body:Record<string,unknown>={...data,code:row.key};
     delete body.id;
     return executeCreate(db,ctx,input.resource,checkCreate(input.resource,body));
    }
    const editData:Record<string,unknown>={...data};delete editData.id;
    delete editData.code;delete editData.barcode;delete editData.baseUnit;
    return applyEdit(db,{...ctx,expectedRevision:row.revision!},
     input.resource,data.id as string,parseEdit(input.resource,editData));
   }
   if(input.resource==="skus"){
    if(creating){
     if(data.createUnit===true){
      await createR1(db,ctx.installationId,"units",parseR1("units",{
       branchId:input.branchId,productId:data.productId,
       unitCode:data.unitCode,toBase:data.toBase}));
     }
     return createR1(db,ctx.installationId,"skus",parseR1("skus",{
      branchId:input.branchId,productId:data.productId,
      sku:row.key,unitCode:data.unitCode,toBase:data.toBase}));
    }
    // SKU lifecycle must use the same update invariants as the single editor.
    // Parent lock precedes variant lock for consistent bulk/single SKU edits.
    const pid=(await db.query<{product_id:string}>(
      'SELECT product_id FROM catalog_sell_sku WHERE installation_id=$1 '+
      'AND branch_id=$2 AND id=$3',
      [ctx.installationId,input.branchId,data.id])).rows[0]?.product_id;
    if(!pid)throw new BulkFault("SKU_NOT_FOUND",409);
    await db.query('SELECT id FROM catalog_product WHERE installation_id=$1 '+
      'AND branch_id=$2 AND id=$3 FOR UPDATE',
      [ctx.installationId,input.branchId,pid]);
    const old=await db.query<{revision:number;active:boolean;productId:string}>(
     'SELECT revision::int,active,product_id AS "productId" FROM catalog_sell_sku '+
     'WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE',
     [ctx.installationId,input.branchId,data.id]);
    if(!old.rows[0])throw new BulkFault("SKU_NOT_FOUND",409);
    requireRevision(row.revision!,old.rows[0].revision);
    if(data.active===true){
     const product=await db.query<{active:boolean}>(
      'SELECT active FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 AND id=$3',
      [ctx.installationId,input.branchId,old.rows[0].productId]);
     if(!product.rows[0]?.active)throw new BulkFault("PRODUCT_DISABLED_ENABLE_FIRST",409);
    }
    await db.query('UPDATE catalog_sell_sku SET active=$4,revision=revision+1 '+
     'WHERE installation_id=$1 AND branch_id=$2 AND id=$3',
     [ctx.installationId,input.branchId,data.id,data.active]);
    // A file can disable an old SKU before creating its replacement.
    // Defer parent retirement until ALL SKU rows have been processed,
    // independent of file order.
    if(data.active===false)skuProductsToCheck.add(old.rows[0].productId);
    return {status:200,body:{id:data.id}};
   }
   return executeCreate(db,ctx,"prices",checkCreate("prices",{
    branchId:input.branchId,priceListId:data.priceListId,
    productId:data.productId,amount:data.amount,
    discountRate:data.discountRate,effectiveAt:data.effectiveAt}));
  };
  const response=await result();
  const body=response.body as Record<string,unknown>;
  applied.push({line:row.line,action:row.action,id:String(body.id??data.id),
   ...(input.resource==="skus"&&data.active===false?{reason:String(data.reason)}:{})});
 }
 for(const productId of [...skuProductsToCheck].sort()){
  const live=await db.query('SELECT 1 FROM catalog_sell_sku WHERE installation_id=$1 '+
   'AND branch_id=$2 AND product_id=$3 AND active LIMIT 1',
   [ctx.installationId,input.branchId,productId]);
  if(live.rowCount===0)await db.query(
   'UPDATE catalog_product SET active=false,revision=revision+1 '+
   'WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active',
   [ctx.installationId,input.branchId,productId]);
 }
 return {status:200,body:{applied,summary:plan.summary,hash:expectedHash}};
}
