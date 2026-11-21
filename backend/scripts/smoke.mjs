/**
 * Public, read-only release smoke. No database credentials or business data.
 * Prisma cloud-deploy-action returns the URL(s) of the actual deployed service.
 */
import assert from "node:assert/strict";

function getBaseUrl() {
  const map = JSON.parse(process.env.DEPLOY_URLS || "{}");
  const urls = Object.values(map).filter((x) => typeof x === "string" && /^https:\/\//.test(x));
  const direct = process.env.DEPLOY_URL;
  const unique = [...new Set([...(direct ? [direct] : []), ...urls])];
  assert.equal(unique.length, 1, "Expected exactly one actual Prisma Compute API URL");
  const url = new URL(unique[0]);
  assert.equal(url.protocol, "https:", "API smoke requires HTTPS");
  return url.origin;
}

async function waitForApi(base) {
  for (let i = 0; i < 24; ++i) {
    try {
      const response = await fetch(base + "/health/live", {
        method: "GET",
        signal: AbortSignal.timeout(5000),
        headers: { "cache-control": "no-cache" },
      });
      if (response.status === 200) {
        const json = await response.json();
        assert.equal(json.status, "live");
        return;
      }
    } catch { /* Service can still be starting. */ }
    await new Promise((resolve) => setTimeout(resolve, 1500));
  }
  throw new Error("Deployed API did not become live");
}

async function checkedGet(url) {
  const response = await fetch(url, {
    signal: AbortSignal.timeout(7000),
    headers: { "cache-control": "no-cache" },
  });
  return { status: response.status, body: await response.json() };
}

const base = getBaseUrl();
await waitForApi(base);
const health = await checkedGet(base + "/health");
assert.equal(health.status, 200, "PostgreSQL is not connected to deployed backend");
assert.equal(health.body.database, "connected");
const modules = await checkedGet(base + "/v1/meta/modules");
assert.equal(modules.status, 200);
assert.deepEqual(modules.body.modules, ["Công Ty", "MCP", "Quản trị", "Bán Lẻ", "Giao Hàng", "Đặt Hàng"]);
assert.equal(modules.body.readOnly, true);
const ready = await checkedGet(base + "/health/ready");
console.info(JSON.stringify({
  event: "erp_release_smoke",
  backendUrl: base,
  live: true,
  postgresConnected: true,
  modules: 6,
  schemaReady: ready.status === 200,
}));
// Deploy smoke proves a real running API and real PostgreSQL connectivity.
// ERP business readiness is a *separate* gated milestone: production migrations
// require backup/restore rehearsal and explicit owner authorization. 503 with
// NOT_READY is expected until that gate passes; any other failure remains red.
if (ready.status === 503) {
  assert.equal(ready.body?.error?.code, "NOT_READY", "Unexpected readiness error");
  console.warn("::warning title=ERP schema pending::Database connected, but schema migration is not approved/applied. Business APIs are not ready.");
} else {
  assert.equal(ready.status, 200, "Unexpected ERP readiness HTTP status");
  assert.equal(ready.body?.status, "ready", "Unexpected ERP readiness response");
}
// Never turn an unimplemented mutation into apparent business readiness.
const denied = await fetch(base + "/v1/orders", { method: "POST", signal: AbortSignal.timeout(7000) });
assert.equal(denied.status, 501, "Mutation contract must remain closed until implemented and authorized");
