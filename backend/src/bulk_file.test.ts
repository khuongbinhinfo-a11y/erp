import test from "node:test";
import assert from "node:assert/strict";
import { deflateRawSync } from "node:zlib";
import { csvRows,parseBulkFile,bulkCsv,BulkFileFault } from "./bulk_file.ts";
import { bulkColumns,suggestBulkMapping,checkBulkInput } from "./bulk_plan.ts";

function workbook(sheet:string,shared:string,relTarget="worksheets/sheet1.xml"):Buffer{
 const entries=[
  {name:"xl/workbook.xml",text:'<?xml version="1.0"?><workbook xmlns:r="urn:rels"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>'},
  {name:"xl/_rels/workbook.xml.rels",text:'<Relationships><Relationship Id="rId1" Target="'+relTarget+'"/></Relationships>'},
  {name:"xl/worksheets/sheet1.xml",text:sheet},
  {name:"xl/sharedStrings.xml",text:shared},
 ];
 const locals:Buffer[]=[],central:Buffer[]=[];
 let offset=0;
 for(const e of entries){
  const name=Buffer.from(e.name),raw=Buffer.from(e.text),deflated=deflateRawSync(raw);
  const local=Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50,0);
  local.writeUInt16LE(20,4);
  local.writeUInt16LE(8,8);
  local.writeUInt32LE(deflated.length,18);
  local.writeUInt32LE(raw.length,22);
  local.writeUInt16LE(name.length,26);
  locals.push(local,name,deflated);
  const c=Buffer.alloc(46);
  c.writeUInt32LE(0x02014b50,0);
  c.writeUInt16LE(20,4);c.writeUInt16LE(20,6);
  c.writeUInt16LE(8,10);
  c.writeUInt32LE(deflated.length,20);
  c.writeUInt32LE(raw.length,24);
  c.writeUInt16LE(name.length,28);
  c.writeUInt32LE(offset,42);
  central.push(c,name);
  offset+=local.length+name.length+deflated.length;
 }
 const directory=Buffer.concat(central);
 const end=Buffer.alloc(22);
 end.writeUInt32LE(0x06054b50,0);
 end.writeUInt16LE(entries.length,8);
 end.writeUInt16LE(entries.length,10);
 end.writeUInt32LE(directory.length,12);
 end.writeUInt32LE(offset,16);
 return Buffer.concat([...locals,directory,end]);
}
const shared='<sst><si><t>Mã khách hàng</t></si><si><t>Tên khách hàng</t></si>'+
 '<si><t>KH-SI</t></si><si><r><t>Khách </t></r><r><t>sỉ</t></r></si></sst>';
const sheet='<worksheet><sheetData>'+
 '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'+
 '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="s"><v>3</v></c></row>'+
 '</sheetData></worksheet>';

test("R1-B CSV: quoted semicolon cells, BOM and multiple lines are preserved",()=>{
 const rows=csvRows('\uFEFF"Mã khách hàng";"Tên khách"\r\nKH-01;"Khách, lẻ"\r\nKH-02;"Đại lý ""A""\nMỹ Tho"\r\n');
 assert.deepEqual(rows,[["Mã khách hàng","Tên khách"],["KH-01","Khách, lẻ"],
  ["KH-02",'Đại lý "A"\nMỹ Tho']]);
 const parsed=parseBulkFile("khach.csv",Buffer.from("code,name\nKH-01,Ông A\n").toString("base64"));
 assert.equal(parsed.rowCount,1);
 assert.deepEqual(parsed.headers,["code","name"]);
 const noHeader=parseBulkFile("data.csv",Buffer.from("KH-01,Ông A").toString("base64"),false);
 assert.deepEqual(noHeader.headers,["A","B"]);
 assert.deepEqual(noHeader.rows,[["KH-01","Ông A"]]);
});
test("R1-B XLSX: ZIP deflate first sheet, shared rich strings, Unicode, no formulas",()=>{
 const encoded=workbook(sheet,shared).toString("base64");
 const parsed=parseBulkFile("khach.xlsx",encoded);
 assert.deepEqual(parsed.headers,["Mã khách hàng","Tên khách hàng"]);
 assert.deepEqual(parsed.rows,[["KH-SI","Khách sỉ"]]);
 const rootRelative=workbook(sheet,shared,"/xl/worksheets/sheet1.xml");
 assert.equal(parseBulkFile("khach.xlsx",rootRelative.toString("base64")).rowCount,1);
 const formulas=sheet.replace('<c r="A2" t="s"><v>2</v></c>',
  '<c r="A2"><f>HYPERLINK("https://example.test")</f><v>2</v></c>');
 assert.throws(()=>parseBulkFile("bad.xlsx",workbook(formulas,shared).toString("base64")),
  /XLSX_FORMULAS_UNSUPPORTED/);
 assert.throws(()=>parseBulkFile("bad.xlsx",workbook(sheet,shared,"../custom.xml").toString("base64")),
  /INVALID_XLSX_SHEET_LINK/);
});
test("R1-B: invalid encoding, duplicate headers, formula-injection-safe CSV export",()=>{
 const to64=(s:string)=>Buffer.from(s).toString("base64");
 assert.throws(()=>parseBulkFile("malicious.xls",to64("csv")),/INVALID_FILE_TYPE/);
 assert.throws(()=>parseBulkFile("duplicate.csv",to64("code,code\nA,B")),/DUPLICATE_HEADERS/);
 assert.throws(()=>parseBulkFile("empty.csv",to64("code,name")),/FILE_ROW_LIMIT/);
 assert.throws(()=>parseBulkFile("bad.csv","***"),/INVALID_FILE_ENCODING/);
 assert.match(bulkCsv(["code","name"],[["=1+2",'a"b'],["@HYPERLINK","text"]]),
  /'=1\+2/);
 assert.match(bulkCsv(["code","name"],[["=1+2",'a"b']]),/"a""b"/);
});
test("R1-B: aliases and key-based mapping reject unmapped/ambiguous lookups",()=>{
 assert.deepEqual(suggestBulkMapping("customers",["Mã KH","Tên khách","Mã khu vực"]),{
  code:"Mã KH",name:"Tên khách",customerRegionCode:"Mã khu vực",
 });
 assert.ok(bulkColumns("skus").includes("reason"));
 const base={branchId:"00000000-0000-4000-8000-000000000001",
  resource:"customers",mode:"UPSERT",fileName:"khach.csv",
  contentBase64:Buffer.from("Mã KH,Tên khách\nC-1,A").toString("base64"),
  hasHeader:true,mapping:{code:"Mã KH",name:"Tên khách"}};
 assert.equal(checkBulkInput(base).mode,"UPSERT");
 assert.throws(()=>checkBulkInput({...base,mapping:{name:"Tên khách"}}),/MISSING_KEY_MAPPING/);
 assert.throws(()=>checkBulkInput({...base,mapping:{code:"Mã KH",name:"Mã KH"}}),
  /DUPLICATE_COLUMN_MAPPING/);
 assert.throws(()=>checkBulkInput({...base,resource:"stocktakes"}),/INVALID_BULK_KIND/);
});
