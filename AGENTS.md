# ERP — Quy tắc bắt buộc cho mọi agent/chat
Đọc [MASTER_PLAN](docs/MASTER_PLAN.md) trước khi sửa. Owner decision 24/11/2026.

## Nghiệp vụ
- Không viết lại backend/app từ đầu. Copy/adapt code nghiệp vụ **và tests** từ legacy read-only; giữ foundation ERP đã đúng. Kiểm dependency, lỗi nguồn, xung đột API/schema/Decimal/RBAC/transaction/ledger/audit/idempotency và ảnh hưởng liên module trước khi copy. Characterization + regression tests; không mang lỗi cũ sang, không tự cắt nghiệp vụ.
- Ghi ma trận source SHA/path:line → target → KEEP/COPY-ADAPT/CONSOLIDATE/DROP/MISSING, lý do và test. Không duplicate engine giá/ledger; không copy raw migration, data/PII/secrets/assets khách cũ. Hai repo cũ chỉ đọc.
- Flutter: UX mới phải tốt hơn; nếu không giữ bố cục/thao tác app cũ. Số format khi gõ, tiếng Việt, bảng compact, toast. V4.1 ưu tiên T0 rồi T1; #44/#43 repo phụ. Không nhảy lô.
- **T2 APK bắt buộc (issue #46):** ngay APK Android đầu tiên phải có **Cập nhật ứng dụng** theo luồng tham khảo read-only `milktea-cus/MCP-FBMN`: agent tự build **signed release** và publish bản mới lên **R2 riêng ERP** sau gate/owner duyệt, app kiểm bản mới → tải ticket xác thực → SHA/signature/package/version verify → Android OS hỏi xác nhận cài đè. Giữ SQLite/outbox/session, không gỡ app, không silent install; test 2 bản signed trên thiết bị thật. Không dùng bucket/secret/package/branding MCP-FBMN; xem `docs/MASTER_PLAN.md §6.1` trước mọi việc T2 và không giao owner build/upload APK.

## Phát hành — không hỏi owner nhắc lại
1. Dev trên `khuongbinhinfo-a11y/erp`, branch agent/* từ exact main. CI required PASS + Codex sạch trên final PR SHA, owner cho phép merge.
2. **Merge repo phụ trước**, sau đó mới đồng bộ main `gustavjung24-ops/ERP` qua diff đúng scope. Repo chính hết quota: CI đỏ do quota/không chạy không phải blocker; không đợi, không rerun, không yêu cầu nâng quota. Chứng minh exact file/tree/SHA khớp bản repo phụ đã qua gate; lỗi thực/sai khác vẫn phải sửa.
3. Khi release được giao: migration/backend nếu thay đổi thì cung cấp một khối lệnh Codespaces đã kiểm exact SHA/target/script; migration cần backup, restore rehearsal, reconciliation và approval riêng. Không bắt owner chạy phần không đổi.
4. Vercel do agent deploy **thủ công trực tiếp Production**, không Preview, auto deploy OFF; đúng SHA, xác minh READY và smoke. Frontend phụ thuộc backend/DB chỉ phát hành sau khi sẵn sàng. Docs-only không deploy.
5. Báo cáo ngắn: task, SHA, PR, CI/Codex, merge/sync, migration/backend, Vercel, smoke/UAT, blocker thật. Không bịa PASS, không gọi CI xanh là UAT. Handoff ghi vào issue và đọc lại ở chat sau. Không tự merge khi gate chưa đạt, không tự migrate/deploy ngoài lệnh owner.

Quy tắc trên thay thế hướng dẫn lịch sử direct-main và preview. Không thay thế bất biến an toàn dữ liệu trong Master Plan.

- T2 release operator: xem [quy trình Android/PWA/offline](docs/T2_RELEASE_RUNBOOK.md). Workflow ký APK và workflow publish R2 tách riêng, môi trường được bảo vệ; không ghi nhận UAT/CI/owner approval giả. Không đặt latest trước khi tải lại và xác minh chính xác APK. Không đóng #46 khi chưa có bằng chứng máy thật.

- **APK Definition of Done (27/11/2026):** đọc [T2 runbook](docs/T2_RELEASE_RUNBOOK.md#quy-tắc-hoàn-tất-apk-và-bàn-giao-bắt-buộc-27112026) và issue #46 ngay đầu mỗi chat. APK signed/upload R2 chỉ là STAGED; phát hành phải cập nhật `releases/latest.json` sau gate, đọc lại manifest, xác minh updater/OTA và báo chính xác version đang phát hành. Không hỏi lại quy trình hay approval đã có; không báo hoàn tất nếu latest còn cũ. UAT máy thật không được suy diễn từ CI/smoke.
