/**
 * Manual-only production migration entrypoint. NEVER called from Compute or automatic CI.
 * Operator reviews backup/restore evidence and obtains a separate signed owner
 * decision for this exact database, repo SHA, and migration window.
 *
 * Source database ID is an externally verified provider identifier; Postgres
 * itself cannot attest its Prisma Console database ID.
 */
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { existsSync } from "node:fs";
import { Pool } from "pg";
import { applyMigrations } from "./migrate.ts";
import { isDatabaseReady } from "./db.ts";

const TARGET = "db_xg7823erugsd1ym7c8lf0l9h";
const CODE_SHA = /^[0-9a-f]{40}$/;
const CHECKSUM = /^[0-9a-f]{64}$/;
const SNAPSHOT = "54ee2ed373e73db40748e2e98aaf9cabb02edca883506ebc06282df2bbccf051";
const OBJECT = "erp-demo-20261119T-backup.dump.age";

function requireGate(): string {
  if (existsSync(resolve(process.cwd(),"db/migrations/0008_sales_orders.sql")))
    throw new Error("LEGACY_SOURCE_MIGRATION_RETIRED");
  const env = process.env;
  // GitHub Actions is permitted ONLY for the explicitly dispatched, protected
  // one-time operator workflow. Normal CI, push, deploy and Vercel remain denied.
  const githubOperator = env.GITHUB_ACTIONS === "true" &&
    env.GITHUB_EVENT_NAME === "workflow_dispatch" &&
    env.GITHUB_REPOSITORY === "gustavjung24-ops/ERP" &&
    env.GITHUB_REF === "refs/heads/main" &&
    env.GITHUB_WORKFLOW_REF ===
      "gustavjung24-ops/ERP/.github/workflows/erp-initial-activation.yml@refs/heads/main" &&
    env.ERP_TRUSTED_OPERATOR_WORKFLOW === "OWNER_APPROVED_MANUAL_ACTIVATION";
  if ((env.GITHUB_ACTIONS === "true" && !githubOperator) || env.VERCEL === "1") {
    throw new Error("MANUAL_OPERATOR_ONLY");
  }
  if (env.ERP_MIGRATION_CONFIRM !== "OWNER_APPROVED_ERP_DEMO_SCHEMA_0001_0005" ||
      env.ERP_TARGET_DATABASE_ID !== TARGET ||
      env.ERP_BACKUP_OBJECT_KEY !== OBJECT ||
      env.ERP_BACKUP_CIPHERTEXT_SHA256 !== SNAPSHOT ||
      env.ERP_RESTORE_REHEARSAL !== "PORTABLE_RESTORE_VERIFIED_WITH_EXTENSION_EXCEPTION" ||
      !["ENFORCED_RETENTION_VERIFIED", "OWNER_WAIVER_EMPTY_DEMO_NON_WORM"].includes(
        env.ERP_BACKUP_RETENTION_GATE ?? "") ||
      env.ERP_PRODUCTION_WRITES_FROZEN !== "YES" ||
      !CODE_SHA.test(env.ERP_APPROVED_GIT_SHA ?? "") ||
      !CHECKSUM.test(env.ERP_BACKUP_CIPHERTEXT_SHA256 ?? "") ||
      !/^OWNER-[A-Za-z0-9_-]{8,100}$/.test(env.ERP_MIGRATION_APPROVAL_REFERENCE ?? "")) {
    throw new Error("MIGRATION_APPROVAL_OR_BACKUP_GATE_MISSING");
  }
  const sha = execFileSync("git", ["rev-parse", "HEAD"], {
    cwd: resolve(process.cwd(), ".."), encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();
  if (sha !== env.ERP_APPROVED_GIT_SHA) {
    throw new Error("APPROVED_SHA_DOES_NOT_MATCH_CHECKOUT");
  }
  const url = env.ERP_POSTGRES_DIRECT_URL;
  if (!url) throw new Error("DIRECT_DB_CONNECTION_MISSING");
  let parsed: URL;
  try { parsed = new URL(url); }
  catch { throw new Error("INVALID_DATABASE_CONNECTION"); }
  if (!["postgresql:", "postgres:"].includes(parsed.protocol) ||
      parsed.hostname !== "db.prisma.io" ||
      parsed.searchParams.get("sslmode") !== "require" ||
      !parsed.username || !parsed.password ||
      !parsed.pathname.startsWith("/")) {
    throw new Error("DIRECT_PRISMA_POSTGRES_CONNECTION_REQUIRED");
  }
  return url;
}

async function main(): Promise<void> {
  const directUrl = requireGate();
  const pool = new Pool({
    connectionString: directUrl,
    max: 1,
    connectionTimeoutMillis: 10000,
    idleTimeoutMillis: 5000,
    statement_timeout: 120000,
    query_timeout: 120000,
  });
  pool.on("error", () => {
    console.error("MIGRATION_POSTGRES_CONNECTION_LOST");
  });
  try {
    const probe = await pool.query<{major: number; user_objects: string; tenant_objects: string}>(
      `SELECT (current_setting('server_version_num')::integer / 10000) AS major,
          (SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE n.nspname NOT IN ('pg_catalog','information_schema')
              AND n.nspname NOT LIKE 'pg_%'
              AND c.relkind IN ('r','p','v','m','S')
              AND NOT EXISTS (
                SELECT 1 FROM pg_depend d
                JOIN pg_extension e ON e.oid = d.refobjid
                WHERE d.classid = 'pg_class'::regclass
                  AND d.objid = c.oid
                  AND d.refclassid = 'pg_extension'::regclass
                  AND d.deptype = 'e'
                  AND e.extname IN ('prisma_postgres','pg_stat_statements')
              )) AS user_objects,
          (SELECT count(*)::text FROM information_schema.tables WHERE table_schema='public'
            AND table_name IN ('installation','schema_migrations','app_user','app_session')) AS tenant_objects`
    );
    if (probe.rows[0]?.major !== 17 ||
        probe.rows[0]?.user_objects !== "0" ||
        probe.rows[0]?.tenant_objects !== "0") {
      throw new Error("SOURCE_DRIFT_OR_UNEXPECTED_EXISTING_SCHEMA");
    }
    const report = await applyMigrations(pool, resolve(process.cwd(), "db/migrations"));
    if (report.applied.length !== 5 || report.skipped.length !== 0) {
      throw new Error("UNEXPECTED_MIGRATION_RESULT_REQUIRES_OPERATOR_REVIEW");
    }
    if (!await isDatabaseReady(pool)) {
      throw new Error("POST_MIGRATION_READINESS_FAILED");
    }
    console.info(JSON.stringify({
      event: "approved_production_migration",
      success: true,
      appliedVersions: report.applied,
      sourceDatabase: TARGET,
      requiresSeparateAdminApproval: true,
    }));
  } finally {
    await pool.end();
  }
}
main().catch((error: unknown) => {
  // Only emit a fixed whitelist of safe operator gate errors and SQLSTATE codes.
  // Never echo a driver message, connection string, customer data or stack trace.
  const safe = new Set([
    "MANUAL_OPERATOR_ONLY",
    "MIGRATION_APPROVAL_OR_BACKUP_GATE_MISSING",
    "APPROVED_SHA_DOES_NOT_MATCH_CHECKOUT",
    "DIRECT_DB_CONNECTION_MISSING",
    "INVALID_DATABASE_CONNECTION",
    "DIRECT_PRISMA_POSTGRES_CONNECTION_REQUIRED",
    "SOURCE_DRIFT_OR_UNEXPECTED_EXISTING_SCHEMA",
    "UNEXPECTED_MIGRATION_RESULT_REQUIRES_OPERATOR_REVIEW",
    "POST_MIGRATION_READINESS_FAILED",
  ]);
  const message = error instanceof Error ? error.message : "";
  const category = safe.has(message) ? message : "DATABASE_OR_MIGRATION_SQL_FAILED";
  const code = error && typeof error === "object" && "code" in error &&
    typeof error.code === "string" && /^[0-9A-Z]{5}$/.test(error.code)
      ? error.code : "NO_SQLSTATE";
  console.error("MIGRATION_GATE_REFUSED_OR_FAILED_REVIEW_PROTECTED_LOGS category=" + category + " sqlstate=" + code);
  process.exitCode = 1;
});
