#!/usr/bin/env bash
# Demuestra que una promoción modificó únicamente versión y número de build del Info.plist.
set -Eeuo pipefail

BASELINE_PLIST="${1:-}"
PROMOTED_PLIST="${2:-}"
BASELINE_VERSION="${3:-}"
BASELINE_BUILD="${4:-}"
TARGET_VERSION="${5:-}"
TARGET_BUILD="${6:-}"
VERIFY_SCRATCH=""

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
    if [[ -n "$VERIFY_SCRATCH" \
        && "$VERIFY_SCRATCH" == /private/tmp/regression-plist-promotion.* ]]; then
        find "$VERIFY_SCRATCH" -mindepth 1 -depth -delete
        /bin/rmdir "$VERIFY_SCRATCH" 2>/dev/null || true
    fi
}
trap cleanup EXIT

[[ -f "$BASELINE_PLIST" && -f "$PROMOTED_PLIST" ]] \
    || fail "uso: $0 BASELINE PROMOTED BASELINE_VERSION BASELINE_BUILD TARGET_VERSION TARGET_BUILD"
for value in "$BASELINE_VERSION" "$BASELINE_BUILD" "$TARGET_VERSION" "$TARGET_BUILD"; do
    [[ -n "$value" ]] || fail "las versiones y builds no pueden estar vacíos"
done
plutil -lint "$BASELINE_PLIST" >/dev/null
plutil -lint "$PROMOTED_PLIST" >/dev/null
[[ "$(plutil -extract CFBundleShortVersionString raw "$BASELINE_PLIST")" == "$BASELINE_VERSION" \
    && "$(plutil -extract CFBundleVersion raw "$BASELINE_PLIST")" == "$BASELINE_BUILD" ]] \
    || fail "el Info.plist baseline no coincide con la versión de origen"
[[ "$(plutil -extract CFBundleShortVersionString raw "$PROMOTED_PLIST")" == "$TARGET_VERSION" \
    && "$(plutil -extract CFBundleVersion raw "$PROMOTED_PLIST")" == "$TARGET_BUILD" ]] \
    || fail "el Info.plist promovido no coincide con la versión de destino"

VERIFY_SCRATCH="$(mktemp -d /private/tmp/regression-plist-promotion.XXXXXX)"
chmod 700 "$VERIFY_SCRATCH"
cp "$PROMOTED_PLIST" "$VERIFY_SCRATCH/normalized.plist"
plutil -replace CFBundleShortVersionString -string "$BASELINE_VERSION" \
    "$VERIFY_SCRATCH/normalized.plist"
plutil -replace CFBundleVersion -string "$BASELINE_BUILD" \
    "$VERIFY_SCRATCH/normalized.plist"
cmp -s "$BASELINE_PLIST" "$VERIFY_SCRATCH/normalized.plist" \
    || fail "Info.plist contiene cambios ajenos a versión/build"

printf 'Promoción Info.plist exacta: %s (%s) -> %s (%s).\n' \
    "$BASELINE_VERSION" "$BASELINE_BUILD" "$TARGET_VERSION" "$TARGET_BUILD"
