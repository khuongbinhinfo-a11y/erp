# ERP Prisma Compute backend — CI-gated release

**Compute project:** `erp-backend` (`proj_ud3b1s5yn03vh0zp9cbs2upa`) in Singapore. **Existing, unchanged database:** `erp-sales` / `erp-demo` (`db_xg7823erugsd1ym7c8lf0l9h`). Prisma Composer's `HostedStateBootstrapError` prevents managing an already populated Prisma project without Composer state; no second database is created.

The Composer module declares only the API service. It intentionally does not provision `rawPostgres()`/`postgres()`, so no second database is created. The backend uses PostgreSQL via `pg` and receives the URL through private service input `ERP_POSTGRES_URL`.

## Automatic deployment gates

1. Owner authorized CI-gated backend deployment for `erp-backend`. A migration of the existing production-role database remains separately gated.
2. Verify a usable backup, **restore rehearsal**, versioned migration checksum, drift and reconciliation. Prisma `main` is marked production-role even while used as demo.
3. Securely set `ERP_POSTGRES_URL` **in erp-backend project production environment** with a dedicated **TCP** connection for `erp-demo`. Do not paste the connection string in chat, repo, logs, Flutter or Vercel web assets. Prisma docs: <https://www.prisma.io/docs/compute/environment-variables>.
4. Verify GitHub project link is `gustavjung24-ops/ERP`, GitHub OIDC available, and repository `main` CI PASS on the **exact release SHA**.
5. GitHub CI `ERP quality gates` runs on every push to main. `ERP Prisma Compute deploy after green CI` automatically deploys the same verified SHA if and only if CI succeeds. No PR or preview deployment.
6. Read back app ID, deployment ID and URL. Test GET `/health/live` returns 200, GET `/health` returns 200 when PostgreSQL connects, GET `/v1/meta/modules` returns 200, and GET `/health/ready` returns 200 only after approved ERP migrations; record protected logs and smoke checks.

**Do not execute the existing `backend/src/migrate.ts` against Prisma.** Its CLI is intentionally limited to ephemeral `localhost/erp_ci`; a reviewed provider production migration mechanism must be implemented and approved separately.

Existing `erp-demo` has no recorded ERP schema or automated backup on Free. This deployment **does not run migrations**; production schema readiness will remain 503 until separately approved, backed up, and verified.

## Automated post-deploy smoke

The official Prisma GitHub action returns service URLs via `steps.deploy.outputs.urls`.
The CI-gated deployment validates `/health/live`, `/health` (actual TCP PostgreSQL),
`/v1/meta/modules` (6 declared read-only features), and `/health/ready`
(versioned ERP schema). Any failure marks the release job red. This does **not**
run or imply permission to run production migration; without an approved migration
the final readiness probe correctly returns 503 and the release is incomplete.
