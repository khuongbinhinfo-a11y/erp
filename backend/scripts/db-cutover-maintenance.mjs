/**
 * Pre-cutover lock: set Compute project maintenance env read-only using GitHub OIDC,
 * while the existing PostgreSQL secret still targets the source.
 * A separate deployment and live API smoke MUST confirm maintenance before copying data.
 */
import { Pool } from "pg";
import { appendFileSync } from "node:fs";
import { randomBytes } from "node:crypto";

const PROJECT="proj_ud3b1s5yn03vh0zp9cbs2upa";
const e=process.env;
function gate(){
 if(e.GITHUB_ACTIONS!=="true"||e.GITHUB_EVENT_NAME!=="issue_comment"||
  e.GITHUB_REPOSITORY!=="gustavjung24-ops/ERP"||
  e.GITHUB_REF!=="refs/heads/main"||e.GITHUB_ACTOR!=="gustavjung24-ops"||
  e.OWNER_COMMENT_AUTHOR!=="gustavjung24-ops"||
  !/^[0-9a-f]{40}$/.test(e.GITHUB_SHA??"")||
  e.APPROVAL_COMMENT!=="ERP_DB_CUTOVER "+e.GITHUB_SHA||
  !e.ERP_POSTGRES_DIRECT_URL||!e.GITHUB_ENV)throw Error("OWNER_MAINTENANCE_GATE_REFUSED");
 const u=new URL(e.ERP_POSTGRES_DIRECT_URL);
 if(!["postgresql:","postgres:"].includes(u.protocol)||u.hostname!=="db.prisma.io"||
  u.searchParams.get("sslmode")!=="require")throw Error("SOURCE_TLS_GATE_REFUSED");
}
async function api(token,method,path,body){
 const r=await fetch("https://api.prisma.io"+path,{
  method,headers:{authorization:"Bearer "+token,"content-type":"application/json"},
  body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(15000)});
 if(!r.ok)throw Error("PRISMA_ENV_HTTP_"+r.status);
 return r.status===204?null:(await r.json()).data;
}
function array(x){return Array.isArray(x)?x:Array.isArray(x?.items)?x.items:[];}
let pool;
try{
 gate();
 pool=new Pool({connectionString:e.ERP_POSTGRES_DIRECT_URL,max:1,connectionTimeoutMillis:12000});
 pool.on("error",()=>{});
 const q=await pool.query("SELECT (SELECT count(*)::integer FROM installation) AS installations,(SELECT count(*)::integer FROM schema_migrations) AS migrations");
 if(q.rows[0]?.installations!==1||q.rows[0]?.migrations!==5)throw Error("SOURCE_SCHEMA_UNEXPECTED");
 const install=(await pool.query("SELECT id::text AS id FROM installation WHERE code=$1",["erp-demo"])).rows[0]?.id;
 if(!/^[0-9a-f-]{36}$/i.test(install??""))throw Error("SOURCE_INSTALLATION_MISSING");
 const t=await fetch(e.ACTIONS_ID_TOKEN_REQUEST_URL+"&audience=prisma-cloud",{
  headers:{authorization:"Bearer "+e.ACTIONS_ID_TOKEN_REQUEST_TOKEN},signal:AbortSignal.timeout(15000)});
 if(t.status!==200)throw Error("GH_OIDC_NOT_READY");
 const jwt=(await t.json()).value;
 const x=await fetch("https://api.prisma.io/v1/auth/github-actions/token",{
  method:"POST",headers:{"content-type":"application/json"},
  body:JSON.stringify({token:jwt}),signal:AbortSignal.timeout(15000)});
 if(![200,201].includes(x.status))throw Error("PRISMA_OIDC_NOT_READY");
 const token=(await x.json()).data?.value;if(!token)throw Error("PRISMA_OIDC_MISSING");
 const vars=array(await api(token,"GET","/v1/environment-variables?projectId="+PROJECT+"&class=production&key=ERP_MAINTENANCE_MODE"));
 const item=vars.find(v=>v.key==="ERP_MAINTENANCE_MODE"&&v.class==="production"&&v.projectId===PROJECT);
 if(item?.id)await api(token,"PATCH","/v1/environment-variables/"+item.id,{value:"READ_ONLY"});
 else await api(token,"POST","/v1/environment-variables",{projectId:PROJECT,class:"production",key:"ERP_MAINTENANCE_MODE",value:"READ_ONLY"});
 console.log("::add-mask::"+install);
 const throttle=randomBytes(48).toString("base64url");
 console.log("::add-mask::"+throttle);
 appendFileSync(e.GITHUB_ENV,"ERP_INSTALLATION_ID="+install+"\n"+
  "ERP_UI_ORIGIN=https://erp-gustavjung24-ops-projects.vercel.app\n"+
  "ERP_THROTTLE_SECRET="+throttle+"\n");
 console.log("ERP_SOURCE_MAINTENANCE_ENV_STAGED_NOT_YET_DEPLOYED");
}catch{
 console.error("ERP_SOURCE_MAINTENANCE_PREPARE_FAILED");
 process.exitCode=1;
}finally{await pool?.end().catch(()=>{});}
