import node from "@prisma/composer/node";
import { compute } from "@prisma/composer-prisma-cloud";
import { secretString } from "@prisma/composer/arktype";
import { type } from "arktype";

// Only provisions a Compute service. Does not create a new Postgres database.
export default compute({
  name: "api",
  deps: {},
  // Identity remains off until approved migration, bootstrap and all secrets exist.
  input: type({
    postgresUrl: secretString(),
    "installationId?": secretString(),
    "uiOrigin?": secretString(),
    "throttleSecret?": secretString(),
    "maintenanceMode?": secretString(),
    "r2AccountId?": secretString(),
    "r2Bucket?": secretString(),
    "r2AccessKeyId?": secretString(),
    "r2SecretAccessKey?": secretString(),
  }),
  build: node({ module: import.meta.url, entry: "../dist/compute.mjs" }),
});
