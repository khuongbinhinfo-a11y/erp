# M1 — Mobile shell and ERP light/dark themes

Status: implementation under review; CI/Codex/device UAT are separate gates. Base auxiliary main `fd7f21a4b65a8ac4d2b702f2762663c3d505bdae`.

## Scope and source mapping
- KEEP: `CompanyWorkspace` typed sections and grants, `SalesWorkspace` server ACK/recovery, catalog and inventory APIs, app update auth/guard, desktop floating sidebar, native signing.
- ADAPT: `erp_tokens.dart` static light palette → context-resolved semantic roles, shared Material themes, local cosmetic setting. UI call sites use semantic roles; deliberate brand artwork/print output stays separate.
- ADAPT: mobile `ErpShell` Drawer → accessible bottom destinations + More sheet. Existing Company sections share one RBAC check and stateful content slot; do not create a parallel sales engine. Bán lẻ entry goes to the current order workspace until M2/T3/T5/T6 implement canonical POS checkout.
- ADAPT: Android generated window backgrounds and PWA startup background avoid a white startup flash, preserving existing origin guard, service worker policy, package and signing.
- No API contract, database migration, R2 updater protocol or business rules changed. APK publication belongs to M3/M4; no versionCode bump in this source-only PR.

## Acceptance
- Sáng/Tối/Theo thiết bị, persistence across restart, no page reload or loss of open form/session; light and dark semantic color tests, text contrast ≥4.5:1; interactive outline ≥3:1.
- Test mobile widths 320/360/390/430, keyboard/IME, orientation, safe-area and larger text; only authorized destinations; navigation lock prevents unresolved order mutation from being abandoned.
- Inspect login, menu, forms, tables, dropdowns, date picker, dialogs, toast, warnings, selected/hover/focus/disabled, loading/empty/error on Android/Web/Windows/iPhone PWA in both themes, including OS mode change while modal is open.
- Capture screenshots and review actual devices before claiming visual acceptance. Existing invoice print/export remains light.
- Run flutter analyze/test, Android and Windows build, Web/PWA build and standard CI 7/7; exact final PR SHA must have clean Codex. Device UAT and release remain separate, no fake PASS.
