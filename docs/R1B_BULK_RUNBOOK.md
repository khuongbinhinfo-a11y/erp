# R1-B — Nhập/cập nhật hàng loạt Excel/CSV và vòng đời SKU

**Triển khai:** chỉ tiếp tục từ repo phụ PR #20 sau CI 5/5 + Codex CLEAN trên exact HEAD. Đồng bộ nguyên Git tree sang repo chính; **không tự chạy migration hoặc deploy backend production**. R1-B hiện **không có SQL migration mới**; PostgreSQL phải ở ít nhất schema `0017_r1a_customer_directories.sql`.

## Người dùng văn phòng

Vào **Công Ty → Khách hàng / Sản phẩm / Bảng giá → Nhập Excel/CSV**.

1. Chọn chi nhánh rồi chọn loại **Khách hàng / Sản phẩm / SKU bán / Giá theo sản phẩm**.
2. Tải mẫu CSV hoặc xuất dữ liệu hiện tại; nhập file XLSX/CSV UTF-8, tối đa **6 MB / 5.000 dòng**.
3. Chọn chế độ **Chỉ thêm / Chỉ cập nhật / Thêm và cập nhật**, khai báo dòng đầu là tiêu đề, ánh xạ từng cột.
4. Phải ánh xạ mã nhận diện: **mã khách**, **mã sản phẩm**, **mã SKU**, hoặc **mã bảng giá + mã sản phẩm**. Mã nhóm/khu vực/ĐVT lấy từ danh mục cùng chi nhánh; không gửi tên tự do.
5. Bấm **Xem trước**. Kiểm tổng CREATE/UPDATE/UNCHANGED/ERROR và từng dòng trước/sau; khi có ERROR cả file chưa thể áp dụng.
6. Xác nhận để ghi **một giao dịch**; khi mất ACK phải bấm **Kiểm tra yêu cầu** (giữ nguyên file, mapping và Idempotency-Key). Timeout sau COMMIT luôn read/replay, không tạo mã mới.
7. Xuất lại CSV và so sánh dữ liệu, giá hiệu lực/nhóm/khu vực, SKU đã ngừng.

**Ý nghĩa ô trống:** không ánh xạ = giữ nguyên; đã ánh xạ nhưng rỗng = xóa trường tùy chọn (nhóm/khu vực/phone/address). Trường bắt buộc không được rỗng. Không ép số trong Excel sang floating point; mã và giá để dạng text/decimal. File có công thức XLSX bị từ chối, không thực thi.

**Bảng giá:** Nhập vào bảng giá *đã tồn tại* theo `priceListCode`, cập nhật theo quy tắc append-only giá hiệu lực (không ghi đè lịch sử). Mỗi `priceListCode+productCode` một dòng/file; giá khác ở cùng thời điểm hiệu lực báo lỗi. Đơn giá chỉ là danh mục thương mại, không tự điều chỉnh chứng từ đã xác nhận.

**Sản phẩm/SKU nhập sai:** Mã SKU, mã vạch và hệ số quy đổi đã tạo không sửa trực tiếp. Vào **Sản phẩm → SKU bán hàng → Sửa**, tắt **Đang sử dụng**, nhập **Lý do ngừng** và lưu. SKU gốc cũng có thể ngừng; khi không còn SKU bán nào hoạt động, server chuyển sản phẩm sang ngừng trong cùng transaction. Trong Excel, ánh xạ cột `active` và `reason` để ngừng SKU sai, rồi tạo SKU thay thế với mã khác; parent chỉ ngừng nếu sau toàn bộ file không còn SKU nào hoạt động. Lịch sử giá, đơn, kho/ledger không sửa.

## Kiểm thử phát hành

- Backend: `npm run typecheck && npm test`; PostgreSQL fresh/replay/restore, concurrency, RBAC, 2 thiết bị, duplicate code, dấu tiếng Việt/UTF8, XLSX/shared strings, formula/zip-bomb, 5.000 dòng, stale preview và retry sau timeout.
- Flutter: `flutter analyze && flutter test && flutter build web --release`, test 390/1024/1440px, mở tệp, mapping, lỗi dòng và xác nhận.
- Codex: CLEAN trên **HEAD cuối**, không chỉ HEAD trước đó.
- Codespaces backend sau khi merge chính: `git switch main && git pull --ff-only origin main`; xác minh approved SHA, `cd backend && npm ci && (cd deploy && npm ci) && npm run build:compute`; deploy Prisma Compute đúng project/target owner giao. R1-B **không tự tạo schema 0018**.
- Vercel: trợ lý build/deploy thủ công từ exact main SHA, kiểm READY, domain production và smoke login/coded dropdown, import preview/apply.
- Smoke thực tế cần 401/403 chi nhánh khác, row count, old/new price, base SKU stop, account switch, lost ACK, không có ảnh hưởng Inventory/AR/AP ledger.

**Trạng thái nghiệm thu:** code/CI, provider, smoke, UAT phải ghi riêng **ĐÃ XÁC MINH / CHƯA XÁC MINH**, không coi PR xanh là production PASS.
