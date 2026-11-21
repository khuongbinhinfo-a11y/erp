# Issue #7 — Catalog / Prices: first working vertical slice
Baseline: main 53b7b34edf331eecdb4df07f61639079641b077d
Scope: first integration phase; issue remains OPEN until all checklist criteria and production UAT.

## Implemented
- PostgreSQL migration `0006_catalog.sql` adds installation+branch scoped customers,
  suppliers, product groups, products, exact NUMERIC unit factors, price lists,
  and immutable price entry history.
- Named branch-scoped endpoints under `/v1/catalog/`: `branches`, `customers`,
  `suppliers`, `groups`, `products`, `price-lists`, `prices`, `warehouses`.
  GET requires a bearer session and appropriate branch catalog.read or explicit
  warehouse grant. POST creation requires catalog.write with a branch, Idempotency-Key,
  If-Match: 0, atomic receipt, and append-only audit. `warehouses` are read-only
  until inventory module supplies its own write flow.
- Prices and conversion factors arrive as decimal strings. PostgreSQL NUMERIC
  and composite FKs enforce precision and installation/branch references.
  New price entries append versions; changing old price rows is blocked by a trigger.
- Flutter Company uses authenticated API rows and an authorized branch picker,
  with empty/error/loading states, create dialogs, live price versions and no
  pretended availability or inventory posting. Preview continues to show
  an explicit read-only mockless empty state.
- CI includes fresh migration, replay, integration HTTP checks for duplicate
  idempotency keys, cross-branch denial, precision, price immutability and audit;
  plus Flutter widget/API mocking tests.

## Deployment and scope limits
- The installed production schema remains 0001–0005 until an independently approved
  and verified migration 0006 is run. The catalog handler checks 0006 migration
  history and returns 503 instead of falsely claiming availability.
- The current production migration operator `migrate_production.ts` is an older
  one-time 0001–0005 gate and MUST NOT be reused for catalog 0006.
- Backend and frontend require explicit production deployment targets after the
  schema gate has been approved and tested. No production migrations or deploys
  are performed in this issue-start commit.
- The order confirmation stale-price guard, inventory availability, full
  edit/deactivate flows, pricing-policy expansion, and production browser UAT
  are NOT yet completed. These remain milestones of #7/#8/#9, respectively.

## Issue #7 control & pricing checks (20/11/2026)
- `0007_catalog_controls.sql` adds group revision/active and a price lookup index. Apply 0006+0007 only through the separately approved production migration procedure.
- Versioned PATCH on catalog customers, suppliers, groups, products and price-lists. Requires Idempotency-Key, If-Match revision, installation/branch catalog.write, and transactional audit. Codes/SKUs and base unit remain immutable; prices remain append-only.
- GET `/v1/catalog/prices/quote` resolves latest effective active price in a branch. POST `/v1/catalog/prices/check` returns 409 PRICE_STALE for an outdated entry ID; both are catalog.read-gated and mark `stockStatus=NOT_VERIFIED` and `confirmationAllowed=false`.
- Not an order confirmation endpoint. Stock ledger, stock check and order posting still require #8/#9 and must fail closed until implemented.

## Prepared manual-only migration operator (20/11/2026)
- `backend/src/migrate_catalog_production.ts` applies exactly 0006–0007, but ONLY from a protected operator after separately approved current-source encrypted backup, isolated restore, reconciliation, exact SHA and production freeze. It refuses GitHub Actions, Vercel and Compute runtime; no automatic migration.
- Negative tests guard operator fail-closed behavior. Provider database backups read-back (20/11) returned an empty automatic backup list: this is NOT a usable production backup or restore rehearsal.
- This change DOES NOT apply production SQL or deploy production code. Do not use the obsolete initial-only 0001–0005 operator for catalog migrations.
