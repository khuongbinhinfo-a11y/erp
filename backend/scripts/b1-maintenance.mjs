/** Operator-only maintenance stage for the existing ERP-DB Compute runtime. */
import { Pool } from "pg";
import { appendFileSync } from "node:fs";
import { randomBytes } from "node:crypto";

const e=process.env,mode=process.argv[2];
const project="proj_ud3b1s5yn03vh0zp9cbs2upa",dbId="db_jg2bl98hzi1jm06lwo0i4rqx";
if(!["freeze","normal"].includes(mode)||e.GITHUB_ACTIONS!=="true"||
 e.GITHUB_EVENT_NAME!=="issue_comment"||e.GITHUB_REPOSITORY!=="gustavjung24-ops/ERP"||
 e.GITHUB_REF!=="refs/heads/main"||e.GITHUB_ACTOR!=="gustavjung24-ops"||
 e.OWNER_COMMENT_AUTHOR!=="gustavjung24-ops"||
 !/^[0-9a-f]{40}$/.test(e.GITHUB_SHA??"")||
 !(
   e.APPROVAL_COMMENT==="ERP_B1_MIGRATE "+e.GITHUB_SHA||
   (mode==="normal"&&e.APPROVAL_COMMENT==="ERP_B1_RESUME "+e.GITHUB_SHA)
 )||
 !e.GITHUB_ENV)throw Error("B1_MAINTENANCE_OWNER_GATE_DENIED");

async function api(token,method,path,body){
 const r=await fetch("https://api.prisma.io"+path,{
  method,headers:{authorization:"Bearer "+token,"content-type":"application/json"},
  body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(16000)});
 if(!r.ok)throw Error("B1_PRISMA_MAINTENANCE_PROVIDER_FAILURE");
 return r.status===204?null:(await r.json()).data;
}
const items=x=>Array.isArray(x)?x:Array.isArray(x?.items)?x.items:[];
let token,connection,pool;
try{
 const a=await fetch(e.ACTIONS_ID_TOKEN_REQUEST_URL+"&audience=prisma-cloud",{
  headers:{authorization:"Bearer "+e.ACTIONS_ID_TOKEN_REQUEST_TOKEN},
  signal:AbortSignal.timeout(15000)});
 if(a.status!==200)throw Error("B1_OIDC_IDENTITY_DENIED");
 const jwt=(await a.json()).value;
 const t=await fetch("https://api.prisma.io/v1/auth/github-actions/token",{
  method:"POST",headers:{"content-type":"application/json"},
  body:JSON.stringify({token:jwt}),signal:AbortSignal.timeout(15000)});
 if(![200,201].includes(t.status))throw Error("B1_OIDC_PROVIDER_DENIED");
 token=(await t.json()).data?.value;
 if(!token)throw Error("B1_OIDC_TOKEN_EMPTY");
 const c=await api(token,"POST","/v1/databases/"+dbId+"/connections",{
  name:"erp-b1-maintenance-"+mode+"-"+e.GITHUB_RUN_ID});
 const raw=c?.endpoints?.direct?.connectionString;
 if(!c?.id||!raw)throw Error("B1_MAINTENANCE_CREDENTIAL_MISSING");
 connection=c.id;
 const u=new URL(raw);
 if(u.hostname!=="db.prisma.io"||u.searchParams.get("sslmode")!=="require")
  throw Error("B1_WRONG_DATABASE_PROVIDER");
 pool=new Pool({connectionString:raw,max:1,connectionTimeoutMillis:15000});
 const rows=await pool.query("SELECT version FROM schema_migrations ORDER BY version");
 if(rows.rows.length!==(mode==="freeze"?7:8)||
    rows.rows.at(-1)?.version!==(mode==="freeze"?"0007_catalog_controls.sql":"0008_sales_orders.sql"))
  throw Error("B1_MAINTENANCE_SCHEMA_DRIFT");
 const installations=await pool.query("SELECT id::text FROM installation WHERE code='erp-demo'");
 const branches=await pool.query("SELECT id::text FROM branch");
 if(installations.rows.length!==1||branches.rows.length!==1)
   throw Error("B1_MAINTENANCE_INSTALLATION_DRIFT");
 const installationId=installations.rows[0].id;
 const branchId=branches.rows[0].id;
 const vars=items(await api(token,"GET",
  "/v1/environment-variables?projectId="+project+"&class=production&key=ERP_MAINTENANCE_MODE"));
 const item=vars.find(x=>x.projectId===project&&x.key==="ERP_MAINTENANCE_MODE"&&x.class==="production");
 const value=mode==="freeze"?"READ_ONLY":"NORMAL";
 if(item?.id)await api(token,"PATCH","/v1/environment-variables/"+item.id,{value});
 else await api(token,"POST","/v1/environment-variables",{
  projectId:project,class:"production",key:"ERP_MAINTENANCE_MODE",value});
 const throttle=randomBytes(48).toString("base64url");
 console.log("::add-mask::"+installationId);
 console.log("::add-mask::"+branchId);
 console.log("::add-mask::"+throttle);
 appendFileSync(e.GITHUB_ENV,"ERP_INSTALLATION_ID="+installationId+"\n"+
  "ERP_BRANCH_ID="+branchId+"\n"+
  "ERP_UI_ORIGIN=https://erp-gustavjung24-ops-projects.vercel.app\n"+
  "ERP_THROTTLE_SECRET="+throttle+"\n");
 console.info(mode==="freeze"?"ERP_B1_MAINTENANCE_READ_ONLY_STAGED":"ERP_B1_NORMAL_STAGED");
}catch{
 console.error("ERP_B1_MAINTENANCE_STAGE_FAILED");
 process.exitCode=1;
}finally{
 await pool?.end().catch(()=>{});
 if(token&&connection)try{
  await api(token,"DELETE","/v1/connections/"+connection);
  console.info("ERP_B1_MAINTENANCE_CREDENTIAL_REVOKED");
 }catch{console.error("ERP_B1_MAINTENANCE_REVOCATION_UNVERIFIED");process.exitCode=1;}
}
