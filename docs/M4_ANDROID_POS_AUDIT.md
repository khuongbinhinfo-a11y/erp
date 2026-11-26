# M4 / T6 — Bán Lẻ POS siêu thị, Android và gate phát hành (26/11/2026)

Baseline read-back lúc khởi sự: repo phụ main `666fd4796be9d541bc8db146917514db9d335326`; repo chính main `05c495f5a687e3f5eee554f943901cdf9a387190`. Trạng thái hiện hành phải kiểm lại, không suy HEAD từ tài liệu. PR code: [repo phụ #73](https://github.com/khuongbinhinfo-a11y/erp/pull/73).

## Ranh giới bất biến

**Bán Lẻ = POS tại quầy**, không phải đơn phân phối đổi tên. App mở `RetailPosWorkspace` riêng; doanh số POS chỉ được ghi khi **API /v1/pos/checkouts** server ACK sau transaction thống nhất: canonical sales create/confirm, direct PICKUP issue inventory ledger, sales fulfillment, AR SALE/PAYMENT, payment receipts/allocations và cash change. Không tự ghi tiền hay trừ tồn bằng Flutter, không lập engine giá thứ hai. Đơn retail `source_type='RETAIL'` không lẫn trong danh sách đơn phân phối. `MANUAL/TRIP` phân phối giữ hợp đồng riêng.

## Đã code trên PR #73 — chưa đồng nghĩa production đã có

- **Quầy**: tìm/quét SKU bằng đầu đọc bàn phím, giỏ, số lượng, tra giá server, chọn khách và bảng giá, điều hướng mobile, tối ưu khoảng trống bàn phím; `local_store.dart` giữ giỏ POS theo installation/actor/branch/warehouse.
- **Thanh toán**: ca bán mở/đóng, đối soát tiền mặt; tiền mặt/chuyển khoản/hỗn hợp và tiền thừa; thao tác gửi server duy nhất, giữ Idempotency-Key/body CAS local và `POST /v1/pos/recovery` read-before-retry khi mất ACK. Với giá thay đổi/hết kho bị từ chối: `POST /v1/pos/checkouts/cancel` dùng **đúng key/action/fingerprint** của checkout gốc; unique `mutation_receipt` tuần tự hóa cancel và checkout. Nếu checkout đã commit trả PAID receipt; nếu chưa thì ghi CANCELED receipt bất biến, Flutter chỉ xóa pending sau ACK và cho sửa giỏ. Test PostgreSQL chứng minh không ghi trùng sau hủy/retry.
- **Hóa đơn bán tại quầy**: `GET /v1/pos/checkouts/:id` đọc dữ liệu đã ACK; tạo phiếu HTML escape dữ liệu khách, Android native `PrintManager` mở cửa sổ in (không báo đã in nếu chưa xác nhận ở thiết bị). `GET /v1/pos/checkouts` lịch sử giao dịch riêng.
- **Hoàn hàng**: `POST /v1/pos/returns` toàn bộ giao dịch bằng REVERSAL của inventory ledger, RETURN/REFUND của AR ledger, bất biến posted; không sửa/xóa lịch sử. Hiện **chưa hỗ trợ hoàn một phần**.
- **Backend**: `backend/src/pos_http.ts`, tái sử dụng `sales_http.ts` canonical create/confirm, `rbac.ts` deny-by-default pos.shift/checkout/return, warehouse locks, Numeric/PostgreSQL, append-only facts.
- **Migration additive**: `backend/db/migrations/0023_t6_pos_checkout.sql`: retail shift, fulfillment, checkout, customer AR ledger, payment receipts, allocations, returns; constraints/unique/immutability. CI fresh/replay, dump/restore count/reconciliation cập nhật 23 versions.
- **Test**: `backend/src/pos_http.test.ts` trên PostgreSQL CI thật: cash/bank/change, quote, ACK, replay, conflicting body, stock posting, AR zero, full return và bút toán đảo, đóng ca, immutable ledger, **hai checkout đua cùng tồn kho chỉ một thành công**. Flutter widget POS, receipt escaping và CAS local có test riêng.

## P0/P1/P2 và bằng chứng còn thiếu

| Mức | Điểm cần đối soát | Trạng thái |
|---|---|---|
| P0 | CI 7/7 trên SHA cuối, Codex Preview sạch, independent review security/invariants | **Chưa mặc định PASS**; đọc Actions/PR trước merge |
| P0 | Production DB ERP-DB migration 0023: backup mã hóa, read-back durable, thử restore cô lập, đối chiếu ledger, duyệt riêng | **CHƯA CHẠY**; không dùng CI backup thay backup production |
| P0 | Backend/POS frontend cùng release SHA, API ACK và smoke với dữ liệu tổng hợp thật | **CHƯA TRIỂN KHAI**; ẩn nút thanh toán nếu API/shift chưa sẵn sàng |
| P1 | Hoàn hàng từng dòng/từng phần; bán trả nợ/công nợ theo quyền; nhiều máy in/driver, cash drawer | **Chưa hoàn tất** |
| P1 | Kết quả tìm SKU hiển thị tồn **chính xác từng kho**; lookup theo SKU có pagination đủ 1000+; chọn khách hàng ngoài trang đầu | **Chưa có bằng chứng UAT đủ** |
| P1 | Gián đoạn mạng lúc chuẩn bị/sau COMMIT, retry, app force-stop, mất SQLite/IndexedDB, account switch, hai tab, hàng chục nghìn giỏ | **Cần test thiết bị thực** |
| P1 | OTA Android 0.2.0 → bản sau: ký đúng key, versionCode tăng, tải tiếp HTTP Range, cài đè giữ session/SQLite | **Chưa UAT máy thật** |
| P2 | Dark Mode tương phản, 320/360/390/430 px, xoay màn hình, font scale, bàn phím, Android/Windows/Web/PWA | **Widget CI có nhưng chưa có nghiệm thu thiết bị** |

## Hạ tầng mục tiêu — read-back 26/11

Prisma project `erp-backend` ID `proj_ud3b1s5yn03vh0zp9cbs2upa`; PostgreSQL `ERP-DB` ID `db_jg2bl98hzi1jm06lwo0i4rqx`, READY, Singapore; Compute `cps_gh30k50bvsc0o9298w9leivf`, latest deployment `cpv_lsaxllv57artocjxcob3iw2k`. Prisma automated backups list trống tại thời điểm kiểm — **không chứng minh** durable manual backup đã mất hay đã có; phải kiểm bên Object Storage trước migration. Các IDs chỉ để đối chiếu, không thay owner approval.

## Gate phát hành

CI exact HEAD PASS + Codex sạch + owner merge approval → merge repo phụ → sync đúng scope sang repo chính → **migration 0023** production chỉ sau backup/isolated restore/reconciliation và owner approval riêng → backend Codespaces đúng target → Vercel **thủ công** đúng SHA khi API đã live → smoke POS → APK Android ký chứng chỉ cũ/versionCode tăng/R2 SHA read-back/stage + activate theo release runbook → test máy thật và owner UAT. Không sửa production từ PR/CI, không deploy frontend POS trước backend/schema. Tài liệu cũ `t1-0022-codespaces-migration.mjs` chỉ áp dụng đến version 0022, **cấm dùng để chạy 0023**.

Đã có operator mới `backend/scripts/t6-0023-codespaces-migration.mjs` (`npm run db:migrate:t6:codespaces -- --check` trước; `--apply` chỉ sau approval): dùng Codespaces repo chính main đúng SHA, GH attestation, Prisma ERP-DB target, maintenance mode, đọc checksum và đối soát dữ liệu; dump `pg_dump` được mã hóa bằng age lên Prisma Object Store riêng, download/hash/decrypt lại và restore vào PostgreSQL 17 Docker cô lập để thử migration 0023, rồi mới apply production. Các key/URL/secrets phải được cấp trong Codespaces protected environment, không đưa vào chat hay commit. Chưa chạy `--check` trên Codespaces production và chưa có bằng chứng `--apply`; CI chỉ test operator fail-closed và thử trên Postgres tạm.
