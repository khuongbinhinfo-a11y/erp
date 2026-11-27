# T3-A — đối chiếu mode giao, kho và dependency T3/T5 (27/11/2026)

> **Cập nhật phạm vi 27/11/2026:** các dòng “MISSING T5-A” ở tài liệu T3-A này là ảnh chụp baseline **trước T5-A**, không phải kết luận hiện tại. Code PR #98 triển khai MANUAL direct completion/return/AR/payment; đối chiếu legacy SHA/path:line → ERP target/disposition/test tại [T5-A source mapping](T5_A_LEGACY_SOURCE_MAPPING_20261127.md). Bằng chứng release phụ thuộc CI/Codex/owner approval, migration 0026 production và device UAT; T5-B/C/D chưa được tuyên bố hoàn tất.\n\n## Baseline và phạm vi
- ERP repo phụ `khuongbinhinfo-a11y/erp` main `62daff7dae999f1a0bf8bfab29b2706cc950f99d`.
- ERP repo chính `gustavjung24-ops/ERP` main `6d290ca94447a75fd2a4f8c6ea1ca3191c35aaee`.
- Legacy chỉ đọc `binhnxwjfjxm/NPP-Platform` main `d39e8a87cdc8905a85d92ee3a4b8c7427b3ecd35`.
- Đây là T3-A: phân luồng và chặn giữ hàng sai mode. **Không** giả định T3-B/T3-C/T5 đã hoạt động; **không** post inventory/AR/payment bằng UI giả. Production release, UAT thật và actual provider cần bằng chứng riêng.

## Ma trận nguồn cũ → ERP mới
| Nguồn legacy / hành vi | Đích ERP | Phân loại và quyết định |
| --- | --- | --- |
| `npp-core/api/src/db/repositories/sales-order-delivery-execution.js:1–55` — mode trên phiên bản, chỉ thay khi bản nháp | `backend/src/sales_order_context.ts:14–77,134–215` và `backend/db/migrations/0022_t1_sales_order_context.sql` | **KEEP/ADAPT**: `MANUAL`/`TRIP`/`PICKUP` nằm trên snapshot từng version, có kho, điều kiện thanh toán, RBAC và guard immutable; không tạo enum/schema thứ hai |
| `npp-core/api/test/manual-delivery-execution-mode.test.js:13–76` — chuyển tuyến và ngăn chuyển khi đã giao/xuất | `backend/src/sales_http.ts:384–569` | **KEEP/ADAPT**: sửa trong DRAFT, phiên bản confirmed immutable; amend/cancel chặn trạng thái đã thực thi và giải phóng giữ hàng khi có thể; phát sinh shipment/trip và guard chuyển chế độ hoàn thiện tại T3-C/T5 |
| `npp-core/api/src/services/sales-direct-stock-issue.js:14–39,301–480` — `MANUAL` & `PICKUP` dùng direct issue, không trip hold | `backend/src/inventory.ts:186–232`, `apps/flutter/lib/ui/inventory_workspace.dart`, `sales_order_view.dart` | **COPY/ADAPT** mode-boundary: version có `MANUAL`/`PICKUP` không được gọi API `inventory.reservation.create`; giao diện không cho chọn giữ hàng đối với hai mode này; đơn lịch sử thiếu context vẫn theo contract cũ. Actual issue cần T3-B |
| `npp-core/api/src/services/sales-manual-completion.js:431–605` — thực nhận, AR, tiền thực thu và retry | Backend delivery/payment chưa có tương đương phân phối | **MISSING T5-A/T5-C**: không post AR từ xác nhận, không tạo payment bằng 0; giữ phần test/giải thuật để copy/adapt sau khi có delivery facts |
| `npp-core/api/src/services/sales-manual-delivery.js:122–317` — manual handover qua `deliveryOrderId` | Luồng MANUAL mới | **DROP đường bắt buộc qua Delivery Order**: không port entrypoint buộc tạo giao hàng riêng; chỉ giữ transaction/idempotency/ledger invariant hữu ích để tích hợp vào direct completion |
| `npp-core/api/src/db/repositories/sales-order-delivery-execution.js:57–142` — facts đã xuất/attempt/trip assignment | T3-C/T5-B | **MISSING**: enforce dựa trên shipment/dispatched facts khi có schema thật; không giả trống bằng trạng thái đơn |
| `npp-core/api/src/db/repositories/customer-receivable.js` và `src/services/customer-receivable.js` | T5-C, cùng ledger POS đã có | **CONSOLIDATE**: không ghi nợ trước hàng thực nhận, không tạo ledger đôi hay payment ảo |

## Phụ thuộc và bất biến
| Giai đoạn | Cần có trước khi ghi fact | Acceptance |
| --- | --- | --- |
| T3-A | Order version context 0022, RBAC kho, immutable confirmed, revision/idempotency | MANUAL/PICKUP không rơi vào luồng giữ hàng; TRIP giữ hàng được, với sản phẩm thiếu tồn theo policy |
| T3-B | Direct stock ISSUE và stock policy, lot/location, inventory ledger/locking | Chỉ actual ISSUE mới trừ tồn, không duplicate và không tiêu thụ giữ hàng của đơn khác |
| T3-C | TRIP reservation/allocation, pick & pack theo quantity thực, issue | Giao một phần và nhiều đợt, không double-post, không ép MANUAL vào soạn chuyến |
| T5-A | Direct ISSUE và return trước hoàn thành, delivered quantity | AR chỉ theo thực nhận; nhập trả không tự sửa posted ledger |
| T5-B | Trip/driver/stop/attempt/POD/retry | Điều phối, giao thiếu, hẹn lại và thất bại có lineage |
| T5-C | Unified receivable/payment allocation, COD custody/handover | Thu 0 là ghi nợ không payment; thu nhiều lần, COD đối soát, không ghi trùng |
| T5-D | API đủ fact T3/T5, Flutter quick actions và in | Từ danh sách/chi tiết đơn làm được thao tác hợp lệ, UAT end-to-end |
| T4 | Shared posting và inventory/AP ledger | Mua hàng/AP không ghi đè hoặc duplicate các ledger dùng chung |

## Regression và phát hành
- Test hiện hành: `backend/src/sales_http.test.ts` đã có create/edit/confirm/warehouse/immutable/permission. T3-A thêm MANUAL reservation 409 không tạo hold, TRIP reserve 201 với backorder chính xác; `apps/flutter/test/sales_order_view_test.dart` kiểm 3 mode, cả list/detail.
- Code mới thêm mode guard tại backend trước SQL tạo reservation, cộng lọc Flutter và kiểm tra server-detail lại trước mutation. Idempotency/revision transaction tiếp tục qua `executeMutation`, không tự post ledger.
- Không cần migration **cho thay đổi T3-A này**: 0022 đã có enum/version context, 0021 đã có partial reserve policy. Các bảng stock ISSUE/TRIP/COD sẽ cần migrations riêng ở các lô sau.
- Required: PR head cuối CI + Codex sạch, migration regression qua CI, review diff/security, merge có phép, sync, deployment theo gate, readback/smoke. Không ghi PASS trước khi log thật xác nhận.
