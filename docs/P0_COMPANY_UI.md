# Lô P0 UI Công Ty & Quản trị — 19/11/2026

## Phạm vi đã code (UI-only, chưa kích hoạt business API)
- Công Ty: dashboard không có số liệu giả; ô nghiệp vụ theo nhóm; điều hướng đến Khách hàng, Sản phẩm, Bảng giá, Kho hàng, Đơn hàng, Công nợ, Báo cáo.
- Danh sách dùng cột thích hợp với từng domain; tìm kiếm giao diện local và trạng thái trống minh bạch.
- Quản trị: hai tab Tài khoản và Ma trận quyền, mã quyền khớp `backend/src/rbac.ts`, không hiển thị user giả.
- Các nút tạo mới/thêm user bị vô hiệu hóa cho tới khi đã có HTTP auth, RBAC, audit, ledger và ACK.
- Desktop-first, mobile scroll và navigation. CI chạy Flutter analyze, widget tests và Web release build.
- Không lưu hoặc đưa bất kỳ dữ liệu giả nào thành tài khoản, chứng từ, tồn kho, công nợ thật.

## Chưa hoàn tất (phải làm tiếp)
- Backend login HTTP với trusted installation, throttling, cookie/session secure, admin bootstrap và thao tác cấp/thu quyền.
- Kết nối API xác thực, dữ liệu thật, phân quyền theo chi nhánh/kho, lưu nháp/offline và nghiệp vụ posting.
- Android/Windows/Web/browser UAT 1440/1280/390/360 chưa chứng minh qua thiết bị thật.
- `erp-demo` chưa migration; cần backup thật, thử restore, đối soát và owner approval riêng.

Không đánh dấu P0 hoàn thành toàn bộ; đây là bước UI để quan sát tiến độ trên Vercel.
