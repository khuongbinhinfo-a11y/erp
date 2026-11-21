# ERP — Architecture Decisions
Ngày chốt: 18/11/2026. Mỗi quyết định thay đổi phải cập nhật tài liệu + commit; PR chỉ khi owner yêu cầu.

| ADR | Quyết định | Hệ quả kiểm thử |
| --- | --- | --- |
| ADR-001 | Installation độc lập, không shared database giữa khách | Isolation test, backup/restore và secret riêng |
| ADR-002 | PostgreSQL cho mọi provider, Prisma Postgres hiện chỉ demo | Không phụ thuộc ORM/provider trong domain |
| ADR-003 | TypeScript modular monolith, API-first | Contract tests và module boundaries |
| ADR-004 | Flutter chung codebase, phân hệ + target/flavor | Analyze, widget, Android/Windows/Web build |
| ADR-005 | Ledger bất biến làm nguồn sự thật | Reversal, reconciliation, race + double-post tests |
| ADR-006 | Offline nháp và intent; commit duy nhất trên server | Retry, lost ACK, stale price/stock, account switch tests |
| ADR-007 | RBAC deny-by-default, scope installation/branch/warehouse | Negative permission tests, audit trails |
| ADR-008 | Production-only, deploy thủ công theo SHA + owner gate | Git auto deploy OFF, no preview release, smoke staged prod |
| ADR-009 | Owner 18/11/2026: commit trực tiếp main, CI tự chạy sau push | Không đòi nhánh/PR; read-back SHA + CI; FAIL sửa/revert; không tự deploy/migration |

## Ranh giới module
Backend: identity/rbac, catalog/pricing, orders, fulfillment/delivery, inventory, receivables/payables, payments, audit. Một transaction DB chỉ ở server; Flutter không kết nối trực tiếp DB. API giữ request-id, actor, revision, Idempotency-Key; không đặt business logic trong Vercel UI.

## Provider
Prisma project demo đã được chỉ định: erp-sales (không tạo project song song). Vercel project phải thuộc team gustavjung24-ops-projects và **không gắn Git tự deploy**. Nếu không có API đúng scope, ghi blocker, không dùng tài nguyên khách khác thay thế.
