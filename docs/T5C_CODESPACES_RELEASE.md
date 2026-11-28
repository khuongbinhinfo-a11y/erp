# T5-C — migration 0028: canonical Nhân viên → Tài xế

**Phạm vi:** repo chính `gustavjung24-ops/ERP` main, ERP-DB
`db_jg2bl98hzi1jm06lwo0i4rqx`, Prisma Compute API
`cps_gh30k50bvsc0o9298w9leivf`. **Mọi lệnh production thuộc owner và
chỉ thực hiện sau duyệt riêng; PR/CI xanh KHÔNG tự cho phép migration.**

## Lý do

App cũ xác định tài xế qua nhân viên đang hoạt động. Bảng ERP 0027 trước đây
tạo tài xế bằng mã/tên/điện thoại rời. Migration 0028 tạo `org_employee`
riêng (không đồng nhất login và nhân viên), liên kết
`delivery_driver.employee_id` bằng khóa ngoại installation + branch và unique
active theo nhân viên. Giữ nguyên mọi mã tài xế/chuyến đã tồn tại; tài xế cũ
chưa liên kết vẫn hiện để quản trị đối soát nhưng không thể phân chuyến mới.

## Gate phát hành

1. CI fresh PostgreSQL + replay + concurrency/RBAC, Flutter web/widget,
   Android/Windows, Compute build, isolation: **7/7 PASS** trên đúng SHA.
2. Codex review sạch đúng SHA và review thread đã giải quyết; merge repo phụ
   rồi đồng bộ chính, đối chiếu Git tree/8+ blob.
3. Cấu hình maintenance READ_ONLY có xác nhận trực tiếp từ
   `/health/live` (không tin CLI exit code riêng).
4. Codespaces main sạch, owner/session/Git remote/SHA/Prisma project và DB
   được operator read-back đối chiếu; PostgreSQL 17 client, age, AWS CLI,
   Docker và credentials ngắn hạn có sẵn trong Codespaces secrets bảo vệ.
5. Chạy **chỉ kiểm tra**, không ghi DB:
   `cd /workspaces/ERP/backend && npm run db:migrate:t5c:codespaces -- --check`
   Ghi bằng chứng preflight: base 0027 + checksums, nguyên trạng chứng từ.
6. **Owner duyệt riêng migration 0028** sau khi có plan backup/restore,
   đánh giá ảnh hưởng trạng thái tài xế/chuyến và phương án xử lý sự cố;
   không nhận câu “làm code” là phê duyệt.
7. Operator `--apply` đòi approval exact-value, project/database target và
   xác thực Codespaces private forwarding; sao lưu bằng pg_dump -Fc, mã hóa age,
   tải bền vững S3, đọc lại, giải mã bằng khóa recovery thật, restore isolated
   PG17, diễn tập 0028 trên restore, đối chiếu bất biến và sau đó mới apply.
   Không ghi dump/secrets ra log/commit/chat.
8. Kiểm `org_employee` tồn tại, `delivery_driver.employee_id`, FK,
   partial unique, triggers, 28 checksums, không tạo nhân viên hay liên kết
   giả, không phát sinh inventory/COD/AR. Sau đó deploy backend Compute trên
   SHA đã duyệt, read-back `/health/release` và `/health/ready`; tắt
   maintenance sau đối soát. Cuối cùng deploy thủ công Vercel
   **Production only**, không Preview, UAT có đăng nhập.
9. Không tự rollback/restore Production. Khi migration đã áp dụng mà app
   thất bại, giữ backend READ_ONLY và điều tra; rollback cần kế hoạch
   mới có duyệt riêng.

## Tài xế legacy và kiểm thử

- `POST /v1/delivery/drivers/{id}/link` yêu cầu chọn đúng nhân viên còn
  làm việc và giữ nguyên ID tài xế/chuyến; không tự ghép bằng tên trùng.
- `POST /v1/delivery/drivers` mới chỉ nhận `employeeId`, không nhận
  mã/tên/điện thoại rời.
- Kiểm tra hai user/thiết bị đồng thời, phân chuyến vs. nghỉ việc, trùng
  driver, người inactive, khóa chuyến, truy cập sai installation/branch.
- **T5-C foundation khác T5-D thực thi chuyến**: ghi nhận giao thành công,
  thất bại, hàng trả, COD và công nợ phải đi qua transaction/ledger riêng,
  tuyệt đối không tự ghi tiền từ một lần nhấn offline hoặc gộp stock OUT
  với giao thành công.

**Các trạng thái cần ghi sau release:**
`TASK | BASELINE | FINDINGS | FIX | TEST/CI | PR | MERGE | MIGRATION | DEPLOY | SMOKE | BLOCKERS`.
