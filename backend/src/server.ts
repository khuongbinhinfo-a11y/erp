import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { randomUUID } from "node:crypto";
import { errorEnvelope, MODULES } from "./contracts.ts";
import { handleIdentityHttp, type IdentityOptions } from "./identity_http.ts";
import { handleCatalogHttp } from "./catalog_http.ts";
import { handleBulkHttp } from "./bulk_http.ts";
import { handleCatalogMediaHttp } from "./catalog_media_http.ts";
import { handleR1Http } from "./r1_catalog_http.ts";
import { handleSalesHttp } from "./sales_http.ts";
import { handleExecutionHttp } from "./sales_execution_http.ts";
import { handlePosHttp } from "./pos_http.ts";
import { handleInventoryHttp } from "./inventory_http.ts";
import { handleDeliveryTripHttp } from "./delivery_trip_http.ts";
import { handleTransferHttp } from "./transfer_http.ts";
import { handleStocktakeHttp } from "./stocktake_http.ts";
import { handlePurchasingHttp } from "./purchasing_http.ts";
import { handleAppReleaseHttp } from "./app_release_http.ts";

declare const ERP_RELEASE_SHA:string|undefined;
const releaseSha=typeof ERP_RELEASE_SHA==="string"&&/^[0-9a-f]{40}$/.test(ERP_RELEASE_SHA)?ERP_RELEASE_SHA:null;

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
    if(req.method==="GET"&&url.pathname==="/health/release"){
      writeJson(res,200,{service:"erp-api",releaseSha,contract:"T1_UAT",requestId:id},id);
      return;
    }
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
    if (url.pathname.startsWith("/v1/app/releases/")) {
      void handleAppReleaseHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/auth/") || url.pathname.startsWith("/v1/admin/")) {
      void handleIdentityHttp(req,res,id,url.pathname,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/catalog/bulk/")) {
      void handleBulkHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/catalog/r1/")) {
      void handleR1Http(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (/^\/v1\/catalog\/products\/[0-9a-f-]{36}\/media(?:\/(?:prepare|complete))?$/i.test(url.pathname)) {
      void handleCatalogMediaHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/catalog/")) {
      void handleCatalogHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/purchasing/")) {
      void handlePurchasingHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/inventory/stocktakes")) {
      void handleStocktakeHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/inventory/transfers")) {
      void handleTransferHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/delivery/")) {
      void handleDeliveryTripHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/inventory/")) {
      void handleInventoryHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/pos/")) {
      void handlePosHttp(req,res,id,url,identityOptions,checkReady);
      return;
    }
    if (url.pathname.startsWith("/v1/sales/execution/")) {
      void handleExecutionHttp(req,res,id,url,identityOptions,checkReady);
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

