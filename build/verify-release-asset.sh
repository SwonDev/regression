#!/usr/bin/env bash
# Audita el artefacto que recibirá un Mac limpio, no el bundle de desarrollo.
set -Eeuo pipefail

ASSET="${1:-}"
CHECKSUM="${2:-}"
EXPECTED_VERSION="${3:-}"
PUBLIC_WINE_PREFIX="/Applications/Regression.app/Contents/SharedSupport/wine-root"
WORK_DIR=""

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup_path()
{
    local target="$1"
    [[ -n "$target" && ( -e "$target" || -L "$target" ) ]] || return 0
    find "$target" -depth -delete
}

cleanup()
{
    if [[ -n "$WORK_DIR" && "$WORK_DIR" == /private/tmp/regression-release-verify.* ]]; then
        cleanup_path "$WORK_DIR"
    fi
}
trap cleanup EXIT

[[ -f "$ASSET" && -f "$CHECKSUM" && -n "$EXPECTED_VERSION" ]] \
    || fail "uso: $0 ASSET CHECKSUM VERSION"

EXPECTED_SHA="$(awk 'NR == 1 { print tolower($1) }' "$CHECKSUM")"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "el manifiesto no contiene un SHA-256 válido"
ACTUAL_SHA="$(shasum -a 256 "$ASSET" | awk '{print tolower($1)}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || fail "el asset no coincide con su manifiesto"

while IFS= read -r entry; do
    case "$entry" in
        Regression.app|Regression.app/|Regression.app/*) ;;
        *) fail "ruta inesperada en el asset: $entry" ;;
    esac
    case "/$entry/" in
        */../*|*/./*) fail "ruta no normalizada en el asset: $entry" ;;
    esac
done < <(tar -tf "$ASSET")

WORK_DIR="$(mktemp -d /private/tmp/regression-release-verify.XXXXXX)"
chmod 700 "$WORK_DIR"
tar --xattrs --no-mac-metadata -xf "$ASSET" -C "$WORK_DIR" --no-same-owner
APP="$WORK_DIR/Regression.app"
WINE_ROOT="$APP/Contents/SharedSupport/wine-root"
MEDIA_ROOT="$APP/Contents/SharedSupport/components/windows-media/1"

[[ -x "$APP/Contents/MacOS/Regression" ]] || fail "falta el ejecutable nativo"
[[ -x "$APP/Contents/MacOS/regression-engine" ]] || fail "falta el lanzador del motor propio"
[[ -x "$APP/Contents/SharedSupport/bin/regressionctl" ]] || fail "falta regressionctl"
[[ -x "$APP/Contents/SharedSupport/bin/install-windows-media-component" ]] \
    || fail "falta la autorreparación Windows Media"
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$EXPECTED_VERSION" ]] \
    || fail "la versión del bundle no coincide con $EXPECTED_VERSION"

for binary in \
    "$WINE_ROOT/bin/wine" \
    "$WINE_ROOT/bin/wineserver" \
    "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
do
    [[ -x "$binary" ]] || fail "falta el binario público $binary"
    file "$binary" | rg -q 'Mach-O 64-bit.*x86_64' || fail "$binary no es x86_64"
    if strings -a "$binary" \
        | grep -E '/Users/[^/]+/.*Regression\.app|/opt/regression/src_*/Regression\.app' \
            >/dev/null; then
        fail "$binary contiene un prefijo de aplicación no instalable"
    fi
done

NTDLL="$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
for required in \
    "$PUBLIC_WINE_PREFIX/bin" \
    "$PUBLIC_WINE_PREFIX/lib/wine" \
    "$PUBLIC_WINE_PREFIX/share/wine" \
    REGRESSION_BOOTSTRAP_REDIRECT_COUNT \
    REGRESSION_WINDOWS_MEDIA_PROFILE
do
    strings -a "$NTDLL" | grep -F "$required" >/dev/null \
        || fail "ntdll.so no contiene el contrato público: $required"
done

for architecture in x86_64-windows i386-windows; do
    for runtime in vcruntime140.dll msvcp140.dll ucrtbase.dll; do
        [[ -f "$WINE_ROOT/lib/wine/$architecture/$runtime" ]] \
            || fail "falta $runtime para $architecture"
    done
done
[[ -f "$WINE_ROOT/lib/wine/x86_64-windows/vcruntime140_1.dll" ]] \
    || fail "falta vcruntime140_1.dll x64"

[[ -f "$MEDIA_ROOT/gstreamer-1.0/libgstasf.dylib" \
    && -f "$MEDIA_ROOT/gstreamer-1.0/libgstlibav.dylib" \
    && -f "$MEDIA_ROOT/manifest.sha256" ]] \
    || fail "el componente Windows Media está incompleto"
(
    cd "$MEDIA_ROOT"
    shasum -a 256 -c manifest.sha256 >/dev/null
) || fail "el componente Windows Media no supera su manifiesto"
codesign --verify --strict "$MEDIA_ROOT/gstreamer-1.0/libgstasf.dylib"
codesign --verify --strict "$MEDIA_ROOT/gstreamer-1.0/libgstlibav.dylib"

if find "$WINE_ROOT/lib/apple_gptk" -type f | grep -q .; then
    fail "el asset redistribuye binarios del GPTK"
fi
if rg -a -l '/Users/adrianpereradelgado|aperdel\.esi@gmail\.com' "$APP" >/dev/null; then
    fail "el asset contiene identidad local"
fi
if find "$APP" -type f \( -name '*.bak' -o -name '*.before-*' \) | grep -q .; then
    fail "el asset contiene copias de laboratorio"
fi
while IFS= read -r -d '' link; do
    [[ "$(readlink "$link")" != /* ]] || fail "enlace absoluto en el asset: $link"
done < <(find "$APP" -type l -print0)

while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q 'Mach-O' || continue
    external="$(otool -L "$candidate" | tail -n +2 \
        | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/' \
        | grep '^/' | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
    [[ -z "$external" ]] || fail "dependencia externa en $candidate: $external"
done < <(find "$APP" -type f -print0)

codesign --verify --deep --strict "$APP"
printf 'Asset público Regression %s verificado: %s\n' "$EXPECTED_VERSION" "$ACTUAL_SHA"
