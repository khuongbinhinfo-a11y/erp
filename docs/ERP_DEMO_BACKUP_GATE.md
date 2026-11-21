# Lô A — `erp-demo` backup/restore gate (19/11/2026)

**Status (19/11/2026):** REAL ENCRYPTED BACKUP EXISTS; OFFSITE ENCRYPTED COPY VERIFIED; PORTABLE ISOLATED RESTORE VERIFIED WITH TWO PROVIDER EXTENSIONS EXCLUDED. Production migration, bootstrap, new backend release and browser UAT have NOT been executed. No native Prisma Pro automated-backup record is expected for this manual snapshot.

## Verified baseline

- GitHub `main`: `85ed28b985046f4e73771d082d2b218c9fe5da25` (check again immediately before any operational action).
- Source: Prisma workspace `wksp_hpw4yyeylyb2ct4b0zqlzf1m`, project `erp-sales`, database `erp-demo` (`db_xg7823erugsd1ym7c8lf0l9h`), Singapore.
- Compute is in separate `erp-backend` project and must continue to connect to the existing source database; no new application database is provisioned.
- Prisma backup API: zero backup records at inspection. Prisma Free does not provide automatic backup; its **direct PostgreSQL connection supports `pg_dump`** ([official Prisma guide](https://www.prisma.io/docs/postgres/database/backups)).
- Direct read-only PostgreSQL 17 catalog inspection later proved **zero user tables** on real `erp-demo` before and after the encrypted backup. Prisma's SQL connector returned `Database not found`, but direct libpq worked. The archived TOC contains just Prisma-managed `prisma_postgres` and `pg_stat_statements` extension definitions/comments; no ERP objects. The Prisma-8 migration history endpoint remains unavailable.
- Versions `0001_identity.sql` through `0005_admin_revision_throttle.sql` exist on `main`. The existing migration CLI deliberately permits only ephemeral `localhost/erp_ci`; keep it restricted.

## Operator-only backup and rehearsal (no Prisma Pro)

Run `backend/scripts/backup-restore-gate.sh` only from a **protected operator runtime** with PostgreSQL client tools, Node 22+, the backend's `pg` dependency, `age`, AWS CLI (or S3-compatible endpoint configuration), and OpenSSL. This is **not** a GitHub Actions job and is not deployed to Prisma Compute.

Provision and verify the following *outside this repository* first:

1. A dedicated Prisma **direct** (not pooled) source connection with the least privilege needed to dump all ERP objects. Provide it through the operator secret manager. Do not paste the URI into a chat, file, issue, CI log or GitHub secret.
2. A separate, ephemeral PostgreSQL instance listening on the operator's localhost, with an **empty and pre-created** database named `erp_restore_*`. It must be isolated from the source PostgreSQL server. This instance must use the same PostgreSQL major version and supported extensions.
3. A **private S3-compatible object bucket** external to Compute's ephemeral filesystem, with encryption in transit, object access restricted to the backup operator, retention/immutability policy, deletion safeguards and an independent recovery/key custody procedure. Use workload identity for object-store access where possible. Confirm upload **and read-back** are permitted. The script encrypts the logical dump client-side with `age` before upload; its decryption identity must be kept outside GitHub and backed up securely.
4. A source write-freeze/maintenance window so source-versus-restored data signatures are comparable, and confirmation that backups and restore contain no other customer's data.

The protected operator environment must supply these **variable names only**; the values must remain in its secret manager:

| Variable | Purpose |
| --- | --- |
| `ERP_BACKUP_SOURCE_URL` | Real `erp-demo` direct PostgreSQL connection |
| `ERP_RESTORE_TARGET_URL` | Independent `localhost/erp_restore_*` connection |
| `ERP_BACKUP_STORE_URI` | Private external `s3://bucket/prefix` |
| `ERP_BACKUP_AGE_RECIPIENT` | Public encryption recipient |
| `ERP_BACKUP_AGE_IDENTITY_FILE` | Protected local decryption key file |
| `ERP_BACKUP_GATE_CONFIRM` | Must equal `ISOLATED_RESTORE_ONLY` |
| `ERP_SOURCE_WRITES_QUIESCED` | Must equal `YES` only after actual write-freeze |
| `ERP_BACKUP_RETENTION_VERIFIED` | Must equal `YES` after external retention verification |

S3 client authentication and optional compatible endpoint configuration are supplied by the protected host, never by committing credentials. **Do not set confirmation flags without the real checks.**

Execute the script only from the backend working directory in the protected operator runtime. It refuses GitHub Actions, a pooled source, identical source/restore hosts, a non-local restore, or a restore database that is not empty. It takes a `pg_dump -Fc` snapshot, encrypts and uploads it, downloads and decrypts it, validates SHA-256, restores **only** to the verified isolated target, compares normalized schemas and checks exact relation counts, order-independent data signatures, sequences and PG major versions. It finally uploads a no-PII PASS manifest. Plaintext temporary files are deleted on exit.

## Go / no-go before migration 0001–0005

- Verify source database catalog objects, row counts, existing ERP migrations, extensions and non-ERP data **read-only**. If schema or ownership is unexpected, stop and review; do not assume it is empty.
- Keep object-store proof of the **real** source snapshot: backup object key, SHA-256, creation time, retention evidence, restored schema/data reconciliation result and recovery key custody test.
- Independently verify a restore from the remote encrypted object into an isolated database using the reviewed process. Confirm rows, sequences, constraints, triggers, migrations history and key table invariants. A local CI restore does not satisfy this.
- Review ordered migration SQL/checksums and run fresh, replay and drift tests. Do not run `backend/src/migrate.ts` against Prisma; `backend/src/migrate_production.ts` is a manually invoked fail-closed production operator entrypoint added on PR #16. It verifies direct Prisma hostname, exact demo database ID, approved Git SHA, encrypted snapshot checksum/object key, empty source schema, PG17, a signed-off backup exception and a separate owner approval reference.
- **STOP** until the owner gives separate explicit approval identifying source database, exact SHA and migration window. A verified backup/restore is necessary but not permission to migrate.
- After migration approval: read-back schema and readiness; only then separately approve secure admin bootstrap and production authentication secrets. No data writes from UI until authorization smoke/UAT passes.


## Actual backup and rehearsal evidence (19/11/2026)

**Real source read-back:** PostgreSQL 17, `erp-demo`, **0 user tables**. `pg_dump -Fc` produced 2,014-byte source archive; this is not an ERP schema export because the ERP migrations have not yet run.

**Encrypted snapshot:** bucket `erp-demo-backup-20261119` (`bkt_qf234cyyyqz2fot3jhqclk5k`), object `erp-demo-20261119T-backup.dump.age`, SHA-256 `54ee2ed373e73db40748e2e98aaf9cabb02edca883506ebc06282df2bbccf051`. Uploaded, downloaded, byte-compared, decrypted and compared to original, all PASS. `erp-demo-20261119T-backup.manifest.json` uploaded and read back. This encrypted file is NOT part of Prisma's automated backup inventory.

**Independent copy:** the *same* encrypted archive and manifest were downloaded from Prisma Object Store into Vercel persistent Drive `erp_backup_keyvault` (`/snapshots/`), using bucket-scoped read-only credentials. A newly created, network-denied, read-only Vercel Sandbox mounted the persistent Drive after the transfer sandbox was deleted and confirmed exact ciphertext SHA-256 and that both the manifest and decryption identity still existed. Decryption with the stored recovery identity was separately tested PASS. **Do not delete that Drive or its key.**

**Restore:** the original archive has four extension/comment TOC entries (`prisma_postgres` and `pg_stat_statements`). Ordinary PostgreSQL 18 cannot create Prisma's proprietary extension: unmodified restore FAILED at that extension. A second isolated PostgreSQL 18 restore excluding exactly those provider-only entries completed PASS and reconciled **0 source user tables = 0 target user tables**. This is a *qualified portable-domain restore*, not a full in-place restoration of Prisma-managed extensions or a rehearsal on PostgreSQL 17. Do not claim otherwise.

**Retention risk:** neither Prisma Object Store nor Vercel Drive is verified WORM/immutable or configured for enforced retention. Prisma Object Store does not provide object versioning. These two encrypted copies mitigate single-location loss for this **empty demo** database, but production-grade backup immutability, recurring snapshots, RPO/RTO and an extension-compatible disaster-recovery test are still required before real customer transactions.

**Candidate tests:** PostgreSQL 18 isolated fresh `0001`–`0005` migration PASS, replay PASS, 5 history rows/14 schema tables. Backend **13/13 PASS** (including first admin bootstrap + scoped identity routes and migration denial), TypeScript typecheck PASS, Composer typecheck PASS. These are independent Vercel Sandbox tests; GitHub Actions CI must separately PASS the **exact candidate SHA** before owner merge approval.

**Identity deployment:** Vercel project `erp` production `ERP_PUBLIC_API_URL` has been configured for the existing Prisma Compute API; a Vercel rebuild/release has not happened. Compute identity inputs are optional and fail-closed until installation ID, UI origin and throttle secret are set through the approved provider release process. Provider environment variables resolve at deployment time, so a separate CI-gated backend release is required before real login.

**Production migration decision:** NO GO until the owner explicitly accepts the qualified provider-extension restore and lack of WORM for this empty demo, verifies exact green SHA/backup, and grants a separate named `erp-sales/erp-demo` migration approval. The manual runner requires `ERP_BACKUP_RETENTION_GATE=OWNER_WAIVER_EMPTY_DEMO_NON_WORM` for this specific approved POC exception (or `ENFORCED_RETENTION_VERIFIED` if real immutable retention is later configured). Even with a waiver it rejects nonempty schemas. A waiver is NOT appropriate once business/customer transactions exist. No migration or real admin bootstrap has been executed.

## Limitations and rollback

This is a **logical snapshot**, not PITR. It cannot recover changes after the snapshot. If migration fails, halt traffic/mutations and request owner approval for a restore plan. **Never automatically restore into the production database.** Do not delete the protected backup before retention expires. The test restore database may contain sensitive data and must have a separately approved secure disposal/expiry policy.

See `docs/PRODUCTION_RUNBOOK.md`, `backend/scripts/ci-backup-restore.sh` (ephemeral CI only), `docs/P0_IDENTITY_BOOTSTRAP.md` and `docs/QA_MATRIX.md`.
