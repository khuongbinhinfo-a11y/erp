import test from "node:test";
import assert from "node:assert/strict";
import {allocateDocumentDiscount,parseDocumentDiscount} from "./sales_document_discount.ts";
const line=(subtotal:string,taxRate="0")=>({subtotal,discountAmount:"0",taxRate,taxAmount:"0",lineTotal:subtotal});
test("discount conserves integer VND, ties follow line order and taxes follow allocated net",()=>{
 const input={mode:"TOTAL_AMOUNT" as const,value:"1001",reason:"test"};
 const result=allocateDocumentDiscount([line("10000","10"),line("20000","10")],input);
 assert.deepEqual(result.map(x=>x.discountAmount),["334","667"]);
 assert.deepEqual(result.map(x=>x.lineTotal),["10633","21266"]);
 const tie=allocateDocumentDiscount([line("1"),line("1"),line("1")],{...input,value:"2"});
 assert.deepEqual(tie.map(x=>x.discountAmount),["1","1","0"]);
 assert.equal(allocateDocumentDiscount([line("99999999999999999999")],{...input,mode:"PERCENT",value:"100"})[0]!.lineTotal,"0");
 assert.throws(()=>allocateDocumentDiscount([line("100")],input),/EXCEEDS/);
 assert.throws(()=>allocateDocumentDiscount([{...line("100"),discountAmount:"1"}],input),/MIXED/);
 assert.throws(()=>parseDocumentDiscount({...input,reason:""},true),/REASON/);
 assert.throws(()=>parseDocumentDiscount({...input,value:"1.2"},true),/INVALID/);
});
