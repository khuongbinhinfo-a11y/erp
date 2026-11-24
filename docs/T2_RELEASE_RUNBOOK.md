# T2 — quy trình phát hành Android/PWA/offline

Trạng thái tài liệu: quy trình và acceptance, **không phải chứng nhận đã phát hành**. Baseline repo phụ `c9d1eab87b549abe4a490bd4d3af2c81a49e1964`; repo chính `0b75cbeaed743815812f8d1bc5f10791e75ede53`. Không đổi migration 0022. Đọc AGENTS và Master Plan §6.1.

## Đối chiếu tham khảo (read-only)

Nguồn MCP-FBMN @ `3175e378628df85410a002950cb1afa064406c62`, chỉ hành vi/API, không copy nguồn/identity.
- app_update_models.dart, app_update_page.dart, app_update_driver_native.dart → ERP app_update_models.dart, app_update_native.dart: CONSOLIDATE luồng menu, version, ticket, tiến độ/resume, SHA; test model.
- MainActivity.kt → ERP platform/android/MainActivity.kt: triển khai riêng package/signer verification và OS installer; UAT bắt buộc.
- backend app_releases.ts, android_release_publisher.ts → app_release_http.ts, r2_media_signer.ts: API auth, scope ticket, private R2, range; test negative.
- sales-android-release.yml/publish_android_release.py → erp-android-release.yml, erp-android-publish.yml, platform/publish_android_release.py: tách build/publish và verify readback.
- DROP mọi secrets, package/app identity, endpoint, bucket, dữ liệu khách, branding của repo tham khảo.

## Gate và thao tác agent

1. CI gốc 5 job + 2 job native, Codex sạch exact final PR SHA; owner cho phép merge. Merge phụ → sync main chính → so Git tree. Không dùng CI chính thiếu quota làm gate.
2. Android package ERP dự kiến `vn.erpdistribution.erp_distribution`; khóa appId/signer sau khi duyệt lần đầu, không xoay key tùy tiện. Agent xác minh protected environment `android-release`, stable keystore riêng ERP và backup khôi phục được; không xuất key/password ra chat/log. Chỉ protected workflow dispatch trên main phụ exact SHA; input versionCode tăng, versionName đúng. Kiểm đủ SHA, apk SHA-256, cert, package, version, size, AAB. Không phát hành debug.
3. Backend release config riêng: ERP_RELEASE_R2_ACCOUNT_ID, ERP_RELEASE_R2_BUCKET, ERP_RELEASE_R2_ACCESS_KEY_ID, ERP_RELEASE_R2_SECRET_ACCESS_KEY (read-only), ERP_ANDROID_CERT_SHA256, ERP_RELEASE_TICKET_SECRET. Tạo bucket riêng ERP sau phê duyệt, private, không public dev URL/custom domain. Không dùng bucket media. Publisher write credential riêng, không dùng backend reader để ghi. Protected env `android-r2-publish` có owner approval thật và UAT link kiểm chứng; string input không tự chứng minh approval. Không chạy khi thiếu reviewer protection hoặc chưa xác minh quyền.
4. Build workflow `.github/workflows/erp-android-release.yml`; UAT hai artifact signed v1/v2 trong môi trường được phép, trước public production release. Agent kiểm cùng signer, appId, dữ liệu test riêng; không dùng dữ liệu thật. Workflow `.github/workflows/erp-android-publish.yml` nhận run ID thành công và exact SHA, đọc artifact, kiểm checksum, conditional immutable object + history. R2 conditional If-None-Match/If-Match: thất bại thì dừng; nếu timeout đọc lại bytes/manifest trước quyết định tiếp. Không overwrite object cũ. Không đổi latest khi readback chưa pass.
5. Backend qua Codespaces đúng target/SHA sau CI; build:compute trước deploy. Vercel Production thủ công do agent, auto deploy OFF. Web SW chỉ cache public build assets cùng version; không cache API, token, response chứng từ. Kiểm origin canonical, iPhone Home Screen, offline reload, update SW, không hiện menu APK.
6. Rollback: không downgrade APK trên máy; điều tra bản lỗi, giữ object immutable, phát hành phiên bản mới cao hơn với fix. Chỉ đổi pointer về artifact đã verify khi owner duyệt và client versionCode policy cho phép; không xóa APK/history. Bằng chứng publish ghi vào #46: source SHA/run, cert SHA, APK SHA, bytes, readback, version, approval, UAT, exact latest readback.

## Checklist chưa được đánh dấu PASS nếu không có evidence

- Android v1→v2 trên máy thật: cài đè giữ session/giỏ/SQLite/intent; quyền unknown sources bị từ chối; mất mạng/range resume; cancel/retry; hết ticket, sai actor/quyền, hash, signer, package, version, dung lượng; không update khi không có bản mới.
- Windows build và máy thật; file picker, in, session, SQLite. iPhone Safari add Home Screen, cache/IndexedDB, storage eviction, account switch.
- Offline cart: dữ liệu lưu máy không có documentNo; cache không là giá/tồn hiện hành; tra giá live trước gửi. Create/update/confirm: giữ cùng key/body nếu không rõ ACK; đối chiếu receipt/canonical state trước retry. Không tự gửi xuất kho, thu tiền, post ledger offline; kiểm mất mạng trước/sau COMMIT, double tap, hai máy, đổi quyền, stale price.
- Kiểm UOM baseline/underlines desktop/mobile, không đổi engine giá/quy đổi/tách dòng. Benchmark startup/search và UX in/barcode/ảnh trên thiết bị thật.
- Known gaps cần hoàn tất trước chốt T2: browser HttpOnly/session migration; auto-save mọi thay đổi đang nhập, recovery khi app chết/eviction; cache đủ catalog/variant/stock, outbox toàn module, sync foreground/backoff, kiểm receipt lookup mới cho create/update/confirm lost ACK, scope kho và test thiết bị; không giả định CI hoặc lớp storage là full acceptance.

## Ghi chú preflight 24/11/2026 — signing chưa được cấp

- Prisma Compute T2 lần đầu thất bại `DEPLOY.PREFLIGHT_FAILED` vì module buộc sáu biến `ERP_RELEASE_R2_*`, `ERP_ANDROID_CERT_SHA256`, `ERP_RELEASE_TICKET_SECRET` chưa tồn tại. Không dùng giá trị giả, không sao chép khóa của ứng dụng cũ.
- Bản sửa deploy tạm thời **bỏ liên kết sáu release secrets khỏi service Compute**; lõi ERP vẫn sử dụng đúng PostgreSQL, auth, R2 media như trước. API cập nhật APK tự từ chối an toàn (`RELEASE_UNAVAILABLE`) thay vì trả manifest sai. Không coi đây là đã phát hành chức năng updater.
- Khi có **keystore ký APK riêng ERP**, chứng chỉ SHA-256 thật, R2 reader credential giới hạn bucket `erp-android-releases` và ticket secret mạnh bảo vệ trong Prisma Production, phải tạo PR bật lại đúng sáu binding, CI/Codex PASS, xác minh provider rồi mới deploy phiên bản Android update. Không thêm giả lập hoặc bật route không có đủ sáu biến.
