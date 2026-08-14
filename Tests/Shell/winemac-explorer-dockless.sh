#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/sources-26.3.0/wine/dlls/winemac.drv/cocoa_app.m"
PATCH="$ROOT/patches/wine-26.3.0-winemac-explorer-dockless.patch"
RUNTIME="${REGRESSION_DOCKLESS_RUNTIME:-$ROOT/Regression.app/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/winemac.so}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

grep -Fq 'wine-26.3.0-winemac-explorer-dockless.patch' \
    "$ROOT/build/apply-wine-patches.sh" \
    || fail "el parche Dock-less no forma parte de la serie Wine"
grep -Fq '@"explorer.exe"' "$SOURCE" \
    || fail "el código Winemac no mantiene explorer.exe como auxiliar"
grep -Fq '@"explorer.exe"' "$PATCH" \
    || fail "el contrato Dock-less no está versionado como parche reproducible"
git -C "$ROOT/sources-26.3.0/wine" apply --reverse --check \
    --whitespace=error-all "$PATCH" \
    || fail "el parche versionado no coincide exactamente con el árbol Wine"
[[ -f "$RUNTIME" && ! -L "$RUNTIME" ]] \
    || fail "falta el winemac físico que se debe acreditar"
strings -a "$RUNTIME" | grep -Fx 'explorer.exe' >/dev/null \
    || fail "el winemac compilado no contiene la exclusión Dock-less"

printf 'Winemac Dock-less verificado: explorer.exe permanece auxiliar y el parche es reproducible.\n'
