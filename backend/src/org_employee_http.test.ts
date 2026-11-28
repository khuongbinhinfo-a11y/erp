import test from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {resolve} from "node:path";
import {Pool} from "pg";
import type {AddressInfo} from "node:net";
import {applyMigrations} from "./migrate.ts";
import {bootstrapInstallation} from "./bootstrap.ts";
import {buildApp} from "./server.ts";
import {isDatabaseReady} from "./db.ts";
const url=process.env.DATABASE_URL;
const local=(()=>{try{const u=new URL(url??"");
 return ["localhost","127.0.0.1"].includes(u.hostname)&&u.pathname==="/erp_ci";
 }catch{return false;}})();
test("IA-A: staff belongs to Company branch, not delivery; user link and RBAC are atomic",
 {skip:!local},async()=>{
 const admin=new Pool({connectionString:url,max:2});
 const dbName="erp_ci_iaa_"+randomUUID().replaceAll("-","").slice(0,12);
 let db:Pool|null=null,server:ReturnType<typeof buildApp>|null=null;
 try{
  await admin.query('CREATE DATABASE "'+dbName+'"');
  const scopedUrl=new URL(url!);scopedUrl.pathname="/"+dbName;
  db=new Pool({connectionString:scopedUrl.toString(),max:10,query_timeout:25000});
  db.on("error",()=>{});
  const migrations=resolve(process.cwd(),"db/migrations");
  const applied=await applyMigrations(db,migrations);
  assert.ok(applied.applied.includes("0029_iaa_employee_access.sql"));
  assert.equal((await applyMigrations(db,migrations)).skipped.length,29);
  const password="iaa-"+randomUUID();
  const owner=await bootstrapInstallation(db,{
   code:"iaa",displayName:"Staff integration",adminLogin:"owner",adminPassword:password,
  });
  const {installationId:t,branchId:b,actorId:ownerId}=owner;
  server=buildApp(()=>isDatabaseReady(db!),async()=>true,{
   pool:db,installationId:t,allowedOrigin:"https://erp.example.test",
   throttleSecret:"test-"+randomUUID(),
  });
  await new Promise<void>(ok=>server!.listen(0,"127.0.0.1",ok));
  const base="http://127.0.0.1:"+(server.address() as AddressInfo).port;
  const call=async(path:string,method="GET",body?:unknown,token?:string,
      headers:Record<string,string>={})=>{
   const r=await fetch(base+path,{method,headers:{
    origin:"https://erp.example.test",
    ...(body===undefined?{}:{"content-type":"application/json"}),
    ...(token?{authorization:"Bearer "+token}:{}),...headers,
   },body:body===undefined?undefined:JSON.stringify(body)});
   return {status:r.status,data:r.status===204?{}:await r.json() as Record<string,any>};
  };
  const auth=await call("/v1/auth/login","POST",{loginName:"owner",password});
  assert.equal(auth.status,200);
  const token=auth.data.token as string;
  const write=(p:string,m:string,data:unknown,who=token,revision=0,key="iaa-"+randomUUID())=>
   call(p,m,data,who,{"if-match":String(revision),"idempotency-key":key});
  const query="?branchId="+b;
  assert.equal((await call("/v1/org/employees"+query)).status,401);
  assert.equal((await call("/v1/org/employees/branches","GET",undefined,token)).status,200);
  const candidate=await write("/v1/org/employees","POST",{
   branchId:b,code:"NV01",fullName:"Nhân viên kế toán",
   jobTitle:"Kế toán",department:"Tài chính",phone:"0912345678",
  });
  assert.equal(candidate.status,201,JSON.stringify(candidate.data));
  const eid=candidate.data.employee.id as string;
  assert.equal(candidate.data.employee.department,"Tài chính");
  const staff=await call("/v1/org/employees"+query,"GET",undefined,token);
  assert.equal(staff.status,200,JSON.stringify(staff.data));
  assert.equal(staff.data.items[0].id,eid);
  assert.equal(staff.data.items[0].department,"Tài chính");
  assert.equal(staff.data.items[0].linkedDriver,false);
  assert.equal((await call("/v1/org/employees"+query+"&offset=1","GET",undefined,token)).status,400);
  assert.equal((await write("/v1/org/employees","POST",{
   branchId:b,code:"NV01",fullName:"Tên trùng",
  })).status,409);
  const change=await write("/v1/org/employees/"+eid,"PATCH",{
   branchId:b,fullName:"Nhân viên kế toán mới",department:"Phòng kế toán",
   jobTitle:"Kế toán trưởng",phone:"",active:true,
  },token,0);
  assert.equal(change.status,200,JSON.stringify(change.data));
  assert.equal(change.data.employee.revision,1);
  assert.equal((await write("/v1/org/employees/"+eid,"PATCH",{
   branchId:b,fullName:"Sai revision",active:true,
  },token,0)).status,409);
  const newUser=await write("/v1/admin/users","POST",{
   loginName:"ke_toan",password:"test-"+randomUUID(),
  });
  assert.equal(newUser.status,201,JSON.stringify(newUser.data));
  const uid=newUser.data.id as string;
  const newUserToken=(await call("/v1/auth/login","POST",{
   loginName:"ke_toan",password:"not-used",
  })).data.token; // incorrect password must not grant a session.
  assert.equal(newUserToken,undefined);
  assert.equal((await call("/v1/org/employees"+query,"GET",undefined,undefined)).status,401);
  const exactKey="iaa-link-"+randomUUID();
  const linkPayload={branchId:b,employeeId:eid};
  const linkPath="/v1/admin/users/"+uid+"/employee";
  const linked=await write(linkPath,"PATCH",linkPayload,token,0,exactKey);
  assert.equal(linked.status,200,JSON.stringify(linked.data));
  assert.equal(linked.data.employeeId,eid);
  const replay=await write(linkPath,"PATCH",linkPayload,token,0,exactKey);
  assert.equal(replay.status,200);
  assert.equal(replay.data.revision,linked.data.revision);
  const accountRows=await call("/v1/admin/users","GET",undefined,token);
  assert.equal(accountRows.status,200);
  assert.equal(accountRows.data.users.find((u:any)=>u.id===uid)?.employeeId,eid);
  const employeeRows=await call("/v1/org/employees"+query,"GET",undefined,token);
  assert.equal(employeeRows.data.items[0].accountUserId,uid);
  const another=await write("/v1/admin/users","POST",{
   loginName:"ban_hang",password:"test-"+randomUUID(),
  });
  assert.equal(another.status,201);
  assert.equal((await write("/v1/admin/users/"+another.data.id+"/employee","PATCH",
   linkPayload)).status,409,"one employee cannot attach two accounts");
  const otherPassword="staff-"+randomUUID();
  const staffAccount=await write("/v1/admin/users","POST",{
   loginName:"hr_01",password:otherPassword,
  });
  assert.equal(staffAccount.status,201);
  const staffLogin=await call("/v1/auth/login","POST",{
   loginName:"hr_01",password:otherPassword,
  });
  assert.equal(staffLogin.status,200);
  const hrToken=staffLogin.data.token as string;
  assert.equal((await call("/v1/org/employees"+query,"GET",undefined,hrToken)).status,403);
  const readGrant=await write("/v1/admin/users/"+staffAccount.data.id+"/grants","POST",{
   permission:"org.employees.read",branchId:b,
  },token,0);
  assert.equal(readGrant.status,201,JSON.stringify(readGrant.data));
  assert.equal((await call("/v1/org/employees"+query,"GET",undefined,hrToken)).status,200);
  assert.equal((await write("/v1/org/employees","POST",{
   branchId:b,code:"HR02",fullName:"Nhân sự chỉ đọc",
  },hrToken,0)).status,403);
  const manageGrant=await write("/v1/admin/users/"+staffAccount.data.id+"/grants","POST",{
   permission:"org.employees.manage",branchId:b,
  },token,1);
  assert.equal(manageGrant.status,201,JSON.stringify(manageGrant.data));
  assert.equal((await write("/v1/org/employees","POST",{
   branchId:b,code:"HR02",fullName:"Nhân sự có quyền",
  },hrToken)).status,201);
  assert.equal((await write(linkPath,"PATCH",{branchId:b,employeeId:null},
   hrToken,linked.data.revision)).status,403,
   "HR permission never implies admin identity account rights");
  const branch=await write("/v1/admin/directory/branches","POST",{
   code:"CN02",name:"Chi nhánh thứ hai",
  });
  assert.equal(branch.status,201,JSON.stringify(branch.data));
  const second=branch.data.id as string;
  assert.equal((await call("/v1/org/employees?branchId="+second,
   "GET",undefined,hrToken)).status,403,"HR grant cannot cross branch");
  assert.equal((await write("/v1/org/employees","POST",{
   branchId:second,code:"CN02NV",fullName:"Chéo chi nhánh",
  },hrToken)).status,403);
  const unlink=await write(linkPath,"PATCH",{branchId:b,employeeId:null},
   token,linked.data.revision);
  assert.equal(unlink.status,200,JSON.stringify(unlink.data));
  const post=await call("/v1/org/employees"+query,"GET",undefined,token);
  assert.equal(post.data.items[0].accountUserId,null);
  const receipts=await db.query<{n:string}>(`SELECT count(*)::text AS n
   FROM mutation_receipt WHERE installation_id=$1
    AND action_code='org.employee.account.link'`,[t]);
  assert.equal(receipts.rows[0]?.n,"2","replayed link cannot double-post");
  const ownerGrant=await db.query<{n:string}>(`SELECT count(*)::text AS n
   FROM role_permission rp JOIN app_role r
    ON r.installation_id=rp.installation_id AND r.id=rp.role_id
   WHERE r.installation_id=$1 AND r.code='PRIMARY_OWNER_MAIN'
    AND rp.permission_code IN ('org.employees.read','org.employees.manage')`,[t]);
  assert.equal(ownerGrant.rows[0]?.n,"2");
  assert.ok(ownerId);
 }finally{
  if(server)await new Promise<void>(done=>server!.close(()=>done()));
  if(db)await db.end();
  await admin.query('DROP DATABASE IF EXISTS "'+dbName+'" WITH (FORCE)').catch(()=>{});
  await admin.end();
 }
});
