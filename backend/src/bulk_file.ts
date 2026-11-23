import { inflateRawSync } from "node:zlib";

/** Bounded, dependency-free CSV/XLSX reader: formulas/macros are never executed. */
export class BulkFileFault extends Error {
 readonly code:string;readonly status:number;
 constructor(code:string,status=400){super(code);this.code=code;this.status=status;}
}
const ROW_LIMIT=5000,FILE_LIMIT=6*1024*1024,TEXT_LIMIT=16*1024*1024;
const decoder=new TextDecoder("utf-8",{fatal:true});
function utf8(buf:Buffer):string{
 try{return decoder.decode(buf);}catch{throw new BulkFileFault("INVALID_UTF8");}
}
export function csvRows(text:string):string[][]{
 if(text.charCodeAt(0)===0xfeff)text=text.slice(1);
 const first=text.split(/\r?\n/,1)[0]??"";
 const count=(char:string)=>{let n=0,inQuote=false;for(const ch of first){
  if(ch==='"')inQuote=!inQuote;
  if(ch===char&&!inQuote)n++;
 }return n;};
 const delimiter=[",",";","\t"].sort((a,b)=>count(b)-count(a))[0]!;
 const rows:string[][]=[];let cells:string[]=[],cell="",quoted=false,closed=false;
 for(let i=0;i<text.length;i++){
  const c=text[i]!;
  if(c==="\u0000")throw new BulkFileFault("INVALID_FILE_NUL");
  if(quoted){
   if(c==='"'&&text[i+1]==='"'){cell+='"';i++;continue;}
   if(c==='"'){quoted=false;closed=true;continue;}
   cell+=c;continue;
  }
  if(c==='"'&&cell.length===0&&!closed){quoted=true;continue;}
  if(c==='"')throw new BulkFileFault("INVALID_CSV_QUOTING");
  if(c===delimiter){cells.push(cell);cell="";closed=false;continue;}
  if(c==="\r"||c==="\n"){
   if(c==="\r"&&text[i+1]==="\n")i++;
   cells.push(cell);cell="";closed=false;
   if(cells.some(x=>x.trim()!==""))rows.push(cells);
   if(rows.length>ROW_LIMIT+1)throw new BulkFileFault("FILE_ROW_LIMIT",413);
   cells=[];continue;
  }
  if(closed)throw new BulkFileFault("INVALID_CSV_QUOTING");
  cell+=c;
  if(cell.length>8192)throw new BulkFileFault("CELL_TOO_LONG",413);
 }
 if(quoted)throw new BulkFileFault("INVALID_CSV_QUOTING");
 cells.push(cell);
 if(cells.some(x=>x.trim()!==""))rows.push(cells);
 if(rows.length>ROW_LIMIT+1)throw new BulkFileFault("FILE_ROW_LIMIT",413);
 return rows;
}

type Entry={name:string;method:number;length:number;compressed:number;offset:number;flags:number};
function zipEntries(file:Buffer):Map<string,Entry>{
 if(file.length<22)throw new BulkFileFault("INVALID_XLSX");
 let eocd=-1;
 for(let at=file.length-22;at>=Math.max(0,file.length-65557);at--){
  if(file.readUInt32LE(at)===0x06054b50){eocd=at;break;}
 }
 if(eocd<0)throw new BulkFileFault("INVALID_XLSX");
 const count=file.readUInt16LE(eocd+10),size=file.readUInt32LE(eocd+12),
  start=file.readUInt32LE(eocd+16);
 if(count>3000||start+size>file.length||count===0)
  throw new BulkFileFault("INVALID_XLSX_ARCHIVE");
 let pos=start;const found=new Map<string,Entry>();
 for(let i=0;i<count;i++){
  if(pos+46>file.length||file.readUInt32LE(pos)!==0x02014b50)
   throw new BulkFileFault("INVALID_XLSX_ARCHIVE");
  const flags=file.readUInt16LE(pos+8),method=file.readUInt16LE(pos+10),
   compressed=file.readUInt32LE(pos+20),length=file.readUInt32LE(pos+24),
   nl=file.readUInt16LE(pos+28),extra=file.readUInt16LE(pos+30),
   comment=file.readUInt16LE(pos+32),offset=file.readUInt32LE(pos+42);
  if(pos+46+nl+extra+comment>file.length||flags&1||!(method===0||method===8))
   throw new BulkFileFault("UNSUPPORTED_XLSX_ARCHIVE");
  const name=utf8(file.subarray(pos+46,pos+46+nl));
  if(name.includes("..")||name.startsWith("/")||name.includes("\\"))
   throw new BulkFileFault("INVALID_XLSX_PATH");
  if(length>TEXT_LIMIT||compressed>FILE_LIMIT)
   throw new BulkFileFault("XLSX_ZIP_BOMB",413);
  found.set(name,{name,method,length,compressed,offset,flags});
  pos+=46+nl+extra+comment;
 }
 return found;
}
function zipRead(file:Buffer,entry:Entry):string{
 const p=entry.offset;
 if(p+30>file.length||file.readUInt32LE(p)!==0x04034b50)
  throw new BulkFileFault("INVALID_XLSX_LOCAL_HEADER");
 const nameLen=file.readUInt16LE(p+26),extraLen=file.readUInt16LE(p+28),
  at=p+30+nameLen+extraLen;
 if(at+entry.compressed>file.length)throw new BulkFileFault("INVALID_XLSX_DATA");
 const zipped=file.subarray(at,at+entry.compressed);
 let buffer:Buffer;
 try{buffer=entry.method===8
   ?inflateRawSync(zipped,{maxOutputLength:TEXT_LIMIT}):zipped;}
 catch{throw new BulkFileFault("XLSX_DECOMPRESSION_FAILED");}
 if(buffer.length!==entry.length)throw new BulkFileFault("XLSX_SIZE_MISMATCH");
 return utf8(buffer);
}
function entities(raw:string):string{
 return raw.replace(/&(?:amp|lt|gt|quot|apos|#x[0-9a-fA-F]+|#[0-9]+);/g,(t)=>{
  const k=t.slice(1,-1);
  switch(k){case "amp":return "&";case "lt":return "<";case "gt":return ">";
   case "quot":return '"';case "apos":return "'";}
  const point=k.startsWith("#x")?parseInt(k.slice(2),16):parseInt(k.slice(1),10);
  return point>=0&&point<=0x10ffff&&!(point>=0xd800&&point<=0xdfff)
    ?String.fromCodePoint(point):"";
 });
}
function innerText(xml:string):string{
 let s="";for(const m of xml.matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g))
  s+=entities(m[1]??"");
 return s;
}
function xmlRows(file:Buffer):string[][]{
 const dir=zipEntries(file);
 if(!dir.has("xl/workbook.xml")||!dir.has("xl/_rels/workbook.xml.rels"))
  throw new BulkFileFault("INVALID_XLSX");
 const wb=zipRead(file,dir.get("xl/workbook.xml")!);
 const rels=zipRead(file,dir.get("xl/_rels/workbook.xml.rels")!);
 const first=/<sheet\b[^>]*r:id="([^"]+)"[^>]*\/?>/i.exec(wb)?.[1];
 if(!first)throw new BulkFileFault("XLSX_NO_WORKSHEET");
 const relationship=[...rels.matchAll(/<Relationship\b[^>]*\/?>/g)]
  .map(m=>m[0]).find(s=>/\bId="([^"]+)"/.exec(s)?.[1]===first);
 const target=relationship?/\bTarget="([^"]+)"/.exec(relationship)?.[1]:undefined;
 if(!target||target.includes("..")||target.includes("\\"))
  throw new BulkFileFault("INVALID_XLSX_SHEET_LINK");
 const relative=target.replace(/^\//,"");
 const sheet=relative.startsWith("xl/")?relative:"xl/"+relative;
 const entry=dir.get(sheet);
 if(!entry)throw new BulkFileFault("XLSX_SHEET_MISSING");
 const xml=zipRead(file,entry);
 const strs=dir.get("xl/sharedStrings.xml")?zipRead(file,dir.get("xl/sharedStrings.xml")!):"";
 const shared=[...strs.matchAll(/<si(?:\s[^>]*)?>([\s\S]*?)<\/si>/g)]
  .map(m=>innerText(m[1]??""));
 const out:string[][]=[];
 const indices=(col:string)=>{let n=0;for(const c of col)n=n*26+c.charCodeAt(0)-64;return n-1;};
 for(const row of xml.matchAll(/<row\b[^>]*>([\s\S]*?)<\/row>/g)){
  const cells:string[]=[];let cursor=0;
  for(const m of (row[1]??"").matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)){
   const attrs=m[1]??"",body=m[2]??"";
   const reference=/\br="([A-Z]+)[0-9]+"/.exec(attrs)?.[1];
   const at=reference?indices(reference):cursor;
   if(at<0||at>100)throw new BulkFileFault("TOO_MANY_COLUMNS",413);
   if(/<f(?:\s|>)/.test(body))throw new BulkFileFault("XLSX_FORMULAS_UNSUPPORTED");
   const type=/\bt="([^"]+)"/.exec(attrs)?.[1];
   let value:string;
   if(type==="inlineStr")value=innerText(body);
   else{
    const stored=/<v(?:\s[^>]*)?>([\s\S]*?)<\/v>/.exec(body)?.[1]??"";
    value=type==="s"?shared[Number(stored)]??"":entities(stored);
   }
   if(value.length>8192)throw new BulkFileFault("CELL_TOO_LONG",413);
   cells[at]=value;cursor=at+1;
  }
  if(cells.some(x=>(x??"").trim()!==""))out.push(Array.from(cells,x=>x??""));
  if(out.length>ROW_LIMIT+1)throw new BulkFileFault("FILE_ROW_LIMIT",413);
 }
 return out;
}
export type ParsedBulkFile={headers:string[];rows:string[][];firstLine:number;rowCount:number};
export function parseBulkFile(fileName:string,contentBase64:string,hasHeader=true):ParsedBulkFile{
 if(!/\.(csv|xlsx)$/i.test(fileName)||fileName.length>180)
  throw new BulkFileFault("INVALID_FILE_TYPE");
 if(!/^[A-Za-z0-9+/]*={0,2}$/.test(contentBase64)||contentBase64.length>FILE_LIMIT*4/3+8)
  throw new BulkFileFault("INVALID_FILE_ENCODING",413);
 const file=Buffer.from(contentBase64,"base64");
 if(file.length===0||file.length>FILE_LIMIT)
  throw new BulkFileFault("FILE_SIZE_LIMIT",413);
 const rows=/\.csv$/i.test(fileName)?csvRows(utf8(file)):xmlRows(file);
 if(rows.length===0)throw new BulkFileFault("EMPTY_FILE");
 const width=Math.max(...rows.map(r=>r.length));
 if(width>100)throw new BulkFileFault("TOO_MANY_COLUMNS",413);
 const rawHeaders=hasHeader?rows.shift()!:Array.from({length:width},(_,i)=>{
  let j=i+1,name="";while(j>0){j--;name=String.fromCharCode(65+j%26)+name;j=Math.floor(j/26);}return name;
 });
 const headers=Array.from({length:width},(_,i)=>(rawHeaders[i]??"").trim()||"Cột "+(i+1));
 if(new Set(headers.map(x=>x.toLocaleLowerCase("vi"))).size!==headers.length)
  throw new BulkFileFault("DUPLICATE_HEADERS");
 if(rows.length===0||rows.length>ROW_LIMIT)throw new BulkFileFault("FILE_ROW_LIMIT",413);
 return {headers,rows:rows.map(r=>Array.from({length:width},(_,i)=>r[i]??"")),
  firstLine:hasHeader?2:1,rowCount:rows.length};
}
export function bulkCsv(columns:string[],rows:string[][]):string{
 const quote=(v:string)=>{
  const safe=/^[=+\-@\t\r]/.test(v)?"'"+v:v;
  return /[",\r\n]/.test(safe)?'"'+safe.replaceAll('"','""')+'"':safe;
 };
 return [columns,...rows].map(r=>r.map(quote).join(",")).join("\r\n")+"\r\n";
}
