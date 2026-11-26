import service from "./service.ts";
import {createHmac} from "node:crypto";
import { buildApp } from "../src/server.ts";
import { createDatabasePool, isDatabaseReady, isDatabaseConnected } from "../src/db.ts";

// Database URL only exists in the private Compute service.
const serviceInput = service.input();
// Private credentials are only materialized inside the server Compute process.
const r2Inputs = {
  ERP_R2_ACCOUNT_ID: serviceInput.r2AccountId?.expose(),
  ERP_R2_BUCKET: serviceInput.r2Bucket?.expose(),
  ERP_R2_ACCESS_KEY_ID: serviceInput.r2AccessKeyId?.expose(),
  ERP_R2_SECRET_ACCESS_KEY: serviceInput.r2SecretAccessKey?.expose(),
};
for (const [key,value] of Object.entries(r2Inputs)) {
  if (value) process.env[key] = value;
}
// Already-provisioned protected backend secret, domain-separated for OTA tickets.
// No release R2 writer credentials are needed in the API process or Android app.
const keyMaterial=serviceInput.throttleSecret?.expose()||serviceInput.r2SecretAccessKey?.expose();
if(keyMaterial&&keyMaterial.length>=32){
  process.env.ERP_RELEASE_READ_ORIGIN="https://erp-android-download.gustavjung24.workers.dev";
  process.env.ERP_ANDROID_CERT_SHA256="545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028";
  process.env.ERP_RELEASE_TICKET_SECRET=createHmac("sha256",keyMaterial)
    .update("ERP-ANDROID-RELEASE-TICKET-v1").digest("hex");
}
const databaseUrl = serviceInput.postgresUrl.expose();
const pool = createDatabasePool(databaseUrl);
if (!pool) throw new Error("ERP PostgreSQL secret missing");
const port = service.port();
const app = buildApp(
  () => isDatabaseReady(pool),
  () => isDatabaseConnected(pool),
  {
    pool,
    installationId: serviceInput.installationId?.expose(),
    allowedOrigin: serviceInput.uiOrigin?.expose(),
    throttleSecret: serviceInput.throttleSecret?.expose(),
  },
  serviceInput.maintenanceMode?.expose() === "READ_ONLY",
);
app.listen(port, "0.0.0.0", () => {
  console.info(JSON.stringify({ event: "erp_compute_listening", port }));
});
process.once("SIGTERM", () => {
  app.close(() => { void pool.end().finally(() => process.exit(0)); });
});
