import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID, createHash } from "node:crypto";
import { Pool } from "pg";
import { AuthDenied, hashPassword, verifyPassword, signIn, signOut, resolveSession } from "./auth.ts";

test("scrypt stores salted hash rather than plaintext and rejects incorrect passwords", async () => {
  const hash1 = await hashPassword("TestingSecret2026!");
  const hash2 = await hashPassword("TestingSecret2026!");
  assert.notEqual(hash1,hash2);
  assert.ok(!hash1.includes("TestingSecret2026"));
  assert.equal(await verifyPassword("TestingSecret2026!",hash1),true);
  assert.equal(await verifyPassword("DifferentSecret2026!",hash1),false);
  await assert.rejects(hashPassword("short"),AuthDenied);
});

test("PostgreSQL auth session is installation-scoped, hashed, revocable, expiring and audited", {
  skip: !process.env.DATABASE_URL,
}, async () => {
  const pool = new Pool({connectionString:process.env.DATABASE_URL,max:4});
  try {
    const makeTenant = async () => (await pool.query<{id:string}>(
      "INSERT INTO installation(code,display_name) VALUES($1,'Synthetic Auth') RETURNING id",
      ["ci_" + randomUUID().slice(0,12)],
    )).rows[0]!.id;
    const tenant=await makeTenant();
    const otherTenant=await makeTenant();
    const login="user_" + randomUUID().slice(0,10);
    const password="SecureCI-" + randomUUID();
    const hash=await hashPassword(password);
    const actor=(await pool.query<{id:string}>(
      "INSERT INTO app_user(installation_id,login_name,password_hash) VALUES($1,$2,$3) RETURNING id",
      [tenant,login,hash],
    )).rows[0]!.id;
    await assert.rejects(signIn(pool,tenant,login,"WrongSecret123456","auth-fail-1"),AuthDenied);
    await assert.rejects(signIn(pool,tenant,"not_existing",password,"auth-fail-2"),AuthDenied);
    const signed=await signIn(pool,tenant,login,password,"auth-ok-1");
    assert.equal(signed.actorId,actor);
    assert.equal(signed.token.length,43);
    assert.ok(new Date(signed.expiresAt).getTime()>Date.now());
    const actualHash=createHash("sha256").update(signed.token).digest("hex");
    const stored=(await pool.query<{token_hash:string}>(
      "SELECT token_hash FROM app_session WHERE installation_id=$1 AND user_id=$2",
      [tenant,actor],
    )).rows[0]!.token_hash;
    assert.equal(stored,actualHash);
    assert.ok(!stored.includes(signed.token));
    const client=await pool.connect();
    try {
      assert.deepEqual(await resolveSession(client,tenant,signed.token),{actorId:actor,installationId:tenant});
      assert.equal(await resolveSession(client,otherTenant,signed.token),null);
      assert.equal(await resolveSession(client,tenant,"broken-token"),null);
    } finally {client.release()}
    assert.equal(await signOut(pool,otherTenant,signed.token,"auth-wrong-tenant"),false);
    assert.equal(await signOut(pool,tenant,signed.token,"auth-logout-1"),true);
    assert.equal(await signOut(pool,tenant,signed.token,"auth-logout-2"),false);
    const client2=await pool.connect();
    try {assert.equal(await resolveSession(client2,tenant,signed.token),null)}
    finally {client2.release()}
    const expired=await signIn(pool,tenant,login,password,"auth-ok-2");
    await pool.query(
      "UPDATE app_session SET issued_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE token_hash=$1",
      [createHash("sha256").update(expired.token).digest("hex")],
    );
    const client3=await pool.connect();
    try {assert.equal(await resolveSession(client3,tenant,expired.token),null)}
    finally {client3.release()}
    const disabled=await signIn(pool,tenant,login,password,"auth-ok-3");
    await pool.query("UPDATE app_user SET disabled=true WHERE installation_id=$1 AND id=$2",[tenant,actor]);
    const client4=await pool.connect();
    try {assert.equal(await resolveSession(client4,tenant,disabled.token),null)}
    finally {client4.release()}
    await assert.rejects(signIn(pool,tenant,login,password,"auth-fail-disabled"),AuthDenied);
    const audit=(await pool.query<{event_code:string;cnt:string}>(
      "SELECT event_code,count(*)::text AS cnt FROM auth_event WHERE installation_id=$1 GROUP BY event_code",
      [tenant],
    )).rows;
    assert.equal(audit.find(x=>x.event_code==="login.denied")?.cnt,"3");
    assert.equal(audit.find(x=>x.event_code==="login.success")?.cnt,"3");
    assert.equal(audit.find(x=>x.event_code==="session.revoked")?.cnt,"1");
    await assert.rejects(
      pool.query("DELETE FROM auth_event WHERE installation_id=$1",[tenant]),
      /append-only/,
    );
  } finally {await pool.end()}
});
