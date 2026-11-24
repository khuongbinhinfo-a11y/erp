# ERP — Architecture Decisions V4 (24/11/2026)
Nguồn điều hành: [Master Plan V4](MASTER_PLAN.md). Đây là quyết định mục tiêu, không phải chứng cứ đã triển khai.

| ADR | Quyết định | Gate |
|---|---|---|
| ADR-001 | Installation độc lập, không shared DB giữa khách | Isolation, backup/restore |
| ADR-002 | PostgreSQL cố định; Prisma Compute/Postgres demo/POC, ORM tùy chọn | Portability, migrations |
| ADR-003 | TypeScript modular monolith, API-first; KEEP ERP foundation, COPY/ADAPT legacy code có ích, consolidate duplicate, không port frontend cũ | Characterization/contract tests, source mapping |
| ADR-004 | Chung Flutter/Dart; Android native, Windows native, iPhone PWA; iOS native không phải gate hiện tại | Build artifact, Safari PWA, máy thật |
| ADR-005 | Inventory/AR/AP ledger append-only, sửa qua correction/reversal | Reconciliation, locking, double-post |
| ADR-006 | Online-first, SQLite/Drift native, IndexedDB web/PWA, app shell Service Worker; local cache/cart/intent, server ACK duy nhất | Offline retry, eviction, scope, stale data |
| ADR-007 | RBAC deny-by-default installation/branch/warehouse/actor | Negative permission tests |
| ADR-008 | Production deploy manual đúng SHA/target; auto OFF | Release manifest, owner approval |
| ADR-009 | Thay thế direct-main 18/11: branch/PR repo phụ, exact-head CI PASS + Codex sạch, merge được duyệt, sync repo chính; Vercel thủ công, backend/migration lệnh Codespace | Diff, CI, read-back, migration gate |
| ADR-010 | Warning-first, ALLOW/WARN/BLOCK policy theo installation/branch/warehouse, âm kho/lô/vị trí linh hoạt; hard gate chỉ cho sai nghiệp vụ/quyền/bất biến | Policy integration tests ở UI/API/DB, audit và reconciliation |
| ADR-011 | Không port MCP và retail cũ; MCP nối Sales Miền Tây qua API, POS mới, Ordering Flutter dùng canonical order | Contract/role/scope, no shared DB |
| ADR-012 | Một engine giá/ledger, canonical order/fulfillment/delivery/payment, POS express flow và một UX theo tác vụ | Source lineage, cross-module UAT |

Backend quản lý identity/rbac, catalog/pricing, order, fulfillment, delivery, inventory, receivables/payables, payments, audit. Client không kết nối DB. Mutation nhạy cảm có request ID, actor, revision và Idempotency-Key; Decimal, transaction, locks và constraints. Object storage riêng signed URL. Không copy tài sản/dữ liệu/secrets/PII cũ. Hai repo cũ chỉ đọc.
Provider: erp-sales demo đã chỉ định; current DB, Compute, Vercel project/team và SHA phải read-back khi release, không suy từ lịch sử.
