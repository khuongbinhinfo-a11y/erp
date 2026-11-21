import { createDatabasePool, isDatabaseReady, isDatabaseConnected } from "./db.ts";
import { buildApp } from "./server.ts";

const port = Number(process.env.PORT ?? "3000");
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("PORT must be an integer between 1 and 65535");
}
const pool = createDatabasePool();
const app = buildApp(
  () => isDatabaseReady(pool),
  () => isDatabaseConnected(pool),
  {
    pool,
    installationId: process.env.ERP_INSTALLATION_ID,
    allowedOrigin: process.env.ERP_UI_ORIGIN,
    throttleSecret: process.env.ERP_THROTTLE_SECRET,
  },
);
app.listen(port, "0.0.0.0", () => {
  console.info(JSON.stringify({ event: "api_listening", port, databaseConfigured: pool !== null }));
});
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, () => {
    app.close(() => {
      if (!pool) { process.exit(0); return; }
      void pool.end().finally(() => process.exit(0));
    });
  });
}
