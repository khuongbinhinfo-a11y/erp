import test from "node:test";
import { Pool } from "pg";
import { randomUUID } from "node:crypto";
import { resolve } from "node:path";
import { applyMigrations } from "./migrate.ts";

import assert from "node:assert/strict";
import { checkCreate, parseEdit, CatalogError } from "./catalog_http.ts";
import { parseCustomerLocation, nextCustomerLocationCode, CustomerLocationFault } from "./catalog_customer_locations.ts";
import { bulkColumns, suggestBulkMapping, normalizeRow, BulkFault } from "./bulk_plan.ts";
import { buildSkuTaxonomyFilters } from "./r1_catalog_http.ts";

const branch="00000000-0000-4000-8000-000000000001";
const brand="00000000-0000-4000-8000-000000000002";
const group="00000000-0000-4000-8000-000000000003";
const category="00000000-0000-4000-8000-000000000004";

test("price SKU taxonomy filters bind $4/$5/$6, never interpolate numeric UUID constants",()=>{
 const all=buildSkuTaxonomyFilters({groupId:group,categoryId:category,brandId:brand});
 assert.deepEqual(all.values,[group,category,brand]);
 assert.equal(all.filters.length,3);
 assert.match(all.filters[0]!,/p\.group_id=\$4::uuid/);
 assert.match(all.filters[1]!,/id=\$5::uuid/);
 assert.match(all.filters[1]!,/WITH RECURSIVE descendants/);
 assert.match(all.filters[2]!,/g\.brand_id=\$6::uuid/);
 const only=buildSkuTaxonomyFilters({brandId:brand});
 assert.deepEqual(only.values,[brand]);
 assert.match(only.filters[0]!,/\$4::uuid/);
});
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
  const addressOnly=parseCustomerLocation({branchId:branch,address:"  12 Lê Lợi  "});
  assert.deepEqual(addressOnly.columns,{name:"Địa chỉ giao hàng",address:"12 Lê Lợi"});
  const optionalName=parseCustomerLocation({branchId:branch,address:"23 Pasteur",name:"   "});
  assert.deepEqual(optionalName.columns,{name:"Địa chỉ giao hàng",address:"23 Pasteur"});
  assert.equal(nextCustomerLocationCode([]),"DC0001");
  assert.equal(nextCustomerLocationCode(["CH01","DC0001","DC0002"]),"DC0003");
  const update=parseCustomerLocation({branchId:branch,active:false},true);
  assert.deepEqual(update.columns,{active:false,is_default:false});
  for(const invalid of [
    {branchId:branch,code:"CH01",name:"Store",address:"A",installationId:branch},
    {branchId:branch,code:"CH01",name:"Store",address:"A",phone:"123"},
  ])assert.throws(()=>parseCustomerLocation(invalid),CustomerLocationFault);
});
test("CSV: explicit group clear cannot keep old category; omitted group can",()=>{
 const refs={
  taxonomyReady:true,
  groups:new Map([["TAP",{id:group,code:"TAP",brandId:brand,active:true}]]),
  categories:new Map([["F04NA",{id:category,groupId:group,brandId:brand,active:true,groupActive:true}]]),
  brands:new Map([["NATURE",{id:brand,active:true}]]),
  regions:new Map(),units:new Map(),products:new Map(),lists:new Map(),productUnits:new Map(),
 };
 const current={id:"item1",code:"TAP01",name:"Nature",groupId:group,
   categoryId:category,baseUnit:"Cuốn",active:true,revision:0};
 assert.throws(()=>normalizeRow("products","UPDATE",
   {groupCode:"",categoryCode:"F04NA"},current,refs,branch),
   (e)=>e instanceof BulkFault&&e.code==="CATEGORY_GROUP_MISMATCH");
 const unchanged=normalizeRow("products","UPDATE",
   {categoryCode:"F04NA"},current,refs,branch);
 assert.equal(unchanged.operation.categoryId,category);
 assert.equal(Object.hasOwn(unchanged.operation,"groupId"),false);
 const cleared=normalizeRow("products","UPDATE",
   {groupCode:""},current,refs,branch);
 assert.equal(cleared.operation.groupId,null);
 assert.equal(cleared.operation.categoryId,null);
 assert.throws(()=>normalizeRow("products","UPDATE",
   {groupCode:"",brandCode:"NATURE"},current,refs,branch),
   (e)=>e instanceof BulkFault&&e.code==="BRAND_GROUP_MISMATCH");
 const sameBrand=normalizeRow("products","UPDATE",
   {brandCode:"NATURE"},current,refs,branch);
 assert.equal(sameBrand.after.brandCode,"NATURE");
 assert.equal(Object.hasOwn(sameBrand.operation,"groupId"),false);
});

test("product CSV/XLSX mapping recognizes Vietnamese brand and category codes",()=>{
  const fields=bulkColumns("products");
  assert.ok(fields.includes("brandCode")&&fields.includes("categoryCode"));
  const mapping=suggestBulkMapping("products",["Mã sản phẩm","Nhãn hàng","Mã danh mục"]);
  assert.equal(mapping.code,"Mã sản phẩm");
  assert.equal(mapping.brandCode,"Nhãn hàng");
  assert.equal(mapping.categoryCode,"Mã danh mục");
});

test("PG16+: nested categories forbid cycles, wrong group and multiple defaults",{
  skip:!process.env.DATABASE_URL
},async()=>{
  const base=process.env.DATABASE_URL!;
  const admin=new Pool({connectionString:base,max:1});
  const name="erp_catalog_tree_"+randomUUID().replaceAll("-","").slice(0,12);
  let db:Pool|null=null;
  try{
    await admin.query('CREATE DATABASE "'+name+'"');
    const uri=new URL(base);uri.pathname="/"+name;
    db=new Pool({connectionString:uri.toString(),max:2});
    // A forced isolated-DB teardown can terminate idle pg clients in the pool.
    // Other integration suites install this handler to avoid uncaught events.
    db.on('error',()=>{});
    const migrated=await applyMigrations(db,resolve(process.cwd(),"db/migrations"));
    assert.equal(migrated.applied.length,28);
    const installation=(await db.query<{id:string}>(`
      INSERT INTO installation(code,display_name) VALUES($1,$2) RETURNING id`,
      ["tree-"+randomUUID().slice(0,8),"Tree test"])).rows[0]!.id;
    const branchId=(await db.query<{id:string}>(`
      INSERT INTO branch(installation_id,code,name)
      VALUES($1,'MAIN','Main') RETURNING id`,[installation])).rows[0]!.id;
    const brandId=(await db.query<{id:string}>(`
      INSERT INTO catalog_brand(installation_id,branch_id,code,name)
      VALUES($1,$2,'NATURE','Nature') RETURNING id`,
      [installation,branchId])).rows[0]!.id;
    const groupId=(await db.query<{id:string}>(`
      INSERT INTO catalog_product_group(installation_id,branch_id,code,name,brand_id)
      VALUES($1,$2,'TAP','Tập HS/SV',$3) RETURNING id`,
      [installation,branchId,brandId])).rows[0]!.id;
    const otherGroupId=(await db.query<{id:string}>(`
      INSERT INTO catalog_product_group(installation_id,branch_id,code,name)
      VALUES($1,$2,'PAPER','Giấy') RETURNING id`,
      [installation,branchId])).rows[0]!.id;
    const parentId=(await db.query<{id:string}>(`
      INSERT INTO catalog_product_category(installation_id,branch_id,group_id,code,name)
      VALUES($1,$2,$3,'F04','100gsm') RETURNING id`,
      [installation,branchId,groupId])).rows[0]!.id;
    const childId=(await db.query<{id:string}>(`
      INSERT INTO catalog_product_category(installation_id,branch_id,group_id,parent_id,code,name)
      VALUES($1,$2,$3,$4,'F04NA','Nature') RETURNING id`,
      [installation,branchId,groupId,parentId])).rows[0]!.id;
    await assert.rejects(db.query(`
      UPDATE catalog_product_category SET parent_id=$4
      WHERE installation_id=$1 AND branch_id=$2 AND id=$3`,
      [installation,branchId,parentId,childId]),{code:"23514"});
    await assert.rejects(db.query(`
      INSERT INTO catalog_product_category(installation_id,branch_id,group_id,parent_id,code,name)
      VALUES($1,$2,$3,$4,'BAD','Sai nhóm')`,
      [installation,branchId,otherGroupId,parentId]),{code:"23503"});
    const customerId=(await db.query<{id:string}>(`
      INSERT INTO catalog_customer(installation_id,branch_id,code,name)
      VALUES($1,$2,'KH01','Khách nhiều cửa hàng') RETURNING id`,
      [installation,branchId])).rows[0]!.id;
    await db.query(`
      INSERT INTO catalog_customer_location
      (installation_id,branch_id,customer_id,code,name,address,is_default)
      VALUES($1,$2,$3,'CH01','Cửa hàng 1','Số 1',true)`,
      [installation,branchId,customerId]);
    await assert.rejects(db.query(`
      INSERT INTO catalog_customer_location
      (installation_id,branch_id,customer_id,code,name,address,is_default)
      VALUES($1,$2,$3,'CH02','Cửa hàng 2','Số 2',true)`,
      [installation,branchId,customerId]),{code:"23505"});
    await db.query(`
      INSERT INTO catalog_customer_location
      (installation_id,branch_id,customer_id,code,name,address)
      VALUES($1,$2,$3,'CH02','Cửa hàng 2','Số 2')`,
      [installation,branchId,customerId]);
    const total=await db.query<{n:string}>(`
      SELECT count(*)::text AS n FROM catalog_customer_location
      WHERE installation_id=$1 AND branch_id=$2 AND customer_id=$3`,
      [installation,branchId,customerId]);
    assert.equal(total.rows[0]!.n,"2");
  }finally{
    if(db)await db.end();
    await admin.query('DROP DATABASE IF EXISTS "'+name+'" WITH (FORCE)');
    await admin.end();
  }
});
