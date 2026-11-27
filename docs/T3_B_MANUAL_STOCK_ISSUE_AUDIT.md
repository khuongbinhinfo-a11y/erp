# T3-B — MANUAL xuất kho thực tế, lô/vị trí và ledger (27/11/2026)

## Source of truth and baseline
- Auxiliary main at start: `d11e2cd4abe27d1abfe879cbe4c8aff07dd4fa09`; primary main `4d484efbc1ed1b5a5512c39ee2ea4fe82e0c1dda`.
- Legacy read-only `binhnxwjfjxm/NPP-Platform` main `d39e8a87cdc8905a85d92ee3a4b8c7427b3ecd35`.
- Legacy source: `npp-core/api/src/services/sales-direct-stock-issue.js` (warehouse-first lock, issued qty, negative-stock/lot/location evidence and policy); `sales-manual-completion.js` and `customer-receivable.js` for later T5 receipt and AR.
- ERP source: `backend/db/migrations/0011_r3_inventory_ledger.sql` (immutable common ledger and view), `0021_t0_partial_reservation_policy.sql` (WARN/BLOCK/ALLOW policy), `0022_t1_sales_order_context.sql` (version-scoped MANUAL/TRIP/PICKUP), `0023_t6_pos_checkout.sql` (shared POS/AR ledger).

## KEEP / COPY-ADAPT / MISSING
| Source | Action | Contract |
| --- | --- | --- |
| Existing `inventory_ledger` and `inventory_stock_balance` | KEEP | Only actual ISSUE decreases warehouse on-hand; on-hand rebuildable from ledger |
| `sales_order_version_context` and order revision | KEEP | MANUAL must be confirmed, current version, warehouse-scope authorized |
| Legacy `sales-direct-stock-issue.js` warehouse-first serialization, no double issue | COPY-ADAPT | Partial items by exact immutable base quantity, per-issue source and immutable ledger lines, idempotent rollback/replay |
| Legacy location + lot FEFO and stock tracking | COPY-ADAPT | Storage locations, expiry-checked lot IDs, policy-required scope, classified existing stock; cannot issue from other lot/bin |
| Existing `inventory_guard_policy.negative_issue_mode` | KEEP/ADAPT | Explicit allow + warehouse permission + source evidence only; WARN never silently posts a negative ISSUE |
| Manual return before acceptance, delivered quantity, money/AR/COD | MISSING; T5-A/C | ISSUE is NOT delivery, settlement or AR; remain independent facts |

## Additive migration 0024
- `inventory_storage_location`, `inventory_product_lot`, `inventory_product_tracking`: warehouse+product scope.
- `inventory_scope_assignment` and view `inventory_scope_balance`: **classification, not additional stock**. Only quantities already available may be assigned; assignments cannot be updated/deleted. For future inbound stock by lot/bin, T3-C / purchase integration should use source-lineage movements and avoid duplicate aggregation.
- `sales_direct_issue`, `sales_direct_issue_line`: immutable fulfillment source per partial shipment, linking to canonical sales version and exact inventory movements. Multiple partial issues per order, no double-post by replay.
- Database guards: confirmed MANUAL/current version, quantity <= original snapshot, non-expired lots, **bidirectional** source/ledger match (including forged movement before header exists), no consumption of classified stock by unscoped POS/transfer; deferred posted-on-commit checks.
- Negative stock is disabled by default even when reserve shortage is WARN; only explicit warehouse policy `ALLOW` plus `inventory.negative.issue` RBAC and a matching MANUAL source permits untracked issue below zero. No negative issue in lot/location-tracked stock.

## API and UX
- `POST /v1/inventory/direct-issues`: branchId, warehouseId, orderId, version, lines `[{lineNo,quantityBase,locationId?,lotId?}]`, `allowNegative`. Requires `inventory.post` warehouse and `orders.update` branch, expected revision in If-Match and Idempotency-Key.
- Readback `GET /v1/inventory/direct-issues`, `GET /v1/inventory/direct-issues/totals` and `GET /v1/inventory/direct-issues/reconcile`: complete issued totals via server aggregate (no 500-event truncation), canonical base unit, and bidirectional source/ledger/warehouse balance checks.
- Lot/bin endpoints: `POST /v1/inventory/locations`, `/lots`, `/tracking-policy`, `/stock-scopes/assign`; `GET /v1/inventory/stock-scopes`.
- Flutter: linked MANUAL button on warehouse workspace, explicit dialog for partial quantity in **product base unit** and optional required lot/bin, setup UI for location/lot/tracking/stock classification, no optimistic 'success' before server response. Existing TRIP reservation is preserved.

## Gate and provider
- CI: backend typecheck, unit/PG integration, Flutter analyze/widget, Android native and Windows native build, Prisma Compute build-only, isolation gate. **Only exact final-head SUCCESS is releasable**.
- Codex review must be completed without findings at final head. Auxiliary merge and primary mirror only after green. Source tree comparison must match.
- This task adds migration **0024**: apply only via `backend/scripts/t3b-0024-codespaces-migration.mjs` in the authenticated primary-main Codespace with separately approved target, actual maintenance mode, durable encrypted backup readback and isolated PG17 restore rehearsal, post-migration schema/data checksum reconciliation. An operator may run `--check` as read-only preflight; `--apply` requires explicit owner approval and secret prerequisites.
- No automatic production DB migration or Compute deployment. Vercel manual production only after Git gate; backend deploy remains owner Codespaces command. Browser/UAT/Android device are separate from CI.

## Test scenarios
- Partial issue 2 + 3 of 5 → two distinct source documents, two immutable `inventory_ledger` ISSUE rows; fulfillment PARTIAL then COMPLETED, delivery NOT_DISPATCHED, payment and receivable remain untouched.
- Replay same key+body no duplicate, same key+different body denied, stale revision denied, concurrent same order one winner, amount exceeding remaining denied.
- Scope assignment cannot exceed available, wrong/unavailable/expired lot or missing required location rejected; untracked issuing cannot consume classified bins.
- Negative stock strict BLOCK and WARN rejected, ALLOW requires actor permission and explicit intent, never for lot/bin tracking.
- Reconciliation on source/line **in both directions** and overall on-hand is exact ledger projection, not client-maintained totals. Deferred trigger rejects a forged movement posted before its direct issue source header.
- PostgreSQL migration fresh/replay/drift and operator 0023→0024 validation, no production SQL until backup+restore gate.

## Dependencies
T3-C trip allocation, pick/pack and trip issue uses same ledger; T5-A accepts/returns actual delivered goods with correction/reversal, then T5-C posts receivable based on actual accepted qty and optional true receipt. T4 purchasing/AP must preserve shared posting invariants.
