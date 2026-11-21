// Protected release UAT: never log admin password or bearer token.
import assert from "node:assert/strict";
const mode=process.argv[2];
assert.ok(["freeze","ready"].includes(mode));
assert.equal(process.env.DEPLOY_OUTCOME,"succeeded");
const map=JSON.parse(process.env.DEPLOY_URLS||"{}");
const urls=Object.values(map).filter(x=>typeof x==="string"&&x.startsWith("https://"));
if(process.env.DEPLOY_URL?.startsWith("https://"))urls.push(process.env.DEPLOY_URL);
const bases=[...new Set(urls.map(x=>new URL(x).origin))];
assert.equal(bases.length,1,"Exact one deployed API origin expected");
const base=bases[0];
const origin=process.env.ERP_UI_ORIGIN||"https://erp-gustavjung24-ops-projects.vercel.app";
const fetchSafe=(path,init={})=>fetch(base+path,{
 ...init,headers:{origin,"cache-control":"no-store",...init.headers},
 signal:AbortSignal.timeout(15000)});
let live;
for(let i=0;i<12;i++){
 try{
  live=await fetchSafe("/health/live");
  if(live.status===200)break;
 }catch{}
 await new Promise(r=>setTimeout(r,1200));
}
assert.equal(live?.status,200,"Deployed API not live");
const body=await live.json();
assert.equal(body.status,"live");
assert.equal(body.maintenance,mode==="freeze","Wrong maintenance state");
// Always also probe the canonical production alias used by the Vercel frontend.
// A green one-off deployment URL must never be mistaken for a promoted live service.
const canonical="https://gh30k50bvsc0o9298w9leivf.sin.prisma.build";
let current;
for(let i=0;i<12;i++){
 try{
  const r=await fetch(canonical+"/health/live",{signal:AbortSignal.timeout(7000),
    headers:{"cache-control":"no-cache"}});
  if(r.status===200){
    current=await r.json();
    if(current?.maintenance===(mode==="freeze"))break;
  }
 }catch{}
 await new Promise(r=>setTimeout(r,1200));
}
assert.equal(current?.maintenance,mode==="freeze","Canonical production alias not promoted to expected state");
if(mode==="freeze"){
 const blocked=await fetchSafe("/v1/auth/login",{method:"POST",
  headers:{"content-type":"application/json"},
  body:JSON.stringify({loginName:"__maintenance_probe__",password:"invalid"})});
 assert.equal(blocked.status,503);
 assert.equal((await blocked.json()).error?.code,"MAINTENANCE");
 console.log("ERP_LIVE_MAINTENANCE_DENY_WRITES_PASS");
}else{
 const ready=await fetchSafe("/health/ready");
 assert.equal(ready.status,200);
 const pass=process.env.ADMIN_PASSWORD;
 assert.ok(pass?.length>=12,"Protected admin credential missing");
 const login=await fetchSafe("/v1/auth/login",{method:"POST",
  headers:{"content-type":"application/json"},
  body:JSON.stringify({loginName:"admin",password:pass})});
 assert.equal(login.status,200,"Real admin login failed");
 const token=(await login.json()).token;
 assert.match(token,/^[A-Za-z0-9_-]{43}$/);
 const branchId=process.env.ERP_BRANCH_ID;
 assert.match(branchId??"",/^[0-9a-f-]{36}$/);
 for(const name of ["customers","suppliers"]){
  const r=await fetchSafe("/v1/catalog/"+name+"?branchId="+encodeURIComponent(branchId),{
   headers:{authorization:"Bearer "+token}});
  assert.equal(r.status,200,name+" list not ready");
  const data=await r.json();
  assert.ok(Array.isArray(data.items),name+" JSON contract incorrect");
 }
 console.log("ERP_LIVE_TARGET_LOGIN_CUSTOMERS_SUPPLIERS_PASS");
}
