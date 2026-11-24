# T0 — Bảng đối chiếu nghiệp vụ cũ → ERP (24/11/2026)

Nguồn sự thật: [MASTER_PLAN V4.1](MASTER_PLAN.md), owner UAT, code ERP main `43eef7ce84f4a890831ba5e150a948c5dbe7d8f9`; legacy NPP-Platform read-only `d39e8a87cdc8905a85d92ee3a4b8c7427b3ecd35`. Không sao chép dữ liệu, secrets, raw migrations, giao diện framework cũ.

## Ma trận code/function/test: bắt buộc áp dụng khi port

| Nguồn legacy (path:function hoặc line) | ERP mới / quyết định | Xung đột/lỗi phải xử lý | Gate/test |
|---|---|---|---|
| `npp-core/api/src/services/sales-fulfillment.js:178–212` `allocateWarehouseDemand`; `test/sales-order-fulfillment-demand.test.js` | **COPY/ADAPT** → `backend/src/inventory.ts` `allocateWarehouseDemand`, `inventory_http.test.ts` | Legacy scaled 12, ERP numeric(24,6): bigint scaled 6, không float; negative availability phải clamp zero. | 0/partial/full demand, >12-digit precise, deterministic ordering |
| `npp-core/api/src/services/sales-fulfillment-hold.js:157–250` `reconcileDemandHold` | **CONSOLIDATE** với `reserveStock`, inventory ledger ERP; migration `0021` thêm `backordered_base` | ERP 0011 ép reservation bằng toàn bộ demand, không lưu số thiếu. Không sinh reservation > available hoặc trừ tồn của đơn khác. | PostgreSQL cạnh tranh hai đơn, 0/partial/full, immutable snapshot, lost ACK |
| `npp-core/api/src/services/inventory-negative-stock-policy.js:27–99` warehouse policy, explicit permission, provenance | **COPY/ADAPT sau kiểm soát domain** → T3 direct issue; giữ movement SQL guard 0011 | Xung đột quan trọng: ERP chưa có trusted direct ISSUE service/source lineage. Cho phép âm từ trigger ngay là lỗ hổng tạo OUT giả. `negative_issue_mode` mặc định BLOCK, không mở API bật âm cho đến T3. | Deny SQL direct, policy/scope/actor, ledger reversal, cùng transaction |
| `npp-core/api/src/services/sales-direct-stock-issue.js:301–618` `issueDirectSalesOrderStock` | **COPY/ADAPT** T3 giữ canonical inventory ledger ERP | Legacy MANUAL/PICKUP chung core, cần warehouse locking + source ID + idempotent movement + exception policy; không copy kho schema raw. | Duplicate issue, lost ACK, negative/allocated source, reversal |
| `npp-core/api/src/services/sales-manual-completion.js:431–599` complete/settle | **COPY/ADAPT** T5 | ERP chưa có AR/payment posting đầy đủ; completion phải dựa thực giao, không post AR trên confirm, thu 0 là ghi nợ không payment 0. | Amounts partial/0, COD, duplicate completion, AR rebuild |
| `npp-core/api/src/services/sales-order-applied-price.js:114–418`, `db/repositories/pricing.js:345+` | **CONSOLIDATE** vào `backend/src/r1_pricing.ts:58+`; giữ engine duy nhất | `sales_http.ts:225–311,382+` còn legacy/R1 paths; quote/save/confirm có thể khác; thiếu giá lần mua trước và override các mode. | Same fixture search→quote→save→confirm, effective/scope/tier/tax/CK, stale quote |
| `npp-core/api/src/services/sales-order-sku-search.js:58–106` | **COPY/ADAPT** T1 search server-side price+available theo kho/kênh/khách | ERP Flutter đang tải SKU riêng và tra giá/tồn riêng; dễ stale và không chọn đúng ĐVT. | Nhiều SKU/cùng tên, barcode exact, pagination, keyboard UAT |
| `npp-core/web/app/sales/sales-orders/SalesOrderCommercialForm.tsx:1159–1240,1600–1995` | **COPY UX BEHAVIOR**, không copy Next.js, vào Flutter T1 | Form hiện không chọn ĐVT; split sai ý nghĩa; keyboard thực tế không lên/xuống; giá trực quan thiếu rõ. | Product/UOM price requote; split SL1 không trừ gốc; phím thật; CK/tax/giá |
| `npp-core/web/app/products/product-workspace.tsx:678–715` | **COPY UX BEHAVIOR** Flutter T1 | Sửa sản phẩm bị cắt các mục SKU, barcode, quy cách, ảnh; mã định danh phải giữ bất biến. | Form sửa tương đương tạo mới, module/catalog references and snapshots |
| ERP `backend/src/mutation.ts`, `rbac.ts`, `db/migrations/0011_r3_inventory_ledger.sql` | **KEEP** | Identity/audit/idempotency/server Decimal hiện là foundation; thay thế bằng legacy raw sẽ làm mất scope và chứng từ. | Transaction, RBAC deny-default, checksum/replay/backup, exact commit |

## T0 — Inventory guards

| Lớp | Điều kiện trước | Quyết định T0 | Bằng chứng |
|---|---|---|---|
| Flutter/UI | Lập đơn không tự post warehouse ledger | KEEP; cho thông báo thiếu tồn, không ép bấm tra giá | Không để UX giả xác nhận |
| Sales API | `confirm` chốt giá/version, chưa reserve tự động | KEEP; T1/T3 nối orchestration theo MANUAL/TRIP | `backend/src/sales_http.ts:382–455` |
| Inventory service | `reserveStock` từ chối nếu thiếu cả demand | COPY/ADAPT partial, shortage policy `BLOCK/WARN/ALLOW` theo kho | `backend/src/inventory.ts` |
| PostgreSQL | 0011: reservation phải bằng demand và <= available | **MIGRATE additive 0021** `backordered_base`, guard sum=demand, giữ lock và immutability | `db/migrations/0021_t0_partial_reservation_policy.sql` |
| PostgreSQL | 0011: movement OUT phải <= available | **KEEP HARD BLOCK** đến T3 trusted issuer; không tạo fake stock/override từ session variable | 0011 movement guard |
| API permission | `inventory.reserve` là warehouse-scoped | KEEP; thêm `inventory.policy.manage`, scoped permission, revision+idempotency+audit | `inventory_http.ts`, `rbac.ts` |

**Cảnh báo chưa hoàn thành:** Chưa có server direct issue MANUAL/PICKUP và warehouse negative issue policy được owner nghiệm thu. Không nhận T0 này là bằng chứng phép xuất âm đã được phát hành. Để UAT âm kho phải hoàn thiện T3 service, kiểm mọi liên module, không bypass raw SQL. Các mục T1 về giá/đơn xem issue #43; không chấp nhận đóng chỉ vì màn đã render.

## Phát hành và bằng chứng

- Source: repo phụ `khuongbinhinfo-a11y/erp`, PR #45; CI 5/5 và Codex sạch tại SHA cuối là gate bắt buộc.
- **Merge repo phụ trước**; đối chiếu SHA/blobs; sync `gustavjung24-ops/ERP`. Repo chính CI đỏ do quota bỏ qua, không bỏ lỗi code thật.
- Migration 0021 production: chỉ theo script `backend/scripts/t0-0021-codespaces-migration.mjs` trên **main repo chính** đã phê duyệt; check → maintenance READ_ONLY → encrypted durable backup/readback → isolated restore/rehearsal → apply/reconcile → backend deploy/health. Owner phê duyệt migration và lưu evidence riêng.
- Vercel frontend do agent deploy thủ công **Production** khi frontend có thay đổi và backend sẵn sàng; docs-only không deploy, không Preview.
- UAT người thật cho T0/T1 vẫn là gate riêng với CI/Codex.
