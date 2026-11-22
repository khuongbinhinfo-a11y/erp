#!/usr/bin/env bash
# CI-only disaster-recovery rehearsal; never accepts provider/production databases.
set -euo pipefail
: "${DATABASE_URL:?DATABASE_URL is required}"
: "${ERP_DB_MIGRATION_TARGET:?CI target confirmation required}"
if [[ "$ERP_DB_MIGRATION_TARGET" != "ci" || "${NODE_ENV:-}" == "production" ]]; then
  echo "Refusing backup rehearsal outside ephemeral CI" >&2
  exit 2
fi

# This script must NOT be reused against Prisma's real erp-demo.
if ! node --input-type=module -e '
  const u = new URL(process.env.DATABASE_URL);
  const ok = ["postgresql:","postgres:"].includes(u.protocol)
    && ["127.0.0.1","localhost"].includes(u.hostname)
    && u.pathname === "/erp_ci" && u.username === "erp_ci";
  process.exit(ok ? 0 : 1);
'; then
  echo "Refusing non-local/non-CI PostgreSQL target" >&2
  exit 2
fi

tmp_dir="$(mktemp -d)"
chmod 700 "$tmp_dir"
restore_url="$(node --input-type=module -e '
  const u = new URL(process.env.DATABASE_URL);
  u.pathname = "/erp_ci_restore_rehearsal";
  process.stdout.write(u.href);
')"
cleanup() {
  dropdb --if-exists --maintenance-db="$DATABASE_URL" erp_ci_restore_rehearsal >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

# No -x / no connection URL or credentials printed to logs. CI archive remains private and temporary.
docker run --rm --network host --env DATABASE_URL --volume "$tmp_dir:/backup" postgres:16 \
  sh -ec 'exec pg_dump --format=custom --no-owner --no-acl --file=/backup/erp_ci.dump "$DATABASE_URL"'
test -s "$tmp_dir/erp_ci.dump"
sha256sum "$tmp_dir/erp_ci.dump" | awk '{print $1}' >"$tmp_dir/erp_ci.sha256"

createdb --maintenance-db="$DATABASE_URL" erp_ci_restore_rehearsal
RESTORE_URL="$restore_url" docker run --rm --network host --env RESTORE_URL --volume "$tmp_dir:/backup:ro" postgres:16 \
  sh -ec 'exec pg_restore --exit-on-error --no-owner --no-acl --dbname="$RESTORE_URL" /backup/erp_ci.dump'

# Verify restore is usable: data, migration history, constraints and audit triggers.
original_migrations="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atc 'SELECT count(*) FROM public.schema_migrations')"
restored_migrations="$(psql "$restore_url" -v ON_ERROR_STOP=1 -Atc 'SELECT count(*) FROM public.schema_migrations')"
if [[ "$original_migrations" != "$restored_migrations" ]]; then echo "CI restore migration count mismatched" >&2; exit 1; fi
if [[ "$restored_migrations" != "13" ]]; then echo "CI restore expected 13 migrations, got $restored_migrations" >&2; exit 1; fi

for relation in installation branch warehouse app_user app_role role_permission user_role mutation_receipt audit_event user_role_warehouse app_session auth_event auth_login_throttle catalog_customer catalog_supplier catalog_product_group catalog_product catalog_unit catalog_price_list catalog_price_entry sales_order sales_order_version sales_order_line sales_order_sequence catalog_sell_sku catalog_sku_barcode catalog_sales_channel catalog_sku_price_rule catalog_sku_price_retirement inventory_ledger inventory_reservation purchase_order_sequence purchase_order purchase_order_line purchase_receipt purchase_receipt_line inventory_transfer inventory_transfer_line inventory_transfer_receipt inventory_transfer_receipt_line; do
  source_count="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "SELECT count(*) FROM public.$relation")"
  target_count="$(psql "$restore_url" -v ON_ERROR_STOP=1 -Atc "SELECT count(*) FROM public.$relation")"
  if [[ "$source_count" != "$target_count" ]]; then echo "CI restore row count mismatched: $relation" >&2; exit 1; fi
done
trigger_count="$(psql "$restore_url" -v ON_ERROR_STOP=1 -Atc "SELECT count(*) FROM pg_trigger WHERE tgname IN ('audit_event_append_only','mutation_receipt_write_once','catalog_price_history_append_only','sales_order_identity_guard','sales_order_version_guard','sales_order_line_guard','catalog_sell_sku_guard','catalog_unit_sku_immutability','catalog_sku_price_immutable','sales_order_channel_guard','catalog_sku_price_retirement_immutable','inventory_ledger_immutable','inventory_reservation_guard','inventory_movement_insert_guard','inventory_reservation_insert_guard','purchase_order_line_insert_guard','purchase_order_line_immutable','purchase_receipt_immutable','purchase_receipt_line_immutable','purchase_receipt_line_guard','purchase_order_guard','inventory_transfer_line_guard','inventory_transfer_header_guard','inventory_transfer_receipt_immutable','inventory_transfer_receipt_line_immutable','inventory_transfer_ledger_guard','inventory_transfer_receipt_line_guard','inventory_transfer_in_commit_guard','inventory_transfer_out_commit_guard') AND NOT tgisinternal")"
if [[ "$trigger_count" != "29" ]]; then echo "CI restore expected 29 audit/immutability triggers, got $trigger_count" >&2; exit 1; fi
table_count="$(psql "$restore_url" -v ON_ERROR_STOP=1 -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
if [[ "$table_count" != "43" ]]; then echo "CI restore expected 43 public tables/views: tables, got $table_count" >&2; exit 1; fi
echo '{"event":"ci_backup_restore_rehearsal","backup":"verified","restore":"verified","data_reconciliation":"verified","scope":"ephemeral_postgres_only"}'
