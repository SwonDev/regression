#!/usr/bin/env bash
# Cubre el contrato raw sellado → transformación pública 1.12 sin empaquetar.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRANSFORM="$ROOT/build/verify-public-runtime-transform-1.12.sh"
PACKAGER="$ROOT/Scripts/package_release.sh"
ASSET_VERIFIER="$ROOT/build/verify-release-asset.sh"
CURRENT_ASSET="$ROOT/build/release-1.12.3/Regression-1.12.3-macos-arm64.tar.gz"
SCRATCH="$(mktemp -d /private/tmp/regression-public-runtime-transform-test.XXXXXX)"
WINE_ROOT="$SCRATCH/wine-root"
SECOND_WINE_ROOT="$SCRATCH/wine-root-second"

cleanup() {
    find "$SCRATCH" -mindepth 1 -depth -delete
    rmdir "$SCRATCH"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local description="$1" expected="$2"
    shift 2
    local output status
    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "$description debía fallar"
    /usr/bin/grep -Fq "$expected" <<< "$output" \
        || fail "$description falló sin el diagnóstico esperado: $output"
}

mkdir -p "$WINE_ROOT"
"$TRANSFORM" --derive "$WINE_ROOT" >/dev/null
"$TRANSFORM" --verify "$WINE_ROOT" >/dev/null
mkdir -p "$SECOND_WINE_ROOT"
"$TRANSFORM" --derive "$SECOND_WINE_ROOT" >/dev/null

while IFS=' ' read -r expected relative; do
    actual="$(shasum -a 256 "$WINE_ROOT/$relative" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] \
        || fail "el PIN post-transform no coincide para $relative"
done <<'EOF'
fed13faa895c9ea5896a6497490db26674c3dca2a318e3389d8e43ba3e00f552 bin/wine
8d14fb9d6d9730c300ba16b5997d98218a2a40a78008d60f3a6edb719f328db3 bin/wineserver
5636a6505e872c8d185d8db7ced2d4aa8e9057e81c4c579e4b623009f9c2857b lib/wine/x86_64-unix/wine
687717fa95835146dfe4b45c6a29d7a82fb37742810fdb4213908dd3176b82e9 lib/wine/x86_64-unix/ntdll.so
EOF

for relative in bin/wine bin/wineserver lib/wine/x86_64-unix/wine lib/wine/x86_64-unix/ntdll.so; do
    cmp -s "$WINE_ROOT/$relative" "$SECOND_WINE_ROOT/$relative" \
        || fail "dos derivaciones no son byte-idénticas: $relative"
    if otool -l "$WINE_ROOT/$relative" \
        | awk '/LC_RPATH/{rpath=1; next} rpath && $1 == "path" { print $2; rpath=0 }' \
        | awk '$0 ~ /^\// && $0 !~ /^\/System\/Library\// && $0 !~ /^\/usr\/lib\// { found=1 } END { exit !found }'; then
        fail "la transformación dejó un LC_RPATH absoluto no permitido: $relative"
    fi
done

if rg -a -F "$ROOT" "$WINE_ROOT" >/dev/null ||
   rg -a -F "$HOME" "$WINE_ROOT" >/dev/null; then
    fail "la transformación dejó rutas personales en el runtime público"
fi

# Fixture del parser real de otool: el campo inmediatamente posterior a
# LC_RPATH es cmdsize, y la ruta llega después. Un rpath Xcode absoluto debe
# clasificarse para eliminación, mientras que los rpaths relativos se conservan.
RPATH_FIXTURE="$SCRATCH/otool-rpath.txt"
printf '%s\n' \
    '          cmd LC_RPATH' \
    '      cmdsize 104' \
    '         path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib (offset 12)' \
    '          cmd LC_RPATH' \
    '      cmdsize 32' \
    '         path @loader_path/ (offset 12)' \
    > "$RPATH_FIXTURE"
parsed_rpaths="$(awk '/LC_RPATH/{rpath=1; next} rpath && $1 == "path" { print $2; rpath=0 }' "$RPATH_FIXTURE")"
first_rpath="$(printf '%s\n' "$parsed_rpaths" | sed -n '1p')"
second_rpath="$(printf '%s\n' "$parsed_rpaths" | sed -n '2p')"
[[ "$first_rpath" == /Applications/Xcode.app/* && "$second_rpath" == '@loader_path/' ]] \
    || fail "el parser LC_RPATH no extrae las rutas reales de otool"
[[ "$first_rpath" == /* && "$first_rpath" != /usr/lib/* && "$first_rpath" != /System/Library/* ]] \
    || fail "un LC_RPATH absoluto de Xcode no se clasifica para eliminación"

printf 'drift\n' >> "$WINE_ROOT/bin/wine"
expect_failure "drift post-transform" \
    'el runtime público no coincide con la transformación derivada: bin/wine' \
    "$TRANSFORM" --verify "$WINE_ROOT"

[[ -f "$CURRENT_ASSET" ]] || fail "falta el asset actual para la regresión post-transform"
CURRENT_EXTRACT="$SCRATCH/current-asset"
mkdir -p "$CURRENT_EXTRACT"
COPYFILE_DISABLE=1 tar --xattrs --no-mac-metadata -xf "$CURRENT_ASSET" -C "$CURRENT_EXTRACT"
"$TRANSFORM" --verify \
    "$CURRENT_EXTRACT/Regression.app/Contents/SharedSupport/wine-root" >/dev/null

# El asset actual debe acreditar la autoridad post-transform. El negativo se aísla
# en una copia temporal: nunca se infiere una regresión a partir de un asset previo.
DRIFT_ASSET_FIXTURE="$SCRATCH/current-asset-drift"
ditto "$CURRENT_EXTRACT" "$DRIFT_ASSET_FIXTURE"
printf 'drift\n' >> "$DRIFT_ASSET_FIXTURE/Regression.app/Contents/SharedSupport/wine-root/bin/wine"
expect_failure "fixture de asset con runtime alterado" \
    'el runtime público no coincide con la transformación derivada: bin/wine' \
    "$TRANSFORM" --verify \
        "$DRIFT_ASSET_FIXTURE/Regression.app/Contents/SharedSupport/wine-root"

PACKAGER_TRANSFORM_CONTRACT="verify-public-runtime-transform-1.12.sh\" --verify \"\$WINE_ROOT\""
/usr/bin/grep -Fq "$PACKAGER_TRANSFORM_CONTRACT" "$PACKAGER" \
    || fail "package_release no verifica la transformación pública derivada"
RPATH_REMOVE_CONTRACT="[[ \"\$rpath\" == /* && \"\$rpath\" != /usr/lib/* && \"\$rpath\" != /System/Library/* ]]"
/usr/bin/grep -Fq "$RPATH_REMOVE_CONTRACT" "$PACKAGER" \
    || fail "package_release no elimina todo LC_RPATH absoluto no-sistema"
ASSET_RPATH_CONTRACT="LC_RPATH absoluto no permitido en \$candidate"
/usr/bin/grep -Fq "$ASSET_RPATH_CONTRACT" "$ASSET_VERIFIER" \
    || fail "verify-release-asset no audita LC_RPATH en todo Mach-O"

printf 'PASS: la autoridad post-transform 1.12 se deriva del builder raw y rechaza drift.\n'
