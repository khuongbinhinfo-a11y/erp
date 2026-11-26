# M3 — Android APK updater/R2, kiểm tra ngày 25/11/2026

**Tình trạng:** CHƯA HOÀN TẤT; đây là trạng thái thực tế và cổng triển khai, không phải chứng nhận UAT.

## Provider read-back
- Repo phụ `khuongbinhinfo-a11y/erp`, baseline main `8e7090d56c362055a80ffbcb86a4e3b537ea2180`.
- Repo chính `gustavjung24-ops/ERP`, baseline main `6c0c30ca461612a1bfd1d700fb56d803be2744ea`.
- Bucket R2 ERP `erp-android-releases` có đúng object `releases/1/erp-1.apk`, 63.425.634 byte; metadata SHA-256 `385766285dfc21e4c9d8cca3ab9d332e94476df1ec5ddbe02628bc0dc46b1328`, fingerprint signer `545d17fc51c8d24de4d73cb84ff7c3953f79c7d14efc7ada29b7075110d0c028`. UAT candidate 0.1.0, **không chứa bản M1+M2 mới nhất**.
- R2 GET `releases/latest.json` trả 404 key not found; chưa có release pointer.
- Worker `erp-android-download` có R2 binding giới hạn bucket này và chỉ phục vụ APK v0.1.0 qua `https://erp-android-download.gustavjung24.workers.dev/ERP-Android-0.1.0.apk`. Không nhầm downloader công khai với authenticated OTA API.
- `backend/deploy/module.ts` và `entry.ts` chưa gắn sáu bí mật release riêng. API updater giữ fail-closed. Không được báo OTA hoạt động cho đến khi bật read-only R2 credentials + ticket secret thật và deploy backend qua Codespaces.

## Cổng chặn trước khi phát hành M1+M2
1. Kiểm exact `main` mới, CI 7/7 PASS, Codex không còn findings. Chỉ merge sau owner approval, sau đó đồng bộ main repo chính và đối chiếu Git tree.
2. Build Android **signed release** từ main M1+M2 bằng đúng PKCS12 cũ, không đổi package `vn.erpdistribution.erp_distribution` hoặc certificate. `versionCode` phải tăng (>1); xác minh apksigner, aapt, SHA-256, size, source SHA và AAB.
3. CI upload APK immutable `releases/<versionCode>/erp-<versionCode>.apk` vào bucket R2 riêng, full bytes read-back. Workflow hiện dùng protected S3 R2 writer secrets; các secret này từng thiếu ở lần stage trước. Phải kiểm thực tế hoặc triển khai luồng OIDC protected được review và kiểm riêng. Không đưa credentials vào chat, log hoặc mã.
4. Thực hiện **UAT trên Android thật** từ APK 0.1.0 → APK signed mới: cùng signer/package, cài đè không gỡ, giữ phiên đăng nhập, SQLite/outbox/đơn chưa đồng bộ, từ chối quyền cài, mất mạng/resume, vé hết hạn, không có update, account switch.
5. **Sau** owner duyệt UAT/release: ghi immutable version manifest và `releases/latest.json` bằng publisher có CAS; xác minh đọc lại nội dung. Không tự tạo pointer giả dựa vào APK cũ.
6. Gắn sáu biến release protected vào Prisma Compute bằng PR riêng sau khi secrets đã có, backup/rollback nếu thay đổi DB (M3 hiện không cần migration). Deploy backend bằng Codespaces target/SHA được phê duyệt. Smoke API đăng nhập `/v1/app/releases/latest`, ticket, range, SHA, native installer. Vercel thủ công chỉ khi đổi phần Web.
7. Không bắt đầu M4 khi chưa hoàn thành các bằng chứng trên.

## Code M3
- PR #69: strict ticket expiry/duplicate validation, error messages tiếng Việt và unit regression test.
- Mỗi kết luận phải ghi ĐÃ XÁC MINH / CHƯA XÁC MINH. CI PASS không thay thế UAT, R2 staged không thay thế activated release.
- Không sửa POS/bán lẻ trong M3; tab Bán lẻ vẫn chỉ là UI tạm, không trộn thêm nghiệp vụ vào đơn phân phối.

## M3 bổ sung: nối backend–R2 OTA an toàn
- Backend có fallback Worker chỉ-đọc và vẫn xác thực phiên/quyền, cấp ticket HMAC ngắn hạn, khóa dẫn xuất từ protected backend secret đã tồn tại (không lộ credential ở client).
- Worker chỉ phục vụ APK v1/v2 cố định, hỗ trợ Range, HEAD, relay `releases/latest.json` và đối chiếu SHA/cert/size/source.
- Cổng phát hành: CI 7/7 + Codex sạch, Worker/R2/manifest readback, backend deploy đúng SHA bằng Codespaces, smoke API đã login và UAT cài đè thật. **Không có migration**.
