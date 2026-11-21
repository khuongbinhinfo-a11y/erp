# P0 Identity Bootstrap — never automatic

This service is **one installation per independent PostgreSQL database/backend/domain**. `bootstrapInstallation()` is an internal server-only function. It atomically creates the initial installation, MAIN branch and warehouse, an admin account and explicit installation/branch/warehouse role grants. It refuses all nonempty installation databases and uses a PostgreSQL advisory lock. It is NOT an HTTP endpoint; credentials never appear in source, tests use synthetic values.

Deployment prerequisites: approved versioned migration with a real, durable backup + successful isolated restore/reconciliation + separate owner permission; then run the approved operator bootstrap via a privileged maintenance process with credentials passed securely (not through GitHub commits/chat, URL query, web UI or logged CLI flags). This repository intentionally does not ship an automatically-running production bootstrap command, to avoid accidental tenant takeover.

New login throttle table keyed by HMAC-SHA256(secret, normalized username), no stored IP, login name, password or raw session tokens. HTTP layer must configure `ERP_THROTTLE_SECRET` with 32+ bytes and one installation ID from provider secret environment; login service is not exposed when missing. Five failures in ten minutes block 15 minutes per principal across workers, with row locking; no reliance on in-memory rate limiting.

CI migration and backup/restore tests use PostgreSQL 16 ephemeral only. Real erp-demo has no approved migration.

## Operator entrypoint
After **separate approval** of production backup, isolated restore/reconciliation and schema migration, authorized operator may invoke `npm run bootstrap:approved` with secure provider-managed environment values `DATABASE_URL`, `ERP_BOOTSTRAP_CONFIRM=OWNER_APPROVED_EMPTY_INSTALLATION`, `ERP_BOOTSTRAP_CODE`, `ERP_BOOTSTRAP_NAME`, `ERP_BOOTSTRAP_ADMIN_LOGIN`, `ERP_BOOTSTRAP_ADMIN_PASSWORD`. Never include credentials in command-line arguments, log, commit or chat. It refuses nonempty tenant DB.

Backend identity HTTP requires `ERP_INSTALLATION_ID` (returned securely by bootstrap), `ERP_UI_ORIGIN` (exact Vercel origin), and `ERP_THROTTLE_SECRET` (at least 32 bytes, secret manager); it fails closed without them. Before these gates, the Flutter UI offers **explicit read-only design preview** only. Bearer token is held in memory, cleared on logout, revalidated every two minutes, and expires after server-issued expiry.
