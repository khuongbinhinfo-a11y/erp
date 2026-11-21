import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { Pool } from "pg";
import { createDatabasePool } from "./db.ts";

export type MigrationResult = { applied: string[]; skipped: string[] };

export async function applyMigrations(pool: Pool, directory: string): Promise<MigrationResult> {
  const filenames = (await readdir(directory))
    .filter((file) => /^\d{4}_[a-z0-9_]+\.sql$/.test(file))
    .sort();
  if (filenames.length === 0) throw new Error("No versioned migrations found");
  const client = await pool.connect();
  const result: MigrationResult = { applied: [], skipped: [] };
  try {
    await client.query("BEGIN");
    await client.query("SELECT pg_advisory_xact_lock(2026, 11)");
    await client.query(
      "CREATE TABLE IF NOT EXISTS public.schema_migrations (" +
      "version text PRIMARY KEY, checksum char(64) NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())"
    );
    const unknown = await client.query<{ version: string }>(
      "SELECT version FROM public.schema_migrations WHERE NOT (version = ANY($1::text[]))",
      [filenames]
    );
    if (unknown.rows.length > 0) throw new Error("Unexpected migration history version");
    for (const version of filenames) {
      const sql = await readFile(resolve(directory, version), "utf8");
      if (/(^|\n)\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im.test(sql)) {
        throw new Error("Transaction commands in versioned migration");
      }
      const checksum = createHash("sha256").update(sql).digest("hex");
      const history = await client.query<{ checksum: string }>(
        "SELECT checksum FROM public.schema_migrations WHERE version = $1", [version]
      );
      if (history.rows.length > 0) {
        if (history.rows[0]?.checksum !== checksum) throw new Error("Migration checksum mismatch");
        result.skipped.push(version);
        continue;
      }
      await client.query(sql);
      await client.query(
        "INSERT INTO public.schema_migrations (version, checksum) VALUES ($1, $2)",
        [version, checksum]
      );
      result.applied.push(version);
    }
    await client.query("COMMIT");
    return result;
  } catch (cause) {
    await client.query("ROLLBACK").catch(() => undefined);
    // Never echo SQL errors/credentials to untrusted logs.
    throw new Error("Migration failed; review protected logs", { cause });
  } finally {
    client.release();
  }
}

// This CLI deliberately cannot migrate Prisma or production: only localhost/erp_ci.
const entry = process.argv[1];
if (entry && import.meta.url === pathToFileURL(entry).href) {
  let allowed = false;
  const raw = process.env.DATABASE_URL;
  if (raw && process.env.ERP_DB_MIGRATION_TARGET === "ci" && process.env.NODE_ENV !== "production") {
    try {
      const url = new URL(raw);
      allowed = ["postgresql:", "postgres:"].includes(url.protocol) &&
        ["localhost", "127.0.0.1"].includes(url.hostname) &&
        url.pathname === "/erp_ci";
    } catch {
      allowed = false;
    }
  }
  if (!allowed) throw new Error("Migration refused: ephemeral CI target only");
  const pool = createDatabasePool();
  if (!pool) throw new Error("CI PostgreSQL is not configured");
  try {
    const report = await applyMigrations(pool, resolve(process.cwd(), "db/migrations"));
    console.info(JSON.stringify({ event: "ci_migration", ...report }));
  } finally {
    await pool.end();
  }
}
