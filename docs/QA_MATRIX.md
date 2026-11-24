# ERP — QA Matrix V4 (24/11/2026)
PASS chỉ dựa trên log thật; [Master Plan V4](MASTER_PLAN.md) là lộ trình hiện hành.

| Vùng | Kiểm thử bắt buộc | Gate |
|---|---|---|
| Legacy reuse | Function-level KEEP/COPY/ADAPT/CONSOLIDATE/DROP/MISSING, characterization test, fixture tổng hợp, không data/secret cũ | Trước từng lô |
| Backend | lint, typecheck, unit, integration, contract | PR CI |
| PostgreSQL | fresh migration, replay, drift, concurrency, constraints | PR CI |
| Policy | WARN/ALLOW tiếp tục đúng scope, BLOCK đúng hard invariant, âm kho/lô/vị trí/FEFO override, audit và reconciliation | T0/T3 |
| Pricing/sales | Một engine search/quote/save/confirm, exact SKU, auto list/override, tax/CK, Decimal, price history, warehouse snapshot, stale/lost ACK | T1 |
| Sales modes/default | MANUAL/TRIP/PICKUP + MCP source; checkbox lưu mặc định theo user/installation qua phiên và thiết bị, đổi riêng một đơn, không lẫn scope; mode snapshot | T1/T8 |
| Direct/normal fulfillment | MANUAL/PICKUP direct issue không bắt soạn/chuyến; TRIP một màn Soạn & đóng, partial, đổi lô/vị trí, xuất đúng fact, no duplicate OUT | T3/T5/T6 |
| Quick payment | Xuất kho/Hoàn thành/Thu đủ/nhập tiền trực tiếp, 0 ghi nợ, partial/thu tiếp, tiền mặt/chuyển khoản, bulk per-order, lost ACK, overpayment đúng allocation; nhập trả trước hoàn thành và customer return sau hoàn thành, AR theo lượng thực nhận | T5/T6 |
| Documents | post-once, revision, idempotency, correction/reversal, lost ACK | Mỗi vertical slice |
| Inventory | partial reserve/backorder, actual negative stock by policy, lot/location, FEFO hint, two-device race, ledger rebuild | T3 |
| Purchasing/AR/AP/COD | partial receipt/delivery, returns, payments/dedupe, custody, allocations, Decimal/reconciliation | T4/T5 |
| RBAC | installation, branch, warehouse, deny-by-default | Mỗi lô |
| Flutter | analyze, widget/integration, Android APK/AAB, Windows/Web build, PWA Safari Home Screen | PR/release; thật từ T2 |
| Số liệu/nhập số | 9800.000000 → 9,800; 12.500000 → 12.5; -1250 → -1,250; giữ 0.125, số lớn/âm/zero; nhập 9800 tự format 9,800, sửa/xóa/paste/caret/decimal; canonical Decimal round-trip, không round hoặc đổi số tiền; Excel/CSV import-export đúng kiểu | Mọi lô |
| Ngôn ngữ production | Không DEV/demo/preview/placeholder/raw error/enum hay hướng dẫn thừa; tiếng Việt nghiệp vụ, trạng thái đúng, lỗi có cách xử lý, toast; quét toàn màn liên quan và UAT | Mọi lô |
| UI | 1440/1280/390/360 px, keyboard/focus/reduced motion, không tab trùng, warning không modal spam, fast-entry | PR/UAT |
| Offline | pre/post COMMIT, retry, stale price/stock, app restart, eviction, account switch, no fake ACK | T2 và mỗi mutation |
| POS/Ordering/MCP | checkout nhanh, barcode/printer, canonical order, scoped portal và external source idempotency | T6–T8 |
| Reports/performance | drilldown, ledger rebuild, CSV Việt hóa, đo tải đại diện 1000 đơn/ngày | T9 |
| Operations | secrets audit, backup thật, restore cô lập, reconciliation, smoke, release SHA | Release |

## Quy trình
Repo phụ branch/PR → exact final head CI PASS và Codex sạch → owner cho phép merge → read-back → sync scope sang repo chính, so sánh blob/tree, ghi rõ repo chính hết quota và mapping CI, không giả PASS. Docs-only không deploy. Vercel deploy thủ công; backend/migration Codespace exact SHA/target khi owner giao. Auto OFF. Không dùng lịch sử direct-main làm gate hiện hành.
Backup CI: postgres-fresh-schema chạy bash backend/scripts/ci-backup-restore.sh ephemeral và kiểm restore schema/history/count/triggers. Không thay cho encrypted backup thật + read-back + isolated restore/reconciliation + owner approval production.
Báo ĐÃ XÁC MINH / CHƯA XÁC MINH / BỊ BÁC BỎ, link SHA/log/môi trường; phân biệt CI/smoke/UAT; không đóng issue nếu acceptance chưa đạt.
