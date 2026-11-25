# M2 — Bán lẻ mobile-first (canonical order entry)

- Entry route: Mobile "Bán lẻ" routes straight to existing `SalesWorkspace` with `retailMode`, instead of a placeholder/redirect. Keep ERP branch-scoped `orders.create`, `inventory.read`, `orders.confirm` RBAC and navigation locks.
- New retail forms default to `PICKUP` and use only the existing active walk-in ID returned by `sales/entry-settings`. No generated customer IDs; an unavailable walk-in requires an explicit selection or existing idempotent prepare.
- Fast SKU search remains backend quote-driven with exact barcode/name/code; row displays unit, authoritative price or clear "unknown", and scoped stock availability or clear "not verified" status. Results have a >=48 px mobile touch target.
- Cart quantity stepper uses BigInt thousandths (no JS/Dart floating-point arithmetic for prices). Every change invalidates old quote/signature and triggers backend quote again. Canonical create/confirm, offline scoped cart and idempotent reconciliation code is reused unchanged.
- Mobile sheet expands to safe viewport and follows keyboard insets; checkout actions stay above the keyboard. Sticky total stays "Chưa xác định" until server quoted it. One-hand primary action is explicit `Lưu và xác nhận đơn`, **not** `Thu tiền`, `Xuất kho` or `Thanh toán`; less-used price/tax and shipping fields remain available behind toggles.
- No new backend route, migration, inventory ledger, AR ledger, payment state or R2 release. True direct POS stock issue/payment/settlement, returns, cashier shift and receipt printing require the future canonical T3/T5/T6 server functions, not simulated client ACK.

## Verification gates

Flutter analyze/test, web/Android/Windows builds on reviewed SHA; mobile 320/360/390/430 touch/keyboard/one-hand; scanner keyboard and barcode; price/qty/unit/discount; walk-in and business customer; warehouse, grants, outbox, retry, disconnect, account switch, dark/light; Codex review, exact git tree readback, then authorized merge and manual Vercel deploy. Real device and end-to-end payment/stock are separate UAT gates.