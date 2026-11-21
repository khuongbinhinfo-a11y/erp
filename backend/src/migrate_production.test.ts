import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

const entry = resolve(process.cwd(), "src/migrate_production.ts");
const dangerous = [
  "ERP_MIGRATION_CONFIRM", "ERP_TARGET_DATABASE_ID", "ERP_BACKUP_OBJECT_KEY",
  "ERP_BACKUP_CIPHERTEXT_SHA256", "ERP_RESTORE_REHEARSAL",
  "ERP_BACKUP_RETENTION_GATE", "ERP_PRODUCTION_WRITES_FROZEN",
  "ERP_APPROVED_GIT_SHA", "ERP_MIGRATION_APPROVAL_REFERENCE",
  "ERP_POSTGRES_DIRECT_URL",
];

test("production migrations fail closed with no explicit owner decision", () => {
  const env = { ...process.env };
  for (const key of dangerous) delete env[key];
  const r = spawnSync(process.execPath, ["--experimental-strip-types", entry], {
    cwd: process.cwd(), env, encoding: "utf8", timeout: 15000,
  });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /MIGRATION_GATE_REFUSED_OR_FAILED_REVIEW_PROTECTED_LOGS/);
  assert.doesNotMatch(r.stderr, /postgres:\/\//);
});

test("production migrations reject CI or Vercel runtime even with confirmation marker", () => {
  for (const indicator of [{ GITHUB_ACTIONS: "true" }, { VERCEL: "1" }]) {
    const env = { ...process.env, ERP_MIGRATION_CONFIRM: "OWNER_APPROVED_ERP_DEMO_SCHEMA_0001_0005", ...indicator };
    const r = spawnSync(process.execPath, ["--experimental-strip-types", entry], {
      cwd: process.cwd(), env, encoding: "utf8", timeout: 15000,
    });
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /MIGRATION_GATE_REFUSED_OR_FAILED_REVIEW_PROTECTED_LOGS/);
  }
});
