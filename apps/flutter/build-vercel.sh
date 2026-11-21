#!/usr/bin/env bash
# Vercel production UI-only build: pinned Flutter SDK, never reads backend DB secrets.
set -euo pipefail
flutter_version="3.50.0"
if ! command -v flutter >/dev/null 2>&1; then
  sdk_dir="${TMPDIR:-/tmp}/erp-flutter-sdk-${flutter_version}"
  if [[ ! -x "$sdk_dir/flutter/bin/flutter" ]]; then
    mkdir -p "$sdk_dir"
    curl --fail --location --silent --show-error --retry 3 \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${flutter_version}-stable.tar.xz" \
      | tar -xJ -C "$sdk_dir"
  fi
  git config --global --add safe.directory "$sdk_dir/flutter"
  export PATH="$sdk_dir/flutter/bin:$PATH"
fi
flutter --version
flutter config --enable-web
flutter pub get
flutter build web --release --base-href / --dart-define="ERP_API_BASE_URL=${ERP_PUBLIC_API_URL:-}"
test -s build/web/index.html
test -s build/web/main.dart.js
echo "Flutter Web static UI build successful"
