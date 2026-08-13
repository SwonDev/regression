#!/usr/bin/env bash
# Audita el artefacto que recibirá un Mac limpio, no el bundle de desarrollo.
set -Eeuo pipefail

ASSET="${1:-}"
CHECKSUM="${2:-}"
EXPECTED_VERSION="${3:-}"
EXPECTED_BUILD="${4:-}"
PUBLIC_WINE_PREFIX="/Applications/Regression.app/Contents/SharedSupport/wine-root"
WORK_DIR=""

# REGRESSION_RELEASE_AUTHORITY_V1_BEGIN
EXPECTED_MEDIA_MANIFEST_SHA256="da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3"
release_runtime_authority_v1()
{
    cat <<'EOF'
f03a7c92ed8cda87fc0bf72a5af29962d26ca981b546b3ce0550fb57ca3ee7ff lib/wine/x86_64-windows/vcruntime140.dll
2a53d2db7e7b760d2b1d7ecd46b05653e11850363a10b097303d3491aaa4e94a lib/wine/x86_64-windows/msvcp140.dll
019e4bebf86cc4642fff63bc371223280ddfb0306ff379b04fe3f4dc2311ad22 lib/wine/x86_64-windows/ucrtbase.dll
69e58956261ae1081a6429c3813b143689f29849ffb693eb4fee399f335e4608 lib/wine/x86_64-windows/vcruntime140_1.dll
02037225c495c37747ae4cde08de6ff31119b850997799fa27237ca61bed7b35 lib/wine/i386-windows/vcruntime140.dll
2727caf41f37eec4141c891e42365e261cc909b01d0ae568b12b9bf2fdcffa85 lib/wine/i386-windows/msvcp140.dll
935fbefeb5462924e628df486ebfdad49b70a91154c9a8a57d9aa221fc91c119 lib/wine/i386-windows/ucrtbase.dll
EOF
}
# REGRESSION_RELEASE_AUTHORITY_V1_END

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

relative_link_stays_within_root()
{
    local root="$1"
    local link="$2"
    local relative base target combined part depth=0
    local parts=()

    case "$link" in
        "$root"/*) relative="${link#"$root"/}" ;;
        *) return 1 ;;
    esac
    target="$(/usr/bin/readlink "$link")" || return 1
    [[ -n "$target" && "$target" != /* ]] || return 1
    if [[ "$relative" == */* ]]; then
        base="${relative%/*}"
    else
        base=""
    fi
    combined="$base/$target"
    IFS='/' read -r -a parts <<< "$combined"
    for part in "${parts[@]}"; do
        case "$part" in
            ''|.) ;;
            ..)
                (( depth > 0 )) || return 1
                depth=$((depth - 1))
                ;;
            *) depth=$((depth + 1)) ;;
        esac
    done
}

verify_confined_symlinks()
{
    local root="$1"
    local link

    [[ -d "$root" && ! -L "$root" ]] || fail \
        "la raíz auditada no es un directorio físico: $root"
    while IFS= read -r -d '' link; do
        relative_link_stays_within_root "$root" "$link" || fail \
            "un enlace simbólico escapa del bundle: $link -> $(/usr/bin/readlink "$link")"
    done < <(/usr/bin/find "$root" -type l -print0)
}

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

[[ -f "$ASSET" && -f "$CHECKSUM" && -n "$EXPECTED_VERSION" && -n "$EXPECTED_BUILD" ]] \
    || fail "uso: $0 ASSET CHECKSUM VERSION BUILD"

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

verify_confined_symlinks "$APP"
FIRST_LABORATORY_COPY="$(find "$APP" -type f \
    \( -name '*.bak*' -o -name '*.before-*' \) -print -quit)"
if [[ -n "$FIRST_LABORATORY_COPY" ]]; then
    fail "el asset contiene copias de laboratorio"
fi

[[ -x "$APP/Contents/MacOS/Regression" ]] || fail "falta el ejecutable nativo"
[[ -x "$APP/Contents/MacOS/regression-engine" ]] || fail "falta el lanzador del motor propio"
[[ -x "$APP/Contents/SharedSupport/bin/regressionctl" ]] || fail "falta regressionctl"
[[ -x "$APP/Contents/SharedSupport/bin/install-windows-media-component" ]] \
    || fail "falta la autorreparación Windows Media"
[[ -x "$APP/Contents/SharedSupport/bin/install-apple-gptk-component" ]] \
    || fail "falta el onboarding y verificador Apple GPTK"
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$EXPECTED_VERSION" ]] \
    || fail "la versión del bundle no coincide con $EXPECTED_VERSION"
[[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "$EXPECTED_BUILD" ]] \
    || fail "el build del bundle no coincide con $EXPECTED_BUILD"

for binary in \
    "$WINE_ROOT/bin/wine" \
    "$WINE_ROOT/bin/wineserver" \
    "$WINE_ROOT/lib/wine/x86_64-unix/wine" \
    "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
do
    [[ -x "$binary" ]] || fail "falta el binario público $binary"
    [[ "$(/usr/bin/file "$binary")" =~ Mach-O[[:space:]]64-bit.*x86_64 ]] \
        || fail "$binary no es x86_64"
    if strings -a "$binary" \
        | grep -E '/Users/[^/]+/.*Regression\.app|/opt/regression/src_*/Regression\.app' \
            >/dev/null; then
        fail "$binary contiene un prefijo de aplicación no instalable"
    fi
done


for required in "$PUBLIC_WINE_PREFIX/bin" "$PUBLIC_WINE_PREFIX/lib"; do
    strings -a "$WINE_ROOT/bin/wine" | grep -F "$required" >/dev/null \
        || fail "el wrapper Wine no contiene la ruta pública requerida: $required"
done

NTDLL="$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
for required in \
    "$PUBLIC_WINE_PREFIX/bin" \
    "$PUBLIC_WINE_PREFIX/lib/wine" \
    "$PUBLIC_WINE_PREFIX/share/wine" \
    REGRESSION_BOOTSTRAP_REDIRECT_COUNT \
    REGRESSION_WINDOWS_MEDIA_PROFILE \
    REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_COUNT \
    compiled-repair-activations-v1.tsv
do
    strings -a "$NTDLL" | grep -F "$required" >/dev/null \
        || fail "ntdll.so no contiene el contrato público: $required"
done

while IFS=' ' read -r expected relative; do
    [[ "$(shasum -a 256 "$WINE_ROOT/$relative" 2>/dev/null | awk '{print $1}')" == "$expected" ]] \
        || fail "el redistribuible sellado no coincide: $relative"
done < <(release_runtime_authority_v1)

[[ -f "$MEDIA_ROOT/gstreamer-1.0/libgstasf.dylib" \
    && -f "$MEDIA_ROOT/gstreamer-1.0/libgstlibav.dylib" \
    && -f "$MEDIA_ROOT/manifest.sha256" ]] \
    || fail "el componente Windows Media está incompleto"
(
    cd "$MEDIA_ROOT"
    shasum -a 256 -c manifest.sha256 >/dev/null
) || fail "el componente Windows Media no supera su manifiesto"
[[ "$(shasum -a 256 "$MEDIA_ROOT/manifest.sha256" | awk '{print $1}')" == \
    "$EXPECTED_MEDIA_MANIFEST_SHA256" ]] \
    || fail "el manifiesto Windows Media no coincide con la autoridad pública compilada"
codesign --verify --strict "$MEDIA_ROOT/gstreamer-1.0/libgstasf.dylib"
codesign --verify --strict "$MEDIA_ROOT/gstreamer-1.0/libgstlibav.dylib"

FIRST_GPTK_FILE="$(find "$WINE_ROOT/lib/apple_gptk" -type f -print -quit)"
if [[ -n "$FIRST_GPTK_FILE" ]]; then
    fail "el asset redistribuye binarios del GPTK"
fi
if /usr/bin/grep -a -R -E -l \
    '/Users/adrianpereradelgado|aperdel\.esi@gmail\.com' "$APP" >/dev/null; then
    fail "el asset contiene identidad local"
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

for entitlement in \
    'com.apple.security.cs.allow-unsigned-executable-memory' \
    'com.apple.security.device.audio-input' \
    'com.apple.security.device.camera'
do
    entitlement_key="${entitlement//./\\.}"
    value="$(codesign -d --entitlements :- "$APP" 2>/dev/null \
        | plutil -extract "$entitlement_key" raw -o - -- -)"
    [[ "$value" == "true" ]] || fail "la firma perdió la capacidad $entitlement"
done
if codesign -d --entitlements :- "$APP" 2>/dev/null \
    | plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - -- - \
        >/dev/null 2>&1; then
    fail "la release conserva una capacidad de Apple Events no autorizada"
fi

SMOKE_PREFIX="$WORK_DIR/wine-smoke-prefix"
WINE_VERSION="$(env WINEPREFIX="$SMOKE_PREFIX" WINEDEBUG=-all \
    /usr/bin/arch -x86_64 "$WINE_ROOT/bin/wine" --version 2>&1)" \
    || fail "el arranque público de Wine no puede cargar ntdll.so"
[[ "$WINE_VERSION" == wine-* ]] \
    || fail "el arranque público de Wine devolvió una versión inesperada: $WINE_VERSION"
printf 'Asset público Regression %s (%s) verificado: %s\n' \
    "$EXPECTED_VERSION" "$EXPECTED_BUILD" "$ACTUAL_SHA"
