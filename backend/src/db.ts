import { Pool } from "pg";

/** PostgreSQL is accessible only to the TypeScript server. */
export function createDatabasePool(connectionString: string | undefined = process.env.DATABASE_URL): Pool | null {
  if (!connectionString || connectionString.includes("db.invalid")) return null;
  // Live auth writes occasionally exceeded the former 3s query limit although
  // health/ready reads returned 200. Allow bounded latency without silently
  // retrying sign-in after an ambiguous PostgreSQL COMMIT.
  const pool = new Pool({
    connectionString,
    max: 5,
    connectionTimeoutMillis: 7500,
    idleTimeoutMillis: 10000,
    query_timeout: 12000,
  });
  pool.on("error", () => {
    // Do not log error objects: some drivers include connection information.
    console.error(JSON.stringify({ event: "postgres_pool_disconnected" }));
  });
  return pool;
}

export async function isDatabaseReady(pool: Pool | null): Promise<boolean> {
  if (!pool) return false;
  try {
    const result = await pool.query<{ migration_applied: boolean; table_count: number }>(
      "SELECT (SELECT COUNT(*)::integer FROM public.schema_migrations WHERE version IN ('0001_identity.sql', '0002_mutation_control.sql', '0003_warehouse_scope.sql', '0004_auth_sessions.sql', '0005_admin_revision_throttle.sql')) = 5 AS migration_applied, " +
      "(SELECT COUNT(*)::integer FROM information_schema.tables WHERE table_schema = 'public' " +
      "AND table_name IN ('installation','branch','warehouse','app_user','app_role','role_permission','user_role','mutation_receipt','audit_event','user_role_warehouse','app_session','auth_event','auth_login_throttle')) AS table_count"
    );
    return result.rows[0]?.migration_applied === true && result.rows[0]?.table_count === 13;
  } catch {
    return false;
  }
}

/** Simple read-only connectivity probe; does not assume that ERP schema has been migrated. */
export async function isDatabaseConnected(pool: Pool | null): Promise<boolean> {
  if (!pool) return false;
  try {
    const result = await pool.query<{ online: number }>("SELECT 1::integer AS online");
    return result.rows[0]?.online === 1;
  } catch {
    return false;
  }
}
