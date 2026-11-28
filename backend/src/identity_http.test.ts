import test from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import type {AddressInfo} from "node:net";
import {Pool} from "pg";
import {resolve} from "node:path";
import {buildApp} from "./server.ts";
import {applyMigrations} from "./migrate.ts";
import {bootstrapInstallation} from "./bootstrap.ts";
import {isDatabaseReady} from "./db.ts";

const url=process.env.DATABASE_URL;
const localCi=(()=>{
  if(!url)return false;
  try{
    const u=new URL(url);
    return ["127.0.0.1","localhost"].includes(u.hostname)&&u.pathname==="/erp_ci";
  }catch{return false;}
})();
test("P0 auth HTTP: bootstrap once, login throttle, RBAC user grants, revoke, audit and lock",{
  skip:!localCi,
},async()=>{
  const base=new URL(url!);
  const adminDb=new Pool({connectionString:url,max:4});
  const name="erp_ci_auth_"+randomUUID().replaceAll("-","").slice(0,12);
  const uiOrigin="https://erp.example.test";
  const secret="private-ci-test-secret-"+randomUUID();
  let pool:Pool|null=null;
  try {
    await adminDb.query('CREATE DATABASE "'+name+'"');
    const tenantUrl=new URL(base);
    tenantUrl.pathname="/"+name;
    pool=new Pool({connectionString:tenantUrl.toString(),max:5,query_timeout:12000});
    pool.on("error",()=>{/* The test asserts request failures explicitly; avoid unhandled idle pool events. */});
    const mig=await applyMigrations(pool,resolve(process.cwd(),"db/migrations"));
    assert.equal(mig.applied.length,29);
    const pass="Admin-ci-"+randomUUID();
    const root=await bootstrapInstallation(pool,{
      code:"tenant-ci",displayName:"Synthetic CI Tenant",adminLogin:"admin_root",adminPassword:pass,
    });
    await assert.rejects(bootstrapInstallation(pool,{
      code:"another",displayName:"Should fail",adminLogin:"other_admin",adminPassword:pass,
    }),/INSTALLATION_ALREADY_INITIALIZED/);
    assert.equal(await isDatabaseReady(pool),true);
    const app=buildApp(()=>isDatabaseReady(pool!),async()=>true,{
      pool,installationId:root.installationId,allowedOrigin:uiOrigin,throttleSecret:secret,
    });
    await new Promise<void>(ok=>app.listen(0,"127.0.0.1",ok));
    try{
      const host="http://127.0.0.1:"+(app.address() as AddressInfo).port;
      const call=async(path:string,method="GET",body?:unknown,token?:string,extra:Record<string,string>={})=>{
        const headers:Record<string,string>={origin:uiOrigin,...extra};
        if(body!==undefined)headers["content-type"]="application/json";
        if(token)headers.authorization="Bearer "+token;
        const r=await fetch(host+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body)});
        return {status:r.status,body:await r.json() as Record<string,any>,
          headers:r.headers};
      };
      const config=await call("/v1/auth/config");
      assert.equal(config.status,200);
      assert.equal(config.headers.get("access-control-allow-origin"),uiOrigin);
      assert.equal((await call("/v1/auth/config","GET",undefined,undefined,{origin:"https://evil.example"})).status,403);
      assert.equal((await call("/v1/admin/users")).status,401,"anonymous admin denied");
      for(let i=0;i<5;i++){
        assert.equal((await call("/v1/auth/login","POST",{loginName:"not_a_user",password:pass})).status,401);
      }
      assert.equal((await call("/v1/auth/login","POST",{loginName:"not_a_user",password:pass})).status,429);
      const login=await call("/v1/auth/login","POST",{loginName:"admin_root",password:pass});
      assert.equal(login.status,200);
      const token=String(login.body.token);
      assert.equal(token.length,43);
      const session=await call("/v1/auth/session","GET",undefined,token);
      assert.equal(session.status,200);
      assert.equal(session.body.actorId,root.actorId);
      assert.equal(session.body.loginName,"admin_root","server owns canonical user label");
      assert.ok(Date.parse(session.body.expiresAt)>Date.now()+365*24*3600_000,
        "demo session remains valid across browser restarts, logout still revokes");
      assert.ok((session.body.grants as any[]).some(x=>x.permission==="identity.users.manage"));
      assert.ok((session.body.grants as any[]).some(x=>x.permission==="inventory.read"&&x.warehouseId===root.warehouseId));
      const org=await call("/v1/admin/organization","GET",undefined,token);
      assert.equal(org.status,200);
      assert.deepEqual(org.body.organization,{code:"tenant-ci",displayName:"Synthetic CI Tenant"});
      assert.equal("installationId" in org.body.organization,false,
        "organization contract exposes canonical display fields, not cross-tenant IDs");
      const catalog=await call("/v1/admin/permissions","GET",undefined,token);
      assert.equal(catalog.status,200);
      assert.ok((catalog.body.permissions as any[]).some(p=>
        p.code==="inventory.policy.manage"&&p.scope==="warehouse"));
      assert.ok((catalog.body.permissions as any[]).some(p=>
        p.code==="org.employees.read"&&p.scope==="branch"));
      assert.equal((await call("/v1/admin/audit","GET",undefined,token)).status,200);
      const policyScopes=await call("/v1/admin/policy-scopes","GET",undefined,token);
      assert.equal(policyScopes.status,200);
      assert.ok((policyScopes.body.warehouses as any[]).some(w=>w.id===root.warehouseId));
      const scopes=await call("/v1/admin/scopes","GET",undefined,token);
      assert.equal(scopes.status,200);
      assert.equal(scopes.body.branches[0].id,root.branchId);
      // Directory: owner can create a branch and a warehouse without inventing
      // global user grants or changing the existing MAIN scope.
      const branchPayload={code:"CN02",name:"Chi nhánh số 2"};
      const branchHeaders={"idempotency-key":"org-branch-"+randomUUID(),"if-match":"0"};
      const newBranch=await call("/v1/admin/directory/branches","POST",
        branchPayload,token,branchHeaders);
      assert.equal(newBranch.status,201,JSON.stringify(newBranch.body));
      const branchId=String(newBranch.body.id);
      const replay=await call("/v1/admin/directory/branches","POST",
        branchPayload,token,branchHeaders);
      assert.equal(replay.status,201);
      assert.equal(replay.body.id,branchId,"same-key replay does not create a second branch");
      assert.equal((await call("/v1/admin/directory/branches","POST",
        {...branchPayload,name:"Changed"},token,branchHeaders)).status,409);
      const warehousePayload={branchId,code:"KHO02",name:"Kho chi nhánh 2"};
      const warehouseHeaders={"idempotency-key":"org-warehouse-"+randomUUID(),"if-match":"0"};
      const newWarehouse=await call("/v1/admin/directory/warehouses","POST",
        warehousePayload,token,warehouseHeaders);
      assert.equal(newWarehouse.status,201,JSON.stringify(newWarehouse.body));
      const newWarehouseId=String(newWarehouse.body.id);
      const freshSession=await call("/v1/auth/session","GET",undefined,token);
      assert.equal(freshSession.status,200);
      assert.ok((freshSession.body.grants as any[]).some(x=>
        x.permission==="catalog.read"&&x.branchId===branchId));
      assert.ok((freshSession.body.grants as any[]).some(x=>
        x.permission==="inventory.negative.issue"&&x.branchId===branchId&&
        x.warehouseId===newWarehouseId));
      const expanded=await call("/v1/admin/scopes","GET",undefined,token);
      assert.equal(expanded.status,200);
      assert.ok((expanded.body.branches as any[]).some(x=>x.id===branchId&&x.name==="Chi nhánh số 2"));
      assert.ok((expanded.body.warehouses as any[]).some(x=>x.id===newWarehouseId&&x.branchId===branchId));
      const policyPath="/v1/inventory/guard-policy?branchId="+branchId+
        "&warehouseId="+newWarehouseId;
      const basePolicy=await call(policyPath,"GET",undefined,token);
      assert.equal(basePolicy.status,200,JSON.stringify(basePolicy.body));
      assert.equal(basePolicy.body.policy.negativeIssueMode,"BLOCK");
      const allow=await call("/v1/inventory/guard-policy","POST",
       {branchId,warehouseId:newWarehouseId,reserveShortageMode:"WARN",
        negativeIssueMode:"ALLOW"},token,
        {"idempotency-key":"org-policy-"+randomUUID(),"if-match":
          String(basePolicy.body.policy.revision)});
      assert.equal(allow.status,200,JSON.stringify(allow.body));
      assert.equal(allow.body.negativeIssueMode,"ALLOW");
      assert.equal((await call(policyPath,"GET",undefined,token)).body.policy.negativeIssueMode,"ALLOW");

      const createKey="create-"+randomUUID();
      const bobPass="Bob-ci-"+randomUUID();
      const createPayload={loginName:"warehouse_user",password:bobPass};
      const createHeaders={"idempotency-key":createKey,"if-match":"0"};
      const created=await call("/v1/admin/users","POST",createPayload,token,createHeaders);
      assert.equal(created.status,201,JSON.stringify(created.body));
      const bobId=String(created.body.id);
      assert.equal((await call("/v1/admin/users","POST",createPayload,token,createHeaders)).body.id,bobId,
        "lost ACK replay returns same user");
      assert.equal((await call("/v1/admin/users","POST",{...createPayload,loginName:"changed_user"},token,createHeaders)).status,409);
      const users=await call("/v1/admin/users","GET",undefined,token);
      assert.equal(users.status,200);
      assert.equal((users.body.users as any[]).filter(x=>x.id===bobId).length,1);
      const userLogin=await call("/v1/auth/login","POST",createPayload);
      assert.equal(userLogin.status,200);
      const bobToken=String(userLogin.body.token);
      const bobSession=await call("/v1/auth/session","GET",undefined,bobToken);
      assert.equal(bobSession.status,200);
      assert.equal((bobSession.body.grants as any[]).length,0);
      assert.equal((await call("/v1/admin/directory/branches","POST",
        {code:"EVIL",name:"Not authorized"},bobToken,
        {"idempotency-key":"evil-branch-"+randomUUID(),"if-match":"0"})).status,403);

      assert.equal((await call("/v1/admin/users","GET",undefined,bobToken)).status,403);
      assert.equal((await call("/v1/admin/organization","GET",undefined,bobToken)).status,403);
      assert.equal((await call("/v1/admin/permissions","GET",undefined,bobToken)).status,403);
      assert.equal((await call("/v1/admin/audit","GET",undefined,bobToken)).status,403);
      assert.equal((await call("/v1/admin/policy-scopes","GET",undefined,bobToken)).status,403);

      const scope={permission:"inventory.read",branchId:root.branchId,warehouseId:root.warehouseId};
      const grant=await call("/v1/admin/users/"+bobId+"/grants","POST",scope,token,
        {"if-match":"0","idempotency-key":"grant-"+randomUUID()});
      assert.equal(grant.status,201,JSON.stringify(grant.body));
      const roleId=String(grant.body.roleId);
      assert.equal((await call("/v1/admin/users/"+bobId+"/grants","GET",undefined,token)).body.grants[0].roleId,roleId);
      const newSession=await call("/v1/auth/session","GET",undefined,bobToken);
      assert.ok((newSession.body.grants as any[]).some(x=>x.permission==="inventory.read"));
      assert.equal((await call("/v1/admin/users/"+bobId+"/grants","POST",
        {permission:"inventory.post",branchId:root.branchId,warehouseId:root.warehouseId},bobToken,
        {"if-match":"1","idempotency-key":"badgrant-"+randomUUID()})).status,403);
      const policyGrant=await call("/v1/admin/users/"+bobId+"/grants","POST",
        {permission:"inventory.policy.manage",branchId:root.branchId,warehouseId:root.warehouseId},
        token,{"if-match":"1","idempotency-key":"policy-grant-"+randomUUID()});
      assert.equal(policyGrant.status,201);
      const scoped=await call("/v1/admin/policy-scopes","GET",undefined,bobToken);
      assert.equal(scoped.status,200);
      assert.deepEqual((scoped.body.warehouses as any[]).map(w=>w.id),[root.warehouseId]);
      assert.equal((await call("/v1/admin/scopes","GET",undefined,bobToken)).status,403);
      assert.equal((await call("/v1/admin/audit","GET",undefined,bobToken)).status,403);
      const revoke=await call("/v1/admin/users/"+bobId+"/grants/"+roleId,"DELETE",undefined,token,
        {"if-match":"2","idempotency-key":"revoke-"+randomUUID()});
      assert.equal(revoke.status,200,JSON.stringify(revoke.body));
      const policyRevoke=await call("/v1/admin/users/"+bobId+"/grants/"+
        String(policyGrant.body.roleId),"DELETE",undefined,token,
        {"if-match":"3","idempotency-key":"policy-revoke-"+randomUUID()});
      assert.equal(policyRevoke.status,200);
      assert.equal((await call("/v1/auth/session","GET",undefined,bobToken)).body.grants.length,0);
      const disable=await call("/v1/admin/users/"+bobId,"PATCH",{disabled:true},token,
        {"if-match":"4","idempotency-key":"disable-"+randomUUID()});
      assert.equal(disable.status,200);
      assert.equal((await call("/v1/auth/session","GET",undefined,bobToken)).status,401);
      assert.equal((await call("/v1/auth/login","POST",createPayload)).status,401);
      assert.equal((await call("/v1/admin/users/"+root.actorId,"PATCH",{disabled:true},token,
        {"if-match":"0","idempotency-key":"owner-lock-"+randomUUID()})).status,400);
      const loggedOut=await call("/v1/auth/logout","POST",undefined,token);
      assert.equal(loggedOut.status,200);
      assert.equal((await call("/v1/auth/session","GET",undefined,token)).status,401);
      const audited=await pool.query<{total:string}>(
        "SELECT count(*)::text AS total FROM audit_event WHERE installation_id=$1",
        [root.installationId]);
      assert.equal(audited.rows[0]!.total,"9",
        "create/grant/revoke/disable plus branch/warehouse/policy mutations audited once");
      const throttles=await pool.query<{count:string}>(
        "SELECT count(*)::text AS count FROM auth_login_throttle WHERE installation_id=$1 AND failed_count>=5",
        [root.installationId]);
      assert.equal(throttles.rows[0]!.count,"1");
    }finally{await new Promise<void>((ok,fail)=>app.close(e=>e?fail(e):ok()))}
  }finally{
    if(pool)await pool.end();
    await adminDb.query('DROP DATABASE IF EXISTS "'+name+'"');
    await adminDb.end();
  }
});
