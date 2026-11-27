# UX-C — đơn hàng và ảnh bán lẻ (27/11/2026)

Baseline ERP auxiliary main `16b765d078e2e0d7595a5a813b6196f58f4870be`; legacy read-only NPP-Platform `d39e8a87cdc8905a85d92ee3a4b8c7427b3ecd35`. Không sao chép dữ liệu/tài sản cũ.

| Nguồn legacy (path:line) | ERP | Quyết định |
|---|---|---|
| docs/operations/phase-6b1-sales-order-operational-ux.md:150–163 | sales_workspace.dart + sales_http.ts | KEEP lifecycle create/update/confirm và quote/idempotency; CONSOLIDATE danh sách, bộ lọc, thao tác nhanh và bản in phiên bản confirmed. |
| docs/operations/phase-6d2-allocation-pick-pack-decisions.md:27–48,64–88; npp-core/api/src/services/sales-fulfillment-order-allocation.js:106–160 | inventory_workspace.dart + inventory_http.ts | KEEP API giữ hàng thật, deep-link đúng order/branch/warehouse, không nhận giữ hàng là xuất kho. MISSING exact lot/location allocation, pick/pack và batch partial. |
| docs/operations/phase-6d3-delivery-order-handover-decisions.md:26–55,58–71; npp-core/api/src/db/repositories/sales-order-delivery-execution.js:57–107 | sales_order statuses, server.ts | MISSING Delivery Order/attempt/POD và dispatch/hand-over transaction ngoài POS. Không gắn nút cập nhật trạng thái giả. Cần T3/T4 backend+schema+regression trước UAT. |
| npp-core/api/src/services/customer-receivable.js:300–349,475–507 | POS ledger và sales order payment status | MISSING phân phối: nguồn phải thu từ thực giao/nhận, allocation thanh toán, COD. Không ghi AR từ confirm. Cần T5. |
| retail_pos_workspace.dart:710 trước sửa; r1_catalog_http.ts:374; catalog_media_http.ts:176–194 | POS wide grid + productPhotos | FIX API SKU có productId nhưng không imageUrl/thumbnailUrl. Lấy downloadUrl ảnh chính từ API ảnh riêng có RBAC; lazy tối đa 4 request, cache trong RAM trước TTL 300s, xóa scope; mobile không gọi. R2 media CORS đã readback cho hai domain ERP. |

Acceptance: bộ lọc chỉ áp dụng tối đa 100 kết quả do API hiện hành; tra cứu server theo mã/tên. Từ đơn xác nhận đủ quyền vào đúng kho, fetch lại canonical order trước giữ hàng; không mutation khi chỉ mở. Bản in web tab và Android A4 native, Windows HTML export; kiểm thiết bị/browser thật. Đơn đã thực thi không có nút điều chỉnh/hủy trái trạng thái server. Dữ liệu/số liệu Decimal giữ nguyên. Backend/migration không đổi trong phạm vi UI. Thiếu T3/T4/T5 không được báo hoàn tất luồng giao hàng/kế toán.

Tests: pos_product_photo_cache_test, retail_m2_test (desktop fetch, mobile no fetch), sales_order_view_test, existing sales/inventory/print regressions. CI/Codex/UAT cập nhật theo evidence, không suy diễn.
