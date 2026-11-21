# ERP — Nền tảng phân phối

Hệ thống phân phối gồm sáu phân hệ **Công Ty, MCP, Quản trị, Bán Lẻ, Giao Hàng, Đặt Hàng**.

- **Trạng thái:** khởi tạo nền tảng ngày 18/11/2026; chưa phát hành sản phẩm.
- **Kiến trúc:** Flutter đa nền tảng, API TypeScript modular monolith, PostgreSQL riêng cho từng installation.
- **Quy trình cập nhật 18/11/2026:** thay đổi trực tiếp trên `main`; CI tự chạy sau mỗi push `main`. CI lỗi phải sửa hoặc revert trước lô tiếp theo. Xem `docs/DEV_WORKFLOW.md`. Không bật Git auto-deploy. Production migration/deploy cần owner phê duyệt riêng đúng target.
- **Màu giao diện:** xanh lá, nền trắng ngà dịu; tham khảo quy tắc chung từ `alibaba240185/fbmn` nhưng không sao chép nội dung hoặc dữ liệu khách cũ.

Theo dõi tiến độ tại [GitHub Issues](https://github.com/gustavjung24-ops/ERP/issues), bắt đầu từ #1, #2, #3, #5, #13 và #14.
