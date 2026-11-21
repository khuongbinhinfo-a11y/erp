# ERP — QA Matrix (PASS chỉ dựa trên log thực)

| Vùng | Kiểm thử bắt buộc | Gate |
| --- | --- | --- |
| Backend | lint, TypeScript strict, unit, integration, contract | PR CI |
| PostgreSQL | fresh migration, replay, drift, constraints, concurrent transactions | POC |
| Documents | post-once, revision, idempotency, reversal, lost ACK | Vertical slice |
| Inventory | no-negative policy, two-device race, reconciliation | Vertical slice |
| AR/AP | NUMERIC precision, payment dedupe, ledger rebuild | Vertical slice |
| RBAC | installation, branch, warehouse, deny-by-default | POC |
| Flutter | analyze, widget + integration, Android, Windows, Web | PR/release |
| UI | 1440/1280/390/360 px, keyboard/focus/reduced motion | PR/UAT |
| Offline | disconnect pre/post COMMIT, retry, stale data, account switch | POC |
| Operations | secrets audit, backup, restore, smoke, release SHA | Release |

## Báo cáo
Phân loại **ĐÃ XÁC MINH / CHƯA XÁC MINH / BỊ BÁC BỎ**. Nêu lệnh chạy, SHA, link log, môi trường, pass/fail/skipped; phân biệt CI, smoke và UAT. Không tự đóng issue khi còn gate chưa đạt.

## Quy trình main-only (owner 18/11/2026)
- GitHub Actions chỉ tự chạy trên `push main`, không cần CI nhánh/PR trước; Codex preview không thay thế kiểm thử.
- Sau mỗi push read-back SHA + từng job/log; CI FAIL thì sửa hoặc revert trên `main`, ghi root cause, chưa triển khai lô mới hoặc deploy.
- Production release vẫn cần CI PASS đúng SHA, backup/restore, reconciliation, smoke/UAT và owner duyệt riêng migration/deploy.

## Backup rehearsal proof (POC)
- CI `postgres-fresh-schema` phải thực thi `bash backend/scripts/ci-backup-restore.sh` trên PostgreSQL ephemeral, test cả restored schema, migration history, row counts và audit triggers. Nếu script chưa PASS không báo backup rehearsal PASS.
- Backup thật `erp-demo`, restore vào DB cô lập, retention và migration production vẫn **CHƯA XÁC MINH**, độc lập với CI rehearsal.
