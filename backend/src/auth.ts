import { createHash, createHmac, randomBytes, scrypt as scryptCallback, timingSafeEqual } from "node:crypto";
import type { Pool, PoolClient } from "pg";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const REQUEST = /^[A-Za-z0-9._:-]{1,80}$/;
const SALT_BYTES = 16;
const KEY_BYTES = 32;
const SCRYPT_N = 16384;
const MAX_PASSWORD_BYTES = 256;
// ERP demo: retain the active browser/device session until explicit sign-out.
// This is a long-lived revocable server session, not a permanent password.
export const SESSION_SECONDS = 10 * 365 * 24 * 60 * 60;

export type SignedIn = { token: string; actorId: string; installationId: string; expiresAt: string };
export type AuthActor = { actorId: string; installationId: string };
export class AuthThrottled extends Error {
  constructor() { super('AUTH_THROTTLED'); }
}
export class AuthDenied extends Error {
  constructor() { super("AUTH_DENIED"); }
}
function validPassword(password: string): boolean {
  return typeof password === "string" && Buffer.byteLength(password,"utf8") >= 12
    && Buffer.byteLength(password,"utf8") <= MAX_PASSWORD_BYTES;
}
async function derive(password: string, salt: Buffer): Promise<Buffer> {
  return await new Promise<Buffer>((resolve,reject) => {
    scryptCallback(password,salt,KEY_BYTES,{N: SCRYPT_N,r: 8,p: 1},(err,key) => {
      if (err) reject(err);
      else resolve(key as Buffer);
    });
  });
}
export async function hashPassword(password: string): Promise<string> {
  if (!validPassword(password)) throw new AuthDenied();
  const salt = randomBytes(SALT_BYTES);
  return "scrypt:v1:" + salt.toString("base64url") + ":" + (await derive(password,salt)).toString("base64url");
}
export async function verifyPassword(password: string, encoded: string): Promise<boolean> {
  if (!validPassword(password) || typeof encoded !== "string") return false;
  const parts = encoded.split(":");
  if (parts.length !== 4 || parts[0] !== "scrypt" || parts[1] !== "v1") return false;
  const salt = Buffer.from(parts[2] ?? "","base64url");
  const expected = Buffer.from(parts[3] ?? "","base64url");
  if (salt.length !== SALT_BYTES || expected.length !== KEY_BYTES) return false;
  const actual = await derive(password,salt);
  return timingSafeEqual(expected,actual);
}
/** Each installation has one private server-side limiter key; required in HTTP production. */
export function validThrottleSecret(secret: string | undefined): secret is string {
  return typeof secret === "string" && Buffer.byteLength(secret,"utf8") >= 32;
}
function loginDigest(secret: string, loginName: string): string {
  return createHmac("sha256",secret).update(loginName.toLowerCase()).digest("hex");
}
function tokenDigest(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}
function validToken(token: string): boolean {
  return typeof token === "string" && /^[A-Za-z0-9_-]{43}$/.test(token);
}
function validRequest(installationId: string, requestId: string): boolean {
  return UUID.test(installationId) && REQUEST.test(requestId);
}

/** This is a server-only service. Do not expose HTTP login without throttling and trusted installation resolution. */
export async function signIn(
  pool: Pool, installationId: string, loginName: string, password: string, requestId: string,
  throttleSecret?: string,
): Promise<SignedIn> {
  if (!validRequest(installationId,requestId) || typeof loginName !== "string"
    || loginName.length < 3 || loginName.length > 120 || !validPassword(password)) {
    throw new AuthDenied();
  }
  if (throttleSecret !== undefined && !validThrottleSecret(throttleSecret)) throw new AuthDenied();
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const digest = throttleSecret ? loginDigest(throttleSecret,loginName) : null;
    if (digest) {
      await client.query(
        "INSERT INTO auth_login_throttle(installation_id,login_digest) VALUES($1,$2) ON CONFLICT DO NOTHING",
        [installationId,digest],
      );
      const lock = await client.query<{blocked: boolean}>(
        "SELECT blocked_until > now() AS blocked FROM auth_login_throttle WHERE installation_id=$1 AND login_digest=$2 FOR UPDATE",
        [installationId,digest],
      );
      if (lock.rows[0]?.blocked === true) {
        await client.query("COMMIT");
        throw new AuthThrottled();
      }
    }
    const user = await client.query<{ id: string; password_hash: string; disabled: boolean }>(
      "SELECT id,password_hash,disabled FROM app_user WHERE installation_id=$1 AND login_name=$2",
      [installationId,loginName],
    );
    const found = user.rows[0];
    // Run an equally costly KDF when user doesn't exist, to reduce timing-based enumeration.
    const verified = found
      ? await verifyPassword(password,found.password_hash)
      : (await derive(password,Buffer.alloc(SALT_BYTES))).length === 0;
    if (!found || found.disabled || !verified) {
      if (digest) {
        await client.query(
          `UPDATE auth_login_throttle SET
             failed_count=CASE WHEN window_started_at < now()-interval '10 minutes' THEN 1 ELSE least(failed_count+1,1000) END,
             blocked_until=CASE WHEN window_started_at < now()-interval '10 minutes' THEN NULL
               WHEN failed_count >= 4 THEN now()+interval '15 minutes' ELSE NULL END,
             window_started_at=CASE WHEN window_started_at < now()-interval '10 minutes' THEN now() ELSE window_started_at END
           WHERE installation_id=$1 AND login_digest=$2`,
          [installationId,digest],
        );
      }
      await client.query(
        "INSERT INTO auth_event(installation_id,request_id,event_code) VALUES($1,$2,'login.denied')",
        [installationId,requestId],
      );
      await client.query("COMMIT");
      throw new AuthDenied();
    }
    if (digest) {
      await client.query(
        "UPDATE auth_login_throttle SET failed_count=0,blocked_until=NULL,window_started_at=now() WHERE installation_id=$1 AND login_digest=$2",
        [installationId,digest],
      );
    }
    const token = randomBytes(32).toString("base64url");
    const result = await client.query<{ expires_at: Date }>(
      "INSERT INTO app_session(token_hash,installation_id,user_id,expires_at) VALUES($1,$2,$3,now()+ ($4::integer * interval '1 second')) RETURNING expires_at",
      [tokenDigest(token),installationId,found.id,SESSION_SECONDS],
    );
    await client.query(
      "INSERT INTO auth_event(installation_id,actor_id,request_id,event_code) VALUES($1,$2,$3,'login.success')",
      [installationId,found.id,requestId],
    );
    await client.query("COMMIT");
    return { token, actorId: found.id, installationId, expiresAt: result.rows[0]!.expires_at.toISOString() };
  } catch (error) {
    await client.query("ROLLBACK").catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}

/** A session only authenticates its own installation and is invalid after revocation, expiration, user disable. */
export async function resolveSession(client: PoolClient, installationId: string, token: string): Promise<AuthActor | null> {
  if (!UUID.test(installationId) || !validToken(token)) return null;
  const result = await client.query<{ user_id: string }>(
    `SELECT s.user_id FROM app_session s
      JOIN app_user u ON u.installation_id=s.installation_id AND u.id=s.user_id
      WHERE s.installation_id=$1 AND s.token_hash=$2
        AND s.revoked_at IS NULL AND s.expires_at > now() AND u.disabled=false`,
    [installationId,tokenDigest(token)],
  );
  return result.rows[0] ? { actorId: result.rows[0].user_id,installationId } : null;
}

/** Revoke only the authenticated actor's current token and record redacted append-only audit. */
export async function signOut(pool: Pool, installationId: string, token: string, requestId: string): Promise<boolean> {
  if (!validRequest(installationId,requestId) || !validToken(token)) return false;
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const actor = await resolveSession(client,installationId,token);
    if (!actor) {
      await client.query("ROLLBACK");
      return false;
    }
    const updated = await client.query(
      "UPDATE app_session SET revoked_at=now() WHERE token_hash=$1 AND installation_id=$2 AND revoked_at IS NULL",
      [tokenDigest(token),installationId],
    );
    if (updated.rowCount !== 1) {
      await client.query("ROLLBACK");
      return false;
    }
    await client.query(
      "INSERT INTO auth_event(installation_id,actor_id,request_id,event_code) VALUES($1,$2,$3,'session.revoked')",
      [installationId,actor.actorId,requestId],
    );
    await client.query("COMMIT");
    return true;
  } catch(error) {
    await client.query("ROLLBACK").catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}
