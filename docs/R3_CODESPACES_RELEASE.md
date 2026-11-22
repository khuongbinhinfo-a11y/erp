# ERP R3 — migration trực tiếp từ Codespaces (operator thủ công)

**Target duy nhất:** repo chính gustavjung24-ops/ERP nhánh main;
Prisma project erp-backend (proj_ud3b1s5yn03vh0zp9cbs2upa);
PostgreSQL ERP-DB (db_jg2bl98hzi1jm06lwo0i4rqx);
backend https://gh30k50bvsc0o9298w9leivf.sin.prisma.build.

Không chạy trên repo phụ, erp-demo, database khách cũ, GitHub Actions hoặc Vercel.
Script không tự lấy secret hoặc in URL/khóa mật; chỉ sử dụng biến môi trường
đã được cấu hình riêng trong Codespaces.

## 0. Chuẩn bị trong Codespaces

Yêu cầu Node 22+, Git, Docker daemon, pg_dump/pg_restore/pg_isready PostgreSQL 17,
age, aws CLI. Backend đã cài npm dependencies.
Kết nối Prisma CLI từ backend/deploy bằng prisma auth whoami (đăng nhập nếu cần).

Đặt biến sau trong **GitHub Settings → Codespaces → Secrets** hoặc môi trường
terminal bảo vệ, không ghi giá trị vào chat, commit, issue, log hoặc file .env:

| Biến | Nguồn / yêu cầu |
| --- | --- |
| ERP_POSTGRES_DIRECT_URL | Direct TCP PostgreSQL URL từ ERP-DB, db.prisma.io, sslmode=require; không phải erp-demo |
| AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY | Key chỉ cho Prisma bucket erp-db-migration-encrypted-backups |
| ERP_BACKUP_S3_ENDPOINT | HTTPS S3 endpoint của bucket trên, không kèm path |
| ERP_AGE_RECIPIENT | Public age recipient được quản lý cùng private recovery key riêng |
| ERP_BACKUP_RECOVERY_KEY_CUSTODY | VERfIED phải viết hoa là VERIFIED, chỉ đặt khi đã xác minh giữ private recovery key |

Bucket đã tồn tại. **Chưa xác minh khóa truy cập từ Codespaces và private recovery key**;
script sẽ từ chối nếu chưa đủ. Backup mã hóa được tải lên bucket riêng, readback SHA256,
restore độc lập qua Docker Postgres 17, đối soát trước khi production migrate.

### Đưa backend vào bảo trì trước khi migration

Từ Codespaces backend/deploy, chạy bằng Prisma CLI đã xác thực:

~~~bash
cd /workspaces/ERP/backend/deploy
npx --no-install prisma project env update ERP_MAINTENANCE_MODE=READ_ONLY --role production --project proj_ud3b1s5yn03vh0zp9cbs2upa
# Nếu key chưa tồn tại, dùng project env add thay vì update một lần.
npx --no-install prisma deploy --entry ./module.ts
curl -fsS https://gh30k50bvsc0o9298w9leivf.sin.prisma.build/health/live
~~~

Phải nhận HTTP 200 và maintenance:true. Nếu không, dừng. Deploy Compute chỉ
đổi chế độ bảo trì, không chạy migration hoặc đổi database.

## 1. Kiểm tra repo main và database (không ghi DB)

~~~bash
cd /workspaces/ERP
git switch main
git pull --ff-only origin main
git rev-parse HEAD
# Gắn đúng SHA 40 ký tự owner đã duyệt từ repo chính sau đồng bộ
export ERP_APPROVED_SHA='<SHA_40_KY_TU_DA_DUYET>'
export ERP_TARGET_PROJECT_ID=proj_ud3b1s5yn03vh0zp9cbs2upa
export ERP_TARGET_DATABASE_ID=db_jg2bl98hzi1jm06lwo0i4rqx
cd backend
npm install --no-audit --no-fund
npm run db:migrate:r3:codespaces -- --check
~~~

Kết quả mong đợi: ERP_R3_BASE_0010_CHECKSUM_AND_LEDGER_PREFLIGHT_PASS
và ERP_R3_CHECK_ONLY_NO_DATABASE_WRITES. Script từ chối sai Codespaces/main/SHA,
history không đúng 10 version, checksum sai hay worktree thay đổi; ngoại lệ
duy nhất cho hai file package-lock.json phát sinh từ npm install của backend và deploy.

## 2. Owner chạy migration R3 — chỉ một lần (ghi ERP-DB)

Chỉ sau khi duyệt target, có maintenance:true, xác minh quyền giữ private key:

~~~bash
cd /workspaces/ERP/backend
export ERP_R3_MIGRATION_APPROVAL=OWNER_APPROVED_R3_0011_0014_ERP_DB
npm run db:migrate:r3:codespaces -- --apply
~~~

Operator:
1. Xác minh main, exact SHA, database và Compose maintenance.
2. Xác minh 10 migration/PG17/checksum/fingerprint nền.
3. Pg_dump, mã hóa age, upload private S3, readback SHA256, một bản rehearsal
   mã hóa riêng và giải mã trên môi trường cô lập.
4. Restore vào PostgreSQL 17 Docker loopback riêng, so dòng dữ liệu cũ,
   rehearsal 0011–0014, xác minh đủ 14 migration và tất cả bảng nghiệp vụ.
5. Trước ghi database thật, kiểm tra maintenance còn hiệu lực và fingerprint
   không đổi; applyMigrations chạy trong transaction và advisory lock.
6. Xác minh 14 version và dữ liệu nền không đổi ngoài schema_migrations
   và các quyền mới trong role_permission. In object URI/hash backup, không secret.
7. Dọn dump/key rehearsal/container cục bộ khi hoàn tất hoặc gặp lỗi.

Không chạy db:migrate:ci, script production R1, SQL tay hoặc prisma migrate deploy
vào ERP-DB. Nếu backup/readback/restore/rehearsal không đạt thì dừng trước SQL
production. Nếu migration lỗi, giữ maintenance, không tự restore production.

## 3. Mở backend sau khi database đã xác minh 14 version

~~~bash
cd /workspaces/ERP/backend/deploy
npx --no-install prisma project env update ERP_MAINTENANCE_MODE=NORMAL --role production --project proj_ud3b1s5yn03vh0zp9cbs2upa
npx --no-install prisma deploy --entry ./module.ts
curl -fsS https://gh30k50bvsc0o9298w9leivf.sin.prisma.build/health/live
curl -fsS https://gh30k50bvsc0o9298w9leivf.sin.prisma.build/health/ready
~~~

/health/live phải trả maintenance:false. /health/ready 200 **không chứng minh R3**:
vẫn phải đối chiếu schema_migrations đủ 14 version, kiểm tra kho/mua hàng/
chuyển kho/kiểm kê và RBAC trong API thực tế. Không tự tạo chứng từ khách thật.

R3 release chỉ hoàn tất sau khi có bằng chứng backup object/hash, restore,
migration version, backend ACK và production smoke. CI xanh chỉ là build gate.
