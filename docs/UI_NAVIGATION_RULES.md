# ERP — Quy tắc điều hướng phân cấp UI

**Hiệu lực:** 20/11/2026. Áp dụng cho toàn bộ 6 phân hệ: Công Ty, MCP, Quản trị, Bán Lẻ, Giao Hàng, Đặt Hàng.

## 1. Các cấp điều hướng

- **Cấp 0** — phân hệ: menu dọc bên trái, tên nhất quán với product contract.
- **Cấp 1** — chức năng chính trong một phân hệ: **phải nằm ngay trên thanh tiêu đề xanh lá**, về **phía bên phải của tên phân hệ**, chữ **trắng tương phản cao**, tab đang chọn có dấu gạch chân **xanh chanh**. Thứ tự chức năng trong dữ liệu được giữ nguyên, nhóm tab căn sát phải; khi không đủ chỗ thì cuộn ngang, không tạo thanh thứ hai bên ngoài vùng xanh.
- **Cấp 2 trở đi** — tab phụ của chức năng cấp 1: nằm **sát trái, bên dưới tiêu đề xanh** trong nội dung trang. Ví dụ `Sản phẩm → Sản phẩm / Nhóm hàng`, `Bảng giá → Bảng giá / Lịch sử đơn giá`. Không đưa tab cấp 2 lên thanh tiêu đề.
- **Không lặp cấp 1** trong body; chỉ một trạng thái lựa chọn có thẩm quyền.

## 2. Widget dùng chung

- `ErpPageHeader(trailing: ErpHeaderTabs<...>)`: cấp 1 trên thanh xanh, dùng cho Công Ty và Quản trị ngay; tất cả phân hệ có tab cấp 1 sau này phải dùng widget này.
- `ErpSectionTabs<T>`: cấp 2 trở đi, căn trái bên trong nội dung; chỉ hiện khi có nhiều tab con.
- Giữ key, onSelected, keyboard semantics, motion-reduction và màu theo `ErpTokens`.
- Thu hẹp viewport: tiêu đề và các tab cấp 1 vẫn ở **cùng khối nền xanh**, được xếp thành hai hàng khi cần; các tab cuộn ngang, không tràn hoặc che text.

## 3. Nguyên tắc thông báo API

- Phân biệt lỗi máy chủ **chưa phát hành API** / thiếu migration với **mạng không kết nối**, không ghi chung thành lỗi mạng của người dùng.
- Flutter không nối trực tiếp PostgreSQL. CORS/OPTIONS và `/v1/catalog/*` là trách nhiệm backend Prisma Compute; build web chỉ chứa public API origin.
- Chưa có backend/catalog migration thực tế: hiển thị trạng thái lỗi có hành động phù hợp, **không thay thế bằng dữ liệu mẫu hoặc giả báo lưu thành công**.
- Lệnh ghi có hiệu lực sau server ACK, retry giữ idempotency/đối soát.

## 4. Acceptance

- Widget tests: tab cấp 1 nằm trong bounding box của `erp-page-header`; cấp 2 nằm dưới và ở trái.
- Không tràn trên desktop 1280/1600 và mobile 390; Quản trị dùng cùng widget; tác vụ tìm kiếm và tạo/sửa danh mục không đổi.
- Máy chủ còn sống nhưng catalog CORS/missing backend phải hiện lỗi chuyên biệt, không thông báo kiểm tra mạng chung.
- CI Flutter analyze + widget + Web release PASS trên đúng SHA; Vercel production chỉ deploy SHA đã PASS.

## 5. Sidebar và phiên đăng nhập (quy tắc owner 20/11/2026)
- Logo ERP ở góc trên trái sidebar; **nút thu gọn/mở rộng ở cùng hàng, phía bên phải logo**, không nằm ở chân sidebar.
- **Chân menu luôn hiển thị tên đăng nhập thực tế kế bên biểu tượng đăng xuất**, lấy từ `/v1/auth/session` của server, không suy đoán từ mã UUID. Menu thu gọn chỉ hiển thị nút đăng xuất có tooltip.
- Sau khi đăng nhập, token revocable được lưu theo origin/app để phiên còn sau reload/đóng-mở trình duyệt; không lưu mật khẩu. Khi mở lại, phải **xác minh với server trước** khi cho gọi API. Mất mạng/503: giữ phiên trên máy, cung cấp "Kết nối lại", không ép logout. Server trả 401/403 hoặc người dùng chọn đăng xuất: xóa token và thu hồi server token.
- Demo ERP sử dụng thời hạn server session dài (10 năm) để mô phỏng "đến khi người dùng logout"; user bị vô hiệu hóa hoặc session bị thu hồi luôn có quyền ưu tiên. **Trước khi cung cấp cho khách hàng thật**, thay browser plaintext storage bằng giải pháp session/cookie hoặc storage bảo vệ thích hợp, bật giới hạn phiên theo chính sách từng installation.
