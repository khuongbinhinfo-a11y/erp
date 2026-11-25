#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tools"
printf 'test-only\n' > "$work/release.apk"
cat > "$work/tools/apksigner" <<'TOOL'
#!/usr/bin/env bash
case "${FAKE_FORMAT:-plain}" in
  plain) printf 'Verifies\nSigner #1 certificate SHA-256 digest: %s\n' "${FAKE_SIGNER:?}" ;;
  leading) printf 'Verifies\n  Signer #1 Certificate SHA-256 Digest: %s \r\n' "${FAKE_SIGNER:?}" ;;
  colon) printf 'Verifies\nSigner #1 certificate SHA-256 digest: %s\n' "$(printf '%s' "${FAKE_SIGNER:?}" | sed 's/../&:/g;s/:$//')" ;;
  duplicate) printf 'Verifies\nSigner #1 certificate SHA-256 digest: %s\nSigner #2 certificate SHA-256 digest: %s\n' "${FAKE_SIGNER:?}" "${FAKE_SIGNER:?}" ;;
  missing) printf 'Verifies\nSigner #1 certificate SHA-1 digest: %s\n' "${FAKE_SIGNER:?}" ;;
  *) exit 2 ;;
esac
TOOL
cat > "$work/tools/aapt" <<'TOOL'
#!/usr/bin/env bash
printf "package: name='%s' versionCode='%s' versionName='%s'\n" "${FAKE_PACKAGE:?}" "${FAKE_CODE:?}" "${FAKE_VERSION:?}"
TOOL
chmod +x "$work/tools/apksigner" "$work/tools/aapt"
export FAKE_SIGNER="$(printf 'a%.0s' {1..64})" FAKE_PACKAGE='vn.erpdistribution.erp_distribution' FAKE_CODE=1 FAKE_VERSION=0.1.0
cmd=(bash "$root/verify_android_signed.sh" "$work/release.apk" "$work/tools" "$FAKE_PACKAGE" 1 0.1.0 "$FAKE_SIGNER")
"${cmd[@]}" | grep -q ERP_ANDROID_SIGNED_APK_VERIFIED
for format in leading colon; do
  FAKE_FORMAT="$format" "${cmd[@]}" | grep -q ERP_ANDROID_SIGNED_APK_VERIFIED
done
for format in duplicate missing; do
  if FAKE_FORMAT="$format" "${cmd[@]}" >"$work/negative.log" 2>&1; then
    echo "Invalid signer report '$format' unexpectedly passed" >&2; exit 1
  fi
  grep -q 'Unable to read exactly one APK signing certificate digest' "$work/negative.log"
done
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
