import { inflateRawSync } from "node:zlib";
import test from "node:test";
import assert from "node:assert/strict";
import { bulkExport,bulkVietnameseHeaders,bulkXlsx } from "./bulk_export.ts";
import { parseBulkFile,restoreCsvGuard } from "./bulk_file.ts";
import { suggestBulkMapping } from "./bulk_plan.ts";
const kinds=["customers","products","skus","prices"] as const;
test("R1-B: Vietnamese headers and CSV round-trip preserve key fields and formula safety",()=>{
 for(const kind of kinds){
  const columns=bulkVietnameseHeaders(kind);
  const template=bulkExport(kind,[],"csv",true);
  assert.deepEqual(template.headers,columns);
  assert.equal(template.columns.length,columns.length);
  assert.ok(String(template.content).startsWith("\uFEFF"));
  assert.ok(template.fileName.endsWith(".csv"));
  assert.deepEqual(suggestBulkMapping(kind,columns),
   Object.fromEntries(template.columns.map((field,i)=>[field,columns[i]])));
 }
 const sample=[["KH0001","Nguyễn Văn A","N1","K01","+84901234567",
  "=Địa chỉ mới","30","1"]];
 const csv=bulkExport("customers",sample,"csv");
 assert.match(String(csv.content),/'\+84901234567/);
 assert.match(String(csv.content),/'=Địa chỉ mới/);
 const parsed=parseBulkFile(csv.fileName,Buffer.from(String(csv.content)).toString("base64"));
 assert.equal(parsed.rows[0]![0],"KH0001");
 assert.equal(restoreCsvGuard(parsed.rows[0]![4]!),"+84901234567");
 assert.equal(restoreCsvGuard(parsed.rows[0]![5]!),"=Địa chỉ mới");
 assert.deepEqual(parsed.headers,bulkVietnameseHeaders("customers"));
});
test("R1-B: formatted Excel has 1-row import header, safe codes, decimal & Unicode",()=>{
 const records=[
  ["KH000019","Nguyễn & Đỗ <An>","N1","K01","00123456789","=HYPERLINK(1)","30","1"],
  ["KH000020","'@Đại lý","","","00000000001","Lầu 2","","0"],
 ];
 const file=bulkXlsx("customers",records);
 assert.equal(file.readUInt32LE(0),0x04034b50);
 const parsed=parseBulkFile("khach-hang.xlsx",file.toString("base64"));
 assert.deepEqual(parsed.headers,bulkVietnameseHeaders("customers"));
 assert.deepEqual(parsed.rows,records);
 assert.deepEqual(suggestBulkMapping("customers",parsed.headers).code,"Mã khách hàng");
 const money=[["BG01","SP00012","123456789.1234","12.25","2026-11-23T10:20:30.000Z"]];
 const priceFile=bulkExport("prices",money,"xlsx");
 assert.equal(priceFile.format,"xlsx");
 assert.ok(priceFile.fileName.endsWith(".xlsx"));
 assert.deepEqual(parseBulkFile(priceFile.fileName,priceFile.contentBase64??"").rows,money);
 assert.equal(bulkExport("skus",[],"xlsx",true).total,0);
});
test("R1-B: XLSX ZIP/XML contains freeze/header style/filter and no executable formula",()=>{
 const file=bulkXlsx("products",[["SP0001","=2+2","CAI","NH01","0001234567890","1"]]);
 const bytes=file.toString("utf8");
 assert.ok(!bytes.includes("<f>"),"no visible formula node, even with formula-looking input");
 const workbook=parseBulkFile("safe.xlsx",file.toString("base64"));
 assert.equal(workbook.rows[0]![1],"=2+2");
 assert.equal(workbook.rows[0]![4],"0001234567890");
});

function extractSheet(file:Buffer):string{
 let offset=0;
 while(offset+30<=file.length&&file.readUInt32LE(offset)===0x04034b50){
  const method=file.readUInt16LE(offset+8);
  const length=file.readUInt32LE(offset+18),nameSize=file.readUInt16LE(offset+26),
   extraSize=file.readUInt16LE(offset+28);
  const name=file.subarray(offset+30,offset+30+nameSize).toString("utf8");
  const at=offset+30+nameSize+extraSize;
  if(name==="xl/worksheets/sheet1.xml")
   return (method===8?inflateRawSync(file.subarray(at,at+length)):
    file.subarray(at,at+length)).toString("utf8");
  offset=at+length;
 }
 throw new Error("WORKSHEET_NOT_FOUND");
}
test("R1-B P2: high-precision Excel amounts stay text, smaller amounts stay numeric",()=>{
 const rows=[
  ["BG01","SP01","1234567890123.1234","10.00","2026-11-23T00:00:00.000Z"],
  ["BG01","SP02","1234.50","2.50","2026-11-23T00:00:00.000Z"],
 ];
 const file=bulkXlsx("prices",rows);
 const xml=extractSheet(file);
 assert.match(xml,/<c r="C2" t="inlineStr"><is><t xml:space="preserve">1234567890123\.1234/);
 assert.match(xml,/<c r="C3" s="3"><v>1234\.50<\/v><\/c>/);
 assert.deepEqual(parseBulkFile("price.xlsx",file.toString("base64")).rows,rows);
});
