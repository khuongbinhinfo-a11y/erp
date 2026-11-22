import { module } from "@prisma/composer";
import { envSecret } from "@prisma/composer-prisma-cloud";
import apiService from "./service.ts";

// Dedicated Compute project. Runtime DB is selected by protected ERP_POSTGRES_URL;
// production cutover is a separate owner-only database maintenance workflow.
// Never provision a database here; inject the existing DB connection as an encrypted input.
export default module("erp-backend", ({ provision }) => {
  provision(apiService, {
    input: {
      postgresUrl: envSecret("ERP_POSTGRES_URL"),
      installationId: envSecret("ERP_INSTALLATION_ID"),
      uiOrigin: envSecret("ERP_UI_ORIGIN"),
      throttleSecret: envSecret("ERP_THROTTLE_SECRET"),
      maintenanceMode: envSecret("ERP_MAINTENANCE_MODE"),
      r2AccountId: envSecret("ERP_R2_ACCOUNT_ID"),
      r2Bucket: envSecret("ERP_R2_BUCKET"),
      r2AccessKeyId: envSecret("ERP_R2_ACCESS_KEY_ID"),
      r2SecretAccessKey: envSecret("ERP_R2_SECRET_ACCESS_KEY"),
    },
  });
});
