import test from "node:test";
import assert from "node:assert/strict";
import { buildApp } from "./server.ts";
import type { AddressInfo } from "node:net";

test("Cutover maintenance denies all state-changing requests before auth/catalog handlers",async()=>{
 const server=buildApp(async()=>true,async()=>true,{pool:null},true);
 await new Promise<void>(ok=>server.listen(0,"127.0.0.1",ok));
 try{
  const base="http://127.0.0.1:"+(server.address() as AddressInfo).port;
  const live=await fetch(base+"/health/live");
  assert.equal(((await live.json()) as {maintenance:boolean}).maintenance,true);
  for(const [method,path] of [
   ["POST","/v1/auth/login"],["POST","/v1/catalog/customers"],
   ["PATCH","/v1/catalog/customers/deadbeef"],["DELETE","/v1/orders"],
   ["PUT","/v1/admin/users"],
  ]){
   const response=await fetch(base+path,{method});
   assert.equal(response.status,503,method+" "+path);
   assert.equal(((await response.json()) as {error:{code:string}}).error.code,"MAINTENANCE");
  }
  const read=await fetch(base+"/v1/meta/modules");
  assert.equal(read.status,200);
 }finally{await new Promise<void>((ok,fail)=>server.close(e=>e?fail(e):ok()));}
});

test("Normal release leaves maintenance gate disabled",async()=>{
 const server=buildApp(async()=>false,async()=>false,{pool:null},false);
 await new Promise<void>(ok=>server.listen(0,"127.0.0.1",ok));
 try{
  const base="http://127.0.0.1:"+(server.address() as AddressInfo).port;
  const live=await fetch(base+"/health/live");
  assert.equal(((await live.json()) as {maintenance:boolean}).maintenance,false);
  const r=await fetch(base+"/v1/orders",{method:"POST"});
  assert.equal(r.status,501,"Normal releases still preserve business API contract");
 }finally{await new Promise<void>((ok,fail)=>server.close(e=>e?fail(e):ok()));}
});
