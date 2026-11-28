# T5-D — Ma trận legacy-first và thực thi chuyến (28/11/2026)

**Nguồn ERP:** `khuongbinhinfo-a11y/erp` baseline `e1bbeb5044d36040f5aabc1a68a586b800e72c7a`. **Nguồn tham chiếu chỉ đọc:** `binhnxwjfjxm/NPP-Platform` main `f0a2cd20893f4a3dc912bfbe0d020ff6b251bd0e`. Không copy dữ liệu khách, secrets, React UI hoặc schema/infra legacy. Mọi phát hành Production, repo chính và APK/R2 đang **hoãn theo owner 28/11**.

| Legacy source / logic | Phân loại | ERP đích / kiểm chứng |
|---|---|---|
| `npp-core/api/src/services/logistics-driver-delivery.js:307–365,475–540`; `npp-core/api/test/logistics-driver-delivery.test.js:160–199` | COPY/ADAPT | `backend/src/delivery_attempt_contract.ts`, `delivery_attempt_contract.test.ts`: kết quả FULL/PARTIAL/FAILED/RESCHEDULED, căn theo exact issued line, số lượng chính xác 6 chữ số thập phân theo PostgreSQL ERP; dư ở trên xe, không fake nhập kho |
| `docs/operations/phase-6e4-delivery-attempt-decisions.md:60–104` | COPY/ADAPT | `backend/src/delivery_execution.ts` + `0030_t5d_trip_execution.sql`: departure và attempt append-only, từng chuyến/đơn/nguồn xuất, quantity guard + deferred source/AR reconciliation |
| `backend/src/trip_fulfillment.ts:189–271`; `backend/db/migrations/0025_t3c_trip_preparation_dispatch.sql` | KEEP | Xuất kho vẫn `inventory_ledger` hiện có, bám đúng `sales_trip_dispatch_line`; khóa đơn cùng transaction, không xuất thêm sau khi xe xuất phát |
| `backend/src/delivery_trip.ts:219–281`, migration 0027/0028 | KEEP | Kế hoạch LOCKED và liên kết tài xế–nhân viên canonical giữ nguyên. Departure là sự kiện riêng, không sửa/xóa plan đã khóa, server kiểm tra tài xế được gán và account thực tế |
| `npp-core/api/src/services/logistics-trip-dispatch.js` + legacy logistics-driver-delivery.js:215–245 | CONSOLIDATE | Không port engine khác: `delivery_execution_http.ts`, `rbac.ts`, `mutation.ts` dùng receipt, scope installation/branch/warehouse, role, actor/revision, POST recovery, idempotency |
| `npp-core/api/src/services/logistics-driver-delivery.js:495–540` | COPY/ADAPT | `delivery_trip_return/_line`: hàng không nhận trên xe được nhập về kho qua `inventory_ledger RETURN` cùng giao dịch; không giảm AR đối với hàng chưa từng giao |
| `docs/operations/phase-6f0-receivable-payment-cod-decisions.md`; ERP `sales_execution_core.ts:215–310` | CONSOLIDATE | Một `customer_receivable_ledger` + `payment_receipt` + `payment_allocation`; AR theo thực giao bằng tỷ lệ cộng dồn; tiền 0 = ghi nợ, tiền mặt ghi custody, ngân hàng không tạo custody tiền mặt, bàn giao từng phần không ghi lại khoản thu |
| Legacy `delivery/web/app/trips/[tripId]/delivery-attempt-panel.tsx:113–161` | ADAPT | `trip_execution_panel.dart`, `driver_trip_workspace.dart`, `delivery_trip_workspace.dart`: thao tác tài xế/điều phối riêng, tiếng Việt mobile-first, chỉ chọn fact thực của backend, không copy component React |
| ERP local outbox `apps/flutter/lib/local/local_store.dart` | KEEP/EXTEND | Lưu original body/key/actor/trip theo scope ở atomic local driver; sau timeout kiểm receipt trước khi gửi lại, không post offline, clear sau ACK đã đối soát |

## Phạm vi API mới

- `GET /v1/delivery/execution/scopes`, `/trips`, `/read`: tài xế chỉ thấy chuyến được phân, điều phối viên thấy đúng kho/quyền.
- `POST /v1/delivery/execution/start|attempt|return|collect|handover`: chứng từ thực tế và revision/receipt bắt buộc.
- `POST /v1/delivery/execution/recovery`: tìm receipt bằng cùng actor/action/key/body sau ACK mất; không tự tạo giao dịch mới.

## Bất biến và đối soát

1. Giao thiếu, không nhận hoặc hẹn lại không tự ghi tồn IN. Tồn chỉ trở lại kho khi xác nhận **thực nhập** bằng chứng từ RETURN đối chiếu dòng đã xuất.
2. AR chỉ theo số lượng đã giao: cùng `sales_order_line` và exact pricing snapshot. Không thu quá số còn phải thu; 0 không tạo payment. Không phát sinh ledger song song.
3. COD tiền mặt là tiền tài xế giữ: chỉ handover thực nhận mới giảm số phải bàn giao, không tạo payment thứ hai. Chặn handover vượt custody.
4. Trigger append-only, kiểm source/amount/quantity khi COMMIT; retry cùng key/body replay receipt, cùng key/body khác xung đột; 2 thiết bị sử dụng khóa order + expected revision.
5. Driver phải là `org_employee.account_user_id` active gắn `delivery_driver` đúng chuyến/kho; role deny-by-default. Chủ quản lý và nhân viên giao không chia sẻ quyền xem toàn bộ đơn.

## Kiểm thử / cổng

- `backend/src/delivery_execution.test.ts`: PostgreSQL thật, xuất thực–partial–return–failed–giao tiếp–AR–thu một phần/0/quá tiền–COD–handover–retry–hai thiết bị–ledger immutability.
- `backend/src/delivery_attempt_contract.test.ts`: nguyên tắc lượng và thời gian, precision, line coverage, bad input.
- `apps/flutter/test/trip_execution_panel_test.dart`: đọc không ghi, hủy popup khi có bàn phím không POST; `local_store_test.dart`: intent durable, isolation và CAS.
- `ci.yml`: migrate fresh/replay, restore rehearsal CI, 8 bảng chứng từ, 18 trigger T5-D.
- **Bằng chứng thực tế:** chỉ ghi PASS theo final SHA và GitHub Actions run thật, không suy từ source. Codex phải sạch trên final PR head; không thay UAT máy thật.

**Giới hạn tách riêng:** Ảnh/chữ ký POD cần object storage riêng và quy trình xác nhận bằng chứng; không coi attempt event là ảnh ký nhận. Trả hàng sau khách đã nhận và đã thanh toán cần chứng từ credit/refund riêng (không dùng stock return trên xe để làm giả hoàn tiền). Không được gọi hai nghiệp vụ này là đã phát hành hoặc đã nghiệm thu. UAT Android thật, smoke Production và tất cả migration/deploy Production tiếp tục hoãn.
