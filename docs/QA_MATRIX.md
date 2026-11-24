# ERP — QA Matrix V4 (24/11/2026)
PASS chỉ dựa trên log thật; [Master Plan V4](MASTER_PLAN.md) là lộ trình hiện hành.

| Vùng | Kiểm thử bắt buộc | Gate |
|---|---|---|
| Legacy reuse | Function-level KEEP/COPY/ADAPT/CONSOLIDATE/DROP/MISSING, characterization test, fixture tổng hợp, không data/secret cũ | Trước từng lô |
| Backend | lint, typecheck, unit, integration, contract | PR CI |
| PostgreSQL | fresh migration, replay, drift, concurrency, constraints | PR CI |
| Policy | WARN/ALLOW tiếp tục đúng scope, BLOCK đúng hard invariant, âm kho/lô/vị trí/FEFO override, audit và reconciliation | T0/T3 |
| Pricing/sales | Một engine search/quote/save/confirm, exact SKU, auto list/override, tax/CK, Decimal, price history, warehouse snapshot, stale/lost ACK | T1 |
| Documents | post-once, revision, idempotency, correction/reversal, lost ACK | Mỗi vertical slice |
| Inventory | partial reserve/backorder, actual negative stock by policy, lot/location, FEFO hint, two-device race, ledger rebuild | T3 |
| Purchasing/AR/AP/COD | partial receipt/delivery, returns, payments/dedupe, custody, allocations, Decimal/reconciliation | T4/T5 |
| RBAC | installation, branch, warehouse, deny-by-default | Mỗi lô |
| Flutter | analyze, widget/integration, Android APK/AAB, Windows/Web build, PWA Safari Home Screen | PR/release; thật từ T2 |
| UI | 1440/1280/390/360 px, keyboard/focus/reduced motion, không tab trùng, warning không modal spam, fast-entry | PR/UAT |
| Offline | pre/post COMMIT, retry, stale price/stock, app restart, eviction, account switch, no fake ACK | T2 và mỗi mutation |
| POS/Ordering/MCP | checkout nhanh, barcode/printer, canonical order, scoped portal và external source idempotency | T6–T8 |
| Reports/performance | drilldown, ledger rebuild, CSV Việt hóa, đo tải đại diện 1000 đơn/ngày | T9 |
| Operations | secrets audit, backup thật, restore cô lập, reconciliation, smoke, release SHA | Release |

## Quy trình
Repo phụ branch/PR → exact final head CI PASS và Codex sạch → owner cho phép merge → read-back → sync scope sang repo chính, so sánh blob/tree, ghi rõ repo chính hết quota và mapping CI, không giả PASS. Docs-only không deploy. Vercel deploy thủ công; backend/migration Codespace exact SHA/target khi owner giao. Auto OFF. Không dùng lịch sử direct-main làm gate hiện hành.
Backup CI: postgres-fresh-schema chạy bash backend/scripts/ci-backup-restore.sh ephemeral và kiểm restore schema/history/count/triggers. Không thay cho encrypted backup thật + read-back + isolated restore/reconciliation + owner approval production.
Báo ĐÃ XÁC MINH / CHƯA XÁC MINH / BỊ BÁC BỎ, link SHA/log/môi trường; phân biệt CI/smoke/UAT; không đóng issue nếu acceptance chưa đạt.
