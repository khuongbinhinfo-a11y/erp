# M4 — Audit Android và ranh giới Bán Lẻ POS (26/11/2026)

Baseline đã read-back khi bắt đầu lô: repo phụ main `666fd4796be9d541bc8db146917514db9d335326`; repo chính main `05c495f5a687e3f5eee554f943901cdf9a387190`. SHA chỉ là mốc, không mặc định HEAD tương lai.

## Quyết định nghiệp vụ bắt buộc

**Bán Lẻ = POS cửa hàng/siêu thị**; độc lập luồng **Công Ty → đơn phân phối**. Không mở lại `SalesWorkspace(retailMode:true)` làm POS. Dùng chung server pricing, canonical order, inventory ledger, payment ledger với direct PICKUP; không phát triển ledger/engine thứ hai. Không coi `order.confirm` là xuất hàng, thanh toán, hoàn tất bán hoặc in hóa đơn.

## Audit có chứng cứ

| Ưu tiên | Phát hiện / bằng chứng | Hành động và cổng chấp nhận |
|---|---|---|
| P0 | `apps/flutter/lib/ui/erp_shell.dart` ở baseline M3 hiển thị `SalesWorkspace(retailMode:true)`, không phải POS; `docs/M2_RETAIL_MOBILE.md` ghi xác nhận đơn nhưng chưa thanh toán/xuất kho | Lô M4-A tách màn POS và không tạo paid/stock giả; **P0 nghiệp vụ checkout vẫn mở**, cần API direct issue/completion/payment canonical T3/T5/T6, idempotent, RBAC và reconciliation |
| P0 | Backend contract `backend/src/sales_http.ts` chỉ có order/quote/confirm hiện hành; chưa có receipt checkout POS chứng minh stock + payment cùng một giao dịch | Không bật nút thanh toán; sau khi backend có contract, thử mất ACK, retry, double tap, hai thiết bị, partial/refund |
| P1 | M2 dùng danh sách đơn phân phối trước khi chọn hàng, thêm một modal lập đơn; quá nhiều thao tác trên 360 px | M4-A POS có màn quét/tìm + giỏ trực tiếp, tổng tiền cố định ở đáy; kiểm thật 320/360/390/430 |
| P1 | Chưa có ca/quầy, in hóa đơn, thanh toán hỗn hợp, khách thành viên, đổi/hoàn hàng và cash drawer trong POS | POS lô tiếp theo; không làm giả receipt hay movement |
| P1 | M4-A chưa có dữ liệu tồn chính xác theo SKU + kho trong kết quả; không nên hiển thị tồn từ trang đầu tiên làm tồn toàn bộ | Kết nối API có pagination/filter theo SKU+kho; cần quyền và cảnh báo stale |
| P1 | M4-A giỏ lưu tách `retail-pos-cart`, actor/installation/branch/warehouse; nhưng chưa có CAS lease đa tab của `sales` | Kiểm sau crash, đa tab, account switch và storage eviction trước khi coi offline PASS |
| P1 | Bàn giao M3 chưa có bằng chứng máy thật về APK cài đè, giữ phiên/SQLite, resume Range và permission installer | Hai APK ký cùng key trên máy thật; gián đoạn giữa chừng và SHA/signature/package/version kiểm |
| P2 | Dark Mode và one-hand/chỗ mở keyboard/popup chưa có ảnh test thật cho Android/Web/Windows/PWA | Ma trận tương phản, scale chữ, safe inset, focus, xoay máy và accessibility |
| P2 | Giá retail cần tự chọn bảng giá chính xác theo customer/channel/tier, không tùy tiện lấy bảng giá sai | M4-A ưu tiên bảng giá code RETAIL, luôn hiển thị chọn; backend quote authoritative; test assignment và override |

## M4-A hiện có gì

- `retail_pos_workspace.dart`: màn quầy riêng, nhập quét barcode bàn phím, tìm SKU branch-scoped, giỏ, chỉnh số lượng, giá và tổng theo `/v1/sales/quote`. Không tự tạo chứng từ.
- `local_store.dart`: giỏ POS riêng không ghi đè giỏ phân phối; phân vùng theo installation/actor/branch/warehouse. Không lưu bearer token.
- Test POS dự kiến: không mở `SalesWorkspace`; không POST `/v1/sales/orders`, payment, settlement hoặc stock issue từ cử chỉ xem giỏ; báo giá sau chỉnh số lượng; giữ giỏ khi đổi kích thước.

## Gate không được bỏ qua

CI và Codex trên đúng SHA cuối; review diff + contract; merge repo phụ khi owner cho phép và gate đạt; đối chiếu file sync repo chính; Vercel deploy thủ công khi được giao. APK mới phải tăng versionCode, ký cùng chứng chỉ và phát hành R2 đúng runbook; cần test máy thật để ghi UAT. Không migration/backend trong M4-A. Không gọi M4 hoàn thành khi checkout POS, UAT Android và OTA chưa đủ.
