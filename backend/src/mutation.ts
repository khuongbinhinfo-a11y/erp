import { createHash } from "node:crypto";
import type { Pool, PoolClient } from "pg";
import { validIdempotencyKey } from "./contracts.ts";

/** Internal-only transaction boundary. No public mutation route is enabled until RBAC ships. */
export type MutationContext = {
  installationId: string;
  actorId: string;
  requestId: string;
  action: string;
  idempotencyKey: string;
  expectedRevision: number;
  payload: unknown;
};
export type MutationResponse = { status: number; body: unknown };
export type MutationOutcome = MutationResponse & { replayed: boolean };
export type MutationHandlers = {
  /** Must check live installation/branch/warehouse permission within this DB transaction. */
  authorize: (client: PoolClient, context: MutationContext) => Promise<boolean>;
  /** All sensitive writes must use this same client; no independent pool queries. */
  execute: (client: PoolClient, context: MutationContext) => Promise<MutationResponse>;
};
export type MutationFaultCode = "INVALID_CONTEXT" | "FORBIDDEN" | "IDEMPOTENCY_CONFLICT" | "REVISION_CONFLICT";
export class MutationFault extends Error {
  readonly code: MutationFaultCode;
  readonly httpStatus: number;
  constructor(code: MutationFaultCode, httpStatus: number) {
    super(code);
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ACTION = /^[a-z][a-z0-9._:-]{2,95}$/;
const REQUEST_ID = /^[A-Za-z0-9._:-]{1,80}$/;

/** Stable JSON fingerprint: object key ordering cannot evade idempotency. Decimal values are strings. */
export function canonicalPayload(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string" || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new MutationFault("INVALID_CONTEXT", 400);
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return "[" + value.map(canonicalPayload).join(",") + "]";
  if (typeof value === "object" &&
      (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null)) {
    return "{" + Object.keys(value).sort().map((key) =>
      JSON.stringify(key) + ":" + canonicalPayload((value as Record<string, unknown>)[key])
    ).join(",") + "}";
  }
  throw new MutationFault("INVALID_CONTEXT", 400);
}

export function requireRevision(expected: number, actual: number): void {
  if (!Number.isSafeInteger(actual) || actual !== expected) {
    throw new MutationFault("REVISION_CONFLICT", 409);
  }
}

function validateContext(ctx: MutationContext): void {
  if (!UUID.test(ctx.installationId) || !UUID.test(ctx.actorId) ||
      !REQUEST_ID.test(ctx.requestId) || !ACTION.test(ctx.action) ||
      !validIdempotencyKey(ctx.idempotencyKey) ||
      !Number.isSafeInteger(ctx.expectedRevision) || ctx.expectedRevision < 0) {
    throw new MutationFault("INVALID_CONTEXT", 400);
  }
}

/**
 * Unique constraint serializes concurrent requests for a key. The receipt, business work
 * and audit commit as ONE PostgreSQL transaction. A lost ACK can be safely retried:
 * committed receipts replay, rolled-back receipts are retried, changed payloads conflict.
 */
export async function executeMutation(
  pool: Pool,
  context: MutationContext,
  handlers: MutationHandlers,
): Promise<MutationOutcome> {
  validateContext(context);
  if (typeof handlers?.authorize !== "function" || typeof handlers?.execute !== "function") {
    throw new MutationFault("FORBIDDEN", 403);
  }
  const fingerprint = createHash("sha256")
    .update(canonicalPayload({
      action: context.action,
      expectedRevision: context.expectedRevision,
      payload: context.payload,
    })).digest("hex");
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    // Check permission even for replay: a revoked user cannot retrieve an old response.
    if (await handlers.authorize(client, context) !== true) {
      throw new MutationFault("FORBIDDEN", 403);
    }
    const inserted = await client.query<{ id: string }>(
      `INSERT INTO mutation_receipt
        (installation_id, actor_id, action_code, idempotency_key, request_id, expected_revision, fingerprint)
       VALUES ($1,$2,$3,$4,$5,$6,$7)
       ON CONFLICT (installation_id, actor_id, action_code, idempotency_key) DO NOTHING
       RETURNING id`,
      [context.installationId, context.actorId, context.action, context.idempotencyKey,
        context.requestId, context.expectedRevision, fingerprint],
    );
    if (inserted.rowCount === 0) {
      const previous = await client.query<{ fingerprint: string; response_status: number; response_body: unknown }>(
        `SELECT fingerprint, response_status, response_body FROM mutation_receipt
         WHERE installation_id=$1 AND actor_id=$2 AND action_code=$3 AND idempotency_key=$4 FOR UPDATE`,
        [context.installationId, context.actorId, context.action, context.idempotencyKey],
      );
      const prior = previous.rows[0];
      if (!prior || prior.fingerprint !== fingerprint || prior.response_status === null) {
        throw new MutationFault("IDEMPOTENCY_CONFLICT", 409);
      }
      await client.query("COMMIT");
      return { status: prior.response_status, body: prior.response_body, replayed: true };
    }
    const response = await handlers.execute(client, context);
    if (!Number.isInteger(response.status) || response.status < 200 || response.status > 299) {
      throw new MutationFault("INVALID_CONTEXT", 400);
    }
    const json = canonicalPayload(response.body);
    await client.query(
      `UPDATE mutation_receipt SET response_status=$2, response_body=$3::jsonb,
        committed_at=now() WHERE id=$1`,
      [inserted.rows[0]?.id, response.status, json],
    );
    await client.query(
      `INSERT INTO audit_event (installation_id, actor_id, receipt_id, request_id,
        action_code, expected_revision, fingerprint, event_code)
       VALUES ($1,$2,$3,$4,$5,$6,$7,'mutation.committed')`,
      [context.installationId, context.actorId, inserted.rows[0]?.id, context.requestId,
        context.action, context.expectedRevision, fingerprint],
    );
    await client.query("COMMIT");
    return { status: response.status, body: JSON.parse(json) as unknown, replayed: false };
  } catch (cause) {
    await client.query("ROLLBACK").catch(() => undefined);
    throw cause;
  } finally {
    client.release();
  }
}
