#!/usr/bin/env bash
# Audita el artefacto que recibirá un Mac limpio, no el bundle de desarrollo.
set -Eeuo pipefail

ASSET="${1:-}"
CHECKSUM="${2:-}"
EXPECTED_VERSION="${3:-}"
EXPECTED_BUILD="${4:-}"
PUBLIC_WINE_PREFIX="/Applications/Regression.app/Contents/SharedSupport/wine-root"
WORK_DIR=""

# REGRESSION_RELEASE_AUTHORITY_V2_BEGIN
EXPECTED_MEDIA_MANIFEST_SHA256="da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3"
EXPECTED_ENGINE_SHA256="38be0b5fd0bed42e5467f9a61c5c972733898523eeac3e34e83eb5317efb3edf"
EXPECTED_GPTK_INSTALLER_SHA256="f6bcd552320e3713693d0a0bbf1af4932b573fc35798282c1724f2b52a688660"
# Hashes del ensemble público derivados del builder raw sellado mediante strip,
# saneado literal y firma ad hoc del staging.
release_runtime_authority_v2()
{
    cat <<'EOF'
fed13faa895c9ea5896a6497490db26674c3dca2a318e3389d8e43ba3e00f552 bin/wine
8d14fb9d6d9730c300ba16b5997d98218a2a40a78008d60f3a6edb719f328db3 bin/wineserver
5636a6505e872c8d185d8db7ced2d4aa8e9057e81c4c579e4b623009f9c2857b lib/wine/x86_64-unix/wine
f17cebf085a0a746224e61b4fc49341f7a0cec48741c5f12d1cc84a4dcd0ba5d lib/wine/x86_64-unix/ntdll.so
0315a55b11a456590a9368f4cb8d0011d6735cc04c9093ea583570d1352e1ee1 share/wine/wine.inf
885c0421bfe30600bae9df83961b0fcbb5b9ccd1c02e7b071ce213ff2522e34a lib/wine/x86_64-windows/ntdll.dll
7b580e19eb4fce14b5730cd2835c5204dc2622ce0fc4f33b68b0155864477667 lib/wine/i386-windows/ntdll.dll
f03a7c92ed8cda87fc0bf72a5af29962d26ca981b546b3ce0550fb57ca3ee7ff lib/wine/x86_64-windows/vcruntime140.dll
2a53d2db7e7b760d2b1d7ecd46b05653e11850363a10b097303d3491aaa4e94a lib/wine/x86_64-windows/msvcp140.dll
019e4bebf86cc4642fff63bc371223280ddfb0306ff379b04fe3f4dc2311ad22 lib/wine/x86_64-windows/ucrtbase.dll
69e58956261ae1081a6429c3813b143689f29849ffb693eb4fee399f335e4608 lib/wine/x86_64-windows/vcruntime140_1.dll
02037225c495c37747ae4cde08de6ff31119b850997799fa27237ca61bed7b35 lib/wine/i386-windows/vcruntime140.dll
2727caf41f37eec4141c891e42365e261cc909b01d0ae568b12b9bf2fdcffa85 lib/wine/i386-windows/msvcp140.dll
935fbefeb5462924e628df486ebfdad49b70a91154c9a8a57d9aa221fc91c119 lib/wine/i386-windows/ucrtbase.dll
EOF
}
# REGRESSION_RELEASE_AUTHORITY_V2_END

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

verify_archive_metadata()
{
    local archive="$1"

    /usr/bin/python3 - "$archive" <<'PY'
import sys
import tarfile

archive = sys.argv[1]
allowed_regular_modes = {0o644, 0o755}
info_plist = "Regression.app/Contents/Info.plist"
found_info_plist = False
with tarfile.open(archive, "r:gz") as tar:
    for member in tar:
        metadata = (member.uid, member.gid, member.uname, member.gname)
        if metadata != (0, 0, "root", "wheel"):
            raise SystemExit(
                "ERROR: header con metadata no neutral en "
                f"{member.name}: uid={member.uid} gid={member.gid} "
                f"uname={member.uname!r} gname={member.gname!r}"
            )
        if member.name == info_plist:
            found_info_plist = True
            if not member.isfile() or (member.mode & 0o777) != 0o644:
                raise SystemExit(
                    "ERROR: Contents/Info.plist debe ser un fichero regular 0644 en el asset"
                )
        if member.isfile() and (member.mode & 0o777) not in allowed_regular_modes:
            raise SystemExit(
                "ERROR: fichero regular con modo no público en "
                f"{member.name}: {member.mode & 0o777:04o}"
            )
if not found_info_plist:
    raise SystemExit("ERROR: falta Contents/Info.plist en los headers del asset")
PY
}

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

# El productor fija todos los headers pax a 0:0 root:wheel. Auditar el tar real
# antes de extraerlo impide que una identidad local o un modo privado sobrevivan
# aunque el contenido del bundle sea correcto.
verify_archive_metadata "$ASSET"

if [[ "${REGRESSION_RELEASE_ARCHIVE_METADATA_ONLY:-0}" == "1" ]]; then
    printf 'Metadata pública del asset verificada: %s\n' "$ACTUAL_SHA"
    exit 0
fi

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
[[ "$(shasum -a 256 "$APP/Contents/MacOS/regression-engine" | awk '{print $1}')" \
    == "$EXPECTED_ENGINE_SHA256" ]] \
    || fail "el lanzador público no coincide con la autoridad 1.12.1"
[[ "$(shasum -a 256 "$APP/Contents/SharedSupport/bin/install-apple-gptk-component" \
    | awk '{print $1}')" == "$EXPECTED_GPTK_INSTALLER_SHA256" ]] \
    || fail "el onboarding GPTK público no coincide con la autoridad 1.12.1"
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
    rpaths="$(otool -l "$binary" \
        | awk '/LC_RPATH/{rpath=1; next} rpath && $1 == "path" { print $2; rpath=0 }')"
    if awk '$0 ~ /^\// && $0 !~ /^\/System\/Library\// && $0 !~ /^\/usr\/lib\// { found=1 } END { exit !found }' \
        <<< "$rpaths"; then
        fail "$binary conserva un LC_RPATH absoluto no permitido"
    fi
    case "${binary#"$WINE_ROOT/"}" in
        bin/wine|bin/wineserver|lib/wine/x86_64-unix/wine)
            [[ -z "$rpaths" ]] || fail "$binary conserva un LC_RPATH no portable"
            ;;
        lib/wine/x86_64-unix/ntdll.so)
            [[ "$rpaths" == "@loader_path/" ]] \
                || fail "$binary no conserva exclusivamente @loader_path/"
            ;;
    esac
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
    REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT \
    REGRESSION_WINDOWS_MEDIA_PROFILE \
    REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_COUNT \
    compiled-repair-activations-v1.tsv
do
    strings -a "$NTDLL" | grep -F "$required" >/dev/null \
        || fail "ntdll.so no contiene el contrato público: $required"
done

if strings -a "$NTDLL" \
    | grep -E 'REGRESSION_EXTERNAL_D3DMETAL_(EXECUTABLE|WINE_ROOT)' >/dev/null; then
    fail "ntdll.so aún acepta la ruta GPTK genérica heredada"
fi

while IFS=' ' read -r expected relative; do
    [[ "$(shasum -a 256 "$WINE_ROOT/$relative" 2>/dev/null | awk '{print $1}')" == "$expected" ]] \
        || fail "el redistribuible sellado no coincide: $relative"
done < <(release_runtime_authority_v2)

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
    rpaths="$(otool -l "$candidate" \
        | awk '/LC_RPATH/{rpath=1; next} rpath && $1 == "path" { print $2; rpath=0 }')"
    if awk '$0 ~ /^\// && $0 !~ /^\/System\/Library\// && $0 !~ /^\/usr\/lib\// { found=1 } END { exit !found }' \
        <<< "$rpaths"; then
        fail "LC_RPATH absoluto no permitido en $candidate"
    fi
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
