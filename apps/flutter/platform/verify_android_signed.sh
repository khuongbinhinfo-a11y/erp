#!/usr/bin/env bash
# Strict release artifact verifier: fails closed and prints the precise failed gate.
set -euo pipefail

apk="${1:?APK path is required}"
tools="${2:?Android build-tools directory is required}"
expected_package="${3:?Expected package is required}"
expected_code="${4:?Expected versionCode is required}"
expected_name="${5:?Expected versionName is required}"
expected_signer="${6:?Expected signer certificate SHA-256 is required}"

fail() { printf '::error title=ERP APK verification::%s\n' "$*" >&2; exit 1; }
[[ -s "$apk" ]] || fail 'Release APK does not exist or is empty.'
[[ "$expected_signer" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Configured signer certificate digest must be 64 hex chars.'
[[ -x "${tools}/apksigner" ]] || fail 'Android build-tools apksigner executable is missing.'
[[ -x "${tools}/aapt" ]] || fail 'Android build-tools aapt executable is missing.'

verification="$("${tools}/apksigner" verify --verbose --print-certs "$apk" 2>&1)" || {
  printf '%s\n' "$verification" >&2
  fail 'apksigner rejected APK integrity or signature.'
}
# Android build-tools can vary capitalization, leading spaces and digest separators.
# Keep the strict one-signer identity check; never substitute the configured digest.
signer="$(printf '%s\n' "$verification" | python3 -c '
import re, sys
report = sys.stdin.read()
# Real Android build-tools emits "V2 Signer: certificate SHA-256 digest: ..."
# (not always "Signer #1 certificate ..."). Parse either, but require one signer.
pattern = re.compile(
    r"(?im)^[ \t]*(?:Signer[ \t]*#(?P<index>\d+)|"
    r"V(?P<scheme>[234])[ \t]+Signer)[ \t]*:?[ \t]*"
    r"certificate[ \t]+SHA-256[ \t]+digest:[ \t]*"
    r"(?P<digest>(?:[0-9a-f]{2}[: \t-]?){32})(?![0-9a-f])"
)
entries = list(pattern.finditer(report))
counts = re.findall(r"(?im)^[ \t]*Number of signers:[ \t]*(\d+)[ \t]*$", report)
if counts and (len(counts) != 1 or counts[0] != "1"):
    sys.exit(1)
if len(entries) != 1:
    sys.exit(1)
entry = entries[0]
if entry.group("index") not in (None, "1"):
    sys.exit(1)
digest = re.sub(r"[^0-9a-f]", "", entry.group("digest").lower())
if len(digest) != 64:
    sys.exit(1)
print(digest)
')" || {
  printf '%s\n' "$verification" >&2
  fail 'Unable to read exactly one APK signing certificate digest from apksigner report.'
}
[[ "$signer" =~ ^[a-f0-9]{64}$ ]] || fail 'Parsed APK signer digest is invalid.'
[[ "${signer,,}" == "${expected_signer,,}" ]] || fail "APK signer mismatch (actual: ${signer,,}; configured: ${expected_signer,,})."

badging="$("${tools}/aapt" dump badging "$apk" 2>&1)" || {
  printf '%s\n' "$badging" >&2
  fail 'aapt could not inspect release APK metadata.'
}
package_line="$(printf '%s\n' "$badging" | grep -m1 '^package: ' || true)"
[[ -n "$package_line" ]] || fail 'aapt package declaration was missing.'
[[ "$package_line" == *"name='$expected_package'"* ]] || fail "APK package mismatch: $package_line"
[[ "$package_line" == *"versionCode='$expected_code'"* ]] || fail "APK versionCode mismatch: $package_line"
[[ "$package_line" == *"versionName='$expected_name'"* ]] || fail "APK versionName mismatch: $package_line"
printf 'ERP_ANDROID_SIGNED_APK_VERIFIED package=%s code=%s name=%s signer=%s\n' "$expected_package" "$expected_code" "$expected_name" "${signer,,}"
