# ERP UX V3 — Bố cục màn làm việc chuyên nghiệp cho 6 phân hệ

**Áp dụng sau khi nghiệp vụ có API thật; không tạo màn giả để lấp menu.** Tham chiếu docs/BUSINESS_UX_PARITY_REBASELINE_20261121.md, docs/UI_NAVIGATION_RULES.md, docs/UI_DESIGN_SYSTEM.md. Nghiệp vụ cũ chỉ là nguồn kiểm chứng use case, không sao chép giao diện cũ.

## 1. Information architecture (IA) cho từng vai trò

| Phân hệ | Cấp 1 trên thanh xanh | Cấp 2 ở nội dung, căn trái |
|---|---|---|
| Công Ty | Tổng quan · Bán hàng · Mua hàng · Kho · Tài chính · Danh mục · Báo cáo | Bán hàng: Đơn hàng / Xử lý / Giao hàng; Mua: Đơn mua / Nhập / Trả NCC; Kho: Tồn / Lô-vị trí / Chuyển / Kiểm kê / Điều chỉnh / Giá vốn; Tài chính: Phải thu / Phải trả / Thu chi / COD; Danh mục: Khách hàng / Nhà cung cấp / Sản phẩm / Đơn vị / Bảng giá / Giá chi tiết |
| MCP | Hôm nay · Tuyến · Điểm bán · Đơn hàng · Báo cáo | Danh sách tuyến / Phiên / Ghé thăm; Khách có mã / Điểm mới / Yêu cầu mở mã |
| Quản trị | Tổng quan · Tổ chức · Người dùng · Quyền · Phê duyệt · Nhật ký | Chi nhánh / Kho / Vị trí; Vai trò / Phạm vi; Cấu hình / Chính sách |
| Bán Lẻ | Bán hàng · Đơn tại quầy · Tồn kiểm tra · In ấn | Giỏ / Thu tiền / Giao tại quầy; Lịch sử / In lại; Máy in |
| Giao Hàng | Công việc · Chuyến giao · Thu COD · Bàn giao | Soạn hàng / Nhận việc; Điểm giao / Kết quả / POD; Tiền đang giữ / Đối soát |
| Đặt Hàng | Danh mục · Giỏ hàng · Đơn của tôi · Tài khoản | Nhóm / Tìm kiếm; Đơn mới / Trạng thái / Đặt lại |

Cấp 1 không được lặp lại dạng card điều hướng ở body. Menu chỉ hiển thị chức năng được phép và thực sự triển khai; nếu chưa có API, không được giả lập kết quả. Toàn hệ thống dùng cùng thuật ngữ, màu trạng thái và vị trí hành động.

## 2. Cấu trúc thống nhất cho mỗi workspace

1. Thanh ngữ cảnh: tiêu đề tác vụ, breadcrumbs nếu cần, chi nhánh/kho đang áp dụng, hành động chính bên phải.
2. Thanh tìm/lọc (gọn): search theo mã/tên/SKU/barcode, lọc trạng thái/ngày/nguồn/đơn vị, lưu lựa chọn khi xem chi tiết và quay lại.
3. Nội dung chính: bảng mật độ vừa trên desktop với heading xanh nhạt; mobile dùng card một cột; danh sách dùng pagination/server search, không tải hàng nghìn record để lọc trên client.
4. Chi tiết: pane hoặc page thay vì chuỗi hộp thoại chồng nhau; khối thông tin chia rõ Người mua · Hàng hóa · Giá/thuế · Giao/nhận · Thanh toán · Lịch sử. Chỉ hiển thị nhóm liên quan tới lifecycle hiện tại.
5. Dải hành động sticky: Back/Hủy, Lưu, Xác nhận (theo quyền/trạng thái). Với thao tác không thể sửa, hỏi xác nhận, nêu số chứng từ, phạm vi, hậu quả và đường đảo.
6. Trạng thái: loading có skeleton nếu kéo dài, rỗng có CTA phù hợp, lỗi tại đúng trường/dòng, audit/traces hiển thị cho người được cấp quyền; toast chỉ là thông báo không thay thế trạng thái bền.

## 3. Màn master data ưu tiên trước Sales

- Khách hàng: list với search mã/tên/điện thoại (nếu được phép), trạng thái và nhóm; chi tiết có thông tin cơ bản, địa chỉ giao, điều kiện thanh toán, lịch sử giao dịch; tạo/sửa trong panel, phát hiện trùng và validate server.
- Sản phẩm: danh sách SKU/biến thể, nhóm, đơn vị cơ sở, đơn vị bán lẻ/thùng, barcode, hệ số chuyển đổi, tồn/giá theo quyền; tạo SKU phải có gắn kết product canonical và không vô tình tạo hai tồn kho.
- Bảng giá: danh sách scoped price lists; xem các dòng giá theo SKU/đơn vị, ngày hiệu lực và priority; tìm nhanh, thêm giá hàng loạt/import có preview lỗi, đối soát số thay đổi; có chế độ **Tra giá bán** theo khách/kênh/số lượng/ngày và giải thích mức giá được áp dụng.
- Luồng mở đơn: trước khi vào form xác định các điều kiện phía server: có khách mua hợp lệ, SKU đang bán, bảng giá hợp lệ và giá tại thời điểm/đơn vị bán. Nếu thiếu, hiển thị đúng màn và CTA **Đến Khách hàng / Sản phẩm / Bảng giá**; không đẩy người dùng vào modal sẽ lỗi sau khi bấm Lưu.

## 4. Màn lập đơn là workspace rộng — không dùng AlertDialog 570px

- Desktop: rộng khoảng 96vw, tối đa 1440px; chiều cao khoảng 94vh; header và footer cố định, vùng dòng hàng cuộn độc lập; 1366×768 không cuộn ngang toàn form.
- Trên cùng: Khách hàng [search], ngày/chế độ giao, chi nhánh, bảng giá; các trường ít dùng thu vào **Thông tin thêm**.
- Trung tâm: một ô tìm kiếm tổng hợp SKU/tên/barcode + chọn đơn vị bán → số lượng → Enter thêm dòng, giữ focus tìm hàng. Bảng dòng: SKU, mô tả, đơn vị, SL, giá gốc, điều chỉnh, giá bán, thành tiền, thao tác; tổng tiền rõ ở footer.
- Bên cạnh hoặc cuối (responsive): giá server preview với nguồn áp giá/tier/CK/thuế; hàng thiếu giá hoặc stale được gắn lỗi cạnh dòng, bắt buộc rà lại trước xác nhận. Không làm phép tính giá thẩm quyền trên Flutter.
- Thao tác: Đóng · Lưu đơn · Lưu và xác nhận (khi đủ quyền); xác nhận là công việc riêng với phiếu soạn, giao và thu tiền.
- Mobile: stepper/sections, sticky tổng tiền và hành động dưới, không ép bảng desktop ngang màn 360/390.
- Khách vãng lai chỉ áp dụng nếu installation có policy/cấu hình an toàn; không hardcode một customer ID. Tạo khách nhanh khi giao hàng phải qua API permissioned, duplicate-phone check và idempotency.
- Dòng đã xác nhận là bất biến; sửa bằng phiên bản điều chỉnh/đảo chứng từ, không cập nhật trực tiếp.

## 5. Quy tắc chất lượng có thể kiểm thử

| Mục | Tiêu chí nghiệm thu |
|---|---|
| Desktop | 1440 và 1280; màn tạo đơn 1366×768 không cuộn ngang toàn form; chi tiết và lịch sử không chồng dialog |
| Mobile | 390 và 360; không tràn, nút quan trọng chạm được, form có nhãn, footer không che keyboard |
| Input | Tìm SKU/barcode, mũi tên + Enter, tab order rõ, focus trở về tìm hàng sau khi thêm dòng |
| API/tiền | Giá/CK/thuế/tổng từ server, so sánh stale giá, hiển thị Việt hóa; không làm tròn JS/Flutter float |
| RBAC | Không chỉ ẩn nút: gọi trực tiếp trái quyền bị server 403, không rò installation/branch/warehouse |
| Offline | Đang gửi/Chưa gửi/Đã xác nhận bởi máy chủ phân biệt được, retry đúng idempotency key+body |
| Trạng thái | Empty/action, validation inline, stale/read-refresh, success toast ở góc trên phải, no DEV / tech jargon |
| Visual | Forest #164E35; nền trắng dịu #F5F7F2, header bảng mint #E8F3EB; card radius khoảng 7; controls khoảng 6; không lạm dụng bo lớn hoặc bóng |
| Accessibility | Semantic labels, screen-reader, keyboard navigation, high contrast, reduced-motion |
| Test | Widget + integration + browser ảnh 4 viewport, API contract/PG integration và UAT theo use case, đủ quyền và không đủ quyền |

## 6. Chiến lược triển khai không phá production

Từ ERP main SHA đã đọc, mỗi lô thiết kế lại phải dựa trên API thật và vượt qua bộ kiểm thử của tính năng cũ lẫn mới, không đổi thứ tự chứng từ khi chỉ sửa giao diện. Tách domain/SQL versioned và Flutter thành PR có acceptance. Không sửa hai repo khách cũ, không lấy assets hay thông tin thật. Chỉ phát hành khi CI/Codex xanh, backup/restore (nếu có migration), owner phê duyệt production target, provider read-back và smoke thành công. **UI snapshot/build PASS không thay cho UAT người dùng.**
