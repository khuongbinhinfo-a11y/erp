import test from "node:test";
import assert from "node:assert/strict";
import { checkCreate, parseEdit, CatalogError } from "./catalog_http.ts";
import { parseCustomerLocation, CustomerLocationFault } from "./catalog_customer_locations.ts";
import { bulkColumns, suggestBulkMapping } from "./bulk_plan.ts";

const branch="00000000-0000-4000-8000-000000000001";
const brand="00000000-0000-4000-8000-000000000002";
const group="00000000-0000-4000-8000-000000000003";
const category="00000000-0000-4000-8000-000000000004";

test("brand / group / nested category identity is validated, no client-provided tenant",()=>{
  assert.deepEqual(checkCreate("brands",{branchId:branch,code:"NH01",name:"Nature"}),{
    branchId:branch,code:"NH01",name:"Nature"
  });
  const g=checkCreate("groups",{branchId:branch,code:"TAP",name:"Tập HS/SV",brandId:brand});
  assert.equal(g.brandId,brand);
  const c=checkCreate("categories",{branchId:branch,code:"F04NA",
    name:"Nature 100gsm",groupId:group,parentId:category});
  assert.equal(c.parentId,category);
  assert.equal(c.groupId,group);
  assert.throws(()=>checkCreate("categories",{branchId:branch,
    code:"F04NA",name:"Nature",groupId:group,parentId:"not-a-uuid"}),
    (e)=>e instanceof CatalogError);
  assert.throws(()=>checkCreate("groups",{branchId:branch,
    code:"TAP",name:"Tập",brandId:brand,installationId:branch}),
    (e)=>e instanceof CatalogError&&e.code==="UNKNOWN_FIELD");
});
test("product classification edits permit one catalog dimension, never identity rewrite",()=>{
  const p=parseEdit("products",{branchId:branch,categoryId:category});
  assert.equal(p.columns.category_id,category);
  assert.throws(()=>parseEdit("products",{branchId:branch,code:"OTHER"}),
    (e)=>e instanceof CatalogError&&e.code==="UNKNOWN_FIELD");
});
test("customer location payload has one client-supplied location and no tenant override",()=>{
  const value=parseCustomerLocation({branchId:branch,code:"CH01",name:"Cửa hàng 1",
    address:"Số 1 Nguyễn Văn A",phone:"+84912345678",isDefault:true});
  assert.deepEqual(value.columns,{code:"CH01",name:"Cửa hàng 1",
    address:"Số 1 Nguyễn Văn A",phone:"+84912345678",is_default:true});
  const update=parseCustomerLocation({branchId:branch,active:false},true);
  assert.deepEqual(update.columns,{active:false,is_default:false});
  for(const invalid of [
    {branchId:branch,code:"CH01",name:"Store",address:"A",installationId:branch},
    {branchId:branch,code:"CH01",name:"Store",address:"A",phone:"123"},
  ])assert.throws(()=>parseCustomerLocation(invalid),CustomerLocationFault);
});
test("product CSV/XLSX mapping recognizes Vietnamese brand and category codes",()=>{
  const fields=bulkColumns("products");
  assert.ok(fields.includes("brandCode")&&fields.includes("categoryCode"));
  const mapping=suggestBulkMapping("products",["Mã sản phẩm","Nhãn hàng","Mã danh mục"]);
  assert.equal(mapping.code,"Mã sản phẩm");
  assert.equal(mapping.brandCode,"Nhãn hàng");
  assert.equal(mapping.categoryCode,"Mã danh mục");
});
