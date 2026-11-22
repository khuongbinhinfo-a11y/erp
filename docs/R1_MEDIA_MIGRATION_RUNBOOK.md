# ERP-DB — Codespaces migration R1 0015–0016

**Operator:** `backend/scripts/r1-media-codespaces-migration.mjs`. This is for **existing**
`erp-backend/ERP-DB` (`proj_ud3b1s5yn03vh0zp9cbs2upa`,
`db_jg2bl98hzi1jm06lwo0i4rqx`) only, from the **primary** repository's
authenticated `gustavjung24-ops` main Codespace. Never run against `erp-demo`.

**Only two migrations:** `0015_r1_unit_dictionary.sql` and
`0016_r1_product_media.sql`. A consistent 14-migration baseline, current
GitHub main SHA, checksum history, legacy UOM validity and unchanged existing
table signatures are required. The script never accepts arbitrary DB URLs.

## Preflight and apply

- Secondary PR CI PASS + Codex CLEAN, primary sync/merge and approved exact main
  SHA are prerequisites. The script verifies current remote main. Check the
  published CI/review evidence separately; local operator checks aren't a CI substitute.
- Main must have a clean worktree (lockfile-only changes allowed). The Codespace
  must authenticate as `gustavjung24-ops` with its short-lived `ghu_` token.
  Its forwarded-port TLS challenge proves process location.
- Protected Codespaces environment must already hold the R3-proven backup inputs:
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `ERP_BACKUP_S3_ENDPOINT`, `ERP_AGE_RECIPIENT`,
  `ERP_AGE_RECOVERY_IDENTITY`. Do not paste, echo, commit or print them.
  Recovery private identity **must** match the intended age recipient.
  If any required variable is missing, stop and provision it through protected
  secrets; do not bypass the operator.
- Tools: authenticated Prisma CLI in `backend/deploy`, Node 22+, `gh`,
  `pg_dump`/`pg_restore` **17**, `pg_isready`, `age`, `age-keygen`,
  `aws` CLI, Docker with access to PostgreSQL 17 image.

Run from primary GitHub Codespaces (set approval SHA dynamically **only after**
reviewing the exact current main commit):

```bash
cd /workspaces/ERP
git switch main
git pull --ff-only origin main
git status --short
cd backend
npm ci
(cd deploy && npm ci)
export ERP_APPROVED_SHA="$(git -C .. rev-parse HEAD)"
export ERP_TARGET_PROJECT_ID="proj_ud3b1s5yn03vh0zp9cbs2upa"
export ERP_TARGET_DATABASE_ID="db_jg2bl98hzi1jm06lwo0i4rqx"
npm run db:migrate:r1-media:codespaces -- --check
```

Before `--apply`, put production backend into READ_ONLY maintenance (this
changes provider configuration; owner must authorize the maintenance window).
Prisma project env values are only used by **new** deployments:

```bash
cd /workspaces/ERP/backend
npm run build:compute
cd deploy
npx --no-install prisma project env update ERP_MAINTENANCE_MODE=READ_ONLY --role production --project proj_ud3b1s5yn03vh0zp9cbs2upa
npx --no-install prisma deploy --entry ./module.ts
cd ..
node -e 'fetch("https://gh30k50bvsc0o9298w9leivf.sin.prisma.build/health/live").then(r=>r.json()).then(j=>{if(j.service!=="erp-api"||j.maintenance!==true)process.exit(1);console.log("COMPUTE_READ_ONLY_CONFIRMED")}).catch(()=>process.exit(1))'
```

Only then, with an explicit owner approval for the exact target and release:

```bash
cd /workspaces/ERP/backend
export ERP_R1_MEDIA_MIGRATION_APPROVAL="OWNER_APPROVED_R1_MEDIA_0015_0016_ERP_DB"
npm run db:migrate:r1-media:codespaces -- --apply
unset ERP_R1_MEDIA_MIGRATION_APPROVAL
```

`--apply` fails closed unless maintenance=true and:

1. A newly minted target-bound, TLS direct database credential checks baseline
   0001–0014 and all checksums. This credential is revoked in a `finally`.
2. PG17 `pg_dump -Fc` is age-encrypted and uploaded to a private durable
   Prisma Object Store S3 bucket with unique R1-MEDIA object key.
3. The **actual remote** backup is read back, hash-checked, decrypted with the
   actual recovery identity and restored into an isolated PG17 Docker database.
4. All old-table row signatures reconcile. Replay applies exactly 0015–0016;
   verifies units are backfilled with unchanged code/name and media table empty.
5. Read-only backend, baseline schema and old-table signatures are rechecked
   on ERP-DB before a transactionally applied migration with advisory lock.
   Post-commit schema, checksum and data signatures are read back.

After `ERP_R1_MEDIA_0015_0016_MIGRATION_PASS_AND_RECONCILED` **and** the
durable backup object/hash and credential cleanup status have been verified,
owner may reopen backend and redeploy:

```bash
cd /workspaces/ERP/backend
npm run build:compute
cd deploy
npx --no-install prisma project env update ERP_MAINTENANCE_MODE=NORMAL --role production --project proj_ud3b1s5yn03vh0zp9cbs2upa
npx --no-install prisma deploy --entry ./module.ts
cd ..
npm run db:migrate:r1-media:codespaces -- --check
```

Then verify `/health/live` maintenance=false, `/health/ready` 200,
UOM listing/creation, product picture upload/signature/gallery and customer/
branch isolation on the real app. These are distinct from CI.

**Failure:** Leave backend read-only and inspect protected logs. Do not rerun
`--apply` blindly after a post-commit error; first run `--check` and inspect
`schema_migrations` and backup proof. Never restore to ERP-DB automatically,
drop an existing table, or label CI backup a production snapshot.
