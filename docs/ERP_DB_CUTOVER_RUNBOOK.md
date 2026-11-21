# ERP Demo — Chuyển production `erp-sales/erp-demo` → `erp-backend/ERP-DB`

Quy trình này **chỉ áp dụng** source DB `db_xg7823erugsd1ym7c8lf0l9h` và **existing** target `db_jg2bl98hzi1jm06lwo0i4rqx`. Không tạo database thứ ba, không ghép dữ liệu khách cũ. PostgreSQL 17 tại Prisma, backend Prisma Compute, frontend Vercel không kết nối DB.

## Bằng chứng trước thao tác

- Owner đã chấp thuận chuyển DB production trong chat ngày 21/11/2026. Lệnh thực thi trên GitHub sau merge là **một** comment của owner trong [Issue #19](https://github.com/gustavjung24-ops/ERP/issues/19): `ERP_DB_CUTOVER <exact-green-main-SHA>`. Không dùng lệnh này khi chưa có CI PASS trên main SHA, khi lỗi backup, hoặc target không trống.
- Backup durable hiện có được giải mã bằng khóa trong Vercel vault, restore cô lập PostgreSQL 18 và đối soát số dòng/2 hash **14/14 bảng**; chứng cứ ghi tại Issue #19. Backup cũ **không thay thế snapshot mới** ngay trước cutover.
- Backup chuẩn chung trong [BACKUP_RESTORE_STANDARD.md](BACKUP_RESTORE_STANDARD.md) khi PR #20 được duyệt; chưa tuyên bố provider hỗ trợ immutability/PITR hoặc backup managed. Dùng bản backup mới mã hóa age qua S3 với key không ghi đè, S3 tải lại/hash, PG17 restore và đối soát lần nữa.

## Duy nhất một luồng: .github/workflows/erp-db-cutover.yml

1. `issue_comment` owner-only trên main, exact SHA CI xanh và protected `production` environment, OIDC `id-token: write`; không chạy vì push/PR/schedule.
2. Dùng secrets source có sẵn trong **GitHub Actions runner**, tuyệt đối không đưa connection string vào chat, công cụ khác, artifacts hay stdout.
3. Prisma OIDC đặt `ERP_MAINTENANCE_MODE=READ_ONLY` trên Compute **source hiện tại**, deploy đúng SHA, kiểm API thật từ chối POST và trả maintenance=true trước khi backup.
4. Prisma OIDC lấy kết nối target tạm trong **cùng runner**, xác minh target không có object người dùng. `pg_dump -Fc` current source (sau đóng ghi), mã hóa age vào S3 private, download và kiểm SHA256. Restore dump vào PG17 cô lập, so khớp counts/hash và history.
5. Restore nguyên 14 bảng nguồn sang **target đã xác minh trống** bằng `pg_restore --single-transaction --exit-on-error`, kiểm 14/14 bảng, lịch sử 5 migration và toàn bộ dữ liệu auth/session/branch/warehouse. Không seed admin mới.
6. Chạy hàm migration versioned `applyMigrations` cho **0006 + 0007** đúng target, kiểm 7 migrations/21 bảng, bảng danh mục khởi đầu trống. Mỗi bước so nguồn lần nữa trước khi chuyển endpoint; mismatch lập tức dừng.
7. Tạo runtime credential mới lưu vào Prisma Compute encrypted `ERP_POSTGRES_URL`, đặt maintenance=NORMAL cho **deployment mới**, build/release đúng main SHA. Future manual release dùng OIDC **target**, không dùng GitHub source secret cũ để derive ID.
8. Live smoke `/health/live` trả maintenance=false, `/health/ready` 200, đăng nhập admin bằng secret đã bảo vệ, GET customers + suppliers có RBAC đều 200 và items array. Chỉ báo người dùng test khi bước này PASS.

## Fail-closed, sự cố, rollback

- Trước restore target: nếu error, source vẫn ở chế độ READ_ONLY, backup cũ không bị ghi đè, không thử cutover lại tự động. Cần khôi phục phục vụ source thông qua provider được ủy quyền; không tự reset production.
- Sau restore target nhưng trước target deploy: target đã có dữ liệu, **không re-run cùng workflow** vì cổng trống sẽ chặn; kiểm lại dữ liệu/CI, xác định phương án tiếp tục release hoặc rollback đã được owner cho phép.
- Mọi khóa S3 tạm và kết nối target operator tạm đều được revoke trong `finally`; credential runtime tồn tại phục vụ backend sau cutover. Phải ghi event revoke PASS; nếu không, cảnh báo và thu hồi thủ công.
- Không đồng thời mở ghi cho cả backend nguồn và đích. Không xóa/restore đè source cũ. Source được giữ phục vụ rollback, không cho ghi cho tới khi quyết định chính thức. Không bật auto deploy production.
- Chuyển schema của target và đổi Compute env phải cùng một lần operator workflow, khi failsafe không có chuyện chỉ thấy CI xanh rồi coi production đã xong.
- Sau smoke backend, kiểm tiếp Flutter Vercel thật: login token, F5 giữ phiên, CRUD khách/nhà cung cấp, quyền, tab/kho. Đây là **UAT riêng**, không đồng nghĩa GitHub CI PASS.
- Với mỗi installation khách thật sau này, phải có RPO/RTO, retention, immutability, PITR và drill theo điều khoản riêng; không sao chép demo policy.

## Báo cáo cần ghi Issue #19

`BASE SHA | BACKUP S3 SHA256 | REHEARSAL | SOURCE MAINTENANCE | TARGET RESTORE | MIGRATION 0006/0007 | COMPUTE DEPLOY | API SMOKE | FLUTTER UAT | ROLLBACK | BLOCKERS`

Mỗi mục ghi `ĐÃ XÁC MINH / CHƯA XÁC MINH / BỊ BÁC BỎ`; không in secrets hay dữ liệu người dùng.
