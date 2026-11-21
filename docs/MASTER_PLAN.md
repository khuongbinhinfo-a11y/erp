# ERP — Master Plan (thực thi theo Issues)

> **Quyết định mới 21/11/2026 — nghiệp vụ đủ và UX chuyên nghiệp trước khi coi các phân hệ hoàn tất:** B1 đã deploy nhưng chỉ là Sales Order foundation, chưa phải sản phẩm có đầy đủ quy trình. Ưu tiên làm xong **Danh mục khách hàng/SKU/đơn vị/bảng giá/engine giá** làm đầu vào đơn hàng, đồng thời tái tổ chức UX theo thao tác của người dùng; sau đó bổ sung Sales operational UX, kho/mua/giao/công nợ/MCP/retail/đặt hàng/offline/báo cáo. Kiểm full coverage bằng ma trận từng use case, không dựa vào số menu hay CI xanh. Nguồn quyết định hiện hành: [Business & UX parity rebaseline](BUSINESS_UX_PARITY_REBASELINE_20261121.md) và [UX Workspace Contract V3](UX_WORKSPACE_CONTRACT_V3.md). Hai repo khách cũ chỉ đọc; không chuyển data/secrets/nhận diện khách.

> **Quyết định ưu tiên 20/11/2026:** chuyển nghiệp vụ từ app NPP cũ sang ERP Flutter theo [Kế hoạch chuyển nghiệp vụ](LEGACY_BUSINESS_PORT_PLAN.md). CORS/production catalog (#7) để sau; triển khai contracts/code và kiểm thử PostgreSQL CI theo thứ tự #8 Sales → #9 Inventory → Purchasing → #10 AR/AP/Delivery → #12 MCP/Retail/Ordering. Không sửa hoặc di chuyển dữ liệu/repo cũ. Không coi UI đã deploy là business API production PASS. Nguồn hiện hành luôn là GitHub code + quyết định owner mới nhất.

Ngày cập nhật: 20/11/2026. Nguồn điều hành: GitHub Issues #1–#18 và code đang được phê duyệt.

## Mục tiêu
Hệ thống phân phối gồm **Công Ty**, **MCP**, **Quản trị**, **Bán Lẻ**, **Giao Hàng**, **Đặt Hàng**. Công Ty desktop-first, MCP/Giao Hàng/Bán Lẻ mobile-first. Android native, Windows desktop và iPhone PWA phải kiểm chứng riêng.

## Kiến trúc đã chốt
- Mỗi khách hàng một installation độc lập: PostgreSQL, backend, danh tính, domain, storage, secrets, backup, cấu hình.
- PostgreSQL cố định, kể cả khi đổi provider. Backend TypeScript modular monolith. Flutter theo feature và flavor.
- API server là nguồn sự thật; SQLite/IndexedDB chỉ nháp/cache/offline intent; không tự post chứng từ hoặc ledger.
- Inventory ledger quyết định tồn, AR/AP ledger quyết định công nợ. Chứng từ đã post chỉ đảo/correction.
- RBAC deny-by-default theo installation, branch, warehouse, actor. Idempotency + audit + revision cho mutations nhạy cảm.

## Trình tự theo Issues
| Lô | Issues | Chứng cứ kết thúc |
| --- | --- | --- |
| L0 | #2, #3, #4, #13 | base SHA, mã nguồn shell, design contract, CI, PR |
| POC | #5, #6, #11, #14 | PostgreSQL demo thật, API auth, migration/replay, offline ACK test |
| Vertical slice | #7–#10 | đối chiếu order, fulfillment, inventory và AR/AP với concurrency test |
| Tích hợp | #12–#13 | build Android/Windows/PWA, responsive, accessibility, UAT |
| Phát hành | #14 | owner duyệt đúng SHA/target, backup/restore rehearsal, smoke, release manifest |

## Cổng thay đổi
**Owner quyết định 18/11/2026 (ưu tiên hơn quy trình nhánh/PR ban đầu):** mặc định code trực tiếp `main`, CI chỉ chạy tự động sau push `main`, không bắt buộc tạo branch/PR trước. Codex preview có thể giúp rà soát, không phải chứng cứ CI PASS. Sau push, read-back SHA + CI; FAIL phải sửa hoặc revert trước lô tiếp. PR chỉ khi owner yêu cầu; PR #15 đã được owner cho phép merge khi CI xanh. Production migration cần backup, restore rehearsal, reconciliation và owner duyệt riêng; deploy cần lệnh target rõ, Git auto-deploy OFF. Xem `docs/DEV_WORKFLOW.md`.

## Trạng thái ban đầu
18/11/2026: PR #15 đã squash merge tại `60a832ec745a0a4b071b144b31d1c460d6d90ff0` sau CI PR xanh 3/3; Vercel `erp` đã tạo đúng team, chưa deploy; Prisma `erp-sales` vẫn chưa có DB. Trạng thái cần read-back trước các lô kế tiếp.

## Quy tắc phát hành owner — CI xanh thì phát hành đầy đủ (20/11/2026)
- Trong lô được owner giao deploy production, **CI PASS trên đúng main SHA** là điều kiện bắt buộc để phát hành **Flutter Vercel + TypeScript Prisma Compute**; phát hành đủ phần code đã thay đổi, kiểm provider read-back + API smoke + đăng nhập thật, rồi báo ngắn link test. Dùng GitHub Issue comment exact SHA (owner account) để kích hoạt workflow backend; không yêu cầu owner chạy terminal.
- **Có migration mới** phải phát hành SQL versioned theo đúng thứ tự **sau khi** có encrypted current-source backup, read-back, isolated PostgreSQL restore, reconciliation và phê duyệt production target/SHA riêng; không dùng CI rehearsal thay cho backup production. Chưa qua cổng thì báo **chưa phát hành nghiệp vụ**, không tuyên bố đã hoàn tất chỉ vì frontend/backend xanh.
- Migration `0006_catalog.sql` và `0007_catalog_controls.sql` cho danh mục chưa chạy production tại bản ghi 20/11: Prisma schema read-back không có bảng `catalog_*`; tự động backup list rỗng. Do đó vẫn cần operator backup/restore đạt và bản duyệt migration riêng trước khi bật CRUD.
- Thứ tự ưu tiên hiện thời: **đăng nhập/phiên + sidebar → catalog migration/API thật → nghiệp vụ #8 Sales Order**, sau đó kho, mua hàng và công nợ theo `docs/LEGACY_BUSINESS_PORT_PLAN.md`; CORS preflight catalog được smoke sau migration và Compute release, không che lỗi bằng dữ liệu giả.
