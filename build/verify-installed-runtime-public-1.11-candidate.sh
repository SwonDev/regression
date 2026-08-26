#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET="${1:-}"
CHECKSUM="${2:-}"
BASELINE_APP="${3:-}"
SCRATCH=""
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
    if [[ -n "$SCRATCH" && "$SCRATCH" == /private/tmp/regression-public-1.11-transition.* ]]; then
        find "$SCRATCH" -depth -delete
    fi
}
trap cleanup EXIT

[[ -f "$ASSET" && -f "$CHECKSUM" && -d "$BASELINE_APP" && ! -L "$BASELINE_APP" ]] \
    || fail "uso: $0 ASSET CHECKSUM BASELINE_APP"
"$ROOT/build/verify-public-1.11-transition-bundle.sh" baseline "$BASELINE_APP"

expected="$(awk 'NR == 1 {print tolower($1)}' "$CHECKSUM")"
actual="$(shasum -a 256 "$ASSET" | awk '{print tolower($1)}')"
[[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] \
    || fail "el asset no coincide con su sidecar"
while IFS= read -r entry; do
    case "$entry" in Regression.app|Regression.app/|Regression.app/*) ;; *) fail "ruta inesperada: $entry";; esac
    case "/$entry/" in */../*|*/./*) fail "ruta no normalizada: $entry";; esac
done < <(tar -tf "$ASSET")
SCRATCH="$(mktemp -d /private/tmp/regression-public-1.11-transition.XXXXXX)"
chmod 700 "$SCRATCH"
tar --xattrs --no-mac-metadata -xf "$ASSET" -C "$SCRATCH" --no-same-owner
CANDIDATE_APP="$SCRATCH/Regression.app"
"$ROOT/build/verify-public-1.11-transition-bundle.sh" candidate "$CANDIDATE_APP"

root_entries() {
    local app="$1"
    find "$app" -mindepth 1 -maxdepth 1 -print \
        | sed "s#^$app/##" | LC_ALL=C sort
}
contents_entries_without_signature() {
    local app="$1"
    find "$app/Contents" -mindepth 1 -maxdepth 1 ! -name _CodeSignature -print \
        | sed "s#^$app/Contents/##" | LC_ALL=C sort
}
cmp -s <(root_entries "$BASELINE_APP") <(root_entries "$CANDIDATE_APP") \
    || fail "el candidato cambió la estructura raíz del bundle"
cmp -s <(contents_entries_without_signature "$BASELINE_APP") \
    <(contents_entries_without_signature "$CANDIDATE_APP") \
    || fail "el candidato cambió la estructura superior de Contents"
cmp -s "$BASELINE_APP/Contents/Info.plist" "$CANDIDATE_APP/Contents/Info.plist" \
    || fail "Info.plist cambió en una transición 1.11 -> 1.11"
"$ROOT/build/verify-byte-identical-tree.sh" \
    "$BASELINE_APP/Contents/MacOS" "$CANDIDATE_APP/Contents/MacOS" \
    Regression regression-engine >/dev/null
"$ROOT/build/verify-byte-identical-tree.sh" \
    "$BASELINE_APP/Contents/Resources" "$CANDIDATE_APP/Contents/Resources" >/dev/null
"$ROOT/build/verify-byte-identical-tree.sh" \
    "$BASELINE_APP/Contents/SharedSupport" "$CANDIDATE_APP/Contents/SharedSupport" \
    bin/regressionctl \
    Switch2Bridge/Switch2Bridge.app/Contents/MacOS/Switch2Bridge \
    Switch2Bridge/Switch2Bridge.app/Contents/_CodeSignature/ >/dev/null
[[ ! -e "$CANDIDATE_APP/Contents/SharedSupport/wine-root/lib/dxvk/x86_64-windows/d3d11.dll.bak-gcc16-ucrt-20260726-162839" \
    && ! -e "$CANDIDATE_APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/winevulkan.so.bak-absolute-toolchain-rpath-20260726-1645" ]] \
    || fail "el candidato conserva copias de laboratorio"

printf 'Candidato público 1.11 actualizado verificado: %s\n' "$actual"
