import test from "node:test";
import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import { buildApp } from "./server.ts";
import { validIdempotencyKey } from "./contracts.ts";

test("public health is live, but database readiness fails closed", async () => {
  const server = buildApp();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const addr = server.address() as AddressInfo;
    const origin = `http://127.0.0.1:${addr.port}`;
    const live = await fetch(origin + "/health/live", { headers: { "x-request-id": "qa-12345678" } });
    assert.equal(live.status, 200);
    assert.equal(live.headers.get("x-request-id"), "qa-12345678");
    assert.equal((await live.json() as { status: string }).status, "live");
    const health = await fetch(origin + "/health");
    assert.equal(health.status, 503, "health fails closed without database connection");
    const ready = await fetch(origin + "/health/ready");
    assert.equal(ready.status, 503);
    const body = await ready.json() as { error: { code: string } };
    assert.equal(body.error.code, "NOT_READY");
    const mutation = await fetch(origin + "/v1/orders", { method: "POST" });
    assert.equal(mutation.status, 501);
    const unprovisioned = await fetch(origin + "/v1/auth/config");
    assert.equal(unprovisioned.status,503,"Identity must fail closed without provisioned installation/secrets/schema");
    const blocked = await fetch(origin + "/v1/admin/users");
    assert.equal(blocked.status,503);
    const meta = await fetch(origin + "/v1/meta/modules");
    assert.equal((await meta.json() as { modules: string[] }).modules.length, 6);
  } finally {
    await new Promise<void>((resolve, reject) => server.close((err) => err ? reject(err) : resolve()));
  }
});

test("idempotency-key syntax primitive rejects missing or short keys", () => {
  assert.equal(validIdempotencyKey(undefined), false);
  assert.equal(validIdempotencyKey("short"), false);
  assert.equal(validIdempotencyKey("sale-20261118-0001"), true);
});

test("readiness only succeeds when database/schema probe succeeds", async () => {
  const probes: Array<[() => Promise<boolean>, number]> = [
    [async () => true, 200],
    [async () => false, 503],
    [async () => { throw new Error("database offline"); }, 503],
  ];
  for (const [probe, expected] of probes) {
    const server = buildApp(probe);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    try {
      const addr = server.address() as AddressInfo;
      const ready = await fetch("http://127.0.0.1:" + addr.port + "/health/ready");
      assert.equal(ready.status, expected);
    } finally {
      await new Promise<void>((resolve, reject) => server.close((err) => err ? reject(err) : resolve()));
    }
  }
});

test("GET /health reflects real PostgreSQL reachability independently of schema migrations", async () => {
  const server = buildApp(async () => false, async () => true);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const addr = server.address() as AddressInfo;
    const origin = `http://127.0.0.1:${addr.port}`;
    const health = await fetch(origin + "/health");
    assert.equal(health.status, 200);
    const body = await health.json() as { database: string; status: string };
    assert.deepEqual({ database: body.database, status: body.status }, { database: "connected", status: "ok" });
    const ready = await fetch(origin + "/health/ready");
    assert.equal(ready.status, 503, "ERP readiness requires the verified schema and migration");
  } finally {
    await new Promise<void>((resolve, reject) => server.close((err) => err ? reject(err) : resolve()));
  }
});
