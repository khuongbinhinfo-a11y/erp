import service from "./service.ts";
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
