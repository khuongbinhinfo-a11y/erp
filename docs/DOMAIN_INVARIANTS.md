# ERP — Domain Invariants V4 (24/11/2026)
Chi tiết chính sách vận hành: [Master Plan V4](MASTER_PLAN.md) mục 3. Đây là contract mục tiêu; chưa có test thật không tuyên bố đã thực hiện.

## Hard invariants
1. Canonical server ID, lifecycle hợp lệ; order, fulfillment, delivery, payment là aggregate riêng có lineage. POS nhận ngay dùng luồng ngắn, không duplicate core.
2. Posted ledger/facts không UPDATE/DELETE. Cho người dùng thao tác Sửa/Điều chỉnh; backend tạo correction/reversal có chứng từ gốc, actor, số lượng/tiền đúng và audit.
3. Mutation nhạy cảm: scope, actor, request ID, revision, Idempotency-Key; cùng key/body replay receipt, khác body conflict; lost ACK read-before-retry, reconcile trước khi sửa payload.
4. Inventory ledger append-only quyết định tồn; AR/AP ledger quyết định nợ, payment allocation quyết định thu/chi/đối trừ. Không suy nợ từ order chưa giao; ứng trước có fact riêng. Snapshot kiểm chứng/rebuild được.
5. PostgreSQL NUMERIC + Decimal, không float JS quyết định tiền. Transaction/locks/constraints chống race, double-post/receipt/payment; không tự sinh tồn giả hoặc tiêu thụ allocation khác âm thầm.
6. RBAC deny-by-default installation/branch/warehouse/actor, scope mọi query/mutation; hard block sai quyền, sai tham chiếu, trạng thái hoặc dữ liệu tối thiểu gây hỏng nghiệp vụ.
7. Offline cache/cart/intent, không báo xuất/thu/post khi chưa server ACK; account switch cô lập intent/cache. Không dựa vào storage không thể eviction.
8. Audit actor/time/trace, redaction, không token/secret/PII trong log, code hoặc client.
9. Migration versioned, fresh/replay/drift, backup/restore rehearsal/reconciliation và owner approval riêng trước production.

## Quy tắc vận hành có thể cấu hình (không phải hard invariants)
- Default WARN/ALLOW: thiếu tồn không cản tạo/xác nhận order; reserve phần có, phần thiếu backorder. Kho âm thực tế được phép theo warehouse policy, audit số âm, phân biệt on_hand/available/reserved; ledger vẫn ghi chính xác. Không dùng stock âm để fake allocation.
- Thiếu/khác lô, HSD, vị trí, FIFO/FEFO: warning hoặc cho phép, trừ yêu cầu truy xuất bắt buộc; điều chỉnh lô/vị trí qua reclassification/transfer/correction, bảo toàn lịch sử.
- Giá dưới vốn, vượt hạn mức, trùng tên/điện thoại: warning theo policy; sửa giá/CK theo quyền và lưu snapshot; không bắt người dùng hiểu quy tắc dev, không chặn để bắt nhập lý do hình thức.
- Một policy resolver server-side, ALLOW/WARN/BLOCK có scope, audit override, UI tiếng Việt dễ tiếp tục. Không nới hard invariants bằng policy. Audit mọi guard API/UI/SQL; sửa bằng migration mới, không sửa migration cũ đã apply.
- Quy tắc trên là quyết định mới, chưa mặc định rằng trigger 0011 hoặc API hiện tại đã thay đổi.
