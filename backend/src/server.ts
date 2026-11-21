import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { randomUUID } from "node:crypto";
import { errorEnvelope, MODULES } from "./contracts.ts";
import { handleIdentityHttp, type IdentityOptions } from "./identity_http.ts";
import { handleCatalogHttp } from "./catalog_http.ts";
import { handleR1Http } from "./r1_catalog_http.ts";
import { handleSalesHttp } from "./sales_http.ts";
import { handleInventoryHttp } from "./inventory_http.ts";

function requestId(req: IncomingMessage): string {
  const raw = req.headers["x-request-id"];
  const id = Array.isArray(raw) ? raw[0] : raw;
  return id && /^[A-Za-z0-9._:-]{1,80}$/.test(id) ? id : randomUUID();
}

function writeJson(res: ServerResponse, status: number, data: unknown, id: string): void {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-request-id": id,
    "x-content-type-options": "nosniff",
  });
  res.end(JSON.stringify(data));
}

export function buildApp(
  checkReady: () => Promise<boolean> = async () => false,
  checkConnected: () => Promise<boolean> = async () => false,
  identityOptions: IdentityOptions = {pool:null},
  maintenanceMode = false,
): Server {
  return createServer((req, res) => {
    const id = requestId(req);
    const url = new URL(req.url ?? "/", "http://localhost");
    if (req.method === "GET" && url.pathname === "/health/live") {
      writeJson(res, 200, { status: "live", service: "erp-api", maintenance: maintenanceMode, requestId: id }, id);
      return;
    }
    if (req.method === "GET" && url.pathname === "/health") {
      void Promise.resolve().then(checkConnected).then((connected) => {
        if (connected) {
          writeJson(res, 200, { status: "ok", service: "erp-api", database: "connected", requestId: id }, id);
        } else {
          writeJson(res, 503, errorEnvelope("NOT_READY", id, "Không kết nối được PostgreSQL"), id);
        }
      }).catch(() => {
        writeJson(res, 503, errorEnvelope("NOT_READY", id, "Không kết nối được PostgreSQL"), id);
      });
      return;
    }
    if (req.method === "GET" && url.pathname === "/health/ready") {
      void Promise.resolve().then(checkReady).then((ready) => {
        if (ready) {
          writeJson(res, 200, { status: "ready", service: "erp-api", requestId: id }, id);
        } else {
          writeJson(res, 503, errorEnvelope("NOT_READY", id, "PostgreSQL chưa sẵn sàng"), id);
        }
      }).catch(() => {
        writeJson(res, 503, errorEnvelope("NOT_READY", id, "PostgreSQL chưa sẵn sàng"), id);
      });
      return;
    }
    if (req.method === "GET" && url.pathname === "/v1/meta/modules") {
      writeJson(res, 200, { modules: MODULES, readOnly: true, requestId: id }, id);
      return;
    }
    // Production cutover: reject ALL state-changing requests at the server entrypoint.
    // This applies before login/session, admin, catalog, and future business modules.
    if (maintenanceMode && !["GET","HEAD","OPTIONS"].includes(req.method ?? "")) {
      writeJson(res, 503, errorEnvelope("MAINTENANCE", id, "ERP đang chuyển cơ sở dữ liệu"), id);
      return;
    }
    if (url.pathname.startsWith("/v1/auth/") || url.pathname.startsWith("/v1/admin/")) {
      void handleIdentityHttp(req,res,id,url.pathname,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/catalog/r1/")) {
      void handleR1Http(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/catalog/")) {
      void handleCatalogHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/inventory/")) {
      void handleInventoryHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/sales/")) {
      void handleSalesHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/")) {
      writeJson(res, 501, errorEnvelope("NOT_IMPLEMENTED", id, "API nghiệp vụ chưa được kích hoạt"), id);
      return;
    }
    writeJson(res, 404, errorEnvelope("NOT_FOUND", id, "Không tìm thấy tài nguyên"), id);
  });
}

