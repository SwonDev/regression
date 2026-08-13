#!/usr/bin/env bash
# Sella por separado los dos extremos permitidos de la transición pública 1.11 -> 1.11.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE="${1:-}"
APP="${2:-}"
WINE_ROOT="$APP/Contents/SharedSupport/wine-root"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
verify_hash() {
    local expected="$1" path="$2" actual
    [[ -f "$path" && ! -L "$path" ]] || fail "falta el recurso físico: $path"
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] \
        || fail "hash $ROLE inesperado en $path (esperado $expected, actual $actual)"
}

case "$ROLE" in
    baseline)
        EXPECTED_MAIN="f8cf83b1437b654c29de47e2680491caf03d3819bc001c7c5817c767474e955f"
        EXPECTED_CTL="da76a6b127a02a055b31740293b1cb188b249d1060cdbc0bcdf4b870329d0abf"
        ;;
    candidate)
        EXPECTED_MAIN="8376d99193b600dc13c955605a2cb5e3a92284965e2ceb4e734e639ed41e300e"
        EXPECTED_CTL="1e03b01193db62bebcff35d31a1af85085eac1780d121fedd14c72318597fca9"
        ;;
    *) fail "rol desconocido; usa baseline o candidate" ;;
esac

[[ -d "$APP" && ! -L "$APP" ]] || fail "el bundle $ROLE debe ser físico"
[[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" == \
    "local.regression.launcher" ]] || fail "bundle ID $ROLE inesperado"
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == \
    "1.11.0" ]] || fail "versión $ROLE inesperada"
[[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "37" ]] \
    || fail "build $ROLE inesperado"

verify_hash "$EXPECTED_MAIN" "$APP/Contents/MacOS/Regression"
verify_hash "$EXPECTED_CTL" "$APP/Contents/SharedSupport/bin/regressionctl"
verify_hash 0aa2c39d5476d8b5767d9a1979af5ecaf96f36648cbe15d376a761aad06e7ca4 \
    "$APP/Contents/MacOS/regression-engine"
verify_hash 291bc4ecf61dc9c7efdebbe9e8e5737baff594ee4bfa626b90b1647a64333073 \
    "$APP/Contents/SharedSupport/bin/install-apple-gptk-component"
verify_hash c43da8ed5b54d6c663a5455d4296accde8d96f5237384f9322bea548e5c6d00d \
    "$APP/Contents/SharedSupport/bin/install-windows-media-component"
verify_hash 8fb847f4f71ae120609c963fc588d3ea77b0887f173858c2d462e424a2d8fd8e \
    "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
verify_hash da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3 \
    "$APP/Contents/SharedSupport/components/windows-media/1/manifest.sha256"
(
    cd "$APP/Contents/SharedSupport/components/windows-media/1"
    shasum -a 256 -c manifest.sha256 >/dev/null
) || fail "Windows Media $ROLE no supera su manifiesto"

GPTK="$WINE_ROOT/lib/apple_gptk"
[[ -d "$GPTK" && ! -L "$GPTK" ]] || fail "falta el esqueleto GPTK $ROLE"
first_gptk_payload="$(find "$GPTK" \( -type f -o -type l \) -print -quit)"
[[ -z "$first_gptk_payload" ]] || fail "el $ROLE contiene payload o enlaces GPTK"
actual_gptk_dirs="$(cd "$GPTK" && find . -type d -print | LC_ALL=C sort)"
expected_gptk_dirs="$(printf '%s\n' . ./external ./wine ./wine/x86_64-unix \
    ./wine/x86_64-windows | LC_ALL=C sort)"
[[ "$actual_gptk_dirs" == "$expected_gptk_dirs" ]] \
    || fail "el esqueleto GPTK $ROLE contiene rutas inesperadas"
gptk_profiles=""
while IFS= read -r -d '' profile_link; do
    case "$(readlink "$profile_link")" in
        *apple_gptk*) gptk_profiles+="${gptk_profiles:+$'\n'}$profile_link" ;;
    esac
done < <(find "$WINE_ROOT/lib/profiles" -type l -print0)
[[ -z "$gptk_profiles" ]] || fail "el $ROLE conserva enlaces de perfil a GPTK"

file "$APP/Contents/MacOS/Regression" | grep -q 'Mach-O 64-bit.*arm64' \
    || fail "Regression $ROLE no es arm64"
file "$APP/Contents/SharedSupport/bin/regressionctl" | grep -q 'Mach-O 64-bit.*arm64' \
    || fail "regressionctl $ROLE no es arm64"
BRIDGE="$APP/Contents/SharedSupport/Switch2Bridge/Switch2Bridge.app"
if [[ "$ROLE" == "baseline" ]]; then
    EXPECTED_BRIDGE="893e94b3e448a57606dd3d821764fa2dc39202b15011356cf6e495a7bcf7348b"
else
    EXPECTED_BRIDGE="c93b8d243487347ad56a27b94a90bccc937f7f4cab13ee493c205b7300101c4f"
fi
verify_hash "$EXPECTED_BRIDGE" "$BRIDGE/Contents/MacOS/Switch2Bridge"
[[ "$(plutil -extract CFBundleIdentifier raw "$BRIDGE/Contents/Info.plist")" == \
    "dev.swondev.switch2bridge" ]] || fail "Switch2Bridge $ROLE tiene bundle ID inesperado"
[[ "$(plutil -extract CFBundleShortVersionString raw "$BRIDGE/Contents/Info.plist")" == \
    "1.0.0" ]] || fail "Switch2Bridge $ROLE tiene versión inesperada"
[[ "$(plutil -extract CFBundleVersion raw "$BRIDGE/Contents/Info.plist")" == "1" ]] \
    || fail "Switch2Bridge $ROLE tiene build inesperado"
[[ "$(plutil -extract Switch2BridgeCommit raw "$BRIDGE/Contents/Info.plist")" == \
    "ff2e1a1d99c8529a8f693fa4ab7cf82583cd3d7d" ]] \
    || fail "Switch2Bridge $ROLE no declara el commit fijado"
file "$BRIDGE/Contents/MacOS/Switch2Bridge" | grep -q 'Mach-O 64-bit.*arm64' \
    || fail "Switch2Bridge $ROLE no es arm64"
codesign --verify --strict "$BRIDGE"
bridge_signature="$(codesign -dv --verbose=4 "$BRIDGE" 2>&1 \
    | awk -F= '/^Signature=/ {print $2; exit}')"
bridge_team="$(codesign -dv --verbose=4 "$BRIDGE" 2>&1 \
    | awk -F= '/^TeamIdentifier=/ {print $2; exit}')"
[[ "$bridge_signature" == "adhoc" && "$bridge_team" == "not set" ]] \
    || fail "Switch2Bridge $ROLE transporta identidad de firma"
bridge_entitlements="$(codesign -d --entitlements :- "$BRIDGE" 2>/dev/null || true)"
if [[ -n "$bridge_entitlements" ]]; then
    fail "Switch2Bridge $ROLE declara entitlements inesperados"
fi
bridge_external="$(otool -L "$BRIDGE/Contents/MacOS/Switch2Bridge" | tail -n +2 \
    | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/' \
    | grep '^/' | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
[[ -z "$bridge_external" ]] || fail "Switch2Bridge $ROLE tiene dependencias externas: $bridge_external"
codesign --verify --deep --strict "$APP"
REGRESSION_APP_PATH="$APP" "$ROOT/build/verify-public-installed-state.sh" --release-1.11.0

if [[ "$ROLE" == "candidate" ]]; then
    signature="$(codesign -dv --verbose=4 "$APP" 2>&1 \
        | awk -F= '/^Signature=/ {print $2; exit}')"
    team="$(codesign -dv --verbose=4 "$APP" 2>&1 \
        | awk -F= '/^TeamIdentifier=/ {print $2; exit}')"
    [[ "$signature" == "adhoc" && "$team" == "not set" ]] \
        || fail "el candidato transporta una identidad de firma"
    for entitlement in \
        'com.apple.security.cs.allow-unsigned-executable-memory' \
        'com.apple.security.device.audio-input' \
        'com.apple.security.device.camera'
    do
        key="${entitlement//./\\.}"
        value="$(codesign -d --entitlements :- "$APP" 2>/dev/null \
            | plutil -extract "$key" raw -o - -- -)"
        [[ "$value" == "true" ]] || fail "falta el entitlement $entitlement"
    done
    if codesign -d --entitlements :- "$APP" 2>/dev/null \
        | plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - -- - \
            >/dev/null 2>&1; then
        fail "el candidato conserva Apple Events"
    fi
fi

printf 'Bundle %s público 1.11 verificado.\n' "$ROLE"
