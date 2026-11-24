import { createHash } from "node:crypto";
import type { PoolClient } from "pg";
import { canonicalPayload,requireRevision,type MutationContext } from "./mutation.ts";
import { checkCreate,executeCreate,parseEdit,applyEdit } from "./catalog_http.ts";
import { parse as parseR1,create as createR1 } from "./r1_catalog_http.ts";
import { parseBulkFile,restoreCsvGuard,type ParsedBulkFile } from "./bulk_file.ts";
import { resolveR1Price,R1QuoteError } from "./r1_pricing.ts";

export type BulkResource="customers"|"products"|"skus"|"prices";
export type BulkMode="CREATE"|"UPDATE"|"UPSERT";
export type BulkAction="CREATE"|"UPDATE"|"UNCHANGED"|"ERROR";
export type BulkInput={
 branchId:string;resource:BulkResource;mode:BulkMode;fileName:string;
 contentBase64:string;hasHeader:boolean;mapping:Record<string,string>;
 priceListId?:string;defaultEffectiveAt?:string;
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
/** Reject non-existent calendar dates before PostgreSQL sees ::timestamptz. */
export function validEffectiveAt(value:string|undefined):boolean{
 if(!value||!ISO.test(value))return false;
 const m=/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-](\d{2}):(\d{2}))$/.exec(value);
 if(!m)return false;
 const y=Number(m[1]),month=Number(m[2]),day=Number(m[3]);
 const hour=Number(m[4]),minute=Number(m[5]),second=Number(m[6]);
 const offsetHour=Number(m[8]??0),offsetMinute=Number(m[9]??0);
 const leap=y%4===0&&(y%100!==0||y%400===0);
 const maxDay=[31,leap?29:28,31,30,31,30,31,31,30,31,30,31][month-1];
 return y>=1&&month>=1&&month<=12&&day>=1&&maxDay!==undefined&&day<=maxDay&&
  hour<=23&&minute<=59&&second<=59&&offsetHour<=23&&offsetMinute<=59&&
  Number.isFinite(Date.parse(value));
}
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
  brandCode:["Mã nhãn hàng","Nhãn hàng","Brand Code","brandCode"],
  categoryCode:["Mã danh mục","Danh mục sản phẩm","Category Code","categoryCode"],
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
  skuCode:["Mã SKU","SKU bán","SKU","skuCode"],
  productCode:["Mã sản phẩm","Mã hàng","Product Code","productCode"],
  amount:["Đơn giá","Giá bán","Giá","Price","amount"],
  discountRate:["Chiết khấu %","CK %","Discount Rate","discountRate"],
  effectiveAt:["Hiệu lực từ","Ngày hiệu lực","Effective At","effectiveAt"],
 },
};
export function bulkColumns(resource:BulkResource){
 // Keep the legacy all-lists file contract. Selected-list SKU templates
 // expose their own exact-SKU columns through bulkExport.
 if(resource==="prices")return ["priceListCode","productCode","amount","discountRate","effectiveAt"];
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
 if(Object.keys(v).some(k=>!["branchId","resource","mode","fileName","contentBase64","hasHeader","mapping","previewHash","priceListId","defaultEffectiveAt"].includes(k)))
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
 if(v.priceListId!==undefined&&(resource!=="prices"||typeof v.priceListId!=="string"||
   !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v.priceListId)))
  throw new BulkFault("INVALID_PRICE_LIST");
 if(v.defaultEffectiveAt!==undefined&&(!v.priceListId||typeof v.defaultEffectiveAt!=="string"||
   !validEffectiveAt(v.defaultEffectiveAt)))throw new BulkFault("INVALID_EFFECTIVE_AT");
 const mapping=v.mapping as Record<string,unknown>;
 if(Object.keys(mapping).some(x=>!DEFINITIONS[resource][x]||
    typeof mapping[x]!=="string"||(mapping[x] as string).length>160))
  throw new BulkFault("INVALID_FILE_MAPPING");
 if(new Set(Object.values(mapping)).size!==Object.keys(mapping).length)
  throw new BulkFault("DUPLICATE_COLUMN_MAPPING");
 const keys=resource==="prices"?(v.priceListId?(mapping.skuCode?["skuCode"]:["productCode"]):["priceListCode","productCode"]):["code"];
 if(keys.some(k=>!mapping[k]))throw new BulkFault("MISSING_KEY_MAPPING");
 return {branchId:v.branchId,resource,mode:v.mode as BulkMode,
   fileName:v.fileName,contentBase64:v.contentBase64,
   hasHeader:v.hasHeader,mapping:mapping as Record<string,string>,
   ...(typeof v.priceListId==="string"?{priceListId:v.priceListId.toLowerCase()}:{}),
   ...(typeof v.defaultEffectiveAt==="string"?{defaultEffectiveAt:v.defaultEffectiveAt}:{})};
}
export function mappedRows(input:BulkInput,parsed:ParsedBulkFile){
 for(const column of Object.values(input.mapping)){
  if(!parsed.headers.includes(column))throw new BulkFault("MAPPING_HEADER_NOT_FOUND");
 }
 const pairs=Object.entries(input.mapping).map(([f,h])=>[f,parsed.headers.indexOf(h)] as const);
 const isCsv=/\.csv$/i.test(input.fileName);
 return parsed.rows.map(cells=>Object.fromEntries(pairs.map(([f,index])=>{
  const cell=(cells[index]??"").trim();
  return [f,isCsv?restoreCsvGuard(cell):cell];
 })) as Record<string,string>);
}
/** Resolve the selected destination against the authenticated branch for both
 * preview and apply. A file declaring another destination is rejected. */
async function mappedTargetRows(db:PoolClient,tenant:string,input:BulkInput,file:ParsedBulkFile){
 const rows=mappedRows(input,file);
 if(!input.priceListId)return rows;
 const list=await db.query<{code:string}>(`SELECT code FROM catalog_price_list
  WHERE installation_id=$1 AND branch_id=$2 AND id=$3 AND active`,
  [tenant,input.branchId,input.priceListId]);
 const target=list.rows[0]?.code;
 if(!target)throw new BulkFault("PRICE_LIST_NOT_FOUND_OR_INACTIVE",409);
 for(const row of rows){
  if(row.priceListCode&&row.priceListCode!==target)
   throw new BulkFault("PRICE_LIST_TARGET_MISMATCH",409);
  row.priceListCode=target;
  if(!row.effectiveAt&&input.defaultEffectiveAt)row.effectiveAt=input.defaultEffectiveAt;
 }
 return rows;
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
export function normalizeRow(
 resource:BulkResource,mode:BulkMode,raw:Record<string,string>,
 current:Record<string,any>|undefined,
 refs:{groups:Map<string,Record<string,any>>;regions:Map<string,Record<string,any>>;
  brands:Map<string,Record<string,any>>;categories:Map<string,Record<string,any>>;
  taxonomyReady?:boolean;
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
  if(resource==="products"){
   if(raw.categoryCode!==undefined){
    const value=raw.categoryCode;
    // Empty mapped columns in exported CSVs must not write category_id on
    // installations that have not yet applied the guarded taxonomy migration.
    if(value===""&&refs.taxonomyReady===false){
      after.categoryCode="";
    }else{
    const c=value===""?null:refs.categories.get(value);
    if(value!==""&&(!c||c.active!==true||c.groupActive!==true))
      throw new BulkFault("CATEGORY_CODE_NOT_FOUND_OR_INACTIVE");
    // Explicit group clearing is different from an omitted group column.
    // Never approve a preview that later writes groupId:null + categoryId:UUID.
    const groupExplicit=Object.prototype.hasOwnProperty.call(op,"groupId");
    const effectiveGroup=groupExplicit?op.groupId:(current?.groupId??c?.groupId??null);
    if(c&&c.groupId!==effectiveGroup)
      throw new BulkFault("CATEGORY_GROUP_MISMATCH");
    // Inferred group must also be written for previously ungrouped products.
    if(c&&!op.groupId&&!(current?.groupId))assign("groupId",c.groupId);
    assign("categoryId",c?.id??null);after.categoryCode=value;
    }
   }else if(!isNew&&op.groupId!==undefined&&
             op.groupId!==current?.groupId&&current?.categoryId){
    assign("categoryId",null);
   }
   if(raw.brandCode!==undefined&&raw.brandCode!==""){
    const b=refs.brands.get(raw.brandCode);
    // An explicit groupCode:'' clears the link to the brand, even when the
    // product was previously assigned to a group. Never fallback on explicit null.
    const gid=Object.prototype.hasOwnProperty.call(op,"groupId")
      ?op.groupId:current?.groupId;
    const group=[...refs.groups.values()].find(g=>g.id===gid);
    if(!b||b.active!==true||(group?.brandId??refs.categories.get(raw.categoryCode??"")?.brandId)!==b.id)
      throw new BulkFault("BRAND_GROUP_MISMATCH");
    after.brandCode=raw.brandCode;
   }
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
  if(!validEffectiveAt(at))throw new BulkFault("INVALID_EFFECTIVE_AT");
  assign("priceListId",l.id);assign("productId",p.id);
  assign("amount",amount);assign("discountRate",discount);assign("effectiveAt",at);
  after.priceListCode=raw.priceListCode;after.productCode=raw.productCode;
 }
 return {after,operation:op};
}
/** Selected-list SKU imports append immutable BASE policy versions to the
 * existing R1 resolver. They cannot overwrite prices in another list or unit. */
async function buildSelectedSkuPrices(db:PoolClient,tenant:string,actor:string,input:BulkInput,
 data:Record<string,string>[],firstLine:number):Promise<BulkPlan>{
 const branch=input.branchId,rows:BulkRow[]=[],seen=new Set<string>();
 const skuCodes=[...new Set(data.map(r=>r.skuCode).filter(Boolean) as string[])];
 const skuRows=await db.query<{id:string;code:string;productCode:string;unitCode:string;name:string}>(
  `SELECT s.id,s.sku AS code,p.sku AS "productCode",s.unit_code AS "unitCode",p.name
   FROM catalog_sell_sku s JOIN catalog_product p
    ON p.installation_id=s.installation_id AND p.branch_id=s.branch_id
      AND p.id=s.product_id AND p.active
   WHERE s.installation_id=$1 AND s.branch_id=$2 AND s.active
     AND s.sku=ANY($3::text[])`,[tenant,branch,skuCodes]);
 const skus=new Map(skuRows.rows.map(r=>[r.code,r]));
 for(let i=0;i<data.length;i++){
  const raw=data[i]!,line=firstLine+i,key=raw.skuCode??"";
  try{
   const codeValue=code(key,"SKU_CODE");
   if(seen.has(codeValue))throw new BulkFault("DUPLICATE_FILE_KEY");
   seen.add(codeValue);
   const sku=skus.get(codeValue);
   if(!sku)throw new BulkFault("SKU_CODE_NOT_FOUND_OR_INACTIVE");
   if(raw.productCode&&raw.productCode!==sku.productCode)
    throw new BulkFault("SKU_PRODUCT_MISMATCH");
   if(raw.unitCode&&raw.unitCode!==sku.unitCode)
    throw new BulkFault("SKU_UNIT_MISMATCH");
   const amount=exactDecimal(raw.amount,MONEY,"PRICE")!;
   const discount=exactDecimal(raw.discountRate,DISCOUNT,"DISCOUNT",true)??"0";
   const at=raw.effectiveAt;
   if(!at||!validEffectiveAt(at))throw new BulkFault("INVALID_EFFECTIVE_AT");
   const converted=await db.query<{net:string}>(`SELECT greatest(0,round(
       $1::numeric*(1-$2::numeric/100),0))::text AS net`,[amount,discount]);
   const net=converted.rows[0]!.net;
   const baseRules=await db.query<{id:string;amount:string;priority:number}>(
    `SELECT r.id,r.amount::text,r.priority FROM catalog_sku_price_rule r
     WHERE r.installation_id=$1 AND r.branch_id=$2 AND r.price_list_id=$3
       AND r.sell_sku_id=$4 AND r.scope_kind='BASE' AND r.min_quantity<=1
       AND r.effective_from<=$5::timestamptz
       AND (r.effective_to IS NULL OR r.effective_to>$5::timestamptz)
       AND NOT EXISTS (SELECT 1 FROM catalog_sku_price_retirement retired
        WHERE retired.installation_id=r.installation_id AND retired.branch_id=r.branch_id
         AND retired.rule_id=r.id AND retired.retired_at<=$5::timestamptz)
     ORDER BY r.priority DESC,r.effective_from DESC,r.id DESC LIMIT 1`,
     [tenant,branch,input.priceListId,sku.id,at]);
   const previousRule=baseRules.rows[0];
   let previous:string|null=null,sourceId:string|null=null,priority=previousRule?.priority??0;
   try{
    const quoted=await resolveR1Price(db,{installationId:tenant,branchId:branch,
     priceListId:input.priceListId!,sellSkuId:sku.id,quantity:"1",priceAt:at});
    previous=quoted.basePrice;
    sourceId=quoted.trace[0]?.ruleId??null;
    priority=quoted.trace[0]?.priority??priority;
   }catch(err){
    if(!(err instanceof R1QuoteError&&err.code==="SKU_HAS_NO_EFFECTIVE_BASE_PRICE"))
     throw err;
   }
   const sameInstant=await db.query<{id:string;amount:string;gross:string|null;discount:string|null}>(
    `SELECT r.id,r.amount::text,r.imported_gross_amount::text AS gross,
       r.imported_discount_rate::text AS discount
       FROM catalog_sku_price_rule r
      WHERE r.installation_id=$1 AND r.branch_id=$2 AND r.price_list_id=$3
       AND r.sell_sku_id=$4 AND r.scope_kind='BASE'
       AND r.effective_from=$5::timestamptz AND r.min_quantity<=1
       AND NOT EXISTS (SELECT 1 FROM catalog_sku_price_retirement retired
        WHERE retired.installation_id=r.installation_id AND retired.branch_id=r.branch_id
         AND retired.rule_id=r.id AND retired.retired_at<=$5::timestamptz)
       LIMIT 1`,[tenant,branch,input.priceListId,sku.id,at]);
   const same=sameInstant.rows[0];
   if(same&&(!equalDecimal(same.amount,net)||
     (same.gross!==null
       ?(!equalDecimal(same.gross,amount)||
         !equalDecimal(same.discount??"0",discount))
       :(!equalDecimal(discount,"0")||
         !equalDecimal(same.amount,amount)))))
    throw new BulkFault("PRICE_EFFECTIVE_TIME_CONFLICT");
   if(previous!==null&&input.mode==="CREATE")
    throw new BulkFault("ALREADY_EXISTS_USE_UPDATE");
   if(previous===null&&input.mode==="UPDATE")
    throw new BulkFault("NOT_FOUND_USE_CREATE");
   const action:BulkAction=same?"UNCHANGED":previous===null?"CREATE":"UPDATE";
   const after={priceListId:input.priceListId,skuCode:sku.code,
     productCode:sku.productCode,name:sku.name,unitCode:sku.unitCode,
     amount,discountRate:discount,effectiveAt:at,netUnitPrice:net};
   rows.push({line,key:codeValue,action,
    before:previous===null?null:{unitPrice:previous,sourceId},
    after,revision:null,error:null,
    internal:{...after,sellSkuId:sku.id,priority}});
  }catch(err){
   rows.push({line,key,action:"ERROR",before:null,after:null,revision:null,
    error:err instanceof BulkFault?err.code:"INVALID_ROW"});
  }
 }
 const summary={create:0,update:0,unchanged:0,error:0,total:rows.length};
 for(const row of rows)summary[row.action.toLowerCase() as "create"|"update"|"unchanged"|"error"]++;
 const digest=rows.map(({line,key,action,before,after,revision,error})=>({line,key,action,before,after,revision,error}));
 const hash=createHash("sha256").update(canonicalPayload({
  tenant,actor,branch,resource:input.resource,mode:input.mode,
  priceListId:input.priceListId,defaultEffectiveAt:input.defaultEffectiveAt??null,
  fileDigest:createHash("sha256").update(input.contentBase64).digest("hex"),
  mapping:input.mapping,hasHeader:input.hasHeader,rows:digest,
 })).digest("hex");
 return {rows,summary,hash};
}
export async function buildBulkPlan(db:PoolClient,tenant:string,actor:string,
 input:BulkInput):Promise<BulkPlan>{
 const file=parseBulkFile(input.fileName,input.contentBase64,input.hasHeader);
 const data=await mappedTargetRows(db,tenant,input,file);
 if(input.resource==="prices"&&input.priceListId&&input.mapping.skuCode)
  return buildSelectedSkuPrices(db,tenant,actor,input,data,file.firstLine);
 const all=(f:string)=>[...new Set(data.map(r=>r[f]).filter(Boolean) as string[])];
 const branch=input.branchId,res=input.resource;
 const taxonomyReady=(await db.query<{ok:boolean}>(
  "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version='0020_catalog_hierarchy_locations.sql') AS ok")).rows[0]?.ok===true;
 const products=await db.query<Record<string,any>>(
  'SELECT id,sku AS code,name,base_unit AS "baseUnit",group_id AS "groupId",'+
  (taxonomyReady?'category_id':'NULL::uuid')+' AS "categoryId",active,revision::int,'+
  '(SELECT b.barcode FROM catalog_sku_barcode b JOIN catalog_sell_sku s ON '+
  's.installation_id=b.installation_id AND s.branch_id=b.branch_id AND s.id=b.sell_sku_id '+
  'WHERE s.installation_id=catalog_product.installation_id AND '+
  's.branch_id=catalog_product.branch_id AND s.product_id=catalog_product.id '+
  'AND s.is_base AND b.active ORDER BY b.is_primary DESC,b.barcode LIMIT 1) AS barcode'+
  ' FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 AND ('+
  'sku=ANY($3::text[]) OR id IN (SELECT product_id FROM catalog_sell_sku '+
  'WHERE installation_id=$1 AND branch_id=$2 AND sku=ANY($3::text[])))',
  [tenant,branch,[...new Set([...all("code"),...all("productCode")])]]);
 // A newly created product also claims its code as the base sell SKU.
 // Existing non-base and inactive sell SKU codes reserve that namespace.
 const sellSkuCodes=res==="products"?await db.query<{code:string}>(
  'SELECT sku AS code FROM catalog_sell_sku WHERE installation_id=$1 '+
  'AND branch_id=$2 AND sku=ANY($3::text[])',
  [tenant,branch,all("code")]):{rows:[]};
 // Barcodes remain globally unique within the branch even when inactive.
 const occupiedBarcodes=res==="products"?await db.query<{barcode:string}>(
  'SELECT barcode FROM catalog_sku_barcode WHERE installation_id=$1 '+
  'AND branch_id=$2 AND barcode=ANY($3::text[])',
  [tenant,branch,all("barcode")]):{rows:[]};
 const customers=res==="customers"?await db.query<Record<string,any>>(
  'SELECT id,code,name,customer_group_id AS "customerGroupId",'+
  'customer_region_id AS "customerRegionId",phone,delivery_address AS "deliveryAddress",'+
  'payment_terms_days AS "paymentTermsDays",active,revision::int'+
  ' FROM catalog_customer WHERE installation_id=$1 AND branch_id=$2 AND code=ANY($3::text[])',
  [tenant,branch,all("code")]):{rows:[]};
 // Check globally occupied active phones, including customers whose code is
 // not in this import. After rows are normalized we validate the FINAL batch
 // state, so changing/retiring an owner and reassigning its phone works.
 const requestedPhones=res==="customers"?[...new Set([
  ...data.map(r=>(r.phone??"").startsWith("'+")?(r.phone??"").slice(1):r.phone),
  // Inactive customers being reactivated can retain an existing phone even
  // when the file maps only code+active. Check these as well against active
  // external owners before marking preview error-free.
  ...customers.rows.map(r=>r.phone),
 ].filter((v):v is string=>typeof v==="string"&&/^\+?[0-9]{9,15}$/.test(v)))]:[];
 const phoneOwners=res==="customers"?await db.query<{code:string;phone:string}>(
  'SELECT code,phone FROM catalog_customer WHERE installation_id=$1 AND branch_id=$2 '+
  'AND active AND phone=ANY($3::text[])',
  [tenant,branch,requestedPhones]):{rows:[]};
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
  'SELECT id,code,active'+(res==="products"&&taxonomyReady?',brand_id AS "brandId"':'')+
  ' FROM '+(res==="customers"?"catalog_customer_group":"catalog_product_group")+
  ' WHERE installation_id=$1 AND branch_id=$2 AND (code=ANY($3::text[])'+
  (res==="products"?' OR id=ANY($4::uuid[])':'')+')',
  res==="products"?
    [tenant,branch,all("groupCode"),
      [...new Set(products.rows.map(p=>p.groupId).filter(Boolean))]]:
    [tenant,branch,all("customerGroupCode")]):{rows:[]};
 const categories=res==="products"&&taxonomyReady?await db.query<Record<string,any>>(
  'SELECT c.id,c.code,c.group_id AS "groupId",c.active,g.active AS "groupActive",'+
  'g.brand_id AS "brandId" FROM catalog_product_category c '+
  'JOIN catalog_product_group g ON g.installation_id=c.installation_id '+
  'AND g.branch_id=c.branch_id AND g.id=c.group_id '+
  'WHERE c.installation_id=$1 AND c.branch_id=$2 AND c.code=ANY($3::text[])',
  [tenant,branch,all("categoryCode")]):{rows:[]};
 const brands=res==="products"&&taxonomyReady?await db.query<Record<string,any>>(
  'SELECT id,code,active FROM catalog_brand WHERE installation_id=$1 '+
  'AND branch_id=$2 AND code=ANY($3::text[])',
  [tenant,branch,all("brandCode")]):{rows:[]};
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
  effectiveAt:validEffectiveAt(r.effectiveAt)?r.effectiveAt:"",
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
  taxonomyReady,
  products:mapBy(products.rows,x=>x.code),
  groups:mapBy(groups.rows,x=>x.code),
  categories:mapBy(categories.rows,x=>x.code),
  brands:mapBy(brands.rows,x=>x.code),
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
 const occupiedSellSkuCodes=new Set(sellSkuCodes.rows.map(x=>x.code));
 const existingBarcodes=new Set(occupiedBarcodes.rows.map(x=>x.barcode));
 const fileBarcodeCounts=new Map<string,number>();
 if(res==="products")for(const raw of data){
  const barcode=raw.barcode,productCode=raw.code;
  if(barcode&&productCode&&!known.has(productCode)){
   fileBarcodeCounts.set(barcode,(fileBarcodeCounts.get(barcode)??0)+1);
  }
 }

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
   if(res==="products"&&!current){
    if(occupiedSellSkuCodes.has(idKey))
     throw new BulkFault("PRODUCT_CODE_OCCUPIED_BY_SELL_SKU");
    const barcode=raw.barcode;
    if(barcode&&existingBarcodes.has(barcode))
     throw new BulkFault("BARCODE_ALREADY_ASSIGNED");
    if(barcode&&(fileBarcodeCounts.get(barcode)??0)>1)
     throw new BulkFault("DUPLICATE_FILE_BARCODE");
   }
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
 if(res==="customers"){
  // Treat an invalid imported row as unchanged in the database. All valid
  // imported rows instead contribute their proposed active/phone end state.
  const valid=rows.filter(r=>r.action!=="ERROR");
  const imported=new Set(valid.map(r=>r.key));
  const owners=new Map<string,Set<string>>();
  const add=(phone:string,owner:string)=>{
   if(!owners.has(phone))owners.set(phone,new Set());
   owners.get(phone)!.add(owner);
  };
  for(const old of phoneOwners.rows)
   if(!imported.has(old.code))add(old.phone,old.code);
  const finalPhones=new Map<number,string>();
  for(const row of valid){
   const current=known.get(row.key);
   const futureActive=typeof row.after?.active==="boolean"?row.after.active:
    current?current.active:true;
   const phone=row.after&&Object.hasOwn(row.after,"phone")?
    row.after.phone:current?.phone;
   if(futureActive===true&&typeof phone==="string"&&phone!==""){
    add(phone,row.key);finalPhones.set(row.line,phone);
   }
  }
  for(const row of valid){
   const phone=finalPhones.get(row.line);
   if(phone&&(owners.get(phone)?.size??0)>1){
    row.action="ERROR";row.before=null;row.after=null;
    row.revision=null;row.error="DUPLICATE_CUSTOMER_PHONE";
    delete row.internal;
   }
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
  ...(input.priceListId?{priceListId:input.priceListId,defaultEffectiveAt:input.defaultEffectiveAt??null}:{}),
 })).digest("hex");
 return {rows,hash,summary};
}
export function publicBulkPlan(plan:BulkPlan):BulkPlan{
 return {...plan,rows:plan.rows.map(({internal:_,...rest})=>rest)};
}
export async function applyBulkPlan(db:PoolClient,ctx:MutationContext,
 input:BulkInput,expectedHash:string):Promise<{status:number;body:unknown}>{
 if(input.resource==="prices"&&input.priceListId&&input.mapping.skuCode){
  const file=parseBulkFile(input.fileName,input.contentBase64,input.hasHeader);
  const data=await mappedTargetRows(db,ctx.installationId,input,file);
  const codes=[...new Set(data.map(row=>row.skuCode).filter(Boolean))].sort();
  // A list/SKU stream is serialized across overlapping batches.
  for(const code of codes)await db.query(
   "SELECT pg_advisory_xact_lock(hashtextextended($1,0))",
   [[ctx.installationId,input.branchId,input.priceListId,code].join("|")]);
  const plan=await buildSelectedSkuPrices(db,ctx.installationId,ctx.actorId,
   input,data,file.firstLine);
  if(plan.summary.error||plan.hash!==expectedHash)
   throw new BulkFault("PREVIEW_STALE_OR_HAS_ERRORS",409);
  const applied:{line:number;action:string;id:string}[]=[];
  for(const row of plan.rows){
   if(row.action==="UNCHANGED")continue;
   const data=row.internal;
   if(!data)throw new BulkFault("INVALID_PLAN",500);
   const result=await createR1(db,ctx.installationId,"rules",parseR1("rules",{
    branchId:input.branchId,priceListId:input.priceListId,
    sellSkuId:data.sellSkuId,scopeKind:"BASE",adjustment:"FIXED_PRICE",
    amount:data.netUnitPrice,priority:data.priority,stacking:"EXCLUSIVE",
    importGrossAmount:data.amount,importDiscountRate:data.discountRate,
    minQuantity:"1",effectiveFrom:data.effectiveAt,
   }));
   applied.push({line:row.line,action:row.action,id:String((result.body as {id:string}).id)});
  }
  return {status:200,body:{applied,summary:plan.summary,hash:expectedHash}};
 }

 if(input.resource==="prices"){
  // Preview uses GET, apply must acquire same scope locks as single-price
  // inserts BEFORE checking the preview hash. Deterministic order avoids
  // deadlocks when two batches overlap multiple price lists/products.
  const raw=await mappedTargetRows(db,ctx.installationId,input,
   parseBulkFile(input.fileName,input.contentBase64,input.hasHeader));
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
 if(input.resource==="skus"){
  // Lock every affected parent BEFORE inserting any canonical unit (FK KEY
  // SHARE) or sell SKU (FOR UPDATE). A sorted global order prevents opposing
  // multi-product bulk files from deadlocking each other.
  const fileRows=mappedRows(input,parseBulkFile(
   input.fileName,input.contentBase64,input.hasHeader));
  const productCodes=[...new Set(fileRows.map(r=>r.productCode).filter(
   (v):v is string=>Boolean(v)))];
  const skuCodes=[...new Set(fileRows.map(r=>r.code).filter(
   (v):v is string=>Boolean(v)))];
  const [direct,existing]=await Promise.all([
   db.query<{id:string}>(
    'SELECT id FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 '+
    'AND sku=ANY($3::text[])',
    [ctx.installationId,input.branchId,productCodes]),
   db.query<{id:string}>(
    'SELECT product_id AS id FROM catalog_sell_sku WHERE installation_id=$1 '+
    'AND branch_id=$2 AND sku=ANY($3::text[])',
    [ctx.installationId,input.branchId,skuCodes]),
  ]);
  const parentIds=[...new Set([...direct.rows,...existing.rows].map(r=>r.id))].sort();
  for(const id of parentIds){
   await db.query(
    'SELECT id FROM catalog_product WHERE installation_id=$1 AND branch_id=$2 '+
    'AND id=$3 FOR UPDATE',
    [ctx.installationId,input.branchId,id]);
  }
 }
 const plan=await buildBulkPlan(db,ctx.installationId,ctx.actorId,input);
 if(plan.summary.error||plan.hash!==expectedHash)
  throw new BulkFault("PREVIEW_STALE_OR_HAS_ERRORS",409);
 if(input.resource==="customers"){
  // PostgreSQL's active-phone unique index is immediate (not deferrable).
  // Releasing all donor phone slots before assigning recipients is required
  // for swaps and one-way transfers regardless of CSV row ordering.
  // This intermediate state is NOT committed; final catalog edits perform
  // the normal revision increment inside the same audited mutation.
  const finals=plan.rows.filter(r=>r.action!=="ERROR").map(row=>({
   row,
   active:typeof row.after?.active==="boolean"?row.after.active:
    row.before?row.before.active:true,
   phone:row.after&&Object.hasOwn(row.after,"phone")?
    row.after.phone:row.before?.phone,
  }));
  const claims=new Map<string,Set<string>>();
  for(const f of finals)
   if(f.active===true&&typeof f.phone==="string"&&f.phone!==""){
    if(!claims.has(f.phone))claims.set(f.phone,new Set());
    claims.get(f.phone)!.add(f.row.key);
   }
  const donors=finals.filter(f=>{
   const original=f.row.before;
   if(f.row.action!=="UPDATE"||!original||original.active!==true||
      typeof original.phone!=="string"||original.phone==="")return false;
   const claimants=claims.get(original.phone);
   return Boolean(claimants&&[...claimants].some(code=>code!==f.row.key)&&
    (f.active!==true||f.phone!==original.phone));
  }).sort((a,b)=>String(a.row.internal?.id).localeCompare(String(b.row.internal?.id)));
  for(const donor of donors){
   const id=donor.row.internal?.id;
   if(typeof id!=="string")throw new BulkFault("PREVIEW_STALE_OR_HAS_ERRORS",409);
   const result=await db.query<{phone:string|null;active:boolean;revision:number}>(
    'SELECT phone,active,revision::int FROM catalog_customer '+
    'WHERE installation_id=$1 AND branch_id=$2 AND id=$3 FOR UPDATE',
    [ctx.installationId,input.branchId,id]);
   const old=result.rows[0];
   if(!old||old.revision!==donor.row.revision||old.phone!==donor.row.before?.phone||
      old.active!==true)throw new BulkFault("PREVIEW_STALE_OR_HAS_ERRORS",409);
   if(donor.active===false){
    await db.query('UPDATE catalog_customer SET active=false WHERE installation_id=$1 '+
     'AND branch_id=$2 AND id=$3',[ctx.installationId,input.branchId,id]);
   }else{
    await db.query('UPDATE catalog_customer SET phone=NULL WHERE installation_id=$1 '+
     'AND branch_id=$2 AND id=$3',[ctx.installationId,input.branchId,id]);
   }
  }
 }
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
   // The bulk plan already validates price decimals, references, exact
   // timestamps and the owner's preview hash under per-stream advisory locks.
   // Avoid the single-entry checkCreate() API's Date conversion: it truncates
   // microseconds and rejects ISO timezone offsets accepted by bulk preview.
   // PostgreSQL stores the original instant with exact microsecond precision.
   const inserted=await db.query<{id:string}>(`
     INSERT INTO catalog_price_entry
      (installation_id,branch_id,price_list_id,product_id,amount,discount_rate,effective_at)
     VALUES ($1,$2,$3,$4,$5::numeric,$6::numeric,$7::timestamptz)
     RETURNING id`,[ctx.installationId,input.branchId,
       data.priceListId,data.productId,data.amount,data.discountRate,data.effectiveAt]);
   return {status:201,body:{id:inserted.rows[0]!.id}};
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
