/** Contract primitives. No financial or inventory mutation is enabled yet. */
export type ErpErrorCode = "NOT_FOUND" | "METHOD_NOT_ALLOWED" | "NOT_IMPLEMENTED" | "NOT_READY" | "MAINTENANCE";
export type ErpError = {
  error: { code: ErpErrorCode; message: string; requestId: string };
};
export function errorEnvelope(code: ErpErrorCode, requestId: string, message: string): ErpError {
  return { error: { code, message, requestId } };
}
export const MODULES = [
  "Công Ty",
  "MCP",
  "Quản trị",
  "Bán Lẻ",
  "Giao Hàng",
  "Đặt Hàng",
] as const;
export type ErpModule = (typeof MODULES)[number];

/** Required on sensitive mutations in future modules; NOT a permission check. */
export type MutationHeaders = {
  "idempotency-key": string;
  "x-request-id": string;
  "if-match": string;
};
export function validIdempotencyKey(value: string | undefined): boolean {
  return typeof value === "string" && /^[A-Za-z0-9._:-]{8,128}$/.test(value);
}
