#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tools"
printf 'test-only\n' > "$work/release.apk"
cat > "$work/tools/apksigner" <<'TOOL'
#!/usr/bin/env bash
printf 'Verifies\nSigner #1 certificate SHA-256 digest: %s\n' "${FAKE_SIGNER:?}"
TOOL
cat > "$work/tools/aapt" <<'TOOL'
#!/usr/bin/env bash
printf "package: name='%s' versionCode='%s' versionName='%s'\n" "${FAKE_PACKAGE:?}" "${FAKE_CODE:?}" "${FAKE_VERSION:?}"
TOOL
chmod +x "$work/tools/apksigner" "$work/tools/aapt"
export FAKE_SIGNER="$(printf 'a%.0s' {1..64})" FAKE_PACKAGE='vn.erpdistribution.erp_distribution' FAKE_CODE=1 FAKE_VERSION=0.1.0
cmd=(bash "$root/verify_android_signed.sh" "$work/release.apk" "$work/tools" "$FAKE_PACKAGE" 1 0.1.0 "$FAKE_SIGNER")
"${cmd[@]}" | grep -q ERP_ANDROID_SIGNED_APK_VERIFIED
FAKE_SIGNER="$(printf 'b%.0s' {1..64})"
if "${cmd[@]}" >"$work/negative.log" 2>&1; then echo 'Signer mismatch unexpectedly passed' >&2; exit 1; fi
grep -q 'APK signer mismatch' "$work/negative.log"
FAKE_SIGNER="$(printf 'a%.0s' {1..64})" FAKE_PACKAGE='foreign.app'
if "${cmd[@]}" >"$work/negative.log" 2>&1; then echo 'Package mismatch unexpectedly passed' >&2; exit 1; fi
grep -q 'APK package mismatch' "$work/negative.log"
FAKE_PACKAGE='vn.erpdistribution.erp_distribution' FAKE_CODE=2
if "${cmd[@]}" >"$work/negative.log" 2>&1; then echo 'Version code mismatch unexpectedly passed' >&2; exit 1; fi
grep -q 'APK versionCode mismatch' "$work/negative.log"
echo 'ERP_ANDROID_SIGNED_VERIFY_SCRIPT_TEST_PASS'
