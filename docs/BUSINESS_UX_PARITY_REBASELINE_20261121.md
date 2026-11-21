# ERP — Chuẩn hóa nghiệp vụ đầy đủ và UX thống nhất (21/11/2026)

> Quyết định mới của owner, ưu tiên hơn việc tiếp tục riêng lẻ B2 sau B1: **hoàn thiện các tiền đề của một giao dịch thật và chuyển đầy đủ tập chức năng vận hành đã được chấp nhận của hệ thống cũ, đồng thời thiết kế lại trải nghiệm end-to-end.** Không coi việc hiển thị 6 phân hệ hay CI xanh là hoàn thành nghiệp vụ.

## 1. Baseline và phạm vi đã đối chiếu

- ERP target: main e87e6d174a38b3c826a76f1262f58da5f21ac79f (21/11/2026).
- Nguồn nghiệp vụ read-only: binhnxwjfjxm/NPP-Platform main 98941bc6776a02ad8a2bded12961fdaea173cf93; riêng nguồn Đặt Hàng được liệt kê trong docs/LEGACY_BUSINESS_PORT_PLAN.md của ERP, cần rà thêm lúc triển khai lô này.
- Nguồn UI reference riêng (không phải domain ERP): alibaba240185/fbmn main f1cade1cb3719493c09de024daed964cf130a3bc; chỉ tham chiếu quy tắc thành phần/nhịp độ/khả năng đọc, không sao chép logo, domain, dữ liệu hay màu thương hiệu cũ.
- Đọc thực tế: NPP docs/user-guide/NPP_OPERATIONS_USER_GUIDE.md (31 phần); docs/operations/phase-6b1-sales-order-operational-ux.md; docs/operations/product-catalog-pricing-decisions.md; docs/operations/frontend-domain-map.md; ERP apps/flutter/lib/ui/{company_workspace,catalog_workspace,sales_workspace,erp_shell}.dart; backend/db/migrations/0006–0008; docs/LEGACY_BUSINESS_PORT_PLAN.md.
- ERP hiện có **identity, catalog tối thiểu, sales order versioned** (migration 0008, số chứng từ và hợp đồng API), nhưng chưa có inventory/AR/AP ledger hoặc purchase/delivery/MCP/retail/ordering đầy đủ. Trên Flutter, chỉ Công Ty và Quản trị có workspace thật; bốn phân hệ còn lại đang là các trang giới thiệu.
- B1 đã phát hành lên ERP-DB / Prisma Compute / Vercel, **không đồng nghĩa đầy đủ luồng kinh doanh**. Catalog production tại thời điểm kiểm tra sau B1 không có khách, SKU, bảng giá hay giá bán. Không chèn dữ liệu giả để đánh lừa điều kiện nghiệm thu.

**Phạm vi “đầy đủ”** = 100% các use case được owner đưa vào danh sách đối chiếu đã có API, UI, quyền, dữ liệu đúng, kiểm thử, báo cáo và nghiệm thu. Không tự nhận 100% theo số màn hình hoặc tổng số dòng code legacy. Các chính sách riêng của khách cũ (giá, tín dụng, định mức, data, asset, domain) không được sao chép; chỉ lấy contract có thể áp dụng cho ERP độc lập theo installation.

## 2. Nguyên tắc UX: nghiệp vụ trước hình thức, luồng thống nhất

- **Điều hướng cấp 0:** sidebar 6 phân hệ; không đưa tất cả tác vụ lên cùng một thanh. **Cấp 1:** nhóm chức năng trên thanh tiêu đề xanh, căn phải. **Cấp 2:** tab hoặc bộ lọc trong màn làm việc, căn trái; không lặp tab ở body. Giữ cấu trúc chung theo docs/UI_NAVIGATION_RULES.md.
- **Mỗi tác vụ có một không gian làm việc**: danh sách → tìm/lọc → chi tiết → sửa/tiếp tục → xác nhận → chứng từ/lịch sử. Màn nhiều dòng có vùng làm việc rộng, bảng gọn, header và action bar cố định; không nhồi trong AlertDialog 570px hay bắt cuộn ngang toàn form.
- **Danh mục là tiền đề để bán:** hướng dẫn theo ngữ cảnh Khách hàng → Nhóm/SKU/đơn vị/quy đổi → Bảng giá/quy tắc giá → Tra giá → Lập đơn. Khi thiếu dữ liệu, UI hiển thị **thiếu gì, ở chi nhánh nào, nút đến đúng màn**, và giữ ngữ cảnh quay lại. Không chỉ hiện toast mơ hồ.
- **Tìm hàng thống nhất** theo mã/tên/SKU/barcode, hỗ trợ phím mũi tên/Enter và ưu tiên kết quả server-side; hiển thị đơn vị bán và giá hiệu lực. Tra giá có customer + channel/group + quantity + date + rule trace; phía Flutter không tự quyết định tiền.
- **Lập đơn:** customer search (cũ/vãng lai theo policy), thêm hàng nhanh, số lượng/đơn vị, giá/chiết khấu/thuế/thành tiền giải thích rõ, tiền tạm tính do server xác nhận, chú thích ít dùng thu gọn, footer hành động nhất quán. Đơn bị đổi giá/tồn thì cho rà soát, không tự chấp nhận.
- **Một cách ứng xử xuyên 6 phân hệ:** field validation cạnh trường, lỗi server có cách khắc phục, loading/skeleton phù hợp, empty state có hành động, toast góc trên phải tự tắt, confirm các thao tác không đảo trực tiếp; trạng thái business được Việt hóa; không lộ ID kỹ thuật, tên migration, label DEV, wording như “nháp” trong giao diện theo owner.
- **Phân quyền & thiết bị:** không cho mở tác vụ khi thiếu quyền, lý do rõ; Công Ty desktop-first; MCP/Giao Hàng/Bán Lẻ mobile-first; 1440/1280/390/360, keyboard, focus, screen reader, reduced motion. Khi offline chỉ báo đã lưu trên máy/đang gửi; không tuyên bố đã xuất/thu khi chưa nhận ACK server.
- **Tuyệt đối không thiết kế mẫu rồi gọi là hoàn thành:** màn chỉ được báo “sẵn sàng” khi API, dữ liệu, mutation, đối soát và UAT đều có bằng chứng.

## 3. Bản đồ chênh lệch nguồn cũ → ERP mới

Ký hiệu: **NỀN** = đã có một phần nhưng thiếu luồng/field cũ; **THIẾU** = chưa có triển khai domain thực; **CHƯA KIỂM** = chưa kiểm tra runtime thực tế theo contract. Một mục chỉ DONE khi acceptance đi kèm hoàn tất.

| Ưu tiên / Luồng | Nguồn nghiệp vụ read-only | ERP hiện tại | Đầu ra cần có |
|---|---|---|---|
| P0 Khách hàng | NPP customer master, groups, addresses, duplicate identify, import/bulk | NỀN: mã, tên, nhóm dạng text, active | Mã/nhóm, liên hệ/địa chỉ, điều kiện bán, mở mã, trùng khách, quyền, nhập/export, lựa chọn trong đơn |
| P0 Sản phẩm/SKU | product catalog, sell units, barcode, conversion, variants, status, category/media | NỀN: product, group, base_unit, catalog_unit; chưa biến thể/barcode chuẩn | Product + sellable variants/SKU riêng, barcode, đơn vị bán & quy đổi có snapshot, tìm kiếm nhanh, nhóm, trạng thái, hình qua storage |
| P0 Bảng giá | price lists/channel resolution, customer & group policy, retail/carton, priority/stack/tier, effective date | NỀN: price list theo branch + price entry theo product; không đủ scope | Giá theo đơn vị bán/khách/nhóm/kênh/thời điểm/số lượng, chiết khấu/override theo quyền, trace giá, version và kiểm stale giá |
| P0 Bán hàng | NPP sales-order, commercial controls, operational UX | NỀN: 0008, create/update/confirm/amend/cancel, UI AlertDialog ~570px | Workspace lập đơn đầy đủ, search SKU/barcode, customer mode, price preview, nhiều dòng, lưu/confirm, version/timeline, nguồn đơn và số chứng từ |
| P0 Kho nền | inventory ledger, opening, lots, reservation, balance/read model, warehouse location | THIẾU ledger; UI kho mới có danh mục | Nguồn tồn duy nhất, tồn khả dụng, vị trí/lô/HSD, đầu kỳ, giữ hàng; negative-stock policy, rebuild |
| P1 Fulfillment | reservation/shortage, allocation, pick/pack, inventory issue & reversal | THIẾU | Nhiều lần cấp phát/giao từ 1 đơn, thiếu hàng/backorder, pick/pack, phát hành xuất kho đúng ledger |
| P1 Mua hàng | PO, supplier purchase pricing, goods receipts/partial, returns | THIẾU | Đơn mua → duyệt → nhận từng đợt → hàng nhập → trả NCC, sai lệch, lịch sử và in |
| P1 Kho nâng cao | transfer/in-transit/receipts, stocktake, adjustments, quarantine, costing | THIẾU | Điều chuyển, kiểm kê, điều chỉnh có duyệt, tồn âm theo policy, giá vốn/kỳ, audit |
| P1 Giao vận | delivery order, trip, driver assignment, attempt, POD, COD custody | THIẾU | Điều phối, soạn giao, giao đủ/một phần/thất bại/hẹn lại, chứng minh giao, tiền COD/bàn giao |
| P1 Công nợ/thu chi | customer receivables, customer payment & allocation, supplier payable/payment, returns/credits/refunds | THIẾU ledger; UI chỉ register | AR/AP append-only, chỉ phát sinh đúng sự kiện, thu một phần, phân bổ/cấn trừ, COD, trả/hoàn tiền, aging |
| P1 MCP | route/outlet, visit/check-in, surveys/field order & customer onboarding | THIẾU (feature giới thiệu) | Tuyến, phiên, điểm bán, GPS/quyền, chăm sóc/khảo sát, yêu cầu mở mã, chuyển đơn chính thức, offline intent |
| P1 Bán Lẻ | POS, product picker, cart, pickup, print/Windows bridge, offline queue | THIẾU (feature giới thiệu) | Bán nhanh, đơn giá/tồn, nhận tại quầy, thu tiền, in chứng từ, xử lý double-tap/offline đúng ACK |
| P1 Đặt Hàng | docs/LEGACY_BUSINESS_PORT_PLAN.md mapping customer-ordering; cần đọc chi tiết mã nguồn riêng | THIẾU (feature giới thiệu) | Đăng nhập khách, catalog/giá đúng khách, giỏ/checkout, status/history/cancel/reorder, bảo vệ tenant |
| P1 Quản trị | legacy users, roles/scopes, org, approval, audit | NỀN: identity, role, scope | Cấu hình installation, nhân sự/chi nhánh/kho, ma trận quyền, duyệt ngoại lệ, audit và chính sách phiên |
| P2 Báo cáo/nhập xuất | NPP sales, purchasing, inventory, receivable, margin, COD, workforce, audit/import-export | THIẾU các read models và báo cáo nghiệp vụ | Báo cáo drilldown thực, ledger reconciliation/rebuild, export/in chuẩn hóa, in mẫu; không số liệu giả |
| Xuyên suốt offline/thiết bị | MCP field, retail and customer-ordering offline contracts | CHƯA KIỂM | SQLite/Drift hoặc IndexedDB intent/cache, replay/lost ACK/role switch, Android/Windows/iPhone PWA testing |

**Đây là ma trận phạm vi bắt buộc, chưa phải bảng nghiệm thu PASS.** Khi kiểm từng nguồn, tách thêm use case con, request/response, ownership, RBAC và kiểm thử vào checklist của issue phụ trách.

## 4. Trình tự mới: tiền đề của đơn hàng trước

### R0 — Đối soát chức năng & tái kiến trúc IA (khởi động)
- [ ] Khóa source SHA và lập inventory route/menu/business contracts từ NPP (read-only), đối chiếu từng mục với API/Flutter ERP; route nào thiếu phải có issue và người chịu trách nhiệm.
- [ ] Chốt 6 module → nhóm công việc → tab trong workspace; loại bỏ navigation trùng chức năng, modal quá hẹp, “màn dựng sẵn” chưa có dữ liệu thật.
- [ ] Bộ UX contract: component, filter/search, data table, form/drawer/sheet, keyboard, responsive, toast, confirm, empty/error/offline; screenshot baseline các viewport.

### R1 — Danh mục & engine giá hoàn chỉnh (P0, trước mở rộng Sales)
- [ ] Khách hàng + nhóm + địa chỉ + supplier, chống trùng, search/import/export, RBAC.
- [ ] Product/SKU variant, barcode, sellable units/conversion, customer-facing catalog, file/image ownership.
- [ ] Price engine theo khách/nhóm/kênh/đơn vị bán/priority/stack/min-qty/effective range; history bất biến, decimal + test.
- [ ] UX Công Ty master data và trang báo giá; tạo khách → sản phẩm → đơn vị → bảng giá → giá hiệu lực hoàn toàn trên giao diện.
- **Gate R1:** trên PostgreSQL CI + UAT thật, nhập bộ master tổng hợp rồi tra đúng giá 2 khách × 2 kênh × đơn vị lẻ/thùng; không SQL thủ công, không seed dữ liệu khách production.

### R2 — Bán hàng đầy đủ và UX lập đơn
- [ ] Từ trang danh sách vào workspace ~96vw ≤1440px, sticky header/footer, item search + Enter; không cuộn ngang form.
- [ ] Khách có sẵn/vãng lai theo config, địa chỉ, tra giá/thuế/CK server-side, số lượng & đơn vị, nhiều dòng, nguồn đơn.
- [ ] Save / confirm / amend / cancel: request ID, idempotency, revision, snapshot, conflict, audit; hiển thị lịch sử và 4 trạng thái độc lập.
- **Gate R2:** nhân viên có quyền tự lập/confirm đơn từ dữ liệu R1 trên Web và test backend; số tiền/số chứng từ đúng, 0 tồn kho/AR tự động từ confirm.

### R3 — Kho, giữ hàng và mua hàng
- [ ] Ledger + lô/vị trí + opening, reservation & available, concurrent no-oversell; allocation/pick/pack/issue/reversal.
- [ ] PO/duyệt, partial receipt, supplier returns, AP; transfer/stocktake/adjustment/costing.
- **Gate R3:** 2 đơn tranh tồn, nhiều phiếu nhập, hàng đang chuyển, kiểm kê, đối soát/rebuild không lệch.

### R4 — Giao hàng, thu tiền và công nợ
- [ ] Delivery Order/trip/attempt/POD, nhận tại quầy, COD custody, customer returns/refunds, AR/AP allocations.
- **Gate R4:** một phần giao/một phần thu, thất bại/hẹn lại, trả hàng/đảo chứng từ, không double-post, ledger và COD đối khớp.

### R5 — MCP / Bán Lẻ / Đặt Hàng / Quản trị / Offline
- [ ] Mỗi client dùng chung canonical order/inventory/finance API; không có business database cục bộ khác.
- [ ] RBAC, customer onboarding, scoped catalog, POS print, mobile delivery, offline retries, session-safe account switch.
- **Gate R5:** 4 nguồn tạo yêu cầu/đơn và 6 phân hệ cùng hiển thị trạng thái cuối nhất quán qua server ACK.

### R6 — Báo cáo, UAT/UX closure & production
- [ ] Báo cáo từ ledgers, audit, export/import, document print; rebuild/reconcile.
- [ ] Widget/integration/browser UAT 1440/1280/390/360, keyboard/screen reader/reduced motion; Android + Windows + iPhone PWA bằng test riêng.
- [ ] Mỗi vertical release: CI exact SHA + Codex review + verified migration rehearsal + owner prod approval/target + backend/frontend deploy + provider read-back + smoke, rồi mới đánh dấu production.
- **Gate R6:** synthetic E2E MCP/Đặt Hàng/Bán Lẻ → order → giữ/xuất hàng → giao → AR → thu/COD → đối soát; tất cả use cases trong ma trận đã PASS hoặc được owner ghi rõ loại khỏi phạm vi.

## 5. Tiêu chí đạt “100% nghiệp vụ / UX chuyên nghiệp”

Một tính năng chỉ **DONE** khi: source contract được ghi lại; dữ liệu + API có migration/test; server xử lý quyền/tính toán/đối soát; Flutter chức năng thật; giao diện theo IA và UX contract; offline/lost-ACK tùy scope; CI, browser/UAT và release provider được kiểm chứng. Mỗi dấu kiểm kèm SHA, test, ảnh/recording nếu có, target và thời gian. Những điểm chưa kiểm xác nhận giữ **CHƯA XÁC MINH**; không che bằng placeholder hoặc cấp “hoàn thành” theo cảm giác.

**Không** sao chép SQL cũ, database/khách hàng/PII/logo/secrets hoặc deploy/chỉnh hai repo cũ. PostgreSQL server giữ business authority; production migration chỉ thực hiện đúng cổng phê duyệt, backup mã hóa, restore riêng và đối soát. Nghiệp vụ có quy tắc đặc thù của khách cũ phải được chủ ERP duyệt lại trước khi áp dụng rộng rãi.
