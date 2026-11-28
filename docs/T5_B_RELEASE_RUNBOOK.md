# T5-B — Điều phối chuyến giao | Release runbook

## Phạm vi

- **Công Ty → Giao nhận → Chuyến giao:** tạo chuyến, chọn nhiều đơn giao theo chuyến, khai báo tài xế/xe, phân công, sắp xếp thứ tự các điểm, mở lại/khóa kế hoạch.
- Nghiệp vụ được đối chiếu với `NPP-Platform` read-only: Phase 6E.1 trip planning / Phase 6E.2 dispatch decisions. Không sao chép PII, logo, tài khoản hoặc thông tin khách cũ.
- Đơn phải `CONFIRMED`, phiên bản `CONFIRMED`, `deliveryChoice=TRIP`, cùng installation/branch/warehouse và có địa chỉ giao. Một đơn chỉ được gán vào một chuyến; muốn đổi chuyến phải gỡ từ bản nháp.
- Trạng thái chuyến `DRAFT → PLANNED → LOCKED`. `PLANNED → DRAFT` khi mở lại. `LOCKED` không chỉnh kế hoạch; không thể xóa chuyến.
- Lập/khóa chuyến **không** tự xác nhận xuất kho, giao hàng, thu tiền COD hay ghi công nợ. Các xác nhận thực tế thuộc T5-C/T5-D, không được suy diễn từ `LOCKED`.

## API và toàn vẹn dữ liệu

- `GET/POST /v1/delivery/{trips,drivers,vehicles}`; `GET /v1/delivery/trips/eligible`; `GET /v1/delivery/trips/:tripId`.
- `POST /v1/delivery/trips/:tripId/{assign,unassign,reorder,plan,reopen,lock}`.
- Backend RBAC deny-by-default theo installation/branch/warehouse; yêu cầu các quyền điều phối, đọc đơn và kho. `If-Match`, `Idempotency-Key`, request ID, audit, transaction/locking; mọi cập nhật từ phản hồi server.
- Migration `0027_t5b_delivery_trip_planning.sql` tạo bảng tài xế, xe, bộ đánh số chuyến, chuyến, điểm giao, sự kiện bất biến; FK, khóa và guard ngăn sửa chuyến đã khóa.
- Biến động kho vẫn chỉ từ inventory ledger; công nợ chỉ từ AR/AP ledger. Không thay đổi engine giá/chứng từ cũ.

## Cổng phát hành bắt buộc

1. PR repo phụ chạy **7/7 CI PASS ở SHA cuối**: typecheck, backend/integration Postgres sạch, Flutter analyze/widget, Android/Windows build, Prisma Compute, isolation/security. Codex review **sạch, toàn bộ thread giải quyết**, khớp cùng SHA.
2. Sau review và chấp thuận của owner: merge nhánh phụ → `main` repo phụ → đồng bộ cùng Git tree lên `main` repo chính. Không chỉnh repo cũ.
3. **Migration 0027 yêu cầu phê duyệt riêng của owner** cho đúng SHA, project/database và maintenance window. Khảo sát production `schema_migrations`: phải đúng baseline `0001..0026`; không đoán database đã migrate.
4. Trong **Codespaces repo chính/main**, chạy `npm run db:migrate:t5b:codespaces -- --check`. Lệnh kiểm tra phải đọc lại chính xác branch, SHA, Codespace, primary remote, provider target, checksum/version và không ghi dữ liệu nghiệp vụ.
5. Chỉ sau phê duyệt migration riêng: bật bảo trì ghi trên backend, snapshot backup mã hóa lên object storage bền, đọc lại hash, giải mã/restore trên PostgreSQL cách ly, tập rehearsal migration, đối soát dữ liệu & quyền. Dùng **cùng operator được duyệt** `--apply`; không gọi `migrate.ts` trực tiếp lên production.
6. Sau migration: đọc lại `schema_migrations`, checksums, 6 bảng/4 triggers, dữ liệu cũ không đổi; chạy backend deploy trong Codespaces ở đúng SHA; xác minh `releaseSha`, health/ready.
7. Cuối cùng Vercel **deploy trực tiếp Production**, không tạo Preview. Đối chiếu phiên bản Git tree, smoke login/role/warehouse/trip. APK Android & R2 `latest.json` cần gate ký, upload, readback, OTA và UAT thiết bị riêng.

## Bài test nghiệm thu

- Tạo 2 tài xế, 2 xe; tạo chuyến theo kho và ngày, số chuyến không lặp.
- Chọn 2+ đơn TRIP, thêm vào chuyến. Một đơn đang sửa/chưa xác nhận, khác kho hoặc đã gán chuyến khác bị từ chối.
- Đổi thứ tự các điểm → tải lại vẫn đúng; đổi tài xế/xe khi nháp; lưu kế hoạch, mở lại và khóa.
- Khóa xong không thêm/bớt đơn, sửa thứ tự, tài xế/xe; 2 người thao tác đồng thời phải báo revision conflict, không có double posting.
- Kiểm inventory ledger, fulfillment, receipts, AR/COD trước/sau lập/khóa: **không tăng**. Mất ACK phải đối soát theo idempotency; khác body cùng key bị bác bỏ.
- Role thiếu quyền/chọn khác installation/branch/warehouse phải trả `403/404`. Thử trên web rộng/hẹp và thiết bị Android thực, không ghi UAT PASS từ test CI.

## Trạng thái cập nhật

Triển khai migration/backend/Vercel **CHƯA ĐƯỢC PHÉP / CHƯA XÁC MINH** cho tới khi tất cả cổng trên đạt và có phê duyệt owner. Mọi kết quả phải gắn exact SHA/run URL.
