# R1-A — migration 0017, Codespaces ERP-DB

**Target duy nhất:** `erp-backend / ERP-DB` — project `proj_ud3b1s5yn03vh0zp9cbs2upa`,
database `db_jg2bl98hzi1jm06lwo0i4rqx`. Không áp dụng sang `erp-demo`.
Owner cần duyệt riêng maintenance/migration production; không tự deploy hoặc migrate chỉ vì CI PASS.

## Phụ thuộc: 0015–0016 phải hoàn tất

R1-A `0017_r1a_customer_directories.sql` chỉ chạy khi `0001–0016`
đã có checksum khớp. Đối chiếu SQL read-only trên ERP-DB; nếu chưa có 0015–0016,
thực hiện runbook `docs/R1_MEDIA_MIGRATION_RUNBOOK.md` bằng operator riêng
sau khi backup/restore, **không cho R1-A chạy vượt thứ tự**.

## Kiểm tra (không ghi DB)

Tại **Codespaces repo chính** trên chính xác main SHA đã merge và owner duyệt,
khi tất cả GitHub checks/review trên repo phụ PASS/CLEAN:

```bash
cd /workspaces/ERP
git switch main && git pull --ff-only origin main
test -z "$(git status --porcelain)"
cd backend
npm ci && (cd deploy && npm ci)
export ERP_APPROVED_SHA="$(git -C .. rev-parse HEAD)"
export ERP_TARGET_PROJECT_ID=proj_ud3b1s5yn03vh0zp9cbs2upa
export ERP_TARGET_DATABASE_ID=db_jg2bl98hzi1jm06lwo0i4rqx
npm run db:migrate:r1a:codespaces -- --check
```

Cần receipt `ERP_R1A_CHECK_ONLY_NO_DATABASE_WRITES`. Nếu thấy
`ERP_DB_MIGRATION_DRIFT_BEFORE`, phải xác minh 0015–0016, tuyệt đối không
chạy thủ công file SQL để bỏ gate.

## Cửa sổ bảo trì

Đóng ghi từ API bằng maintenance **READ_ONLY** sau owner duyệt. Thay đổi project
env chỉ có hiệu lực sau deploy mới; xác minh `/health/live` trả `maintenance:true`.

```bash
cd /workspaces/ERP/backend
npm run build:compute
(
 cd deploy
 npx --no-install prisma project env update ERP_MAINTENANCE_MODE=READ_ONLY --role production --project proj_ud3b1s5yn03vh0zp9cbs2upa
 npx --no-install prisma deploy --entry ./module.ts
)
node -e 'fetch("https://gh30k50bvsc0o9298w9leivf.sin.prisma.build/health/live").then(async r=>{const j=await r.json();if(!r.ok||j.service!=="erp-api"||j.maintenance!==true)process.exitCode=1;else console.log("READ_ONLY_CONFIRMED")}).catch(()=>process.exitCode=1)'
```

Khi đã xác nhận maintenance và được phép áp dụng đúng 0017:

```bash
cd /workspaces/ERP/backend
export ERP_R1A_MIGRATION_APPROVAL=OWNER_APPROVED_R1A_0017_ERP_DB
npm run db:migrate:r1a:codespaces -- --apply
unset ERP_R1A_MIGRATION_APPROVAL
```

Operator buộc: xác thực Codespace repo chính + SHA `main` từ GitHub;
tài khoản một lần đúng ERP-DB; PG17; snapshot dump `age` gửi kho S3 riêng,
tải lại/kiểm SHA/decrypt bằng recovery identity thật; restore cô lập PG17;
replay đúng `0017`; đối soát nguyên vẹn **mọi cột cũ của khách hàng, barcode**
và các bảng khác; kiểm backfill group code/name, số group, khu vực ban đầu rỗng;
dọn container + Docker volume plaintext và thu hồi credential.

PASS chỉ khi có receipt:
`ERP_R1A_0017_MIGRATION_PASS_AND_RECONCILED`, chứng cứ S3 key+SHA,
recovery rehearsal và thu hồi credential.

## Mở lại và smoke

```bash
cd /workspaces/ERP/backend
npm run build:compute
(
 cd deploy
 npx --no-install prisma project env update ERP_MAINTENANCE_MODE=NORMAL --role production --project proj_ud3b1s5yn03vh0zp9cbs2upa
 npx --no-install prisma deploy --entry ./module.ts
)
npm run db:migrate:r1a:codespaces -- --check
```

Smoke: /health/live maintenance=false, /health/ready 200,
mã nhóm/khu vực create/PATCH/list; khách tạo/chọn/sửa theo ID;
khách cũ nhóm có dấu giữ nguyên và giá nhóm cũ/mới resolve trùng khớp;
401/403 scope khác chi nhánh, stale revision, popup 390/1280, SKU/mã vạch
lifecycle; không được tự động đổi báo cáo/kho/chứng từ.
Nếu lỗi giữa các giai đoạn, để READ_ONLY, đọc trạng thái DB/backup trước
khi retry, không restore trực tiếp production và không chạy lại vô điều kiện.
