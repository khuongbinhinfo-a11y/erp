# IA-A — Canonical nhân sự dùng chung, migration 0029 và release gate

## Quyết định IA (Issue #112)

- **Công Ty → Nhân sự → Nhân viên** quản lý hồ sơ theo chi nhánh và bộ phận/chức vụ, không yêu cầu tài khoản login hoặc kho.
- **Quản trị → Tài khoản → Liên kết nhân viên** chỉ người có `identity.users.manage` installation và `org.employees.manage` đúng chi nhánh; account mapping tùy chọn, unique.
- **Công Ty → Giao nhận** chỉ liên kết nhân viên đang hoạt động làm tài xế; không tạo/sửa nhân sự tại màn chuyến.
- Mọi nhân viên/driver/trip cũ giữ nguyên canonical ID và lịch sử. Dùng bảng `org_employee` từ 0028, không clone sang bảng mới.
- API mới: `GET /v1/org/employees/branches`, `GET/POST /v1/org/employees`, `PATCH /v1/org/employees/{id}`, `PATCH /v1/admin/users/{id}/employee`. Legacy delivery employee route vẫn phục vụ tương thích cho T5-C, nhưng chỉnh sửa yêu cầu HR permission.
- Quyền `org.employees.read`, `org.employees.manage` là scope branch, deny-by-default. Owner branch roles hiện có nhận grant mới qua migration; người dùng thông thường không tự có quyền.

## Migration 0029

`backend/db/migrations/0029_iaa_employee_access.sql`: additive, `org_employee.department` và quyền nhân sự owner-branch. Không sửa/xóa chứng từ hoặc migration 0028.

**Lệnh Production chỉ chạy trong Codespaces repo chính sau khi owner duyệt migration 0029 bằng quyết định riêng.** Không coi lệnh làm IA-A là phê duyệt migration.

### Trình tự bắt buộc

1. PR #113 CI + Codex clean trên final SHA, owner cho phép merge repo phụ, sau đó đồng bộ primary main, kiểm exact blobs/tree.
2. Xác minh main SHA, Codespaces origin, Prisma project `proj_ud3b1s5yn03vh0zp9cbs2upa`, DB `db_jg2bl98hzi1jm06lwo0i4rqx` và kiểm `/health/release`.
3. Bật bảo trì `READ_ONLY` trên Compute và readback `/health/live` `maintenance:true`.
4. Cài dependencies trong Codespaces, kiểm script `npm run test:iaa:operator`; export `ERP_APPROVED_SHA=<sha đã đồng bộ>`, `ERP_TARGET_PROJECT_ID`, `ERP_TARGET_DATABASE_ID`.
5. **Preflight read-only:** `npm run db:migrate:iaa:codespaces -- --check`. Script không cho phép migration files ngoài đúng baseline 0001–0028 + delta 0029, kiểm checksum 28 migration, dữ liệu, repo origin và private forwarding attestation.
6. Sau phê duyệt migration riêng của owner, đặt `ERP_IAA_MIGRATION_APPROVAL=OWNER_APPROVED_IAA_0029_ERP_DB` (không tự coi giá trị này là chứng cứ owner đã duyệt); operator đã bảo vệ bằng Codespaces session, target DB, exact SHA, maintenance và secrets. `npm run db:migrate:iaa:codespaces -- --apply`.
7. Operator phải tạo `pg_dump -Fc`, mã hóa age bằng recipient thật, lưu object bất biến S3 riêng, đọc lại và xác minh hash, giải mã bằng recovery key thật, khôi phục vào PostgreSQL 17 Docker cô lập và chạy 0029 rehearsal; đối soát toàn bộ hàng tồn trước/sau (trừ cột mới/grants mới) và checksum. Chỉ sau đó mới apply 0029 Production. Không ghi credentials, dump, PII vào logs/chat.
8. Kiểm lại 29 checksum, `org_employee.department`, CHECK constraint, owner permission scopes, trigger, FK driver→employee, không mất nhân viên/chuyến/đơn/ledger.
9. Build/backend Compute trong Codespaces exact SHA; kiểm `/health/release`, `/health/ready`. Tắt READ_ONLY sau reconciliation, readback maintenance false. **Sau đó** agent tự deploy Vercel Production thủ công (không Preview) đúng SHA, xác nhận READY.
10. Authenticated smoke/UAT gồm: một nhân viên không có user; HR chỉ xem không được sửa; HR khác branch bị 403; quản lý nhân viên không cần quyền delivery/warehouse; liên kết tài khoản unique & retry; tài xế chọn nhân viên; nhân viên đang có PLANNED/LOCKED trip không thể ngừng/chuyển. Android signed APK/R2 OTA là gate phát hành khác, không suy ra từ Web READY.

**Nếu một gate thất bại:** ngừng triển khai; không tự restore/rollback production. Đã apply migration mà frontend không sẵn sàng thì giữ READ_ONLY và điều tra, cần quyết định riêng cho khôi phục.

**Báo cáo cuối:** `TASK | BASELINE | FINDINGS | FIX | TEST/CI | PR | MERGE | MIGRATION | DEPLOY | SMOKE | BLOCKERS`.
