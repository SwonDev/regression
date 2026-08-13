#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENTITLEMENTS="$ROOT/assets/native/Regression.entitlements"
INSTALLER="$ROOT/Scripts/install_regression.sh"
CANDIDATE_VERIFIER="$ROOT/build/verify-installed-runtime-candidate.sh"
RELEASE_VERIFIER="$ROOT/build/verify-release-asset.sh"
SCRATCH="$(mktemp -d /private/tmp/regression-entitlements-test.XXXXXX)"

cleanup()
{
    find "$SCRATCH" -mindepth 1 -depth -delete
    rmdir "$SCRATCH"
}
trap cleanup EXIT

verify_extracted_entitlements()
{
    local executable="$1"
    local extracted="$SCRATCH/extracted.plist"
    local entitlement key value

    codesign -d --entitlements :- "$executable" > "$extracted" 2>/dev/null
    for entitlement in \
        com.apple.security.cs.allow-unsigned-executable-memory \
        com.apple.security.device.audio-input \
        com.apple.security.device.camera
    do
        key="${entitlement//./\\.}"
        value="$(plutil -extract "$key" raw -o - "$extracted")"
        [[ "$value" == "true" ]] || return 1
    done
    ! plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - \
        "$extracted" >/dev/null 2>&1
}

cp /usr/bin/true "$SCRATCH/Regression-good"
codesign --force --entitlements "$ENTITLEMENTS" --sign - "$SCRATCH/Regression-good" \
    >/dev/null
verify_extracted_entitlements "$SCRATCH/Regression-good" || {
    printf 'FAIL: el contrato canónico de capacidades no supera el gate.\n' >&2
    exit 1
}

cp "$ENTITLEMENTS" "$SCRATCH/Regression-bad.entitlements"
/usr/libexec/PlistBuddy \
    -c 'Add :com.apple.security.automation.apple-events bool true' \
    "$SCRATCH/Regression-bad.entitlements"
cp /usr/bin/true "$SCRATCH/Regression-bad"
codesign --force --entitlements "$SCRATCH/Regression-bad.entitlements" --sign - \
    "$SCRATCH/Regression-bad" >/dev/null
if verify_extracted_entitlements "$SCRATCH/Regression-bad"; then
    printf 'FAIL: el gate aceptó Apple Events en los entitlements extraídos.\n' >&2
    exit 1
fi

for file in "$INSTALLER" "$CANDIDATE_VERIFIER" "$RELEASE_VERIFIER"; do
    grep -F "plutil -extract 'com\.apple\.security\.automation\.apple-events'" "$file" \
        >/dev/null || {
            printf 'FAIL: %s no rechaza Apple Events después de extraer la firma.\n' "$file" >&2
            exit 1
        }
done

printf 'PASS: la firma conserva solo capacidades necesarias y rechaza Apple Events.\n'
