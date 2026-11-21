# ERP — Production-only Runbook (chưa được kích hoạt)

## Điều kiện trước release
- Read-back team Vercel, project ERP, git integration, auto deploy OFF, Prisma DB đúng erp-sales, backup policy và owner target.
- Lấy exact main SHA, CI `push main` PASS trên **đúng release SHA**, kiểm phân hệ đúng target. Không cần PR cho lô mới khi owner đã phê duyệt direct-main. Không release nếu CI PENDING/FAIL.
- Review migrations, checksum, replay trên fresh DB, drift, backup, **thử restore** và reconciliation trước khi xin duyệt migration production.
- Secrets cấp ở provider protected scope; không ghi vào chat/issues/logs/client. Không tái sử dụng tài nguyên khách cũ.

## Quy trình phát hành có phê duyệt riêng
1. Owner giao lệnh phát hành có target installation/environment, SHA và cửa sổ phát hành.
2. Kiểm CI + audit + migration gates. Nếu migration thật cần phê duyệt riêng trước khi chạy.
3. Stage **production artifact** theo chính sách production-only; không tạo preview. Smoke build đã stage trước khi promote.
4. Chỉ promote artifact được smoke/UAT + owner duyệt. Release manifest lưu SHA, checks, deployment ID, URL, smoke evidence, rollback plan.
5. Nếu lỗi, dừng mutation, quyết định rollback/reversal phù hợp; không restore production khi thiếu quyết định owner.

## Trạng thái repo
Không có automation triển khai production trong L0. CI phân tích/test trên `main`, không tự deploy hoặc migration sản xuất. Quyền Vercel đã được xử lý và project `erp` đã tạo (chưa deploy); Prisma connector vẫn thiếu thao tác tạo DB vào project hiện có `erp-sales`.

## Prisma demo database (18/11/2026)
- Verified: `erp-sales` owns `erp-demo` (`db_xg7823erugsd1ym7c8lf0l9h`) in Singapore, status READY. Prisma branch `main` has role production; no Prisma migration was recorded at inspection.
- Versioned backend migrations use transaction + advisory lock + checksum; CLI is **restricted to ephemeral localhost/erp_ci**. It cannot modify Prisma or production. CI checks fresh migration, replay and real DB readiness.
- Applying any migration to Prisma `erp-demo` requires separate reviewed authorization and backup/restore/reconciliation gates; no database secrets in GitHub, chat or logs.

## Prisma Compute manual-only backend release preparation (18/11/2026)
- Source: `backend/deploy/{module,service,prisma.config,entry}.ts`, `backend/deploy/README.md`. Composer declares only the API service; it does not provision another Postgres DB.
- GitHub Actions `prisma-compute-manual.yml` runs ONLY on `workflow_dispatch`, requires `erp-sales` target, exact main SHA and verified successful main CI, and uses short-lived GitHub OIDC.
- Prisma production secret `ERP_POSTGRES_URL` must point at existing `erp-demo` and must be created inside provider, never exposed to Flutter/Vercel static output.
- Before dispatch, owner must separately authorize target SHA, migration, backup/restore rehearsal and production deployment; never treat a manual workflow definition as authorization to run it.

## ERP backend CI-gated deploy (owner instruction, 18/11/2026)
- Prisma Composer failed to adopt existing erp-sales branch (HostedStateBootstrapError: existing erp-demo resource but empty Composer deploy state). **Preserve project/database.** A dedicated EMPTY Compute project `erp-backend` was created in Singapore; module provisions API service only, no DB.
- Owner specifically requested automated backend release after CI green. `.github/workflows/prisma-compute-after-ci.yml` uses `workflow_run` on successful `ERP quality gates`, checks the exact CURRENT `main` SHA, uses GitHub OIDC and publishes only Compute service to `erp-backend`; no preview; no schema migration.
- Prisma Compute production secret `ERP_POSTGRES_URL` must point to existing `erp-demo` via dedicated DB credential; it is never copied into Flutter or Vercel.
- Existing `erp-demo` production schema remains a **separate migration approval and backup/restore rehearsal gate**; do not run production migrations in CI or Compute deploy.
- Verify GET `/health/live`, `/health` (TCP PostgreSQL), `/health/ready` (schema), GET `/v1/meta/modules` (read-only) separately. Record real URL/provider read-back and exact CI SHA.

## Tách release smoke và business readiness (18/11/2026)
- Release smoke PASS khi Compute thực sự chạy (GET /health/live 200), PostgreSQL TCP SELECT 1 thành công (GET /health 200), contract /v1/meta/modules 200/6 phân hệ và chưa bật mutation (POST /v1/orders 501).
- GET /health/ready 503 kèm NOT_READY khi ERP chưa có schema là một cảnh báo có ghi nhận, **không phải lỗi deploy runtime**. Chỉ HTTP 200/status ready mới xác nhận nghiệp vụ sẵn sàng. Mọi trạng thái khác hoặc lỗi không đúng contract đều làm deploy smoke FAIL.
- Không tự chạy migration vào erp-demo đang có role production, do chưa có backup/restore rehearsal và owner approval riêng.

## Backup không cần Prisma Pro — kiểm chứng bằng CI, KHÔNG thay thế backup thật
- `backend/scripts/ci-backup-restore.sh` chạy `pg_dump -Fc`, restore vào PostgreSQL CI tạm mới, kiểm migration, số bản ghi và triggers. Script chỉ cho `localhost/erp_ci`, từ chối mọi database Prisma/provider thật và xóa archive tạm khi kết thúc. **Đây là thử quy trình, không phải backup `erp-demo`.**
- Khi triển khai manual backup trên `erp-demo`, operator phải dùng dedicated read-only/backup credential trong môi trường quản trị bảo vệ, tải snapshot qua `pg_dump` vào **object storage riêng có mã hóa, retention và quyền truy cập tối thiểu**, kiểm SHA256, rồi restore vào PostgreSQL cô lập (không dùng chung service) để đối chiếu dữ liệu/schema/checksums. Không lưu ở filesystem tạm bền, GitHub artifact, issue hoặc chat. Không làm nếu thiếu đường kết nối an toàn và kho backup bền.
- Lập lịch, RPO/RTO, giám sát backup và thực nghiệm khôi phục riêng trước installation khách hàng thật. `pg_dump` là logical backup, không tương đương point-in-time recovery; Free không có PITR tự động. Snapshot *trước* migration phải tồn tại, thử restore và đối chiếu thật, rồi mới xin owner duyệt riêng migration đúng `erp-sales/erp-demo`.
- Không chạy SQL schema trực tiếp bằng connector; không dùng backup rehearsal CI làm bằng chứng đủ gate production.
