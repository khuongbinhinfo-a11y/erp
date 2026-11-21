#!/usr/bin/env bash
# Operator-only Prisma Postgres logical backup + isolated restore rehearsal.
# This NEVER runs a migration and NEVER restores into the source database.
set -Eeuo pipefail
set +x
umask 077

refuse() { printf '%s\n' "BACKUP GATE BLOCKED: $1" >&2; exit 2; }
require() { [[ -n "${!1:-}" ]] || refuse "Missing protected configuration: $1"; }
for name in ERP_BACKUP_SOURCE_URL ERP_RESTORE_TARGET_URL ERP_BACKUP_STORE_URI ERP_BACKUP_AGE_RECIPIENT ERP_BACKUP_AGE_IDENTITY_FILE; do
  require "$name"
done
[[ "${ERP_BACKUP_GATE_CONFIRM:-}" == "ISOLATED_RESTORE_ONLY" ]] || refuse "Operator confirmation missing"
[[ "${ERP_SOURCE_WRITES_QUIESCED:-}" == "YES" ]] || refuse "Source writes are not confirmed quiesced"
[[ "${ERP_BACKUP_RETENTION_VERIFIED:-}" == "YES" ]] || refuse "External encrypted storage retention is unverified"
[[ "${GITHUB_ACTIONS:-}" != "true" ]] || refuse "Use a protected operator runtime, not GitHub Actions"
[[ -r "$ERP_BACKUP_AGE_IDENTITY_FILE" ]] || refuse "Age recovery identity is unavailable"
[[ "$ERP_BACKUP_STORE_URI" =~ ^s3://[a-zA-Z0-9.-]+(/[a-zA-Z0-9_./-]*)?$ ]] || refuse "Expected a private S3-compatible bucket URI"
for command in node pg_dump pg_restore psql aws age sha256sum cmp diff mktemp openssl sed; do
  command -v "$command" >/dev/null 2>&1 || refuse "Missing required executable: $command"
done

# Validate targets without putting passwords in argv/logs. An isolated restore must be
# on another host and in a purpose-named empty database. Use direct, not pooled, source.
node --input-type=module <<'JS' || refuse "Unsafe source or isolated restore target"
const source = new URL(process.env.ERP_BACKUP_SOURCE_URL);
const target = new URL(process.env.ERP_RESTORE_TARGET_URL);
const postgres = u => ["postgres:", "postgresql:"].includes(u.protocol);
const safe = postgres(source) && postgres(target)
  && source.hostname !== target.hostname
  && source.hostname !== "localhost" && source.hostname !== "127.0.0.1"
  && !source.hostname.startsWith("pooled.")
  && target.pathname.startsWith("/erp_restore_") && /^[a-z0-9_]+$/.test(target.pathname.slice(13))
  && ["localhost", "127.0.0.1"].includes(target.hostname);
process.exit(safe ? 0 : 1);
JS

# Libpq credentials are held in the protected process environment, never on command-line argv.
# PGDATABASE contains only the database name, not a connection URI.
pg_from_url() {
  local connection="$1"
  local -a values=()
  mapfile -d '' -t values < <(PG_CONN_URI="$connection" node --input-type=module -e '
    const u = new URL(process.env.PG_CONN_URI);
    const fields = [
      u.hostname.replace(/^\[(.*)\]$/, "$1"),
      u.port || "5432",
      decodeURIComponent(u.pathname.slice(1)),
      decodeURIComponent(u.username),
      decodeURIComponent(u.password),
      u.searchParams.get("sslmode") || (["localhost", "127.0.0.1"].includes(u.hostname) ? "prefer" : "require"),
    ];
    for (const field of fields) process.stdout.write(field + "\0");
  ')
  [[ "${#values[@]}" == "6" && -n "${values[2]}" ]] || refuse "Failed to parse protected PostgreSQL connection"
  export PGHOST="${values[0]}" PGPORT="${values[1]}" PGDATABASE="${values[2]}" \
    PGUSER="${values[3]}" PGPASSWORD="${values[4]}" PGSSLMODE="${values[5]}"
}
# Pre-provision a temporary local PostgreSQL database; do not overwrite any existing data.
pg_from_url "$ERP_RESTORE_TARGET_URL"
existing="$(psql -X -Atq -v ON_ERROR_STOP=1 -c "
  SELECT count(*) FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname <> 'information_schema' AND n.nspname NOT LIKE 'pg_%'
    AND c.relkind IN ('r','p','v','m','S');
" 2>/dev/null)" || refuse "Cannot verify isolated target"
[[ "$existing" == "0" ]] || refuse "Isolated target contains database objects"

tmp="$(mktemp -d)"
chmod 700 "$tmp"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

# Nothing written to Prisma source: a transactionally consistent logical snapshot.
pg_from_url "$ERP_BACKUP_SOURCE_URL"
pg_dump --format=custom --no-owner --no-acl \
  --file="$tmp/source.dump" 2>"$tmp/dump.err" \
  || refuse "Direct pg_dump failed; see protected operator diagnostics"
[[ -s "$tmp/source.dump" ]] || refuse "Empty logical dump"
dump_sha="$(sha256sum "$tmp/source.dump" | cut -d' ' -f1)"
age -r "$ERP_BACKUP_AGE_RECIPIENT" -o "$tmp/source.dump.age" "$tmp/source.dump" \
  2>"$tmp/encryption.err" || refuse "Backup encryption failed"
cipher_sha="$(sha256sum "$tmp/source.dump.age" | cut -d' ' -f1)"

# Durable encrypted object, not a GitHub artifact or temporary Compute filesystem.
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 12)"
object="${ERP_BACKUP_STORE_URI%/}/erp-demo-${run_id}.dump.age"
aws s3 cp "$tmp/source.dump.age" "$object" --only-show-errors >"$tmp/upload.out" 2>&1 \
  || refuse "Encrypted object upload failed"
aws s3 cp "$object" "$tmp/remote.dump.age" --only-show-errors >"$tmp/download.out" 2>&1 \
  || refuse "Remote archive read-back failed"
[[ "$(sha256sum "$tmp/remote.dump.age" | cut -d' ' -f1)" == "$cipher_sha" ]] \
  || refuse "Encrypted archive checksum mismatch"
age -d -i "$ERP_BACKUP_AGE_IDENTITY_FILE" -o "$tmp/remote.dump" "$tmp/remote.dump.age" \
  2>"$tmp/decrypt.err" || refuse "Remote backup cannot be decrypted"
[[ "$(sha256sum "$tmp/remote.dump" | cut -d' ' -f1)" == "$dump_sha" ]] \
  || refuse "Decrypted backup checksum mismatch"
cmp -s "$tmp/source.dump" "$tmp/remote.dump" || refuse "Read-back differs from snapshot"

pg_from_url "$ERP_RESTORE_TARGET_URL"
pg_restore --exit-on-error --no-owner --no-acl \
  --dbname="$PGDATABASE" "$tmp/remote.dump" 2>"$tmp/restore.err" \
  || refuse "Isolated pg_restore failed"

# Schema equality and exact table counts + independent order-insensitive data signatures.
pg_from_url "$ERP_BACKUP_SOURCE_URL"
pg_dump --schema-only --no-owner --no-acl --file="$tmp/source-schema.sql" \
  2>"$tmp/schema-source.err" || refuse "Source schema inspection failed"
pg_from_url "$ERP_RESTORE_TARGET_URL"
pg_dump --schema-only --no-owner --no-acl --file="$tmp/restore-schema.sql" \
  2>"$tmp/schema-restore.err" || refuse "Restored schema inspection failed"
sed -E '/^\\(un)?restrict /d; /^-- Dumped (from database|by pg_dump) version/d' \
  "$tmp/source-schema.sql" > "$tmp/source-normalized.sql"
sed -E '/^\\(un)?restrict /d; /^-- Dumped (from database|by pg_dump) version/d' \
  "$tmp/restore-schema.sql" > "$tmp/restore-normalized.sql"
diff -q "$tmp/source-normalized.sql" "$tmp/restore-normalized.sql" >"$tmp/diff.out" \
  || refuse "Schema mismatch; review in isolated environment"
node "$(dirname "$0")/reconcile-isolated-restore.mjs" || refuse "Data reconciliation failed"

# The manifest is written only after a successful isolated restore and reconciliation.
verified_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"status":"PASS","verified_at":"%s","encrypted_sha256":"%s","dump_sha256":"%s","isolation":"localhost_erp_restore","migration_executed":false}\n' \
  "$verified_at" "$cipher_sha" "$dump_sha" >"$tmp/manifest.json"
aws s3 cp "$tmp/manifest.json" "$object.manifest.json" --only-show-errors >"$tmp/manifest-upload.out" 2>&1 \
  || refuse "Durable proof upload failed"
printf '%s\n' "BACKUP GATE PASS: encrypted snapshot read back and isolated restore reconciled."
printf 'Backup object: %s\n' "$object"
printf 'Encrypted SHA256: %s\n' "$cipher_sha"
printf '%s\n' "Migration not executed. Separate owner approval still required."
