#!/usr/bin/env bash
# Verifica un candidato local cuyo runtime procede byte a byte de la instalación canónica.
# Deliberadamente no ejecuta Regression, regressionctl, Wine ni ningún helper del bundle.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--baseline-public-1.11" ]]; then
    [[ $# -eq 4 ]] || {
        printf 'ERROR: uso: %s --baseline-public-1.11 ASSET CHECKSUM BASELINE_APP\n' "$0" >&2
        exit 64
    }
    exec "$ROOT/build/verify-installed-runtime-public-1.11-candidate.sh" "$2" "$3" "$4"
fi
ASSET="${1:-}"
CHECKSUM="${2:-}"
BASELINE_APP="${3:-/Applications/Regression.app}"
BASELINE_VERSION="1.10.1"
BASELINE_BUILD_NUMBER="36"
TARGET_VERSION="1.11.0"
TARGET_BUILD_NUMBER="37"
VERIFY_SCRATCH=""
GPTK_PROFILE_LINKS=(
    grim-dawn dragonsword
    dragons-dogma-2/x86_64-unix/atidxx64.so
    dragons-dogma-2/x86_64-unix/d3d11.so
    dragons-dogma-2/x86_64-unix/d3d12.so
    dragons-dogma-2/x86_64-unix/dxgi.so
    dragons-dogma-2/x86_64-windows/atidxx64.dll
    dragons-dogma-2/x86_64-windows/d3d11.dll
    dragons-dogma-2/x86_64-windows/d3d12.dll
    dragons-dogma-2/x86_64-windows/dxgi.dll
)
GPTK_PROFILE_EXCLUSIONS=()
for gptk_profile_link in "${GPTK_PROFILE_LINKS[@]}"; do
    GPTK_PROFILE_EXCLUSIONS+=("wine-root/lib/profiles/$gptk_profile_link")
done

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

verify_hash()
{
    local expected="$1" path="$2" actual
    [[ -f "$path" ]] || fail "falta el recurso candidato: $path"
    actual="$(shasum -a 256 "$path" | awk '{ print $1 }')"
    [[ "$actual" == "$expected" ]] \
        || fail "hash inesperado en $path (esperado $expected, actual $actual)"
}

cleanup()
{
    if [[ -n "$VERIFY_SCRATCH" \
        && "$VERIFY_SCRATCH" == /private/tmp/regression-runtime-candidate-verify.* ]]; then
        find "$VERIFY_SCRATCH" -mindepth 1 -depth -delete
        /bin/rmdir "$VERIFY_SCRATCH" 2>/dev/null || true
    fi
}
trap cleanup EXIT

[[ -f "$ASSET" && -f "$CHECKSUM" ]] \
    || fail "uso: $0 ASSET CHECKSUM [BASELINE_APP]"
[[ -d "$BASELINE_APP" && ! -L "$BASELINE_APP" ]] \
    || fail "el baseline debe ser un bundle físico: $BASELINE_APP"
codesign --verify --deep --strict "$BASELINE_APP"

expected_sha="$(awk 'NR == 1 { print tolower($1) }' "$CHECKSUM")"
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] \
    || fail "el manifiesto no contiene un SHA-256 válido"
actual_sha="$(shasum -a 256 "$ASSET" | awk '{ print tolower($1) }')"
[[ "$actual_sha" == "$expected_sha" ]] || fail "el asset no coincide con su manifiesto"

while IFS= read -r entry; do
    case "$entry" in
        Regression.app|Regression.app/|Regression.app/*) ;;
        *) fail "ruta inesperada en el asset: $entry" ;;
    esac
    case "/$entry/" in
        */../*|*/./*) fail "ruta no normalizada en el asset: $entry" ;;
    esac
done < <(tar -tf "$ASSET")

VERIFY_SCRATCH="$(mktemp -d /private/tmp/regression-runtime-candidate-verify.XXXXXX)"
chmod 700 "$VERIFY_SCRATCH"
tar --xattrs --no-mac-metadata -xf "$ASSET" -C "$VERIFY_SCRATCH" --no-same-owner
CANDIDATE_APP="$VERIFY_SCRATCH/Regression.app"

app_entries()
{
    local app="$1"
    find "$app" -mindepth 1 -maxdepth 1 -print \
        | sed "s#^$app/##" | LC_ALL=C sort
}

contents_entries_without_signature()
{
    local app="$1"
    find "$app/Contents" -mindepth 1 -maxdepth 1 ! -name _CodeSignature -print \
        | sed "s#^$app/Contents/##" | LC_ALL=C sort
}

cmp -s <(app_entries "$BASELINE_APP") <(app_entries "$CANDIDATE_APP") \
    || fail "el candidato cambió la estructura raíz del bundle"
cmp -s \
    <(contents_entries_without_signature "$BASELINE_APP") \
    <(contents_entries_without_signature "$CANDIDATE_APP") \
    || fail "el candidato añadió o eliminó contenido fuera de la firma"
[[ -x "$CANDIDATE_APP/Contents/MacOS/Regression" ]] \
    || fail "falta el ejecutable nativo candidato"
file "$CANDIDATE_APP/Contents/MacOS/Regression" | grep -q 'Mach-O 64-bit.*arm64' \
    || fail "el ejecutable candidato no es Mach-O arm64"
"$ROOT/build/verify-plist-version-promotion.sh" \
    "$BASELINE_APP/Contents/Info.plist" "$CANDIDATE_APP/Contents/Info.plist" \
    "$BASELINE_VERSION" "$BASELINE_BUILD_NUMBER" "$TARGET_VERSION" "$TARGET_BUILD_NUMBER" \
    --remove-apple-events-description \
    >/dev/null
verify_hash 0aa2c39d5476d8b5767d9a1979af5ecaf96f36648cbe15d376a761aad06e7ca4 \
    "$CANDIDATE_APP/Contents/MacOS/regression-engine"
"$ROOT/build/verify-byte-identical-tree.sh" \
    "$BASELINE_APP/Contents/MacOS" \
    "$CANDIDATE_APP/Contents/MacOS" \
    Regression regression-engine >/dev/null
"$ROOT/build/verify-byte-identical-tree.sh" \
    "$BASELINE_APP/Contents/Resources" \
    "$CANDIDATE_APP/Contents/Resources" >/dev/null
"$ROOT/build/verify-byte-identical-tree.sh" \
    "$BASELINE_APP/Contents/SharedSupport" \
    "$CANDIDATE_APP/Contents/SharedSupport" \
    bin/regressionctl bin/install-apple-gptk-component \
    Switch2Bridge/Switch2Bridge.app/Contents/MacOS/Switch2Bridge \
    wine-root/bin/wine wine-root/bin/wineserver \
    wine-root/lib/wine/x86_64-unix/wine \
    wine-root/lib/wine/x86_64-unix/ntdll.so \
    wine-root/lib/dxvk/x86_64-windows/d3d11.dll.bak-gcc16-ucrt-20260726-162839 \
    wine-root/lib/wine/x86_64-unix/winevulkan.so.bak-absolute-toolchain-rpath-20260726-1645 \
    wine-root/lib/profiles/heroes-hammerwatch-2/x86_64-unix/winemac.so \
    wine-root/lib/apple_gptk/ \
    "${GPTK_PROFILE_EXCLUSIONS[@]}" >/dev/null

for removed_laboratory_copy in \
    wine-root/lib/dxvk/x86_64-windows/d3d11.dll.bak-gcc16-ucrt-20260726-162839 \
    wine-root/lib/wine/x86_64-unix/winevulkan.so.bak-absolute-toolchain-rpath-20260726-1645
do
    [[ ! -e "$CANDIDATE_APP/Contents/SharedSupport/$removed_laboratory_copy" ]] \
        || fail "el candidato conserva la copia de laboratorio: $removed_laboratory_copy"
done

# Cada excepción de la transición pública queda sellada explícitamente. No se acepta una
# diferencia genérica entre 1.10.1 y 1.11.0.
verify_hash cfcad4b7ce914877d1a20df4dcd1f2215aac826fdefe2b91483c6c278f5e6690 \
    "$CANDIDATE_APP/Contents/SharedSupport/bin/regressionctl"
verify_hash 291bc4ecf61dc9c7efdebbe9e8e5737baff594ee4bfa626b90b1647a64333073 \
    "$CANDIDATE_APP/Contents/SharedSupport/bin/install-apple-gptk-component"
BRIDGE_APP="$CANDIDATE_APP/Contents/SharedSupport/Switch2Bridge/Switch2Bridge.app"
file "$BRIDGE_APP/Contents/MacOS/Switch2Bridge" | grep -q 'Mach-O 64-bit.*arm64' \
    || fail "Switch2Bridge candidato no es Mach-O arm64"
[[ "$(plutil -extract Switch2BridgeCommit raw "$BRIDGE_APP/Contents/Info.plist")" == \
      "ff2e1a1d99c8529a8f693fa4ab7cf82583cd3d7d" ]] \
    || fail "Switch2Bridge no declara el commit público fijado"
codesign --verify --strict "$BRIDGE_APP"
verify_hash b7bc2eb61356ce14d8a290a4b95b0831185bd8a9b4e53767a3e1299690d4498a \
    "$CANDIDATE_APP/Contents/SharedSupport/wine-root/bin/wine"
verify_hash d893d2e3df2678dfc192dfe102047de8ef4afc009271f33acce4555828eaf4c7 \
    "$CANDIDATE_APP/Contents/SharedSupport/wine-root/bin/wineserver"
verify_hash 44158083e51393abfe42fb9cd0beeb52ba0ca005a919f4303f5af5eb4cf06587 \
    "$CANDIDATE_APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
verify_hash 8fb847f4f71ae120609c963fc588d3ea77b0887f173858c2d462e424a2d8fd8e \
    "$CANDIDATE_APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
verify_hash d86aafb6d73fd472ce4615bad47e97aa51d9a49549e73074b4e17d38968af3e8 \
    "$CANDIDATE_APP/Contents/SharedSupport/wine-root/lib/profiles/heroes-hammerwatch-2/x86_64-unix/winemac.so"

BASELINE_GPTK="$BASELINE_APP/Contents/SharedSupport/wine-root/lib/apple_gptk"
CANDIDATE_GPTK="$CANDIDATE_APP/Contents/SharedSupport/wine-root/lib/apple_gptk"
[[ -d "$BASELINE_GPTK/external/D3DMetal.framework" ]] \
    || fail "el baseline no contiene el GPTK local esperado"
FIRST_CANDIDATE_GPTK_PAYLOAD="$(find "$CANDIDATE_GPTK" \
    \( -type f -o -type l \) -print -quit)"
if [[ -n "$FIRST_CANDIDATE_GPTK_PAYLOAD" ]]; then
    fail "el candidato contiene archivos o enlaces GPTK que no pueden viajar en el asset"
fi
actual_gptk_directories="$(
    cd "$CANDIDATE_GPTK"
    find . -type d -print | LC_ALL=C sort
)"
expected_gptk_directories="$(printf '%s\n' \
    . ./external ./wine ./wine/x86_64-unix ./wine/x86_64-windows | LC_ALL=C sort)"
[[ "$actual_gptk_directories" == "$expected_gptk_directories" ]] \
    || fail "el candidato no contiene únicamente el esqueleto GPTK permitido"
for relative_link in "${GPTK_PROFILE_LINKS[@]}"; do
    baseline_link="$BASELINE_APP/Contents/SharedSupport/wine-root/lib/profiles/$relative_link"
    candidate_link="$CANDIDATE_APP/Contents/SharedSupport/wine-root/lib/profiles/$relative_link"
    [[ -L "$baseline_link" && "$(readlink "$baseline_link")" == *apple_gptk* ]] \
        || fail "el enlace GPTK de referencia es inesperado: $relative_link"
    [[ ! -e "$candidate_link" && ! -L "$candidate_link" ]] \
        || fail "el candidato conserva el enlace GPTK omitido: $relative_link"
done
while IFS= read -r -d '' candidate_link; do
    [[ "$(readlink "$candidate_link")" != /* ]] \
        || fail "el candidato contiene un enlace de perfil absoluto: $candidate_link"
    [[ -e "$candidate_link" ]] \
        || fail "el candidato conserva un enlace de perfil roto: $candidate_link"
done < <(find "$CANDIDATE_APP/Contents/SharedSupport/wine-root/lib/profiles" \
    -type l -print0)

if cmp -s \
    "$BASELINE_APP/Contents/MacOS/Regression" \
    "$CANDIDATE_APP/Contents/MacOS/Regression"; then
    fail "el supuesto candidato conserva el ejecutable nativo anterior"
fi
if cmp -s \
    "$BASELINE_APP/Contents/SharedSupport/bin/regressionctl" \
    "$CANDIDATE_APP/Contents/SharedSupport/bin/regressionctl"; then
    fail "el supuesto candidato conserva regressionctl anterior"
fi
file "$CANDIDATE_APP/Contents/SharedSupport/bin/regressionctl" \
    | grep -q 'Mach-O 64-bit.*arm64' \
    || fail "regressionctl candidato no es Mach-O arm64"
for binary in \
    "$CANDIDATE_APP/Contents/MacOS/Regression" \
    "$CANDIDATE_APP/Contents/SharedSupport/bin/regressionctl"
do
    external_dependencies="$(otool -L "$binary" | tail -n +2 \
        | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/' \
        | grep '^/' | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
    [[ -z "$external_dependencies" ]] \
        || fail "$binary tiene dependencias externas: $external_dependencies"
    codesign --verify --strict "$binary"
done

codesign --verify --deep --strict "$CANDIDATE_APP"
REGRESSION_APP_PATH="$CANDIDATE_APP" \
    "$ROOT/build/verify-public-installed-state.sh" --release-1.11.0
baseline_identifier="$(plutil -extract CFBundleIdentifier raw "$BASELINE_APP/Contents/Info.plist")"
candidate_identifier="$(plutil -extract CFBundleIdentifier raw "$CANDIDATE_APP/Contents/Info.plist")"
[[ "$candidate_identifier" == "$baseline_identifier" ]] \
    || fail "el candidato cambió el identificador del bundle"
signature="$(codesign -dv --verbose=4 "$CANDIDATE_APP" 2>&1 \
    | awk -F= '/^Signature=/ { print $2; exit }')"
candidate_team="$(codesign -dv --verbose=4 "$CANDIDATE_APP" 2>&1 \
    | awk -F= '/^TeamIdentifier=/ { print $2; exit }')"
[[ "$signature" == "adhoc" && "$candidate_team" == "not set" ]] \
    || fail "la release pública transporta una identidad de firma"
if rg -a -l '/Users/adrianpereradelgado|aperdel\.esi@gmail\.com' \
    "$CANDIDATE_APP" >/dev/null; then
    fail "la release pública contiene identidad local"
fi

for entitlement in \
    'com.apple.security.cs.allow-unsigned-executable-memory' \
    'com.apple.security.device.audio-input' \
    'com.apple.security.device.camera'
do
    entitlement_key="${entitlement//./\\.}"
    value="$(codesign -d --entitlements :- "$CANDIDATE_APP" 2>/dev/null \
        | plutil -extract "$entitlement_key" raw -o - -- -)"
    [[ "$value" == "true" ]] || fail "la firma perdió la capacidad $entitlement"
done
if codesign -d --entitlements :- "$CANDIDATE_APP" 2>/dev/null \
    | plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - -- - \
        >/dev/null 2>&1; then
    fail "la release conserva una capacidad de Apple Events no autorizada"
fi

printf 'Candidato local verificado sin ejecutar código: %s\n' "$actual_sha"
