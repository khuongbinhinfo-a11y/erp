import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { Pool } from "pg";
import { canonicalPayload, executeMutation, MutationFault, requireRevision, type MutationContext } from "./mutation.ts";

test("fingerprints ignore object ordering and reject fractional JS numbers for Decimal safety", () => {
  assert.equal(canonicalPayload({ b: { z: 1, a: "1.20" }, a: true }),
    canonicalPayload({ a: true, b: { a: "1.20", z: 1 } }));
  assert.throws(() => canonicalPayload({ amount: 1.25 }), (e) =>
    e instanceof MutationFault && e.code === "INVALID_CONTEXT");
  assert.throws(() => requireRevision(3, 2), (e) =>
    e instanceof MutationFault && e.code === "REVISION_CONFLICT");
});

test("PostgreSQL concurrency, lost ACK replay, cross-payload conflict, revoke and rollback", {
  skip: !process.env.DATABASE_URL,
}, async () => {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
  try {
    const install = (await pool.query<{ id: string }>(
      "INSERT INTO installation(code, display_name) VALUES ($1,'CI synthetic installation') RETURNING id",
      ["ci_" + randomUUID().slice(0, 12)],
    )).rows[0]!.id;
    const actor = (await pool.query<{ id: string }>(
      "INSERT INTO app_user(installation_id,login_name,password_hash) VALUES ($1,$2,$3) RETURNING id",
      [install, "ci_" + randomUUID().slice(0, 12), "x".repeat(64)],
    )).rows[0]!.id;
    const key = "qa-" + randomUUID();
    const branchCode = "b_" + randomUUID().slice(0, 12);
    const context: MutationContext = {
      installationId: install, actorId: actor, requestId: "qa-mutation-1",
      action: "branch.create", idempotencyKey: key, expectedRevision: 0,
      payload: { code: branchCode, numericQty: "1.250" },
    };
    let writes = 0;
    const handlers = {
      authorize: async () => true,
      execute: async (client: import("pg").PoolClient) => {
        writes++;
        const result = await client.query<{ id: string }>(
          "INSERT INTO branch(installation_id,code,name) VALUES($1,$2,'CI synthetic branch') RETURNING id",
          [install, branchCode],
        );
        return { status: 201, body: { branchId: result.rows[0]!.id } };
      },
    };
    const [a, b] = await Promise.all([
      executeMutation(pool, context, handlers),
      executeMutation(pool, { ...context, requestId: "qa-mutation-2", payload: { numericQty: "1.250", code: branchCode } }, handlers),
    ]);
    assert.equal(writes, 1, "concurrent duplicate executes business once");
    assert.equal(a.replayed !== b.replayed, true);
    assert.deepEqual(a.body, b.body);
    assert.equal((await pool.query<{ count: string }>(
      "SELECT count(*) FROM audit_event WHERE installation_id=$1 AND action_code='branch.create'", [install]
    )).rows[0]?.count, "1");
    assert.equal((await pool.query<{ count: string }>(
      "SELECT count(*) FROM branch WHERE installation_id=$1 AND code=$2", [install, branchCode]
    )).rows[0]?.count, "1");
    await assert.rejects(
      executeMutation(pool, { ...context, payload: { code: "different" } }, handlers),
      (e) => e instanceof MutationFault && e.code === "IDEMPOTENCY_CONFLICT",
    );
    await assert.rejects(
      executeMutation(pool, context, { ...handlers, authorize: async () => false }),
      (e) => e instanceof MutationFault && e.code === "FORBIDDEN",
    );
    assert.equal(writes, 1);
    const retry = { ...context, idempotencyKey: "qa-" + randomUUID(), action: "branch.retry" };
    await assert.rejects(executeMutation(pool, retry, {
      authorize: async () => true,
      execute: async (client) => {
        await client.query("INSERT INTO branch(installation_id,code,name) VALUES($1,$2,'Will rollback')",
          [install, "temp_" + randomUUID().slice(0, 10)]);
        throw new Error("simulate error before COMMIT");
      },
    }), /simulate error before COMMIT/);
    const done = await executeMutation(pool, retry, {
      authorize: async () => true,
      execute: async () => ({ status: 200, body: { recovered: true } }),
    });
    assert.equal(done.replayed, false, "failed transaction does not reserve a key");
    assert.equal((await pool.query<{ count: string }>(
      "SELECT count(*) FROM audit_event WHERE installation_id=$1 AND action_code='branch.retry'", [install]
    )).rows[0]?.count, "1");
    await assert.rejects(
      pool.query("DELETE FROM audit_event WHERE installation_id=$1", [install]),
      /append-only/,
    );
    await assert.rejects(
      pool.query("UPDATE mutation_receipt SET response_status=202 WHERE installation_id=$1", [install]),
      /cannot be rewritten/,
    );
  } finally {
    await pool.end();
  }
});
