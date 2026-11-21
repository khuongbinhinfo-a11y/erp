# ERP — Domain Invariants

## Chứng từ
1. Canonical ID phía server, trạng thái DRAFT → CONFIRMED → POSTED hoặc CANCELLED theo điều kiện hợp lệ. Order, fulfillment, delivery, payment là aggregate khác nhau.
2. POSTED không được UPDATE/DELETE; sai sót dùng reversal/correction có liên kết chứng từ gốc và actor.
3. Mỗi mutation nhạy cảm yêu cầu installation scope, actor, request ID, revision và Idempotency-Key. Cùng key+cùng fingerprint trả cùng kết quả; cùng key+khác fingerprint báo conflict. Sau timeout COMMIT phải read-before-retry.

## Tồn kho và công nợ
4. Inventory ledger append-only là nguồn tính tồn; số dư snapshot chỉ là cache kiểm chứng được. Cấm âm kho trừ khi policy rõ theo warehouse.
5. AR/AP ledger append-only là nguồn công nợ; thu tiền, ứng trước, đối trừ, trả hàng có entries tương ứng. Không suy ra công nợ từ đơn hàng chưa post.
6. Số tiền/đơn giá dùng PostgreSQL NUMERIC + Decimal phía backend; không dùng float JS để quyết định tiền.
7. Transaction/locking/unique constraints chịu trách nhiệm chống race, double-post, double-receipt. Test hai thiết bị và double-tap.

## Quyền và offline
8. Deny-by-default; không có claim/permission tương ứng thì 403. Filter mọi dữ liệu theo installation, branch, warehouse.
9. Offline chỉ lưu nháp, cache, intent: không ghi nhận đã xuất/thu/post khi chưa có server ACK. Account switch phải cô lập/clear cache.
10. Log không ghi token, URL DB, bí mật, PII; audit có actor/time/trace nhưng redacted.

## Migration
11. Versioned, kiểm fresh DB, replay, drift và rollback/restore; production migration chỉ với approval + backup rehearsal + reconciliation.
12. Chưa có test thực tế thì trạng thái của bất biến là **CHƯA XÁC MINH**, không coi tài liệu là hiện thực.
