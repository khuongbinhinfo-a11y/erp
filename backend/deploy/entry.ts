import service from "./service.ts";
import { buildApp } from "../src/server.ts";
import { createDatabasePool, isDatabaseReady, isDatabaseConnected } from "../src/db.ts";

// Database URL only exists in the private Compute service.
const serviceInput = service.input();
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
