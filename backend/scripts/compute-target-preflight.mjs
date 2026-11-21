/**
 * Every future approved Compute release reads installation identity from ERP-DB,
 * never from the OLD source GitHub secret. Temporary target connection revoked.
 */
import { Pool } from "pg";
import { randomBytes } from "node:crypto";
import { appendFileSync } from "node:fs";
const e=process.env;
const target="db_jg2bl98hzi1jm06lwo0i4rqx";
if(e.GITHUB_ACTIONS!=="true"||e.GITHUB_REPOSITORY!=="gustavjung24-ops/ERP"||
 e.GITHUB_REF!=="refs/heads/main"||!e.GITHUB_ENV||!e.ACTIONS_ID_TOKEN_REQUEST_URL)
 throw Error("COMPUTE_TARGET_OPERATOR_ONLY");
let token,id,pool;
try{
 const a=await fetch(e.ACTIONS_ID_TOKEN_REQUEST_URL+"&audience=prisma-cloud",{
  headers:{authorization:"Bearer "+e.ACTIONS_ID_TOKEN_REQUEST_TOKEN},signal:AbortSignal.timeout(15000)});
 if(a.status!==200)throw Error("GH_OIDC_UNAVAILABLE");
 const jwt=(await a.json()).value;
 const b=await fetch("https://api.prisma.io/v1/auth/github-actions/token",{
  method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({token:jwt}),
  signal:AbortSignal.timeout(15000)});
 if(![200,201].includes(b.status))throw Error("PRISMA_OIDC_UNAVAILABLE");
 token=(await b.json()).data?.value;
 if(!token)throw Error("OIDC_TOKEN_MISSING");
 const c=await fetch("https://api.prisma.io/v1/databases/"+target+"/connections",{
  method:"POST",headers:{"content-type":"application/json",authorization:"Bearer "+token},
  body:JSON.stringify({name:"erp-release-temporary-"+e.GITHUB_RUN_ID}),signal:AbortSignal.timeout(15000)});
 if(!c.ok)throw Error("TARGET_TEMP_CREDENTIAL_HTTP_"+c.status);
 const obj=(await c.json()).data;id=obj?.id;
 const raw=obj?.endpoints?.direct?.connectionString;
 if(!id||!raw)throw Error("TARGET_DIRECT_CONNECTION_MISSING");
 const u=new URL(raw);
 if(u.hostname!=="db.prisma.io"||u.searchParams.get("sslmode")!=="require")
  throw Error("TARGET_DIRECT_TLS_REQUIRED");
 pool=new Pool({connectionString:raw,max:1,connectionTimeoutMillis:15000});
 pool.on("error",()=>{});
 const h=await pool.query("SELECT version FROM schema_migrations ORDER BY version");
 if(h.rows.length!==10||h.rows.at(-1)?.version!=="0010_r1_sales_price_snapshot.sql")
  throw Error("ERP_DB_NOT_MIGRATED_NO_DEPLOY");
 const i=await pool.query("SELECT id::text AS id FROM installation WHERE code=$1",["erp-demo"]);
 if(i.rows.length!==1||!/^[0-9a-f-]{36}$/i.test(i.rows[0].id))throw Error("ERP_DB_IDENTITY_MISSING");
 const install=i.rows[0].id, secret=randomBytes(48).toString("base64url");
 console.log("::add-mask::"+install);console.log("::add-mask::"+secret);
 appendFileSync(e.GITHUB_ENV,"ERP_INSTALLATION_ID="+install+"\n"+
  "ERP_UI_ORIGIN=https://erp-gustavjung24-ops-projects.vercel.app\n"+
  "ERP_THROTTLE_SECRET="+secret+"\n");
 console.log("ERP_NEW_TARGET_RELEASE_PREFLIGHT_PASS");
}catch{
 console.error("ERP_NEW_TARGET_RELEASE_PREFLIGHT_FAILED");
 process.exitCode=1;
}finally{
 await pool?.end().catch(()=>{});
 if(token&&id)try{
  const r=await fetch("https://api.prisma.io/v1/connections/"+id,{
   method:"DELETE",headers:{authorization:"Bearer "+token},signal:AbortSignal.timeout(15000)});
  if(r.status!==204)throw Error("REVOCATION_FAILED");
  console.log("ERP_RELEASE_TEMP_CONNECTION_REVOKED");
 }catch{
  console.error("ERP_RELEASE_TEMP_CONNECTION_REVOCATION_UNVERIFIED");
  process.exitCode=1;
 }
}
