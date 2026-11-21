# Vercel ERP Flutter Web (UI shell, chưa có nghiệp vụ)

Target: existing Vercel project `erp` under team `gustavjung24-ops-projects`. Build Flutter Web 3.50.0 to `apps/flutter/build/web`, serve static files only. No DB credentials in browser.

Deployment is **manual** to Vercel production, using a reviewed `main` SHA. The project must remain disconnected from automatic Git deployments; no preview environment.

Production UI-only smoke: load root HTML and Flutter bundle, see six navigation modules on desktop/mobile. Do not claim business readiness: ERP `/health/ready` remains blocked by production migration approval, and all business writes are disabled.

Vercel build script installs a pinned Flutter SDK only when Flutter isn't preinstalled. GitHub CI performs `flutter build web --release` independently before Vercel release.
