import { createDatabasePool, isDatabaseReady } from "./db.ts";
import { bootstrapInstallation } from "./bootstrap.ts";

/** Operator-only first-admin command; never used by CI or server startup. */
if(process.env.ERP_BOOTSTRAP_CONFIRM!=="OWNER_APPROVED_EMPTY_INSTALLATION"){
  throw new Error("BOOTSTRAP_REQUIRES_SEPARATE_OWNER_APPROVAL");
}
const code=process.env.ERP_BOOTSTRAP_CODE;
const displayName=process.env.ERP_BOOTSTRAP_NAME;
const adminLogin=process.env.ERP_BOOTSTRAP_ADMIN_LOGIN;
const adminPassword=process.env.ERP_BOOTSTRAP_ADMIN_PASSWORD;
if(!code||!displayName||!adminLogin||!adminPassword){
  throw new Error("BOOTSTRAP_MISSING_SECRET_OR_IDENTITY_CONFIG");
}
const pool=createDatabasePool();
if(!pool)throw new Error("BOOTSTRAP_DATABASE_NOT_CONFIGURED");
try{
  if(!await isDatabaseReady(pool))throw new Error("BOOTSTRAP_REQUIRES_APPROVED_MIGRATIONS");
  await bootstrapInstallation(pool,{code,displayName,adminLogin,adminPassword});
  // No credentials, IDs or personal data in operator logs.
  console.info(JSON.stringify({event:"identity_bootstrap",created:true}));
}finally{await pool.end();}
