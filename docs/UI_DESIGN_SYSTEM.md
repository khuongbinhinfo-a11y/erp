# ERP UI Design System v2 — 19/11/2026

## Direction
Modern Enterprise ERP: more visual hierarchy, sharper surfaces, deep forest with selective fresh green/lime accents.
- Forest #164E35 primary, #103D2A hover, sidebar #102E24 → #164E35 gradient.
- Fresh green #27B97B for table active stripe and positive emphasis.
- Lime #D7EF8A as restrained menu logo/selected item accent.
- Soft white #F5F7F2 canvas, #FCFDF9 cards, #E8F3EB table header, text #1B3328.
- Flat **7px cards**, **6px controls**, narrow 3px active sidebar stripe; avoid many oversized round cards.
- Sidebar collapses from 246px to 78px on desktop with icon tooltips; mobile remains labeled.
- Table header is mint with green line, no tinted rows.

## Notification policy
- General startup information appears as a **top-right overlay toast**, width <=370px, dismiss button, auto closes after 4 seconds.
- Navigation does not restart/repeat this toast. Timer is canceled on widget dispose or manual close.
- No permanent informational banners on Công Ty or Quản trị.
- Contextual empty state and disabled controls remain visible to avoid suggesting unacknowledged/fictional sales, ledger or user grants.
- Actual failure states requiring user action must remain recoverable even if a transient toast disappears. Never label client-only intent as successful inventory/payment posting.

## Verification gates
Flutter analyze, widget tests for close/auto-hide/no repeat/sidebar navigation, flutter build web --release and CI PASS on final SHA before manual Vercel production deployment. Android/Windows and live-browser UAT separate. No copy of other customers' assets.

## Stable navigation and motion — 19/11/2026
- Login: forest gradient and original Flutter-only geometric shapes behind the foreground form.
- Header: 74px mobile / 80px desktop, same fixed geometry across six modules, outside scrolling body.
- Subsections: flat underline tabs, static item widths, no chips; pinned above content.
- Transitions: content opacity 160ms in fixed viewport, underline 180ms, sidebar 300ms. Respect system reduced-motion.
- Widget coverage: login backdrop and pinned company header. Browser UAT still separate.

## Login card editorial image — 19/11/2026
- The desktop left panel now contains the image provided directly by the owner (warehouse, delivery truck, stylized world map), converted to a small bundled WebP. No third-party assets or external runtime requests.
- A vertical forest-green overlay maintains contrast for the logo and headings while allowing the logistics artwork to appear below the text.
- The form remains unchanged and readable; narrow screens omit the decorative left panel. CI widget tests cover both widths.
