# ERP — Thẩm định tham khảo UI
Nguồn chỉ đọc: repo alibaba240185/fbmn tại commit ed491e6e5a5b034802a51e2a0ea4c8ad43bd0af4.

## Tài liệu đối chiếu
- docs/futurebook-ui-contract.md: geometry, toast, modal/drawer motion, keyboard, table header.
- docs/admin-ui-design-system.md: semantic tokens, hierarchy, card/form/state.
- apps/ceo/flutter/lib/ceo_ui_tokens.dart: Flutter theme tổ chức token.

## Đã chuyển thể (viết mới)
Kích thước 36/40/44, font >=13, radius 9, menu 200ms, popup 280/220, drawer 300, toast góc phải, header bảng chỉ tô thead; chuyển palette sang xanh lá ERP.

## Không sao chép
Không lấy logo, nhận diện tím, assets/font có license chưa rà soát, screenshot, data SKU, khách hàng, domain, endpoint, secrets hoặc code nghiệp vụ từ fbmn. UI và code trong ERP được viết mới theo contract độc lập.

## Kiểm chứng còn thiếu
Ảnh thực 1440/1280/390/360, test keyboard/reduced motion trên Flutter Android/Windows/Web, iPhone PWA và xác minh bản quyền font/asset chưa thực hiện tại L0.
