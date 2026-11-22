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
**ERP-DB là PostgreSQL 17.x, bắt buộc pg_dump/pg_restore phiên bản 17.**
Ubuntu 24.04 có thể cài client 16 mặc định; nếu báo
`POSTGRES_17_CLIENT_REQUIRED_PG_DUMP` hoặc
`POSTGRES_17_CLIENT_REQUIRED_PG_RESTORE`, cài **chỉ client 17**
từ repository PostgreSQL chính thức
(https://www.postgresql.org/download/linux/ubuntu/),
kiểm tra `pg_dump --version` và `pg_restore --version`
trước khi chạy lại. Không đổi PostgreSQL server production.
Nếu client 17 vẫn báo lỗi, operator chỉ in mã phân loại (ví dụ
`PG_DUMP_AUTHENTICATION_FAILED`, `PG_DUMP_TLS_VERIFY_FAILED`,
`PG_DUMP_DATABASE_PERMISSION_DENIED`, `PG_DUMP_SNAPSHOT_MODE_UNSUPPORTED`)
và dừng trước migration. Không in stderr gốc vì có thể chứa thông tin kết nối.
Kết nối Prisma CLI từ backend/deploy bằng prisma auth whoami (đăng nhập nếu cần).

Đặt biến sau trong **GitHub Settings → Codespaces → Secrets** hoặc môi trường
terminal bảo vệ, không ghi giá trị vào chat, commit, issue, log hoặc file .env:

| Biến | Nguồn / yêu cầu |
| --- | --- |
| Prisma CLI đã đăng nhập | Operator tự tạo credential TCP một lần cho đúng database ID và tự thu hồi sau khi chạy. Không dùng URL tự nhập. |
| AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY | Key chỉ cho Prisma bucket erp-db-migration-encrypted-backups |
| ERP_BACKUP_S3_ENDPOINT | HTTPS S3 endpoint của bucket trên, không kèm path |
| ERP_AGE_RECIPIENT | Public age recipient được quản lý cùng private recovery key riêng |
| ERP_AGE_RECOVERY_IDENTITY | Khóa riêng age tương ứng recipient (secret Codespaces, chỉ dùng giải mã bản backup production thực sự để thử restore; không xuất log) |

Bucket đã tồn tại. **Chưa xác minh khóa truy cập từ Codespaces và private recovery key**;
script sẽ từ chối nếu chưa đủ. Khóa khôi phục chỉ được đưa vào Codespaces secret
trong thời gian chạy operator, phải được thu hồi/luân chuyển sau phiên phát hành.
Operator giải mã trực tiếp bản backup đã đọc lại từ bucket bằng chính khóa riêng
khôi phục (không dùng khóa thử khác), restore độc lập qua Docker Postgres 17 và đối soát.
Trước khi kết nối database, operator dùng authenticated Prisma CLI tạo credential mới
cho đúng ID ERP-DB và GitHub CLI xác minh Codespace đang chạy trên repo chính.
Yêu cầu GitHub Codespaces tự cung cấp GITHUB_TOKEN dạng ghu_ được phát hành theo
phiên Codespace (không nhận local Personal Access Token hoặc gh login đơn thuần),
GITHUB_USER, GITHUB_REPOSITORY. Không copy GITHUB_TOKEN ra ngoài Codespaces.
Token phiên được dùng để đọc /user/codespaces/<CODESPACE_NAME> và đối chiếu
trạng thái Available, repo chính và owner.login = gustavjung24-ops.
Để chống sao chép token sang máy khác, script còn mở một HTTP server tạm trên
một cổng ngẫu nhiên, rồi kiểm tra nonce trả về qua **HTTPS GitHub Codespaces
private forwarded port** (<CODESPACE_NAME>-<PORT>.app.github.dev). GitHub
Codespaces tự động forward khi terminal in http://localhost:<PORT>.
Nếu terminal VS Code không auto-forward, mở tab PORTS và forward đúng PORT
đang được in trong lúc operator còn chạy, để Private; nếu không, operator
dừng **trước khi đụng database**, không được bỏ qua/chuyển sang public.
Nếu token phiên thiếu quyền API hoặc không có port forwarding, script từ chối;
không thay bằng PAT ngoài Codespaces.

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

Chỉ sau khi duyệt target, có maintenance:true, đã cấu hình private recovery key trong Codespaces secret:

~~~bash
cd /workspaces/ERP/backend
export ERP_R3_MIGRATION_APPROVAL=OWNER_APPROVED_R3_0011_0014_ERP_DB
npm run db:migrate:r3:codespaces -- --apply
~~~

Operator:
1. Xác minh main, exact SHA, database và Compose maintenance.
2. Xác minh 10 migration/PG17/checksum/fingerprint nền.
3. Pg_dump, mã hóa age, upload private S3, readback SHA256, giải mã chính bản đã
   đọc lại từ S3 bằng recovery key thực và xác minh SHA256 của dump.
4. Restore vào PostgreSQL 17 Docker loopback riêng, so dòng dữ liệu cũ,
   rehearsal 0011–0014, xác minh đủ 14 migration và tất cả bảng nghiệp vụ.
5. Trước ghi database thật, kiểm tra maintenance còn hiệu lực và fingerprint
   không đổi; applyMigrations chạy trong transaction và advisory lock.
6. Xác minh 14 version và dữ liệu nền không đổi ngoài schema_migrations
   và các quyền mới trong role_permission. In object URI/hash backup, không secret.
7. Dọn dump/khóa khôi phục tạm/container cục bộ và thu hồi credential Prisma
   do operator tạo khi hoàn tất hoặc gặp lỗi. Thu hồi không xác minh được sẽ báo lỗi.

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
