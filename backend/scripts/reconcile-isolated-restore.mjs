// Read-only comparison of the original PostgreSQL database with an isolated restore.
// Run solely from a protected operator environment; never log connection strings or row data.
import pg from "pg";

const { Client } = pg;
const sourceUrl = process.env.ERP_BACKUP_SOURCE_URL;
const restoreUrl = process.env.ERP_RESTORE_TARGET_URL;
if (!sourceUrl || !restoreUrl) {
  console.error("Reconciliation requires protected source and isolated restore connections.");
  process.exit(2);
}

const relationSql = `
  SELECT n.nspname AS schema_name, c.relname AS relation_name, c.relkind AS kind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname <> 'information_schema'
     AND n.nspname NOT LIKE 'pg_%'
     AND c.relkind IN ('r', 'p', 'm', 'S')
   ORDER BY n.nspname, c.relname, c.relkind
`;
const quote = (value) => '"' + value.replaceAll('"', '""') + '"';

async function snapshot(client) {
  const version = await client.query(
    "SELECT (current_setting('server_version_num')::integer / 10000)::text AS major"
  );
  const relationRows = (await client.query(relationSql)).rows;
  const entries = [];
  for (const { schema_name, relation_name, kind } of relationRows) {
    const qualified = `${quote(schema_name)}.${quote(relation_name)}`;
    if (kind === "S") {
      const data = (await client.query(`SELECT last_value::text AS last_value, is_called FROM ${qualified}`)).rows[0];
      entries.push({ schema_name, relation_name, kind, last_value: data.last_value, is_called: data.is_called });
      continue;
    }
    // Order-independent data signatures, combined with exact counts and schema comparison.
    // This is a corruption/reconciliation gate, not a cryptographic proof of row equality.
    const sql = `
      SELECT count(*)::text AS row_count,
        coalesce(bit_xor(hashtextextended(row_to_json(t)::text, 0))::text, '0') AS xor_digest,
        coalesce(sum(hashtextextended(row_to_json(t)::text, 1)::numeric)::text, '0') AS sum_digest
      FROM ${qualified} AS t
    `;
    const { row_count, xor_digest, sum_digest } = (await client.query(sql)).rows[0];
    entries.push({ schema_name, relation_name, kind, row_count, xor_digest, sum_digest });
  }
  return { major: version.rows[0].major, entries };
}

const source = new Client({ connectionString: sourceUrl, connectionTimeoutMillis: 15000 });
const restore = new Client({ connectionString: restoreUrl, connectionTimeoutMillis: 15000 });
try {
  await source.connect();
  await restore.connect();
  await source.query("SET TIME ZONE 'UTC'");
  await restore.query("SET TIME ZONE 'UTC'");
  const [before, after] = await Promise.all([snapshot(source), snapshot(restore)]);
  if (before.major !== after.major) throw new Error("PostgreSQL major version mismatch");
  if (JSON.stringify(before.entries) !== JSON.stringify(after.entries)) {
    throw new Error("Relation, count, sequence or data-signature mismatch");
  }
  const count = before.entries.filter((e) => e.kind !== "S").length;
  console.info(`RECONCILIATION PASS: ${count} relations and ${before.entries.length - count} sequences, matching PostgreSQL major versions`);
} catch {
  console.error("RECONCILIATION FAIL: protected review required; no production action permitted.");
  process.exitCode = 1;
} finally {
  await Promise.allSettled([source.end(), restore.end()]);
}
