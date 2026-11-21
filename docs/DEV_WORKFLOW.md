# ERP — Quy trình phát triển main-only

**Owner chốt ngày 18/11/2026:** CI xanh thì merge PR đang chờ, sau đó mặc định commit trực tiếp main; không bắt buộc nhánh hoặc PR trước khi có CI. Lý do owner nêu: có Codex preview và phần mềm chưa có người dùng. Quyết định này thay thế cổng bắt buộc branch agent/* + PR của Lô 0.

## Quy trình làm mỗi lô
1. Read-back HEAD main (exact SHA), Issues và kết quả CI gần nhất, kiểm provider liên quan và quyết định owner mới nhất.
2. Review code/diff, security và các bất biến nghiệp vụ; commit/push trực tiếp main đúng scope. Không đưa token, database URL, PII, khách cũ hoặc secrets vào git/chat/log.
3. GitHub Actions chạy trên push main; read-back từng job, SHA, logs. Không coi Codex preview hoặc việc workflow đã được kích hoạt là CI PASS.
4. Nếu FAIL, ưu tiên sửa hoặc revert trực tiếp main và thêm regression test; không làm lô mới, không release, không báo PASS khi chưa xanh. Nếu PENDING thì ghi PENDING.
5. Nếu PASS, ghi evidence vào Issue. Chỉ đánh dấu các hạng mục thực sự có test; những test integration/RBAC/concurrency/Android/Windows/Web/smoke/UAT chưa chạy vẫn là CHƯA XÁC MINH.
6. Nhánh/PR chỉ dùng theo yêu cầu riêng của owner. PR #15 đã được owner cho phép merge sau CI xanh.

## Cổng release vẫn giữ nguyên
- Code push main không phải lệnh deploy. Vercel chỉ production, không Git auto-deploy, không preview; deploy phải có lệnh target rõ và owner cho phép.
- Migration production cần backup, restore rehearsal, reconciliation và owner phê duyệt riêng.
- Không tự đổi provider, xoá dữ liệu, restore, thay secrets hoặc dùng dữ liệu/tài nguyên khách cũ.
- PostgreSQL riêng cho mỗi installation, server giữ quyền quyết định ledger, RBAC deny-by-default.

## Format bằng chứng
TASK | BASELINE | FINDINGS | FIX | TEST/CI | MERGE (nếu PR) | MIGRATION | DEPLOY | SMOKE | BLOCKERS

Trạng thái CI của chính commit thay đổi tài liệu này chỉ được kết luận sau khi GitHub Actions chạy xong trên main.
