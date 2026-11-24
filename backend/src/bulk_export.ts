import { deflateRawSync } from "node:zlib";
import { bulkCsv } from "./bulk_file.ts";
import { bulkColumns,type BulkResource } from "./bulk_plan.ts";

/** Stable field keys remain in API contracts; file headers are localized. */
const VI:Record<BulkResource,Record<string,string>>={
 customers:{
  code:"Mã khách hàng",name:"Tên khách hàng",
  customerGroupCode:"Mã nhóm khách",customerRegionCode:"Mã khu vực",
  phone:"Số điện thoại",deliveryAddress:"Địa chỉ giao hàng",
  paymentTermsDays:"Số ngày công nợ",active:"Trạng thái",
 },
 products:{
  code:"Mã sản phẩm",name:"Tên sản phẩm",baseUnit:"Mã đơn vị gốc",
  groupCode:"Mã nhóm hàng",barcode:"Mã vạch gốc",active:"Trạng thái",
 },
 skus:{
  code:"Mã SKU",productCode:"Mã sản phẩm",unitCode:"Mã đơn vị",
  toBase:"Hệ số quy đổi",active:"Trạng thái",reason:"Lý do ngừng",
 },
 prices:{
  priceListCode:"Mã bảng giá",productCode:"Mã sản phẩm",
  name:"Tên hàng",unitCode:"Đơn vị",
  amount:"Đơn giá",discountRate:"Chiết khấu %",effectiveAt:"Hiệu lực từ",
 },
};
const TITLES:Record<BulkResource,string>={
 customers:"khach-hang",products:"san-pham",skus:"sku-ban",prices:"bang-gia",
};
export function bulkVietnameseHeaders(kind:BulkResource):string[]{
 return bulkColumns(kind).map(field=>VI[kind][field]!);
}
function escapeXml(value:string):string {
 return value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g,"")
  .replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;")
  .replaceAll('"',"&quot;").replaceAll("'","&apos;");
}
function col(n:number):string{
 let s="";for(let i=n+1;i>0;){i--;s=String.fromCharCode(65+i%26)+s;i=Math.floor(i/26);}return s;
}
function crc32(bytes:Buffer):number{
 let crc=-1;
 for(const byte of bytes){crc^=byte;for(let i=0;i<8;i++)crc=(crc>>>1)^(-(crc&1)&0xedb88320);}
 return (crc^(-1))>>>0;
}
/** Minimal ZIP archive: no scripts, macros, external links or formulas. */
function zip(files:{path:string;body:string}[]):Buffer{
 const local:Buffer[]=[],central:Buffer[]=[];let offset=0;
 for(const file of files){
  const name=Buffer.from(file.path,"utf8"),raw=Buffer.from(file.body,"utf8");
  const packed=deflateRawSync(raw),crc=crc32(raw);
  const head=Buffer.alloc(30);head.writeUInt32LE(0x04034b50,0);
  head.writeUInt16LE(20,4);head.writeUInt16LE(0x800,6);
  head.writeUInt16LE(8,8);head.writeUInt32LE(crc,14);
  head.writeUInt32LE(packed.length,18);head.writeUInt32LE(raw.length,22);
  head.writeUInt16LE(name.length,26);
  local.push(head,name,packed);
  const dir=Buffer.alloc(46);dir.writeUInt32LE(0x02014b50,0);
  dir.writeUInt16LE(20,4);dir.writeUInt16LE(20,6);
  dir.writeUInt16LE(0x800,8);dir.writeUInt16LE(8,10);
  dir.writeUInt32LE(crc,16);dir.writeUInt32LE(packed.length,20);
  dir.writeUInt32LE(raw.length,24);dir.writeUInt16LE(name.length,28);
  dir.writeUInt32LE(offset,42);central.push(dir,name);
  offset+=head.length+name.length+packed.length;
 }
 const directory=Buffer.concat(central),end=Buffer.alloc(22);
 end.writeUInt32LE(0x06054b50,0);end.writeUInt16LE(files.length,8);
 end.writeUInt16LE(files.length,10);end.writeUInt32LE(directory.length,12);
 end.writeUInt32LE(offset,16);
 return Buffer.concat([...local,directory,end]);
}
const xml='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
const styles=xml+
 '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'+
 '<numFmts count="2"><numFmt numFmtId="164" formatCode="#,##0.####"/>'+
 '<numFmt numFmtId="165" formatCode="#,##0.00"/></numFmts>'+
 '<fonts count="2"><font><sz val="11"/><name val="Aptos"/></font>'+
 '<font><b/><sz val="11"/><color rgb="FF164E35"/><name val="Aptos"/></font></fonts>'+
 '<fills count="2"><fill><patternFill patternType="none"/></fill>'+
 '<fill><patternFill patternType="solid"><fgColor rgb="FFE8F3EB"/>'+
 '<bgColor indexed="64"/></patternFill></fill></fills>'+
 '<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border>'+
 '<border><left/><right/><top/><bottom style="thin"><color rgb="FFBCD8C2"/></bottom>'+
 '<diagonal/></border></borders>'+
 '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'+
 '<cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'+
 '<xf numFmtId="0" fontId="1" fillId="1" borderId="1" xfId="0" applyFill="1" applyFont="1" applyBorder="1"/>'+
 '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'+
 '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>'+
 '</styleSheet>';
function excelCell(field:string,value:string,address:string,header=false):string{
 if(header)return '<c r="'+address+'" s="1" t="inlineStr"><is><t>'+escapeXml(value)+'</t></is></c>';
 // Numeric literals are validated by the import preview before any database write.
 // Never convert identifiers/phone/barcodes to numbers, even if all digits.
 // Excel numbers are limited to 15 significant decimal digits. Store high-
 // precision monetary and conversion values as text so save/reimport is lossless.
 const significantDigits=value.replace(/\D/g,"").replace(/^0+/,"").length;
 const numeric=["amount","discountRate","toBase","paymentTermsDays"].includes(field)&&
  /^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/.test(value)&&significantDigits<=15;
 if(numeric)return '<c r="'+address+'" s="'+(field==="amount"?"3":"2")+'"><v>'+value+'</v></c>';
 return '<c r="'+address+'" t="inlineStr"><is><t xml:space="preserve">'+
   escapeXml(value)+'</t></is></c>';
}
export function bulkXlsx(kind:BulkResource,rows:string[][],fields=bulkColumns(kind)):Buffer{
 const headers=fields.map(field=>VI[kind][field]!);
 if(rows.length>5000)throw new Error("EXPORT_ROW_LIMIT");
 const records=[headers,...rows].map((values,i)=>
  '<row r="'+(i+1)+'"'+(i===0?' ht="27" customHeight="1"':'')+'>'+
  values.map((value,j)=>excelCell(fields[j]!,String(value??""),col(j)+(i+1),i===0)).join("")+
  '</row>').join("");
 const end=col(fields.length-1);
 const widths=fields.map((field,i)=>'<col min="'+(i+1)+'" max="'+(i+1)+'" width="'+
  Math.min(38,Math.max(16,headers[i]!.length+6,field==="name"?36:0))+
  '" customWidth="1"/>').join("");
 const sheet=xml+'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'+
  '<dimension ref="A1:'+end+Math.max(1,rows.length+1)+'"/>'+
  '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'+
  '<sheetFormatPr defaultRowHeight="17"/><cols>'+widths+'</cols>'+
  '<sheetData>'+records+'</sheetData><autoFilter ref="A1:'+end+Math.max(1,rows.length+1)+'"/></worksheet>';
 const workbook=xml+'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '+
  'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'+
  '<sheets><sheet name="Danh muc" sheetId="1" r:id="rId1"/></sheets></workbook>';
 const rels=xml+'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+
  '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'+
  '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>';
 const types=xml+'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'+
  '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'+
  '<Default Extension="xml" ContentType="application/xml"/>'+
  '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'+
  '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'+
  '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>';
 const rootRels=xml+'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+
  '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>';
 return zip([{path:"[Content_Types].xml",body:types},{path:"_rels/.rels",body:rootRels},
  {path:"xl/workbook.xml",body:workbook},{path:"xl/_rels/workbook.xml.rels",body:rels},
  {path:"xl/worksheets/sheet1.xml",body:sheet},{path:"xl/styles.xml",body:styles}]);
}
export function bulkExport(kind:BulkResource,rows:string[][],format:"csv"|"xlsx",
 template=false,at=new Date(),selectedList=false){
 const stem=(template?"mau-":"xuat-")+TITLES[kind]+"-"+at.toISOString().slice(0,10);
 const columns=selectedList&&kind==="prices"?["productCode","name","unitCode","amount","discountRate","effectiveAt"]:bulkColumns(kind);
 const headers=columns.map(field=>VI[kind][field]!);
 if(format==="xlsx")return {
  fileName:stem+".xlsx",format,columns,headers,contentBase64:bulkXlsx(kind,rows,columns).toString("base64"),
  total:rows.length,
 };
 return {fileName:stem+".csv",format,columns,headers,
  content:"\uFEFF"+bulkCsv(headers,rows),total:rows.length};
}
