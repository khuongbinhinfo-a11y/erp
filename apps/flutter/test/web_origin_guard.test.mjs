import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

const html = readFileSync(new URL("../web/index.html", import.meta.url), "utf8");
const found = /<script id="erp-canonical-origin">([\s\S]*?)<\/script>/i.exec(html);
assert.ok(found, "web entry must canonicalize known deployment aliases before bootstrap");
assert.ok(html.indexOf('id="erp-canonical-origin"') < html.indexOf('src="flutter_bootstrap.js"'),
  "origin guard must execute before Flutter reads the API origin");

function run(raw) {
  const location = new URL(raw);
  let target = null;
  const fake = {
    hostname: location.hostname, protocol: location.protocol,
    href: location.href, replace(next) { target = next; },
  };
  runInNewContext(found[1], { window: { location: fake }, URL });
  return target;
}
test("canonical production ERP origin is not redirected", () => {
  assert.equal(run("https://erp-gustavjung24-ops-projects.vercel.app/?x=1"), null);
});
test("all three assigned Vercel aliases go to the one CORS-allowed origin", () => {
  const source = [
    "erp-two-orcin.vercel.app",
    "erp-git-main-gustavjung24-ops-projects.vercel.app",
    "erp-p3oobrctl-gustavjung24-ops-projects.vercel.app",
  ];
  for (const alias of source) {
    assert.equal(
      run(`https://${alias}/products?branch=MAIN#details`),
      "https://erp-gustavjung24-ops-projects.vercel.app/products?branch=MAIN#details",
    );
  }
});
test("unrelated/custom/local origins are untouched", () => {
  assert.equal(run("http://localhost:3000/"), null);
  assert.equal(run("https://erp.customer.example/"), null);
  assert.equal(run("https://another-project.vercel.app/"), null);
});
