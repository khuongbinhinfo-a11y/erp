# ERP — Kế hoạch chuyển nghiệp vụ app cũ → nền tảng Flutter mới

**Ngày lập:** 20/11/2026 · **Trạng thái:** PORTING PLAN / CHƯA TRIỂN KHAI NGHIỆP VỤ · **Ưu tiên:** Lô nghiệp vụ trước; CORS/production catalog issue #7 được tạm hoãn theo quyết định owner 20/11.
**ERP target main:** `ffb88b2692d5f9d6b34dabca90943d06a45e9f97` (CI `44651371267`: 5/5 PASS).
**Nguồn đối chiếu read-only:**
- [NPP-Platform @ 98941bc](https://github.com/binhnxwjfjxm/NPP-Platform/tree/98941bc6776a02ad8a2bded12961fdaea173cf93) — **nguồn nghiệp vụ Công Ty / MCP / Quản trị / Bán Lẻ / Giao Hàng**, PostgreSQL + JavaScript/Next.js.
- [nguyenlieuhungphat @ ac87bf](https://github.com/binhnxwjfjxm/nguyenlieuhungphat/tree/ac87bf22c1b692f54b78bde008c49041abab5cf0) — **luồng Đặt Hàng khách** / customer-ordering.
- [ERP current](https://github.com/gustavjung24-ops/ERP/tree/ffb88b2692d5f9d6b34dabca90943d06a45e9f97) — TypeScript modular monolith, Flutter, PostgreSQL, identity/catalog foundation.

> **Không đụng vào hai repo cũ:** chỉ đọc code, tài liệu, test và các migration làm bằng chứng. Không sửa, merge, deploy hoặc kết nối DB cũ. **Bê quy tắc/lifecycle sau khi kiểm chứng, không bê nguyên hạ tầng, dữ liệu khách, PII, secrets, thương hiệu, ảnh hay raw SQL migration cũ.** Tạo fixtures tổng hợp không nhận dạng. Mọi chính sách không chắc chắn được ghi là CHƯA XÁC MINH; không mặc nhiên copy production policy của một khách cũ sang mọi installation.

## 1. Ranh giới nguồn sự thật cần giữ

- **Sales Order** ghi khách đặt gì; **Fulfillment / Allocation** ghi kho giữ, soạn, đóng gói gì; **Delivery Order** ghi nhu cầu giao/nhận tại quầy; **Trip / Attempt** ghi thực giao; **Inventory Ledger** quyết định tồn; **AR/AP Ledgers** quyết định nợ; **Payment và Allocation** quyết định đã thu/đã cấn chứng từ; **Audit/Outbox** ghi actor/trace. Không thay chúng bằng một status hoặc một bảng tổng hợp.
- **MCP field outlet ≠ khách chính thức**: chỉ liên kết với canonical customer được phép tạo Sales Order; prospect vẫn được thăm, khảo sát và gửi yêu cầu mở mã.
- **Retail, Delivery, Đặt Hàng và MCP là client/cổng nghiệp vụ**; backend ERP thống nhất giữ quyền post, versioning và accounting, **không có DB thứ hai**. Flutter giữ module desktop/mobile riêng, dùng chung API contracts.
- Idempotency-Key cùng payload trả receipt cũ, payload khác trả conflict; version/revision, deny-by-default theo installation/branch/warehouse, Decimal, row/advisory lock, immutable posted facts, reversal/correction, request ID và server ACK là bất biến.
- Dữ liệu cần **migrate từ app cũ sang ERP demo**: **KHÔNG**. Mục tiêu hiện tại là chuyển **nghiệp vụ/code behavior** vào repo mới và kiểm thử bằng dữ liệu synthetic; data import riêng khi owner cấp phép và có mapping/anonymization.

## 2. Bản đồ nghiệp vụ có bằng chứng (nguồn cũ → đích mới)

| Miền / Issue | Nguồn code hoặc contract cũ (đọc) | Nghiệp vụ phải viết lại cho ERP | Chưa có trong ERP mới |
|---|---|---|---|
| **Danh mục, giá** #7 | `database/migrations/shared/012_product_catalog_foundation.sql`, `013_product_units_conversions_barcodes.sql`, `014_price_lists_channel_resolution.sql`; `npp-core/api/src/db/repositories/pricing.js` | SKU/variants, units/conversions/barcodes, branch/kho/location, customer/address, channel/customer-group pricing, min qty, effective range, precedence và snapshot giá khi xác nhận | Mới có catalog 0006/0007 & quote đơn giản, **chưa** channel/customer scope/full pricing; production API chưa phát hành |
| **Bán hàng** #8 | `database/migrations/sales/037_sales_order_foundation.sql`; `docs/operations/phase-6b-sales-order-foundation.md`; `npp-core/api/src/db/repositories/sales-order.js` | Order draft → versioned confirm → amendment/cancel, dòng giá/thuế/CK frozen, số chứng từ khi confirm, source reference MCP/Retail/Portal, pickup/delivery và 4 trạng thái độc lập | **Chưa** sales schema, API hoặc UI ghi thật |
| **Giữ hàng/kho** #9 | `database/migrations/inventory/017_inventory_ledger_foundation.sql`, `018_inventory_balance_read_model.sql`, `019_inventory_reservations_negative_stock.sql`; `docs/operations/phase-6d1-reservation-demand-decisions.md`, `phase-6d2-allocation-pick-pack-decisions.md` | Ledger append-only; available = on_hand − reserved − blocked/quarantine; reservation không phải OUT; allocation/lô/vị trí, FEFO/FIFO, pick/pack, thiếu hàng/backorder, concurrency, no oversell | **Chưa** inventory ledger + allocation implementation |
| **Mua hàng** (issue mới) | `database/migrations/purchasing/021_purchase_order_foundation.sql`; `docs/operations/phase-5-2-partial-goods-receipt-decisions.md`; `npp-core/api/src/db/repositories/goods-receipt.js` | PO → approve → nhiều partial receipts → stock IN, variance/return/reversal, supplier AP ledger và payment allocation; số phiếu cấp khi post | **Chưa** purchasing + goods receipt implementation |
| **Giao hàng/điều phối** #12 | `database/migrations/sales/044_sales_delivery_order_handover.sql`, `database/migrations/logistics/049_logistics_delivery_attempts.sql`; `docs/operations/phase-6d3-delivery-order-handover-decisions.md`, `phase-6e4-delivery-attempt-decisions.md` | One order → many Delivery Orders; trips/stops/assignments; delivered_full/partial/failed/rescheduled, COD, driver scope, optional POD; phần chưa giao vẫn có lineage | **Chưa** fulfillment/delivery/trip/attempt endpoints |
| **Phải thu, thu tiền, COD** #10 | `database/migrations/accounting/053_customer_receivable_ledger.sql`; `docs/operations/phase-6f0-receivable-payment-cod-decisions.md`; `npp-core/api/src/db/repositories/customer-receivable.js`, `customer-payment.js` | AR ledger chỉ post từ số **thực giao/nhận tại quầy** theo policy đã chốt; payments ≠ allocations; partial, credit, refund, customer returns, COD custody/handover/reconcile | **Chưa** accounting ledger + payment engine |
| **MCP Field** #12 | `mcp/apps/backend/foundation/core-sales-client.js`, `docs/operations/phase-6c2-mcp-sales-order-adapter.md`, `mcp/src/app/api/mcp-day/…` | Tuyến, outlet, phiên làm việc, GPS/check-in, khảo sát, follow-up, đề nghị mở mã, draft offline và submit canonical Sales Order qua ERP API | **Chưa** MCP domain/Flutter feature |
| **Bán Lẻ** #12 | `retail/web/lib/retail-order-consistency.mjs`, `retail/web/app/api/retail/…` | Giỏ, tìm SKU, snapshot giá, thao tác nhận tại quầy dùng canonical order + pickup handover + payment, trạng thái máy in | **Chưa** Retail flow nối API |
| **Đặt Hàng khách** #12 | Website repo: `customer-ordering/lib/customer-ordering-service.ts`, `contracts.ts`, `customer-portal-lifecycle.ts`, `docs/customer-ordering-phase-9-2-core-order-intake.md` | Catalog per-customer, cart/checkout drafts, submit idempotent, order status/history/cancel/reorder; customer auth và mapping membership server-side | **Chưa** Customer Ordering API / Flutter/PWA flow |
| **Báo cáo, offline, audit** #11–#13 | `docs/operations/phase-8-reporting-operations-plan.md`, `retail/web/lib/retail-order-consistency.mjs`, `customer-ordering/lib/storage/catalog-indexed-db.ts` | Báo cáo rebuild từ ledgers, cash/stock/order reconciliation; offline drafts/intents, retry/lost ACK, role switch/eviction; print/PWA target tests | **Chưa** operational read models/offline queue tích hợp |

**Mức bằng chứng:** ĐÃ XÁC MINH các file và contract nêu trên tồn tại ở commit nguồn đã khóa; **CHƯA XÁC MINH** tính chính xác/sẵn sàng production của mọi luồng legacy khi chạy thực tế. Kết quả CI ERP hiện chỉ xác minh nền tảng/catalog trên DB CI, không chứng minh business flows đã được chuyển.

## 3. Thứ tự thực thi — ưu tiên người dùng có luồng thật trước, không chờ CORS

### Lô B0 — Khóa nguồn và contract (lô hiện tại)

- [x] Chốt exact SHA của 2 repo nguồn và ERP; đối chiếu source nghiệp vụ.
- [x] Bản đồ module, ownership, source paths, dependency và acceptance.
- [ ] Liệt kê API request/response và permission tối thiểu từ read-only code mỗi vertical slice (không giữ legacy auth/provider internals).
- [ ] Chốt decision mới khi nguồn cũ chưa đủ: customer price resolution priority; credit/negative-stock override; transfer/stocktake approval threshold; NPP customer-specific posting policy. Tất cả giữ fail-closed cho đến khi chốt.
- [ ] Bộ **synthetic fixtures**: ít nhất 2 installation, 2 branch, 2 warehouse, 3 SKU (base + carton conversion), 2 khách, 2 suppliers, channel/group prices, lô có/không hạn, partial receipt/delivery/payment.

### Lô B1 — Sales Order foundation / #8 (P0 làm kế tiếp)

- [ ] Thiết kế module `backend/src/sales/` TS và migration versioned **0008+ (số cuối xác định khi triển khai)**. `sales_order`, `sales_order_version`, `sales_order_line`, `sales_order_source`; status order/fulfillment/delivery/payment riêng.
- [ ] API `GET /v1/sales/orders`, `POST /v1/sales/orders` draft, `PATCH /v1/sales/orders/:id/draft`, `POST .../:id/confirm`, `POST .../:id/amend`, `POST .../:id/cancel`, version history. Chưa tự post kho/công nợ.
- [ ] Snapshot Decimal exact unit/price/discount/tax; compare stale price; code SKU/customer/branch RBAC; source-id dedupe, lock, idempotency receipt and audit.
- [ ] Flutter Công Ty > Đơn hàng: list/filter, create draft/cart, edit/confirm, view status/timeline; không báo hoàn tất/giao/thu chỉ vì confirm.
- [ ] PostgreSQL integration: expired price, duplicate key mismatched body, 2 requests đồng thời confirm, inactive SKU/customer, cross installation/branch and lost ACK read-before-retry.

**B1 Gate:** Từ Flutter tạo được đơn **draft → confirmed** với số chứng từ và snapshot đúng trên PostgreSQL CI; 0 stock movement, 0 receivable ledger tại confirm; RBAC, audit, idempotency tests PASS.

### Lô B2 — Inventory + fulfillment / #9

- [ ] Inventory ledger + opening stock/post IN/OUT/reversal, read model/rebuild, no-negative default.
- [ ] Reservation/shortage/backorder, allocation exact warehouse-location-lot, FEFO/FIFO, pick/pack, Delivery Order draft/ready; shipment/pickup issue theo sự kiện vật lý.
- [ ] UI Công Ty > Kho hàng/Đơn hàng: tồn/available/reserved, nhập/soạn/đóng/giao; drill-down movement.
- [ ] Đồng thời test concurrent sell/reserve, double post, partial, cancel/reversal, no phantom stock, read model rebuild.

**B2 Gate:** Hai đơn cùng tranh một tồn kho không oversell; mỗi movement có source doc và chống ghi trùng; tồn trước/sau/rebuild khớp.

### Lô B3 — Mua hàng/nhập kho/phải trả (và phụ thuộc B2)

- [ ] PO draft/approve, supplier scope, multi receipt partial, stock receipt, tracking policy, supplier return.
- [ ] AP ledger, supplier payment/allocation và reversal; không sửa trực tiếp nợ.
- [ ] UI Công Ty: Mua hàng → Đơn mua/Phiếu nhận/Trả NCC/Công nợ phải trả.
- [ ] Test nhiều phiếu nhận cùng PO, nhận quá remaining, post một lần, reverse downstream, AP reconcile.

### Lô B4 — Giao hàng + AR / #10 + #12

- [ ] Tách Delivery Order, trip, assignment và attempt; 4 kết quả giao; partial/failed không auto-complete; driver role bound to active assignment.
- [ ] Receivable chỉ phát sinh theo accepted delivery / physical pickup. Thu tiền có payment + allocation; COD collection → driver custody → company handover → reconciliation là 4 việc khác nhau.
- [ ] Return/credit/refund/adjustment/reversal, payment một phần, overpayment, aging, report drilldown.
- [ ] Flutter Công Ty + Giao Hàng + Công nợ; tests race double collection, partial payment/return, balance rebuild và no cross-driver read.

### Lô B5 — Tích hợp 4 client còn lại / #12 + #11

- [ ] MCP Field: field route/outlet, visit/check-in, onboard request, Core order adapter (chưa link customer không tạo official order).
- [ ] Bán Lẻ: bán tại quầy dùng Sales Order + pickup + payment chung. In/Windows bridge tách theo target.
- [ ] Đặt Hàng: per-customer pricing/catalog, cart/checkout, order history, guarded reorder/cancel, portal identity boundary.
- [ ] Quản trị: users/roles/scope, ngoại lệ cần duyệt; không chiếm CRUD hằng ngày của Công Ty.
- [ ] Offline draft/intent; SQLite/Drift (native), IndexedDB (PWA), không post ledger khi mất mạng; account-switch/eviction tests.

### Lô B6 — Báo cáo/UAT 6 phân hệ / #12–#14

- [ ] Reporting read models/drilldown từ inventory/AR/AP ledger + attempts + source docs, report reconcile.
- [ ] E2E synthetic: **MCP tạo yêu cầu/Đặt Hàng/Retail → Core Order → giữ hàng → kho xuất → giao thực tế → công nợ → thu tiền → đối soát**.
- [ ] Build Flutter Web/Android/Windows; device QA iPhone PWA; screen widths, accessible focus, toast/UX theo `docs/UI_NAVIGATION_RULES.md`.
- [ ] Thực hiện production migration/deploy/smoke **chỉ ở giai đoạn phát hành, đúng target + owner approval + backup/restore/reconciliation**; UI build không coi là API production live.

## 4. API/data implementation conventions (bắt buộc)

```text
Flutter feature (API only)
  -> /v1/{catalog,sales,inventory,purchasing,delivery,accounting,mcp,...}
     -> session/actor/installation/branch/warehouse RBAC
        -> domain service + exact Decimal + lifecycle guards
           -> PostgreSQL transaction + row/advisory locks
              -> immutable ledger/document versions + audit + idempotency receipt
  -> ACK mới hiện thành công; offline chỉ là local intent/draft
```

- Mỗi aggregate có canonical UUID, installation_id, branch/warehouse scope khi áp dụng, revision, actor, request_id, created/updated, source_ref; posted facts append-only.
- Migration versioned tuần tự trong ERP, **không chạy legacy SQL nguyên trạng** do schema, DB namespace, identity và permission khác. Không chạy SQL tay production.
- Các API phải có contract tests cho replay cùng key, changed-body conflict, concurrency, partial, scope denied và response after COMMIT timeout.
- Flutter tận dụng semantic tokens xanh lá và rule UI: cấp 1 nằm **bên phải trên thanh xanh**, cấp 2 nằm **bên trái** trong content. Không copy frontend Next.js cũ vào Flutter.
- Không “copy hết rồi sửa”: chuyển vertical slice có test đi qua domain invariant, review source code cũ chỉ làm spec tham khảo. Chứng cứ là CI đúng SHA, notepad/báo cáo không tính PASS.

## 5. Khoảng trống phải giải quyết ở từng lô (không tự bịa business policy)

| Cần chốt | Mặc định an toàn khi chưa chốt | Block ở đâu |
|---|---|---|
| Policy áp giá: customer/group/channel, minQty, priority, discount & tax | Không confirm nếu không resolve được giá/snapshot nhất quán | Sales confirm B1 |
| On-order/dispatch/delivery AR recognition | Không ghi receivable từ order confirm; nhận hàng thực tế mới xét posting | B4 |
| Negative stock, lot FEFO/expiry, backorder | Không cho âm; expired/restricted lot bị chặn; shortage rõ | B2 |
| Return/variance/overpayment approval | Giữ request/pending, không tự post/hoàn tiền | B3–B4 |
| Anonymous field outlet vs Core customer | Prospect không tạo official order khi chưa link/approved | B5 |
| External Customer Ordering auth/membership | Server-side resolve; không cho client tự chọn installation/customer khác | B5 |

## 6. Definition of Done per vertical slice

`TASK | BASELINE (old SHA + ERP main SHA) | SOURCE PATHS | DOMAIN CONTRACT | MIGRATION (fresh + replay + restore CI) | UNIT/INTEGRATION/CONCURRENCY/RBAC | FLUTTER WIDGET + WEB | CI 5/5 | PR/MERGE state | PROD MIGRATION | DEPLOY | SMOKE | BLOCKERS`.

**Không gộp trạng thái:** `CODE/CI PASS` khác `PRODUCTION READY` khác `OWNER UAT PASS`. Issue #7/CORS tạm hoãn theo lệnh mới nhưng không được xóa/giả rằng API danh mục production đã chạy. Khi build order #8, integration tests phải áp dụng catalog 0006/0007 trên **PostgreSQL CI**, không phụ thuộc CORS production.

## 7. Lệnh thực thi kế tiếp

Bắt đầu **B1 Sales Order foundation** theo existing Issue #8, trước hết viết contract/migration trên ERP main, làm backend lifecycle + tests, sau đó UI Flutter. Khi B1 xanh, tiến B2 kho; procurement làm sau inventory posting nền tảng. Mọi legacy repo vẫn read-only.
