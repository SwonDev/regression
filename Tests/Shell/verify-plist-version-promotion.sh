#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$ROOT/build/verify-plist-version-promotion.sh"
SCRATCH="$(mktemp -d /private/tmp/regression-plist-promotion-test.XXXXXX)"
cleanup() { find "$SCRATCH" -mindepth 1 -depth -delete; rmdir "$SCRATCH"; }
trap cleanup EXIT

plutil -create xml1 "$SCRATCH/baseline.plist"
plutil -insert CFBundleIdentifier -string local.regression.launcher "$SCRATCH/baseline.plist"
plutil -insert CFBundleShortVersionString -string 1.10.0 "$SCRATCH/baseline.plist"
plutil -insert CFBundleVersion -string 35 "$SCRATCH/baseline.plist"
cp "$SCRATCH/baseline.plist" "$SCRATCH/promoted.plist"
plutil -replace CFBundleShortVersionString -string 1.10.1 "$SCRATCH/promoted.plist"
plutil -replace CFBundleVersion -string 36 "$SCRATCH/promoted.plist"
"$VERIFY" "$SCRATCH/baseline.plist" "$SCRATCH/promoted.plist" \
    1.10.0 35 1.10.1 36 >/dev/null

plutil -insert UnexpectedKey -string drift "$SCRATCH/promoted.plist"
if "$VERIFY" "$SCRATCH/baseline.plist" "$SCRATCH/promoted.plist" \
    1.10.0 35 1.10.1 36 >/dev/null 2>&1; then
    printf 'FAIL: la puerta aceptó un cambio ajeno a versión/build.\n' >&2
    exit 1
fi

printf 'PASS: la promoción acepta solo versión/build y rechaza drift adicional.\n'
